"""Offline LAN-only recap. Does not connect to a device, start a relay, or open packet content."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import re
from long_metrics import RECORD
from phone_burst_metrics import summary as burst_summary
from phone_dispatch import margin_opportunities

def host_density(path):
    """The sender uses integer milliseconds: two adjacent bins bound any rolling 1-ms window."""
    n=path.stat().st_size if path.is_file() else 0
    if not RECORD.size<=n<=100_000_025 or n%RECORD.size:return None
    with path.open('rb') as f:
        f.seek(-RECORD.size,2)
        if RECORD.unpack(f.read(RECORD.size))!=(255,0,0,n//RECORD.size-1,0):return None
        f.seek(0);left=n-RECORD.size; prev_ms=None;prev_count=0;count=0;last=None
        histogram=Counter();peak2=0;packets=0
        def close():
            nonlocal prev_count,prev_ms,peak2
            if last is not None:
                histogram[count]+=1
                peak2=max(peak2,count+(prev_count if prev_ms==last-1 else 0))
                prev_ms,prev_count=last,count
        while left:
            data=f.read(min(8192*RECORD.size,left))
            if not data or len(data)%RECORD.size:return None
            left-=len(data)
            for kind,_,ms,_,_ in RECORD.iter_unpack(data):
                if kind not in (0,1):return None
                if kind!=1:continue
                if last is not None and ms<last:return None
                if ms!=last:close();last=ms;count=0
                count+=1;packets+=1
        close()
    if not packets:return None
    return dict(video_udp_accepted=packets,peak_in_one_integer_ms=max(histogram),
                upper_bound_any_rolling_1ms=peak2,nonempty_ms=sum(histogram.values()))

def prefix(epochs,seconds):
    active=[e for e in epochs if e.get('samples')]
    if len(active)!=1:return None
    rows=[r for r in active[0]['samples'] if 8000<=r[0]<=seconds*1000+500]
    if len(rows)<2 or not 0<=seconds*1000+500-rows[-1][0]<=2000:return None
    a,b=rows[0],rows[-1];ms=b[0]-a[0]
    if ms<=0 or b[3]<a[3] or b[4]<a[4]:return None
    return dict(until_ms=b[0],sampled_ms=ms,fps=round((b[3]-a[3])*1000/ms,2),
                useful_mbps=round((b[4]-a[4])*.008/ms,3),missing=b[5],longest_ms=b[8],decode_errors=b[7])

def subset(report,fields):
    return {k:report.get(k) for k in fields}

def known_gap_budget(run):
    """Ceiling on bytes belonging to the mapped missing frames, not inferred encoder output."""
    a,p=run.get('attribution',{}),run.get('playback',{})
    g,n,span=p.get('frame_gaps'),a.get('host_frame_wire_max_bytes'),p.get('secs')
    if (run.get('route')!='lan' or a.get('host_trace_complete')!=1 or a.get('host_stream_epochs')!=1
            or a.get('stream_epochs')!=1 or a.get('source_not_seen')!=0 or not isinstance(g,int) or g<0
            or a.get('mapped_missing')!=g or a.get('reported_missing')!=g or not isinstance(n,int) or n<=0
            or not isinstance(span,(int,float)) or not math.isfinite(span) or span<=.01):return None
    # Deliberately overcount: every known gap (including startup) at the biggest entire
    # source frame (including parity + encapsulation). Allow for rounded interval length.
    cap=math.ceil(g*n*8/(span-.01)/1000)/1000
    return dict(mapped_frames=g,max_source_frame_including_overhead_bytes=n,
                max_mean_mbps_from_these_frames=cap)

def tod(s):
    m=re.fullmatch(r'(\d\d):(\d\d):(\d\d)\.(\d{3,6})',s or '')
    return ((int(m[1])*60+int(m[2]))*60+int(m[3]))*1000+int(m[4][:3]) if m else None

def since(t,pivot):return (t-pivot+43200000)%86400000-43200000

def longest_unit_break(epochs,groups,att,events,core=None):
    if (len(epochs)!=1 or len(groups)!=1 or att.get('host_trace_complete')!=1
            or att.get('host_stream_epochs')!=1 or att.get('stream_epochs')!=1):return None
    rows=[r for r in epochs[0].get('gap_events',[]) if len(r)==9]
    if not rows:return None
    index=max(range(len(rows)),key=lambda i:rows[i][4])
    observed=[int(m[1]) for _,msg in events if (m:=re.fullmatch(r'core_wait_idr at=(\d+)',msg))]
    out=unit_break(rows[index],groups[0],observed,core)
    if index+1<len(rows):
        a,b=rows[index:index+2]
        # A delayed but consecutive picture can be followed shortly by an IDR skipping old frames.
        if b[1]==a[2] and 0<b[0]-a[0]<=200 and b[3]>0:
            out['following_sequence_gap']=unit_break(b,groups[0],observed,core)
    return out

def unit_break(row,group,observed,core=None):
    end,prev,nextframe,n,gap,assembly,wait,idr,_=row
    out=dict(unit_gap_ms=gap,missing=n,next_unit_is_idr=bool(idr),recovery_unit_assembly_ms=assembly,
             recovery_unit_callback_wait_ms=wait)
    if not 0<n<=20_000 or nextframe!=prev+n+1:return out
    if core and core.get('status')=='matched':
        heads=[h for h in core.get('heads',[]) if h.get('f')==prev+1 and h.get('n')==n]
        if len(heads)==1:
            h=heads[0]
            # Join by the missing frame range, not nearest event time. 'late'
            # is evidence in the first frame only; waitn/failn cover this group.
            out['decoder_core']=dict(first_boundary=h['boundary'],first_decision=h['decision'],
                first_fragments_observed_after_abandon=h['late'],first_fragments_needed_at_abandon=h['need'],
                withheld_complete_for_reference=h['waitn'],abandoned_frames=h['failn'])
    path=[group.get(str(i),{}) for i in range(prev+1,nextframe)]
    # Host writer serializes Counter: zero successful sends is omitted, but must have a
    # source entry and explicit phone counts; unknown phone evidence is never zero.
    if not all(0<r.get('source_packets',0) and 0<=r.get('phone_loopback',-1)<=r.get('phone_authenticated',-1)
               <=r.get('sent_packets',0)<=r['source_packets'] for r in path):return out
    return dict(**out,host_sent_complete=sum(r.get('sent_packets',0)==r['source_packets'] for r in path),
        host_sent_nothing=sum(not r.get('sent_packets') for r in path),
        incomplete_at_phone_ingress=sum(r['phone_authenticated']<r.get('sent_packets',0) for r in path),
        phone_received_nothing=sum(r.get('sent_packets',0)>0 and r['phone_authenticated']==0 for r in path),
        local_forward_short=sum(r['phone_loopback']<r['phone_authenticated'] for r in path),
        complete_to_local_player=sum(r['phone_loopback']==r['source_packets'] for r in path),
        logged_core_waits=sum(end-gap<t<=end for t in observed))

def queue_age_profile(rows):
    # Quantiles of per-window maxima are not packet-delay percentiles.
    good=[r for r in rows if r.get('packets',0)>=256 and r.get('stamped',0)*10>=9*r['packets']
          and 0<=r.get('aged',-1)<=r['stamped']<=r['packets'] and r.get('age',-1)>=0]
    if len(good)<3:return None
    age=sorted(r['age'] for r in good)
    return dict(windows=len(good),p95_window_max_us=age[math.ceil(.95*len(age))-1],max_us=age[-1],
                stamped_at_least_5ms_pct=round(100*sum(r['aged'] for r in good)/sum(r['stamped'] for r in good),2))

def socket_after_growth(rows,transitions):
    if len(transitions)!=1 or transitions[0].get('state')!=1:return None
    pivot=tod(transitions[0].get('time'))
    if pivot is None:return None
    covered=[]
    for a,b in zip(rows,rows[1:]):
        t,u=tod(a.get('log_time')),tod(b.get('log_time'))
        dt=b['t']-a['t']
        if (t is None or u is None or since(t,pivot)<0 or not 0<dt<=3500
                or since(u,t)<=0 or abs(since(u,t)-dt)>500):continue
        d,e=a.get('socket_counter'),b.get('socket_counter')
        if d is None or e is None or e<d:continue
        covered.append((b,e-d,dt))
    if not covered:return None
    stamped=sum(r['stamped'] for r,_,_ in covered)
    return dict(covered_seconds=round(sum(ms for _,_,ms in covered)*.001,1),
                new_socket_drops=sum(d for _,d,_ in covered),max_arrivals_1ms=max(r['burst'] for r,_,_ in covered),
                peak_queue_age_us=max(r['age'] for r,_,_ in covered),queue_age_profile=queue_age_profile([r for r,_,_ in covered]),
                stamped_at_least_5ms_pct=round(100*sum(r['aged'] for r,_,_ in covered)/stamped,2) if stamped else None)

def after_growth(epochs,transitions):
    # Do not subtract lifetime-maximum pauses; use recorded sample windows.
    active=[e for e in epochs if e.get('samples')]
    if len(active)!=1 or len(transitions)!=1 or transitions[0].get('state')!=1:return None
    pivot=tod(transitions[0]['time'])
    if pivot is None:return None
    e=active[0];selected=[]
    for stamp,r in zip(e.get('sample_stamps',[]),e['samples']):
        t=tod(stamp)
        if t is None:return None
        if since(t,pivot)>=0:selected.append(r)
    if len(selected)<3:return None
    a,b=selected[0],selected[-1];dt=b[0]-a[0]
    if dt<=0:return None
    peaks={int(k):v for k,v in e.get('peaks',{}).items()}
    whole=all(r[0] in peaks and 0<r[0]-last[0]<=1700 for last,r in zip(selected,selected[1:]))
    return dict(seconds=round(dt/1000,1),fps=round((b[3]-a[3])*1000/dt,2),
                useful_mbps=round((b[4]-a[4])*.008/dt,3),new_missing=b[5]-a[5],
                longest_complete_window_ms=max(peaks[r[0]] for r in selected[1:]) if whole else None)

def bounded_margin_exposure(rows,epochs,transitions):
    """Only complete phone-clock intervals strictly inside a proven 1.5 MiB readback."""
    states=[(x.get('state'),x.get('before'),x.get('effective')) for x in transitions]
    grown=(1,1048576,1572864); reverted=(2,1572864,1048576)
    if states not in ([grown],[grown,reverted]):return None
    start=tod(transitions[0].get('time'))
    if start is None:return None
    stop=tod(transitions[-1].get('time')) if len(states)==2 else None
    if len(states)==2 and (stop is None or not 200<since(stop,start)<=3_600_000):return None
    def selection(times):
        ts=[tod(x) for x in times]
        if any(t is None for t in ts) or any(since(b,a)<=0 for a,b in zip(ts,ts[1:])):return None
        return [i for i,t in enumerate(ts) if since(t,start)>100 and (stop is None or since(stop,t)>100)]
    ri=selection([r.get('log_time') for r in rows])
    active=[e for e in epochs if e.get('samples')]
    if ri is None or len(active)!=1:return None
    e=active[0]; stamps=e.get('sample_stamps',[])
    if len(stamps)!=len(e['samples']):return None
    ei=selection(stamps)
    if ei is None:return None
    trimmed={**e,'samples':[e['samples'][i] for i in ei],'sample_stamps':[stamps[i] for i in ei]}
    return dict(reverted=len(states)==2,between_readbacks_s=round(since(stop,start)*.001,3) if stop is not None else None,
                complete_socket_intervals=socket_after_growth([rows[i] for i in ri],transitions[:1]),
                complete_player_intervals=after_growth([trimmed],transitions[:1]))

def recap(path):
    run=json.loads((path/'result.json').read_text('utf8'))
    if run.get('route')!='lan' or run.get('host_refuses_input') is not True or not run.get('encrypted_video_audio'):
        raise ValueError('not_encrypted_view_only_lan_run')
    phone=json.loads((path/'phone-numeric.json').read_text('utf8'))
    gaps=path/'missing-frame-path.json'
    windows=path/'phone-burst-windows.json'
    rows=json.loads(windows.read_text('ascii')) if windows.is_file() else []
    core=path/'core-receive-numeric.json'
    phases=path/'phone-reader-dispatch.json'
    return dict(target=run.get('sunshine_rate_witness'),socket=run.get('phone_authenticated_udp_socket'),
                known_gap_payload_ceiling=known_gap_budget(run),
                longest_unit_break=longest_unit_break(phone['epochs'],json.loads(gaps.read_text('utf8')) if gaps.is_file() else [],
                                                     run.get('attribution',{}),phone.get('events',[]),
                                                     json.loads(core.read_text('utf8')) if core.is_file() else None),
                headroom_transitions=run.get('phone_rx_headroom_transitions',[]),
                socket_after_growth=socket_after_growth(rows,run.get('phone_rx_headroom_transitions',[])),
                after_growth=after_growth(phone['epochs'],run.get('phone_rx_headroom_transitions',[])),
                burst_margin_exposure=bounded_margin_exposure(rows,phone['epochs'],run.get('reader_margin_transitions',[])),
                burst_margin_gate_replay=margin_opportunities(json.loads(phases.read_text('ascii')),rows) if phases.is_file() else None,
                queue_age_profile=queue_age_profile(rows),
                first_five_minutes=prefix(phone['epochs'],300),
                whole=subset(run['playback'],('usable_decode_seconds','video_mbps','rendered_fps','frame_gaps',
                    'largest_gap_ms','render_errors','clean_windows','windows','sustained_20mbps_60fps')),
                windows_sender=host_density(path/'host-numeric.ssmeta'),receiver=burst_summary(rows))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run')
    args=p.parse_args();root=Path(__file__).resolve().parents[1]/'.generated/lan-compare'
    candidate=(root/args.run).resolve()
    if candidate.parent!=root.resolve() or not candidate.is_dir():p.error('owned local LAN run required')
    print(json.dumps(recap(candidate),indent=2))
