"""Same-run source gap evidence for the isolated, encrypted, primary-display LAN trial."""
import argparse
import bisect
from collections import Counter, defaultdict
import json
from pathlib import Path
import re

from lan_encoder_witness import ANCHOR, utc_base
from lan_phone_progress import correlate as phone_progress, socket_brackets
from long_metrics import RECORD
from lan_player_timeline import Timeline

GUARD = 12  # ms; exceeds the accepted anchor drift and call duration.
PATH = re.compile(r'video_path stage=0 ms=(\d+) packets=\d+ event_gap=(\d+) peak_gap=\d+ previous_frame=(\d+) frame=(\d+) loop_peak=(\d+)')
ROLES = {1:'capture', 2:'video_session', 3:'video_broadcast', 4:'capture_sync'}


def source_frames(file):
    size = file.stat().st_size
    if not 3*RECORD.size <= size <= 100_000_025 or size % RECORD.size:
        raise ValueError('invalid_ledger_size')
    frames, last = [], [-1, -1]
    with file.open('rb') as f:
        f.seek(-RECORD.size, 2)
        if RECORD.unpack(f.read()) != (255, 0, 0, size//RECORD.size-1, 0):
            raise ValueError('unsealed_host_ledger')
        f.seek(0)
        left = size-RECORD.size
        while left:
            block = f.read(min(left, 16384*RECORD.size))
            if not block or len(block) % RECORD.size:
                raise ValueError('truncated_ledger')
            left -= len(block)
            for kind, frame, ms, _, _ in RECORD.iter_unpack(block):
                if kind not in (0, 1) or ms < last[kind]:
                    raise ValueError('invalid_packet_order')
                last[kind] = ms
                if kind == 1:
                    continue
                if frames and frame == frames[-1][0]:
                    frames[-1][2] = ms
                elif not frames or frame == frames[-1][0]+1:
                    frames.append([frame, ms, ms])
                else:
                    raise ValueError('noncontiguous_source_ids')
    if len(frames) < 2:
        raise ValueError('insufficient_source_frames')
    return frames


def clock(lines):
    base = utc_base(lines)
    samples = [tuple(map(int, m.groups())) for l in lines if (m := ANCHOR.fullmatch(l))]
    if base is None or len(samples) != 2:
        return None
    a, b = samples
    if abs((b[2]-a[2])-(b[1]-a[1])/1000) > 10:
        return None
    return base


def desktop(rows, start, end):
    # Treat a timeout as a successful no-update poll, but never bridge an
    # unread/masked interval to claim an unchanged desktop. Pointer-only
    # acquisitions have no LastPresentTime and are not desktop presents.
    left, right = start+GUARD, end-GUARD
    seen = set()
    covered = longest = run = n = accumulated = 0
    masked = slow = 0
    prev = None
    for r in rows:
        t, us, count, last, valid = r
        if t < left or t+us/1000 > right:
            continue
        if not valid or us > 10000:
            if not valid: masked += 1
            else: slow += 1
            prev = None
            run = 0
            continue
        n += 1
        if count and left <= last <= min(right, t+us/1000+1):
            seen.add(last)
        if prev is not None and 0 < t-prev <= 95:
            dt = t-prev
            covered += dt
            if not count and not last:
                run += dt
                longest = max(longest, run)
            else:
                run = 0
                if prev < last <= right:
                    accumulated += count
        else:
            run = 0
        prev = t
    kind = ('desktop_updated' if len(seen) >= 2 else 'one_update' if seen else
            'quiet_interior' if longest >= max(75, .60*(end-start)) else 'insufficient_coverage')
    return dict(signal=kind, polls=n, distinct_presents=len(seen), enclosed_accumulated=accumulated,
                covered_ms=covered, contiguous_quiet_ms=longest,
                excluded_masked_polls=masked,excluded_slow_unmasked_polls=slow)


def worker(rows, start, end):
    prev = None
    count = running = waiting = ready_flat = longest = 0
    for r in rows:
        t, us, role, state, generation, cycles = r
        if not start+GUARD <= t <= end-GUARD or t+us/1000 > end-GUARD:
            continue
        if us > 10000 or not generation:
            prev = None
            ready_flat = 0
            continue
        count += 1
        waiting += state == 5
        if prev and prev[2] == role and prev[4] == generation and 0 < t-prev[0] <= 95 and cycles >= prev[5]:
            running += cycles > prev[5]
            # Equal cycle counts prove no observable CPU progress. States are
            # two snapshots, not proof this thread was Ready in between them.
            if cycles == prev[5] and prev[3] in (1,3) and state in (1,3):
                ready_flat += t-prev[0]
                longest = max(longest, ready_flat)
            else:
                ready_flat = 0
        else:
            ready_flat = 0
        prev = r
    return dict(samples=count, progress_pairs=running, wait_snapshots=waiting, ready_endpoints_flat_ms=longest)


def stages(entries, start, end):
    groups = defaultdict(list)
    for r in entries:
        groups[r['stage']].append(r)
    out = {}
    for name, group in groups.items():
        for a,b in zip(group, group[1:]):
            if 19000 <= b['utc_ms']-a['utc_ms'] <= 22000 and a['utc_ms']+GUARD <= start <= end <= b['utc_ms']-GUARD:
                out[name] = b['max_ms']
                break
    return out


class Series:
    def __init__(self, rows):
        self.rows, self.times = rows, [r[0] for r in rows]
        if any(a >= b for a,b in zip(self.times,self.times[1:])):
            raise ValueError('invalid_observer_time_order')

    def window(self, start, end):
        return self.rows[bisect.bisect_left(self.times,start):bisect.bisect_right(self.times,end)]


def compositor_progress(rows, start, end):
    # Never turn a vblank, an invalid/reset counter or a hole in sampling
    # into evidence about frame submission by the test video.
    rows=[r for r in rows if start+GUARD<=r[0] and r[0]+r[1]/1000<=end-GUARD and 0<=r[1]<=10000]
    adjacent=[(a,b) for a,b in zip(rows,rows[1:]) if 0<b[0]-a[0]<=95
              and all(b[i]>=a[i] for i in range(2,6))]
    if not adjacent:return None
    return dict(scope='global_dwm_not_player',observed_pairs=len(adjacent),
                covered_ms=sum(b[0]-a[0] for a,b in adjacent),
                advancing_submission_pairs=sum(b[4]>a[4] for a,b in adjacent),
                advancing_confirmation_pairs=sum(b[5]>a[5] for a,b in adjacent))


def interpretation(d, age, duration):
    if age is not None and age >= duration*.6:
        return 'resumed_picture_already_old_at_packetization'
    if d == 'not_observed':
        return 'desktop_not_observed'
    if d == 'quiet_interior':
        return 'no_desktop_presents_in_observed_interior'
    if d == 'desktop_updated' and age is not None and age <= min(40,duration*.25):
        return 'desktop_changed_resumed_picture_fresh'
    return 'desktop_changed' if d == 'desktop_updated' else 'inconclusive'


def phone_stalls(frames, gaps, path_gaps):
    """A decoder-unit gap need not be an ingress gap. Bound the latter inside both boundary frames."""
    out=[]
    for r in sorted((r for r in gaps if len(r)==9 and r[4]>=140),key=lambda r:-r[4])[:12]:
        _,prev,frame,missing,ms,assembly,callback,_,_=r
        i,j=prev-frames[0][0],frame-frames[0][0]
        if not 0<=i<j<len(frames) or frame-prev!=missing+1:continue
        # Every frame ID between the two endpoints must exist. For gaps within a
        # single frame, its first-to-last duration is an *upper bound*, not a
        # witnessed inter-packet silence. Only use this to exclude source stalls.
        chunk=frames[i:j+1]
        quiet=max(b[1]-a[2] for a,b in zip(chunk,chunk[1:]))
        upper=max(quiet,max(f[2]-f[1] for f in chunk))
        evidence=[g for g in path_gaps if prev<=g['previous_frame']<=g['frame']<=frame
                  and g['host_udp_accept_peak_ms'] is not None]
        greatest=max(evidence,key=lambda g:g['phone_packet_gap_ms'],default=None)
        out.append(dict(previous=prev,frame=frame,missing=missing,phone_unit_gap_ms=ms,phone_assembly_ms=assembly,
                        phone_callback_wait_ms=callback,source_interframe_quiet_ms=quiet,
                        source_packet_gap_upper_ms=upper,intervening_source_frames=j-i-1,
                        nested_phone_packet_gap_ms=greatest['phone_packet_gap_ms'] if greatest else None,
                        nested_host_udp_gap_upper_ms=greatest['host_udp_accept_peak_ms'] if greatest else None))
    return out


def cadence(frames, base, ds):
    """Compare source packetized frames with an independent lower count of desktop updates.

    Use only fully enclosed consecutive good polls; never extrapolate missing
    observations or equate DDA publications with freshly encoded video frames.
    """
    times=[f[1] for f in frames]
    windows=[]
    for left in range(times[0],times[-1]-10000+1,10000):
        start,end=base+left,base+left+10000
        polls=ds.window(start+GUARD,end-GUARD)
        covered=count=0
        for a,b in zip(polls,polls[1:]):
            if not (a[4] and b[4] and max(a[1],b[1])<=10000 and 0<b[0]-a[0]<=95
                    and b[0]+b[1]/1000<=end-GUARD):
                continue
            if b[2] and not a[0]+a[1]/1000 < b[3] <= b[0]+b[1]/1000+1:
                continue
            covered+=b[0]-a[0]
            count+=b[2]
        source=bisect.bisect_left(times,left+10000)-bisect.bisect_left(times,left)
        windows.append(dict(source_start_ms=left,source_fps=source/10,
                            desktop_updates_per_second_lower=count/10,observed_ms=covered))
    covered=[w for w in windows if w['observed_ms']>=9500]
    return dict(windows=len(windows),covered_windows=len(covered),
                desktop_ge55_source_lt55=sum(w['desktop_updates_per_second_lower']>=55 and w['source_fps']<55 for w in covered),
                lowest_source=min(covered,key=lambda w:w['source_fps'],default=None),rows=windows)


def source_during_refusals(frames, base, witness, ds):
    # Accept only real OS refusals anchored by the independent network witness.
    # The middle of a refusal, not its preceding/following recovery traffic.
    if base is None or witness.get('clock_inconsistent_spans',0):
        return []
    times=[f[1] for f in frames]
    out=[]
    for span in witness.get('long_refusals',[]):
        a,b=span['begin_ms'],span['end_ms']
        if span['errno']!=10035 or abs(b-a-span['busy_ms'])>3 or b-a<150:continue
        i,j=bisect.bisect_left(times,a+GUARD-base),bisect.bisect_right(times,b-GUARD-base)
        if i<1 or j>=len(frames) or j-i<2:continue
        inside=frames[i:j]
        out.append(dict(busy_ms=span['busy_ms'],source_frames_inside=len(inside),
                        first_frame=inside[0][0],last_frame=inside[-1][0],
                        source_quiet_inside_ms=max(y[1]-x[2] for x,y in zip(inside,inside[1:])),
                        desktop=desktop(ds.window(a,b),a,b) if ds is not None else None,
                        pc_gateway_timeouts=span.get('pc_gateway',{}).get('confirmed_timeout'),
                        pc_gateway_replies=span.get('pc_gateway',{}).get('ok'),
                        phone_gateway_replies=span.get('phone_gateway',{}).get('ok')))
    return out


def analyze(folder):
    load = lambda name: json.loads((folder/name).read_text('utf-8'))
    res, phone_data = load('result.json'), load('phone-numeric.json')
    phone = phone_data['epochs']
    t, attr = res['timeline'],res['attribution']
    if not (res['route']=='lan' and res['host_refuses_input'] is True and not res['usb_forward']
            and res['encrypted_video_audio'] is True and res['primary_capture_confirmed'] is True
            and res['source_desktop_size'][0]>=1920 and res['source_desktop_size'][1]>=1080
            and res['host_setups']==[[1920,1080,60,20000]] and res['sunshine_rate_witness'].get('encoder_kbps')==20000
            and res['full_hd']['observed_pictures']==[[1920,1080]] and len(phone)==1
            and all(t.get(k) for k in ('single_phone_epoch','complete_single_host_epoch','matching_duration'))
            and attr['host_trace_complete'] and attr['host_stream_epochs']==attr['stream_epochs']==1):
        raise ValueError('unsafe_or_ambiguous_scope')
    frames = source_frames(folder/'host-numeric.ssmeta')
    lines = (folder/'host-path-numeric.txt').read_text('ascii').splitlines()
    base = clock(lines)
    player = Timeline.load(folder, base+frames[0][1] if base is not None else None,
                           base+frames[-1][2] if base is not None else None)
    logged = defaultdict(list)
    for line in lines:
        if m := PATH.fullmatch(line):
            elapsed,gap,before,after,loop = map(int,m.groups())
            if gap:
                logged[before,after].append((elapsed,gap,loop))
    gaps = defaultdict(list)
    for row in phone[0]['gap_events']:
        if len(row)==9 and row[3]==0:
            gaps[row[1],row[2]].append(row)
    obs = load('lan-capture-samples.json') if (folder/'lan-capture-samples.json').is_file() else {}
    summary = obs.get('summary',{})
    good = bool(base is not None and summary.get('primary_verified') and summary.get('clock_ok') and not summary.get('probe_failed')
                and summary==res.get('primary_capture_observer') and summary.get('polls')==len(obs.get('desktop',())))
    desks = Series(obs['desktop'] if good else [])
    dwm = Series(obs.get('dwm',[]) if good and summary.get('dwm_capable') is True
                 and summary.get('dwm_polls')==len(obs.get('dwm',[])) else [])
    workers = {ROLES[int(k)]:Series(v) for k,v in obs.get('workers',{}).items() if good and int(k) in ROLES}
    gpu = Series(obs.get('nvenc',[]) if good else [])
    timings = {}
    if good:
        start,end=base+frames[0][1],base+frames[-1][2]
        for role, series in dict(desktop=desks,nvenc=gpu,**workers).items():
            rows=series.window(start,end)
            intervals=sorted(b[0]-a[0] for a,b in zip(rows,rows[1:]))
            calls=sorted(r[1] for r in rows)
            if intervals:
                timings[role]=dict(rows=len(rows),p95_poll_interval_ms=intervals[(len(intervals)-1)*95//100],
                                   max_poll_interval_ms=intervals[-1],p99_query_us=calls[(len(calls)-1)*99//100])
                if role=='desktop':
                    # The observer process and its clock can be healthy even when
                    # the compositor masks the entire video interval. Do not count
                    # those polls as evidence of either activity or inactivity.
                    timings[role].update(usable_polls=sum(bool(r[4]) and r[1]<=10000 for r in rows),
                                         excluded_masked_polls=sum(not r[4] for r in rows),
                                         excluded_slow_unmasked_polls=sum(bool(r[4]) and r[1]>10000 for r in rows))
    quiet = [(b[1]-a[2],a,b) for a,b in zip(frames,frames[1:])]
    selected = sorted((q for q in quiet if q[0]>=80), key=lambda q:-q[0])
    out = []
    for gap,a,b in selected[:128]:
        before,after = a[0],b[0]
        start,end = (base+a[2],base+b[1]) if base is not None else (0,0)
        matches = gaps[before,after]
        p = matches[0] if len(matches)==1 else None
        age = p[8]/10 if p and 0<p[8]<65535 else None
        wd = desktop(desks.window(start,end),start,end) if good else dict(signal='not_observed')
        ev = [r for r in logged[before,after] if abs(r[0]-b[1])<=10 and abs(r[1]-gap)<=8]
        nv = [r for r in gpu.window(start+GUARD,end-GUARD) if r[1]<=10000 and r[0]+r[1]/1000<=end-GUARD]
        out.append(dict(previous=before,frame=after,source_quiet_ms=gap,source_first_to_first_ms=b[1]-a[1],
                        resumed_capture_to_packet_ms=age,phone_unit_gap_ms=p[4] if p else None,
                        phone_assembly_ms=p[5] if p else None,phone_callback_wait_ms=p[6] if p else None,
                        helper_loop_lifetime_peak_ms=ev[0][2] if len(ev)==1 else None,desktop=wd,
                        global_compositor=compositor_progress(dwm.window(start,end),start,end),
                        player_submission=player.gap(start,end),
                        worker={r:worker(s.window(start,end),start,end) for r,s in workers.items()},
                        nvenc_session_latency_us=[min(r[3] for r in nv),max(r[3] for r in nv)] if nv else None,
                        stage_interval_max_ms=stages(obs.get('host_stages',()),start,end) if good else {},
                        interpretation=interpretation(wd['signal'],age,gap)))
    stalls=phone_stalls(frames,phone[0]['gap_events'],t['gaps'])
    forward=phone_progress(phone[0],phone_data.get('path',[]))
    socket=(res.get('phone_authenticated_udp_socket') or {}).get('counted_drops')
    drops=socket_brackets(phone[0],load('phone-burst-windows.json')) if (
        socket is not None and socket>=0 and (folder/'phone-burst-windows.json').is_file()) else {}
    for s in stalls:
        s['phone_timed_handoff']=forward.get((s['previous'],s['frame']))
        s['phone_socket_bracket']=drops.get((s['previous'],s['frame']))
    # LAN 1080p60 currently does not arm the phone's narrow/WAN IDR-wait
    # logger. Missing records cannot establish that the core was not waiting.
    idr_wait_seen=any(re.fullmatch(r'core_wait_idr at=\d+',line) for _,line in phone_data.get('events',[]))
    return dict(source_frames=len(frames),max_source_quiet_ms=max(q[0] for q in quiet),
                gaps_ge80_ms=len(selected),gaps_ge250_ms=sum(q[0]>=250 for q in selected),
                dual_clock_ok=base is not None, independent_observer=good,
                player_submission_status=player.status,
                cadence=cadence(frames,base,desks) if good else None,
                observer=summary,observer_sampling=timings,phone_stalls=stalls,
                phone_idr_wait_signal='observed' if idr_wait_seen else 'not_observed_not_a_negative',
                windows_refusals=source_during_refusals(frames,base,res.get('wifi_uplink',{}),desks if good else None),
                interpretations=dict(Counter(g['interpretation'] for g in out)),events=out)


if __name__=='__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder',type=Path); parser.add_argument('--write',action='store_true')
    args = parser.parse_args()
    report = analyze(args.folder)
    if args.write:
        (args.folder/'source-stages.json').write_text(json.dumps(report,indent=2),'ascii')
    print(json.dumps({**report,'cadence':{k:v for k,v in report['cadence'].items() if k!='rows'} if report['cadence'] else None,
                      'events':report['events'][:4]},separators=(',',':')))
