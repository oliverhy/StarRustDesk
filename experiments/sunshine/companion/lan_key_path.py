"""Allowlisted host timestamps for the isolated view-only LAN recovery comparison."""
from datetime import datetime
from collections import Counter
import hashlib
import json
import math
import re
from pathlib import Path
from lan_encoder_witness import ANCHOR,utc_base
from lan_recovery_witness import wall_bounds,stamp_interval
from long_metrics import RECORD

HOST=re.compile(r'\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\]: (?:Info|Debug): (CLIENT CONNECTED|CLIENT DISCONNECTED|type \[IDX_REQUEST_IDR_FRAME\]|type \[IDX_INVALIDATE_REF_FRAMES\]|NvEnc: idr frame ([0-9]{1,8}))')
NAMES=('host-numeric.ssmeta','phone-numeric.json','result.json','encoder-size-numeric.json','host-path-numeric.txt')

class HostKeys:
    def __init__(self):
        self.armed=self.open=False
        self.bad=self.sessions=0
        self.rows=[]
    def observe(self,line,wall):
        if not self.armed or len(line)>180:return
        m=HOST.fullmatch(line.rstrip('\r\n'))
        if not m:return
        msg=m[2]
        if msg=='CLIENT CONNECTED':
            self.sessions+=1;self.open=True;return
        if msg=='CLIENT DISCONNECTED':
            self.open=False;return
        if not self.open:return
        try:t=round(datetime.strptime(m[1],'%Y-%m-%d %H:%M:%S.%f').timestamp()*1000)
        except (ValueError,OSError,OverflowError):
            self.bad+=1;return
        if not -20<=wall-t<=1500 or len(self.rows)>=65536:
            self.bad+=1;return
        self.rows.append([t,1 if m[3] else 2 if 'INVALIDATE' in msg else 0,int(m[3] or 0)])

def binding(folder):
    out={}
    for name in NAMES:
        p=folder/name
        if not 0<p.stat().st_size<=100_000_025:return None
        with p.open('rb') as f:out[name]=hashlib.file_digest(f,'sha256').hexdigest()
    return out

def seal(folder,h):
    # Never join frame IDs reused by a different session; no raw control or frame data.
    with (folder/'lan-key-host.json').open('x',encoding='ascii') as f:
        json.dump(dict(version=1,artifacts=binding(folder),sessions=h.sessions,bad=h.bad,rows=h.rows),f,separators=(',',':'))

PHASE=re.compile(r'lan_key_phase f=(\d+) first=(\d+) loss=(\d+) wait=(\d+) kind=([012]) queue=(\d+) sent=(\d+) last=(\d+) nq=(\d+) ns=(\d+)')
OUT=re.compile(r'lan_key_out f=(\d+) first=(\d+) unit=(\d+) surface=(\d+) exact=([01]) idr=([01]) backup=(\d+) tries=([012])')
REJECT=re.compile(r'lan_key_reject f=(\d+) why=([1234]) at=(\d+) idr=([01])')
SLOT=re.compile(r'lan_key_slot f=(\d+) wait_us=(\d+) pushed=([01]) idr=([01])')
SLOT_END=re.compile(r'lan_key_slot_end tries=(\d+) pushed=(\d+)')
RETURN=re.compile(r'lan_slot_return f=(\d{1,10}) us=(\d{1,12}) seen=([01])')
RETURN_END=re.compile(r'lan_slot_return_end kept=(\d{1,3}) overflow=(\d{1,10})')

def slot_returns(events,rejects):
    rows=[tuple(map(int,m.groups())) for _,msg in events if (m:=RETURN.fullmatch(msg))]
    ends=[tuple(map(int,m.groups())) for _,msg in events if (m:=RETURN_END.fullmatch(msg))]
    if not rows and not ends:return dict(status='not_in_archive')
    ids=[f for f,us,seen in rows]
    if (len(ends)!=1 or ends[0][0]!=len(rows) or len(rows)>256 or
        len(set(ids))!=len(ids) or any(not f or (not seen and us) for f,us,seen in rows)):
        return dict(status='incomplete')
    relevant=Counter(f for f,why,at,idr in rejects if why==1)
    # Missing log rows, sampling outside the live session and truncated trials
    # must not turn into a zero delay or an apparent original-frame recovery.
    if ends[0][1] or relevant!=Counter(ids):return dict(status='incomplete')
    return dict(status='measured' if rows else 'no_rejections',events=[
        dict(frame=f,reject_to_available_us=us if seen else None) for f,us,seen in rows])
RENDER=re.compile(r'render_gap at=(\d+) count=(\d+) gap=(\d+) call=\d+ backlog=\d+')

def host_evidence(rows):
    enc={};ctl=[];prev=None;last_id=-1
    if not isinstance(rows,list) or len(rows)>65536:raise ValueError('marker_count')
    for row in rows:
        if not isinstance(row,list) or len(row)!=3 or any(type(x)!=int for x in row):raise ValueError('marker_shape')
        t,k,f=row
        if not 10**12<=t<10**13 or k not in (0,1,2) or (k!=1 and f!=0):raise ValueError('marker_value')
        if k==1:
            if f<=last_id:raise ValueError('reused_encoder_ids')
            enc[f]=(t,prev);prev=t;last_id=f
        else:ctl.append((t,k))
    return enc,sorted(ctl)

def wire(path,wanted):
    spans={f:[None,None,0,0] for f in wanted}
    size=path.stat().st_size
    if not 3*RECORD.size<=size<=100_000_025 or size%RECORD.size:raise ValueError('trace_size')
    with path.open('rb') as s:
        s.seek(-RECORD.size,2)
        if RECORD.unpack(s.read())!=(255,0,0,size//RECORD.size-1,0):raise ValueError('trace_unsealed')
        s.seek(0);left=size-RECORD.size;prior=0
        while left:
            buf=s.read(min(left,16384*RECORD.size));left-=len(buf)
            if not buf:raise ValueError('short_trace')
            for kind,f,t,_,_ in RECORD.iter_unpack(buf):
                if kind not in (0,1):raise ValueError('trace_kind')
                if kind==0 and f!=prior:
                    if f!=prior+1:raise ValueError('reused_wire_id')
                    prior=f
                a=spans.get(f)
                if a is None:continue
                if kind==0:
                    if a[0] is None:a[0]=t
                    a[2]+=1
                else:a[1]=t;a[3]+=1
    return spans

def slots(events,pattern):
    out={};dupes=set()
    for stamp,msg in events:
        if m:=pattern.fullmatch(msg):
            row=tuple(map(int,m.groups()));key=row[:2]
            if key in out:dupes.add(key)
            else:out[key]=(stamp,row)
    return {k:v for k,v in out.items() if k not in dupes}

def interval(a,b):
    # Causal delay, with rounding and USB uncertainty carried to the result.
    return None if b<0 else [max(0,math.floor(a)),max(0,math.ceil(b))]

def causal_floor(unit,last_wire,nearby):
    # Every previously observed decode unit (even one rejected by the HW decoder)
    # must postdate its first arrival at the Windows media sender. Subtract two
    # short monotonic intervals, not two wall clocks. Use only adjacent witnesses
    # in the same verified epoch; reserve 8 ms for integer clocks and short drift.
    # This is a LOWER bound, never actual one-way latency or radio-only time.
    usable=[(ingress-at,f,at) for f,at,ingress in nearby if 0<unit-at<=2500]
    if not usable:return None
    off,f,at=max(usable)
    return dict(min_ms=max(0,unit+off-last_wire-8),anchor_frame=f,anchor_age_ms=unit-at)

def prior_repair_window(folder):
    """Old archives lack host request/encoder markers. Only date the final *identified*
    recovery picture entering the host sender against a unique preceding phone retry."""
    read=lambda n:json.loads((folder/n).read_bytes())
    r=read('result.json');p=read('phone-numeric.json')
    if not (r.get('route')=='lan' and r.get('encrypted_video_audio') is True and r.get('primary_capture_confirmed') is True
            and r.get('usb_forward') is False and r.get('host_refuses_input') is True and r.get('windows_medium_at_boundaries')==['ethernet']*2
            and r['attribution'].get('host_trace_complete')==r['attribution'].get('host_stream_epochs')==1 and len(p['epochs'])==1):return None
    e=p['epochs'][0];clock=wall_bounds(read('encoder-size-numeric.json')['clocks'])
    if not clock or len(e['gap_events'])!=len(e['gap_stamps']):return None
    gaps=[(g,stamp_interval(st,clock)) for st,g in zip(e['gap_stamps'],e['gap_events']) if g[3]>0 and g[7]==1]
    if not gaps:return None
    g,t=max(gaps,key=lambda v:v[0][4]);f=g[2]
    if not t:return None
    done=re.compile(r'lan_loss_recovered unit_ms=(\d+) surface_ms=(\d+) idr=1 retry=1 source=[12]')
    pairs=[(m,stamp_interval(st,clock)) for st,msg in p['events'] if (m:=done.fullmatch(msg))]
    match=[(m,s) for m,s in pairs if s and abs((s[0]-t[0])-(int(m[2])-int(m[1])))<=8]
    if len(match)!=1:return None
    m,finish=match[0]
    retries=[stamp_interval(st,clock) for st,msg in p['events'] if msg=='lan_loss_idr_retry=1']
    candidates=[v for v in retries if v and finish[0]-int(m[2])<=v[0]<=t[0]]
    if len(candidates)!=1:return None
    lo,hi=candidates[0];lines=(folder/'host-path-numeric.txt').read_text('ascii').splitlines();base=utc_base(lines)
    if base is None:return None
    guard=3+max(abs(int(a[3])-int(a[2])/1000-base)+int(a[4])/1000 for line in lines if (a:=ANCHOR.fullmatch(line)))
    ingress,last,n,sent=wire(folder/'host-numeric.ssmeta',{f})[f]
    if ingress is None or n!=sent or not n:return None
    return dict(frame=f,gap_frames=g[3],phone_log_retry_to_recovered_surface_ms=finish[0]-lo,
                retry_log_to_final_keyframe_host_ingress_ms=interval(base+ingress-hi-guard,base+ingress-lo+guard),
                host_first_ingress_to_last_accept_ms=last-ingress,source_and_sent_shards=n,frame_assembly_ms=g[5],
                host_receipt_of_request_known=False,earlier_idr_status_known=False)

def join(folder):
    read=lambda n:json.loads((folder/n).read_bytes())
    d=read('lan-key-host.json');bound=binding(folder)
    if not bound or d.get('version')!=1 or d.get('artifacts')!=bound:raise ValueError('unbound')
    r=read('result.json');p=read('phone-numeric.json')
    if not (r.get('route')=='lan' and r.get('encrypted_video_audio') is True and r.get('usb_forward') is False and
            r.get('primary_capture_confirmed') is True and r.get('host_refuses_input') is True and
            r.get('windows_medium_at_boundaries')==['ethernet','ethernet'] and r.get('ethernet_phone_wifi',{}).get('phone_source_bound') and
            r.get('host_setups')==[[1920,1080,60,20000]] and len(p['epochs'])==1 and
            r['attribution'].get('host_trace_complete')==r['attribution'].get('host_stream_epochs')==1):
        raise ValueError('scope_or_epoch')
    enc,ctl=host_evidence(d['rows']) if d.get('sessions')==1 and d.get('bad')==0 else ({},[])
    ep=p['epochs'][0];gaps={g[2]:g for g in ep['gap_events']}
    phase=slots(p['events'],PHASE);end=slots(p['events'],OUT)
    rejects=[tuple(map(int,m.groups())) for _,x in p['events'] if (m:=REJECT.fullmatch(x))]
    waits=[tuple(map(int,m.groups())) for _,x in p['events'] if (m:=SLOT.fullmatch(x))]
    wait_end=[tuple(map(int,m.groups())) for _,x in p['events'] if (m:=SLOT_END.fullmatch(x))]
    renders=[tuple(map(int,m.groups())) for _,x in p['events'] if (m:=RENDER.fullmatch(x))]
    ends=[row[3] for _,row in end.values()]
    wanted=set(enc)|{f for f,_ in end}|{f for g in gaps.values() for f in g[1:3] if f>0}
    wirepath=wire(folder/'host-numeric.ssmeta',wanted)
    lines=(folder/'host-path-numeric.txt').read_text('ascii').splitlines()
    base=utc_base(lines);clocks=wall_bounds(read('encoder-size-numeric.json')['clocks'])
    guard=(3+max(abs(int(m[3])-int(m[2])/1000-base)+int(m[4])/1000 for line in lines if (m:=ANCHOR.fullmatch(line)))) if base is not None else None
    nearby=[]
    if base is not None and clocks and len(ep['gap_stamps'])==len(ep['gap_events']):
        for sg,g in zip(ep['gap_stamps'],ep['gap_events']):
            when=stamp_interval(sg,clocks)
            if not when or len(g)<8 or not 0<g[1]<g[2] or not 0<g[4]<=2500:continue
            for f,at in ((g[2],g[0]),(g[1],g[0]-g[4])):
                h=wirepath[f]
                if h[0] is not None and 0<h[3]<=h[2]:
                    nearby.append((f,at,h[0],when[0]-(g[0]-at)))
    out=[]
    for key in sorted(phase.keys() & end.keys()):
        f,start=key
        _,(_,_,loss,wait,kind,q,s,last,nq,ns)=phase[key]
        stamp,(_,_,unit,surf,exact,idr,backup,tries)=end[key]
        if not (0<start<=unit<=surf and surf-start<60000 and all(not t or start<=t<=unit for t in (loss,wait,q,s,last,backup))
                and (not s or last>=s) and bool(nq)==bool(q) and bool(ns)==bool(s)):continue
        g=gaps.get(f)
        if g and (g[0]!=unit or g[7]!=idr):continue
        h=wirepath[f];etime,old=enc.get(f,(None,None))
        anchored=bool(idr and etime is not None and base is not None and h[0] is not None and
                      -guard<=base+h[0]-etime<=200+guard)
        item=dict(frame=f,missing=g[3] if g else None,decoder_gap_ms=g[4] if g else None,first_evidence_to_surface_ms=surf-start,
            first_evidence_to_submit_ms=unit-start,confirmed_loss_to_wait_ms=wait-loss if wait>=loss>0 else None,
            wait_type=kind,first_wait_to_intent_ms=q-wait if q>=wait>0 else None,intent_to_control_handoff_ms=s-q if s>=q>0 else None,
            first_control_to_submit_ms=unit-s if s else None,control_handoffs=ns,request_intents=nq,
            backup_attempts=tries,first_backup_after_ms=backup-start if backup else None,
            frame_assembly_ms=g[5] if g else None,decoder_callback_queue_ms=g[6] if g else None,
            exact_pts=bool(exact),rendered_idr=bool(idr and exact),submit_to_surface_ms=surf-unit if exact else None,
            encoder_idr_frame_match=anchored,source_shards=h[2],sent_shards=h[3])
        item['decoder_rejections']=[dict(frame=n,reason=why,idr=bool(ki)) for n,why,t,ki in rejects if start<=t<=unit and n<=f]
        # Both timestamps originate in the same phone callback, immediately before/after
        # its accounting. If two outputs are too close we cannot identify the picture.
        match=[g for at,_,g in renders if 0<=at-surf<=3 and sum(0<=at-u<=3 for u in ends)==1]
        item['matched_surface_gap_ms']=match[0] if exact and len(match)==1 else None
        if anchored and h[3]==h[2] and h[2]>0 and h[1]>=h[0]:
            item['host_encode_to_last_udp_accept_ms']=interval(base+h[1]-etime-guard,base+h[1]-etime+guard)
        ph=stamp_interval(stamp,clocks) if clocks else None
        if ph and g and h[2]==h[3]>0 and h[1] is not None:
            selected=[(n,t,ts) for n,t,ts,wl in nearby if n!=f and abs((ph[0]-wl)-(surf-t))<=12]
            item['post_last_udp_causal_bound']=causal_floor(unit,h[1],selected)
        if anchored and ph:
            # Same-session USB wall bounds plus phone-local monotonic deltas.
            # The hilog stamp belongs to the post-render diagnostic, not to the request.
            # Cross-check its translation against a second independent decode callback stamp.
            idx=next((i for i,g in enumerate(ep['gap_events']) if g[2]==f),None)
            other=stamp_interval(ep['gap_stamps'][idx],clocks) if idx is not None and idx<len(ep['gap_stamps']) else None
            if not other or abs((ph[0]-other[0])-(surf-unit))>12:out.append(item);continue
            lo,hi=ph[0]-12,ph[1]+2  # diagnostic publication/rounding envelope
            # A protocol request carries no correlation ID. Keep the last/first separately and
            # include prior/in-flight candidate keyframes rather than claiming a retransmission.
            begin=lo-(surf-start);endtime=hi-(surf-unit)
            controls=[(t,k) for t,k in ctl if begin<=t<=etime]
            earlier=([i for i in enc if g[1]<i<f] if g else
                     [i for i,(t,_) in enc.items() if i<f and begin<=t<=etime])
            item['earlier_candidate_encoded_idrs']=earlier
            item['missing_encoded_idr_wire']=[dict(frame=i,source=wirepath[i][2],sent=wirepath[i][3]) for i in earlier]
            if old is not None:
                controls=[(t,k) for t,k in controls if t>=old]
            item['host_control_candidates_since_previous_idr']=len(controls)
            if len(controls)==1 and controls[0][1]==0 and ns==1 and nq==1 and s and exact and not earlier:
                t=controls[0][0];delivered=interval(t-(hi-(surf-s)),t-(lo-(surf-s)))
                if delivered is not None:
                    item['control_handoff_to_host_candidate_ms']=delivered
                    item['host_candidate_to_encoded_ms']=etime-t
                    local=item.get('host_encode_to_last_udp_accept_ms')
                    if local:
                        # End-to-end duration on the phone minus the known host-local work:
                        # no subtraction of absolute timestamps across machines. The two
                        # remaining directions cannot be separated by this identity alone.
                        rest=unit-s-(etime-t)
                        item['before_host_plus_after_last_send_ms']=interval(rest-local[1]-2,rest-local[0]+2)
            if guard is not None and h[3]==h[2] and h[1] is not None:
                item['host_last_udp_to_submit_ms']=interval(lo-(surf-unit)-base-h[1]-guard,
                                                           hi-(surf-unit)-base-h[1]+guard)
        out.append(item)
    return dict(status='measured' if out else 'no_completed_incidents_observed',
                sessions=d.get('sessions'),host_stamp_rejections=d.get('bad'),host_control_markers=len(ctl),host_encoded_markers=len(enc),
                longest_logged_surface_gap_ms=max((g for _,_,g in renders),default=None),
                largest_exact_recovery_surface_gap_ms=max((e['matched_surface_gap_ms'] for e in out if e['matched_surface_gap_ms']),default=None),
                phase_rows=len(phase),surface_rows=len(end),unmatched=len(phase.keys()^end.keys()),
                keyframe_protocol_has_request_ids=False,phone_policy=sorted({msg for _,msg in p['events'] if re.fullmatch(r'lan_key_policy=[01]',msg)}),
                censored=sum(msg.startswith('lan_key_censored ') for _,msg in p['events']),
                local_reject_counts=dict(Counter(why for _,why,_,_ in rejects)),
                slot_policy_observed=any(x=='lan_key_slot_policy=1' for _,x in p['events']),
                slot_end_counts=wait_end[0] if len(wait_end)==1 else None,
                first_available_input_slot=slot_returns(p['events'],rejects),
                slot_waits=[dict(frame=f,us=t,pushed=bool(ok),key=bool(key)) for f,t,ok,key in waits],
                gaps_with_matched_episode=sum(bool(e['missing']) for e in out),total_gap_events=sum(g[3]>0 for g in ep['gap_events']),
                episodes=sorted(out,key=lambda v:-v['first_evidence_to_surface_ms']))

if __name__=='__main__':
    import argparse
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('folder',type=Path);ap.add_argument('--save',action='store_true')
    ap.add_argument('--historical-final',action='store_true')
    args=ap.parse_args();report=prior_repair_window(args.folder) if args.historical_final else join(args.folder)
    if args.save:
        target=args.folder/('lan-key-prior-final.json' if args.historical_final else 'lan-key-path.json')
        with target.open('x',encoding='ascii') as f:json.dump(report,f,indent=2)
        print('saved',target.name)
    else:print(json.dumps(report,indent=2))
