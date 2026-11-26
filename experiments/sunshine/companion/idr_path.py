"""Opt-in numeric IDR tracing for the isolated Windows benchmark; CLI reads archives only."""
import argparse
import base64
from bisect import bisect_left, bisect_right
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import threading
import time
from typing import NamedTuple
import zlib

from udp_broker import TRACE_LIMIT, TRACE_EPOCHS


# A matched upstream control message is not proof of an encoded picture. The
# NVENC message is issued for NV_ENC_PIC_TYPE_IDR (not merely a force-IDR flag).
PREFIX = re.compile(r"\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}\]: (Debug|Info): ([^\r\n]*)", re.ASCII)
ENCODED = re.compile(r"NvEnc: idr frame ([1-9][0-9]{0,8})")
CONTROL_KIND = {'type [IDX_REQUEST_IDR_FRAME]': 0, 'type [IDX_INVALIDATE_REF_FRAMES]': 2}
U32 = 0xffffffff
LEGACY_LIMIT = 2048
# The old budget filled in ~105 s in a real WAN recovery storm. Allow two
# markers per frame for ten minutes at 60 Hz with headroom, still bounded.
LIMIT = 131072
MARK = struct.Struct('<QBI')   # monotonic observation ms, allowlisted type, frame
MAX_SIDECAR = 8 * 1024 * 1024
RECORD = struct.Struct('<BIIQQ')  # first two kinds: encrypted video ingress and accepted UDP send


def private_debug_config(config, runtime, *, active=True):
    # The stock binary always opens a second log sink and rotates its siblings.
    # An ordinary debug log contains arbitrary upstream strings. Use only the
    # verified Windows null character device in this *owned* temporary folder.
    null = runtime / 'NUL'
    if os.name != 'nt' or not runtime.is_absolute() or not runtime.name.startswith('session-'):
        raise ValueError('idr_private_windows_sink_required')
    if any(p.name.partition('.')[0].upper() == 'NUL' for p in runtime.iterdir()):
        raise ValueError('idr_log_path_conflict')
    with null.open('rb', buffering=0) as h:
        if not stat.S_ISCHR(os.fstat(h.fileno()).st_mode):
            raise ValueError('idr_log_sink_not_device')
    old = {'min_log_level': 'info', 'log_path': (runtime / 'sunshine.log').as_posix()}
    new = {'min_log_level': 'debug' if active else 'info', 'log_path': null.as_posix()}
    lines = config.splitlines()
    for key, val in old.items():
        idx = [i for i, line in enumerate(lines) if line.partition('=')[0].strip() == key]
        if len(idx) != 1 or lines[idx[0]] != f'{key} = {val}':
            raise ValueError('idr_unrecognized_test_config')
        lines[idx[0]] = f'{key} = {new[key]}'
    return '\n'.join(lines)+'\n'


class HostMarkers:
    def __init__(self):
        self.lock = threading.Lock()
        self.origin = None
        self.open = False
        self.sessions = 0
        self.invalid = False
        self.rows = bytearray()      # at most 1.625 MiB of numeric records while streaming
        self.truncated = False
        self.totals = [0, 0, 0]
        self.last_frame = 0

    def arm(self):
        with self.lock:
            if self.origin is not None and self.sessions:
                self.invalid = True  # never join frame IDs across launches
            self.origin = time.monotonic_ns()

    def observe(self, line):
        # Never copy unknown debug text, wrapped lines, PTS, addresses or keys
        # to the base host's in-memory log or the persisted marker ledger.
        m = PREFIX.fullmatch(line.rstrip('\r\n')) if len(line) <= 512 else None
        if not m:
            return False
        level, msg = m.groups()
        if level == 'Info' and msg.startswith('NvEnc: created encoder v'):
            return True  # carry only this bit for the existing capture check
        with self.lock:
            if self.origin is None or self.invalid:
                return False
            if (level,msg) == ('Info','CLIENT CONNECTED'):
                self.sessions += 1
                self.open = True
                self.invalid = self.sessions != 1
            elif (level,msg) == ('Info','CLIENT DISCONNECTED'):
                self.open = False
            elif self.open and level == 'Debug':
                key = ENCODED.fullmatch(msg)
                if not key and msg not in CONTROL_KIND:
                    return False
                f = int(key[1]) if key else 0
                kind = 1 if key else CONTROL_KIND[msg]
                if (key and f <= self.last_frame) or self.totals[kind] == U32:
                    self.invalid = True
                else:
                    if key: self.last_frame = f
                    self.totals[kind] += 1
                    if len(self.rows) < LIMIT * MARK.size:
                        self.rows.extend(MARK.pack((time.monotonic_ns()-self.origin)//1_000_000, kind, f))
                    else:
                        self.truncated = True
        return False

    def snapshot(self):
        with self.lock:
            return dict(version=2, sessions=self.sessions, invalid=self.invalid, truncated=self.truncated,
                        totals=list(self.totals), rows=[list(row) for row in MARK.iter_unpack(self.rows)])

    def host_type(self, base):
        marks = self
        class ObservedHost(base):
            # Discovery stays at info level and needs its live display list.
            # Neither process needs a raw file. Only the verified display uses debug.
            def conf(self):
                return private_debug_config(super().conf(), self.runtime, active=bool(self.output_id))

            def mark_start(self):
                super().mark_start()
                marks.arm()

            def line(self, row):
                if not self.output_id:
                    super().line(row)
                elif marks.observe(row):
                    super().line('NvEnc: created encoder')
        return ObservedHost


REQUEST = re.compile(r'freshness_request at=(\d+) frame=(\d+) gap_ms=\d+ extra_ms=\d+ request=1')
SUBMIT = re.compile(r'freshness_submit at=(\d+) frame=(\d+) skipped=\d+ extra_ms=\d+ wait_ms=(\d+) requests=([12])')
RENDER = re.compile(r'freshness_render at=(\d+) wait_ms=(\d+) pts_ms=\d+')
CORE_WAIT = re.compile(r'core_wait_idr at=(\d+)')


class FreshEpisode(NamedTuple):
    request_frame: int
    recovery_frame: int
    wait_ms: int
    output_ms: int
    request_at_ms: int
    requests: int


def phone_episodes(phone):
    # Same phone monotonic clock plus an independently marked IDR decode unit.
    gaps = {(g[0], g[2]) for e in phone['epochs'] for g in e['gap_events'] if len(g) >= 8 and g[7] == 1}
    out, req, sub = [], None, None
    for _, msg in phone['events']:
        if msg.startswith(('quality_restart ', 'decoder_setup_code=', 'core_connection_end=')):
            req = sub = None
        elif m := REQUEST.fullmatch(msg):
            req, sub = tuple(map(int,m.groups())), None
        elif m := SUBMIT.fullmatch(msg):
            stamp, f, wait, count = map(int,m.groups())
            if req and sub is None and req[0] <= stamp and stamp-req[0] == wait and 0 < req[1] < f <= U32 and (stamp,f) in gaps:
                sub = stamp, f, count
            else:
                req = sub = None
        elif m := RENDER.fullmatch(msg):
            stamp,wait = map(int,m.groups())
            if req and sub and stamp >= sub[0] and stamp-req[0] == wait:
                out.append(FreshEpisode(req[1],sub[1],sub[0]-req[0],stamp-sub[0],req[0],sub[2]))
            req = sub = None
    return out


def core_wait_evidence(stamps,ep):
    # Same phone monotonic clock, within a single identified decoder epoch.
    # The core may withhold dependent units while waiting for an IDR. These
    # are observations, not a count of all received pictures or IDR requests.
    left=bisect_left(stamps,ep.request_at_ms)
    right=bisect_right(stamps,ep.request_at_ms+ep.wait_ms)
    return dict(phone_freshness_requests=ep.requests,core_wait_observations=right-left,
                first_core_wait_after_request_ms=stamps[left]-ep.request_at_ms if left<right else None,
                last_core_wait_after_request_ms=stamps[right-1]-ep.request_at_ms if left<right else None)


def marker_evidence(doc):
    unknown = (None, None)
    if (not isinstance(doc,dict) or type(doc.get('version')) is not int or doc['version'] not in (1,2)
            or type(doc.get('sessions')) is not int or doc['sessions']!=1
            or doc.get('invalid') is not False):
        return unknown
    rows = doc.get('rows'); last_t = last_f = 0; counts = [0,0,0]
    if not isinstance(rows,list) or len(rows) > (LEGACY_LIMIT if doc['version']==1 else LIMIT): return unknown
    for row in rows:
        if not isinstance(row,list) or len(row)!=3 or any(type(i) is not int for i in row): return unknown
        t,k,f = row
        if t < last_t or k not in (0,1,2) or (k!=1 and f!=0) or (k==1 and not last_f < f <= U32): return unknown
        if k==1: last_f = f
        last_t = t; counts[k]+=1
    if doc['version']==1: return rows,counts
    totals,cut=doc.get('totals'),doc.get('truncated')
    if (not isinstance(totals,list) or len(totals)!=3 or type(cut) is not bool
            or any(type(n) is not int or not c<=n<=U32 for c,n in zip(counts,totals))):
        return unknown
    if cut:
        # Valid whole-session totals are still useful. Never anchor individual
        # pictures to a truncated prefix, even when its row data passes validation.
        return (None,totals) if len(rows)==LIMIT and sum(totals)>len(rows) else unknown
    return (rows,totals) if totals==counts else unknown


def accepted_markers(doc):
    return marker_evidence(doc)[0]


def encoder_observations(rows):
    encoded={}; req=[]; invalidations=0
    for t,k,f in rows or []:
        if k==0:
            req.append(t)
        elif k==2:
            invalidations+=1
        elif k==1:
            encoded[f]=dict(host_encoder_observed_ms=t, preceding_request_count=len(req),
                            preceding_reference_invalidations=invalidations,
                            single_request_to_idr_observed_ms=t-req[0] if len(req)==1 and not invalidations else None)
            req=[]; invalidations=0
    return encoded


def gap_idr_units(epoch):
    # These are decoder-input observations, not proof of a render or of an
    # explicit freshness request. A repeated/conflicting frame cannot anchor.
    out={}; seen=set()
    for g in epoch['gap_events']:
        if (not isinstance(g,(list,tuple)) or len(g)!=9 or any(type(v) is not int for v in g)
                or g[7]!=1 or not 0<g[1]<g[2]<=U32 or g[3]!=g[2]-g[1]-1 or g[4]<=0):
            continue
        f=g[2]
        if f in seen:
            out.pop(f,None)
        else:
            out[f]=(g[4],g[3])
        seen.add(f)
    return out


def fingerprints(folder):
    out={}
    required=('host-numeric.ssmeta','phone-numeric.json','result.json')
    for name in (*required,'relay-packet-status.json','phone-packet-counts.json'):
        path=folder/name
        if name not in required and not path.exists(): continue
        if not path.is_file() or not 0<path.stat().st_size<=40_000_025: return None
        with path.open('rb') as handle: out[name]=hashlib.file_digest(handle,'sha256').hexdigest()
    return out


def save_markers(folder, marks):
    # Prevent accidental cross-run joins even when two encoders reuse frame 1.
    doc=dict(marks.snapshot(),artifacts=fingerprints(folder))
    with (folder/'idr-host-numeric.json').open('x',encoding='ascii') as out:
        json.dump(doc,out,separators=(',',':'))


def frame_path(folder, wanted, relay):
    host = folder/'host-numeric.ssmeta'
    if not host.is_file() or not 0 < host.stat().st_size <= 40_000_025: return None
    raw = host.read_bytes()
    if len(raw)%RECORD.size: return None
    last = RECORD.unpack_from(raw,len(raw)-RECORD.size)
    if last[0]!=255 or last[3]!=len(raw)//RECORD.size-1 or last[4]: return None
    routes = {}
    if relay:
        saved = folder/'relay-packet-status.json'
        if not saved.is_file() or saved.stat().st_size>TRACE_EPOCHS*TRACE_LIMIT*2: return None
        packed=json.loads(saved.read_bytes())
        if not isinstance(packed,dict) or not 0<len(packed)<=TRACE_EPOCHS: return None
        for k,v in packed.items():
            dec=zlib.decompressobj(); chunk=dec.decompress(base64.b64decode(v,validate=True),TRACE_LIMIT+1)
            if not dec.eof or dec.unused_data or len(chunk)>TRACE_LIMIT or int(k) in routes: return None
            routes[int(k)]=chunk
    ledger = folder/'phone-packet-counts.json'
    rx = json.loads(ledger.read_bytes()) if ledger.is_file() else {}
    audited = rx.get('valid') is True and len(rx.get('status',[]))==3 and rx['status'][1:]==[0,0]
    rows = {f:Counter() for f in wanted}; seen=set(); last_source=0
    for kind,f,ms,tag,n in RECORD.iter_unpack(raw):
        if kind == 0 and f <= 32 and last_source >= f+64: return None  # another encoder epoch
        if kind == 0: last_source=max(last_source,f)
        if f not in rows: continue
        row=rows[f]
        if kind==0:
            if not row['host_in']: row['first_ms']=ms
            row['host_in']+=1
        elif kind==1:
            if (tag,n) in seen: return None
            seen.add((tag,n));row['win_udp']+=1;row['last_ms']=ms
            if relay:
                states=routes.get(tag,b''); s=states[n] if n<len(states) else 0
                if s not in (0,1,2,3,4): return None
                row['relay_out']+=s==1; row['limited']+=s in (2,4)
                row['send_error']+=s==3; row['absent']+=s==0
    results={}
    for f,v in rows.items():
        src,tx=v['host_in'],v['win_udp']; fw=v['relay_out'] if relay else None
        auth=local=None
        if audited and 0<f<=rx['status'][0]:
            off=(f-1)%128;block=bytes.fromhex(rx['blocks'].get(str(f-off),''))
            if len(block)==256:
                a,b=block[2*off:2*off+2]
                if b<=a<255 and a<=(fw if relay else tx): auth,local=a,b
        status=('host_ingress_unobserved' if not src else 'inconsistent_counters' if tx>src else
                'windows_send_incomplete' if tx<src else 'relay_limited' if v['limited'] else
                'relay_send_failure' if v['send_error'] else 'relay_forward_unconfirmed' if relay and fw<tx else 'phone_unobserved' if auth is None else
                'phone_ingress_incomplete' if auth<(fw if relay else tx) else 'phone_local_incomplete' if local<auth else
                'all_traced_fragments_delivered')
        results[f]=dict(frame=f,status=status,host_ingress=src,windows_udp=tx,relay_forwarded=fw,
                        relay_limited=v['limited'] if relay else None,relay_send_errors=v['send_error'] if relay else None,
                        relay_not_observed=v['absent'] if relay else None,
                        phone_authenticated=auth,phone_local=local,
                        host_first_to_last_send_ms=v['last_ms']-v['first_ms'] if src and tx==src and v['last_ms']>=v['first_ms'] else None)
    return results


def largest_gap_hops(folder,gaps,relay):
    # These missing sequence IDs are between two *observed* decoder inputs.
    # No encoder marker or assumption that all fragments are needed for FEC.
    eligible=[(ms,f,n) for f,(ms,n) in gaps.items() if n>0]
    if not eligible: return None
    ms,f,n=max(eligible,key=lambda row:(row[0],-row[1]))
    if n>50000 or f<=n+1: return None
    rows=frame_path(folder,range(f-n,f),relay)
    if rows is None:return None
    def total(key):
        vals=[v[key] for v in rows.values()]
        return None if any(v is None for v in vals) else sum(vals)
    return dict(previous_input_frame=f-n-1,recovery_input_frame=f,decoder_input_gap_ms=ms,
                missing_sequences=n,source_seen_frames=sum(v['host_ingress']>0 for v in rows.values()),
                windows_incomplete_frames=sum(0<=v['windows_udp']<v['host_ingress'] for v in rows.values()),
                host_ingress_fragments=total('host_ingress'),windows_udp_fragments=total('windows_udp'),
                relay_forwarded_fragments=total('relay_forwarded'),relay_limited_fragments=total('relay_limited'),
                phone_authenticated_fragments=total('phone_authenticated'),phone_local_fragments=total('phone_local'))


def _report(folder):
    def read(name): return json.loads((folder/name).read_bytes())
    r=read('result.json'); a=r['attribution']; p=read('phone-numeric.json'); relayed=r['playback']['route']=='relay'
    if not (r.get('view_only') is True and r['playback']['route'] in ('relay','direct') and
            r.get('verified_physical_nvenc_and_encrypted_playback') is True and a.get('host_trace_complete') and
            (not relayed or a.get('relay_trace_complete')) and a.get('host_stream_epochs')==a.get('stream_epochs')==len(p['epochs'])==1):
        return {'status':'unverified_session_or_reused_frame_ids'}
    sidecar=folder/'idr-host-numeric.json'
    doc=json.loads(sidecar.read_bytes()) if sidecar.is_file() and 0<sidecar.stat().st_size<=MAX_SIDECAR else None
    markers,totals=marker_evidence(doc)
    bound=(isinstance(doc,dict) and type(doc.get('sessions')) is int and doc['sessions']==1 and
           isinstance(doc.get('artifacts'),dict) and doc['artifacts']==fingerprints(folder))
    if not bound: markers=totals=None
    windows=phone_episodes(p); encoded=encoder_observations(markers)
    gap_units=gap_idr_units(p['epochs'][0]); common=gap_units.keys() & encoded.keys()
    counts=dict(host_marker_coverage=('complete' if markers is not None else 'totals_only' if totals is not None else 'unavailable'),
                host_request_markers_in_session=totals[0] if totals is not None else None,
                host_reference_invalidation_markers_in_session=totals[2] if totals is not None else None,
                host_encoded_idrs_in_session=totals[1] if totals is not None else None,
                phone_gap_idr_units=len(gap_units),
                largest_phone_gap_fragment_path=largest_gap_hops(folder,gap_units,relayed) if bound else None)
    wanted=common | {e.recovery_frame for e in windows} | {
        f for e in windows if e.recovery_frame in encoded for f in encoded if e.request_frame<f<=e.recovery_frame}
    if not wanted:
        return dict(status='no_confirmed_phone_recovery',**counts,matched_gap_idr_units=0 if markers is not None else None,
                    longest_gap_idr_units=[] if markers is not None else None,episodes=[])
    hops=frame_path(folder,wanted,relayed)
    if hops is None: return {'status':'incomplete_hop_trace'}
    waits=sorted({int(m[1]) for _,msg in p['events'] if (m:=CORE_WAIT.fullmatch(msg))})
    episodes=[]
    for ep in windows:
        lo,hi,delay,render=ep[:4]
        anchored=hi in encoded and hops[hi]['host_ingress']>0
        # Requests in the stock protocol do not have an end-to-end request ID.
        # An IDR in this frame range is a candidate, not proof of causation.
        episodes.append(dict(recovery_frame=hi,phone_request_to_submit_ms=delay,phone_submit_to_output_ms=render,
            **core_wait_evidence(waits,ep),
            final_frame=hops[hi],encoder_evidence='matched' if anchored else 'not_recorded' if doc is None else
            'invalid_or_unbound_markers' if markers is None else 'no_shared_frame_anchor',
            final_encoder_observation=encoded[hi] if anchored else None,
            # unit_gap is sampled on a gap, not emitted for every unit; absence
            # cannot be interpreted as a decoder rejection or a missing frame.
            earlier_observed_idrs=[dict(hops[f], **encoded[f],
                phone_decoder_input_gap_ms=gap_units[f][0] if f in gap_units else None)
                for f in sorted(encoded) if lo<f<hi] if anchored else None))
    anchored_gaps=sorted((f for f in common if hops[f]['host_ingress']>0),key=lambda f:(-gap_units[f][0],f))
    return dict(status='observed' if windows else 'no_confirmed_phone_recovery',**counts,
                matched_gap_idr_units=len(anchored_gaps) if markers is not None else None,
                longest_gap_idr_units=[dict(phone_decoder_input_gap_ms=gap_units[f][0],missing_sequence_numbers=gap_units[f][1],
                                      frame_path=hops[f],encoder_observation=encoded[f]) for f in anchored_gaps[:3]] if markers is not None else None,
                episodes=episodes)


def report(folder):
    try: return _report(folder)
    except (OSError,ValueError,TypeError,KeyError,IndexError,struct.error,zlib.error):
        return {'status':'unreadable_or_invalid_numeric_evidence'}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('folder',type=Path)
    print(json.dumps(report(parser.parse_args().folder),indent=2))
