"""Offline WLAN send recovery -> phone Surface evidence. No frame contents or endpoint identifiers."""
import argparse
from bisect import bisect_right
import json
import math
from pathlib import Path
import re

from lan_encoder_witness import ANCHOR,frame_times,utc_base
from long_metrics import RECORD

DAY=86400000
STAMP=re.compile(r'(\d\d):(\d\d):(\d\d)\.(\d{3,6})')
RENDER=re.compile(r'render_gap at=(\d+) count=(\d+) gap=(\d+) call=(\d+) backlog=(\d+)')
RESUME=re.compile(r'lan_tx_resume elapsed_ms=(\d+) busy_us=(\d+) ready_seen=([01]) noticed_us=(\d+) to_send_us=(\d+) false_ready=\d+ attempts=\d+ holds=\d+')
PHASE3=re.compile(r'wan_tx_event phase=3 utc_ms=(\d{13}) elapsed_ms=(\d+) busy_ms=\d+ errno=(\d+) ready=\d+ flags=\d+ attempts=\d+ queue=0 packet=0 wakes=\d+ holds=\d+')


def wall_bounds(clocks):
    if len(clocks)!=2 or not all(isinstance(c,dict) for c in clocks):return None
    a,b=clocks
    if (a['tz_min']!=b['tz_min'] or not 0<b['host_ms']-a['host_ms']<1200000 or
        any(not 0<c['radius_ms']<=202 for c in clocks) or
        abs(a['offset_ms']-b['offset_ms'])>a['radius_ms']+b['radius_ms']+50):return None
    # Keep the wider end-to-end envelope; do not average away USB uncertainty.
    return (a['tz_min'],(a['host_ms']+b['host_ms'])//2,
            min(c['offset_ms']-c['radius_ms'] for c in clocks)-3,
            max(c['offset_ms']+c['radius_ms'] for c in clocks)+3)


def stamp_interval(stamp,clock):
    m=STAMP.fullmatch(stamp)
    if not m:return None
    h,mi,s=map(int,m.groups()[:3]);tz,mid,min_off,max_off=clock
    if h>23 or mi>59 or s>59:return None
    raw=((h*60+mi-tz)*60+s)*1000+int(m[4][:3])
    raw+=round((mid+(min_off+max_off)/2-raw)/DAY)*DAY
    return raw-max_off-1,raw-min_off+1


def known_missing(epoch,first,last):
    # Count only disjoint explicitly skipped frame IDs in the single sealed stream.
    ranges=[];total=0
    for e in epoch['gap_events']:
        _,prev,frame,n,*_=e
        if not n:continue
        if n<0 or frame-prev-1!=n or not first<=prev<frame<=last or (ranges and prev<ranges[-1][1]):
            return []
        ranges.append((prev+1,frame-1));total+=n
    return ranges if total==epoch['samples'][-1][5] else []


def single(span,events,samples,first,frame_utc,source_guard,missed,resumes,idr_units=()):
    a,b=span['begin_ms'],span['end_ms']
    cut=bisect_right(frame_utc,b+source_guard)
    if not 0<cut<len(frame_utc):return {'status':'outside_source_timeline'}
    premax=cut-sum(max(0,min(first+cut-1,y)-x+1) for x,y in missed)
    # If the Surface render count exceeds the number of distinct old pictures
    # that could have been received, at least one newly sourced picture reached
    # the Surface. No need to assume the first post-gap render was itself fresh.
    fresh=[hi-b for lo,hi,n in samples if n>premax and hi>=b]
    fresh.extend(hi-b for lo,hi,n,gap in events if n>premax and hi>=b)
    out=dict(blocked_ms=span['busy_ms'],errno=span['errno'],
             phone_gateway_ok_while_pc_failed=bool(span.get('phone_ok_during_pc_failure')),
             new_source_surface_upper_ms=min(fresh,default=None))
    # The phone logs only exceptional decode callbacks. Report a witnessed IDR,
    # not necessarily the first IDR, never as a render/panel measurement.
    for frame,lo,hi in idr_units:
        ix=frame-first
        if not 0<=ix<len(frame_utc):continue
        at=frame_utc[ix]-b
        if not source_guard<at<3000 or hi-b>3500:continue
        left=max(math.floor(at-source_guard),lo-b)
        if left>hi-b:continue
        out['new_idr_callback_interval_ms']=[left,hi-b]
        out['host_first_packet_of_idr_ms']=round(at)
        break
    wake=resumes.get((b,span['errno']))
    out['observed_writable_to_send_us']=wake[0] if wake and abs(wake[1]/1000-span['busy_ms'])<=3 else None
    # Require a single render gap spanning the middle of the Windows refusal
    # even allowing for the full USB clock envelope. Confirm its render count
    # against periodic phone samples either side (not merely matching durations).
    middle=(a+b)/2
    matched=[(lo,hi,n,g) for lo,hi,n,g in events if hi-g+2<middle<lo and
             hi>=b-300 and lo<=b+3000 and any(before==n-1 and late<lo for _,late,before in samples) and
             any(after>=n and early>hi for early,_,after in samples)]
    if len(matched)!=1:return dict(out,status='ambiguous' if matched else 'no_confirmed_crossing_render')
    lo,hi,n,g=matched[0]
    return dict(out,status='crossing_render',render_gap_ms=g,
                render_after_send_interval_ms=[lo-b,hi-b],
                order_proven=lo>=b,render_count=n)


def next_wire(rows,ends,first,frame_ms):
    """Clock in wire ledger and phase-3 elapsed_ms shares the same host Instant.

    Use the first video shard after a real dry spell. trace.wire() runs just
    before sent(); integer timestamps can therefore differ by a millisecond.
    Never claim actual over-the-air delivery from this Windows observation.
    """
    pending=iter(sorted(ends));p=next(pending,None);out={};prior=None
    for kind,n,t,_,_ in rows:
        if p is None:break
        if kind!=1:continue
        if prior is not None and t<prior:return {}
        while p is not None and t>=p-1:
            ix=n-first
            if prior is not None and t-prior>=140 and 0<=ix<len(frame_ms) and 0<=t-frame_ms[ix] and t-p<=3000:
                out[p]=dict(source_frame=n,age_ms=t-frame_ms[ix],relative_ms=t-p)
            p=next(pending,None)
        prior=t
    return out


def report(folder):
    load=lambda name:json.loads((folder/name).read_text('utf-8'))
    def unavailable(s):return dict(status='unavailable',reason=s)
    r=load('result.json');w=r.get('wifi_uplink',{})
    if not (r['route']=='lan' and r.get('encrypted_video_audio') is True and
            r.get('usb_forward') is False and r.get('primary_capture_confirmed') is True and
            w.get('wlan_registered') and w.get('phone_source_bound') and
            r.get('attribution',{}).get('host_trace_complete')==1 and
            r.get('attribution',{}).get('host_stream_epochs')==1 and
            r.get('windows_medium_at_boundaries',['wifi','wifi'])==['wifi','wifi']):
        return unavailable('not_single_verified_wireless_lan')
    spans=w.get('long_refusals',[])
    if w.get('clock_inconsistent_spans'):return unavailable('sender_clock_discontinuity')
    if not spans:return dict(status='no_windows_refusal_ge150ms',events=[])
    c=load('encoder-size-numeric.json')['clocks'];clock=wall_bounds(c)
    if not clock:return unavailable('phone_clock_unverified')
    p=load('phone-numeric.json');epochs=p.get('epochs',[])
    if len(epochs)!=1:return unavailable('non_unique_decoder')
    ep=epochs[0];samples=[]
    if not ep['samples'] or len(ep['samples'])!=len(ep['sample_stamps']):return unavailable('missing_samples')
    for v,stamp in zip(ep['samples'],ep['sample_stamps']):
        t=stamp_interval(stamp,clock)
        if (not t or t[1]<c[0]['host_ms']-400 or t[0]>c[1]['host_ms']+400 or
            not 0<=v[3]<=v[2]<=v[1] or (samples and (v[3]<samples[-1][2] or
                t[0]<=samples[-1][0] or abs((t[0]-samples[0][0])-(v[0]-ep['samples'][0][0]))>100))):
            return unavailable('phone_sample_discontinuity')
        samples.append((*t,v[3]))
    path=folder/'host-numeric.ssmeta';frames=frame_times(path)
    lines=(folder/'host-path-numeric.txt').read_text('ascii').splitlines()
    base=utc_base(lines)
    if not frames or base is None:return unavailable('unsealed_source_or_clock')
    with path.open('rb') as f:
        while (row:=f.read(RECORD.size)):
            kind,first,*_=RECORD.unpack(row)
            if kind==0:break
    if first!=1:return unavailable('source_start_not_witnessed')
    anchors=[m for l in lines if (m:=ANCHOR.fullmatch(l))]
    guard=3+max(abs(int(m[3])-int(m[2])/1000-base)+int(m[4])/1000 for m in anchors)
    frame_utc=[base+x for x in frames];missed=known_missing(ep,first,first+len(frames)-1)
    if ep['samples'][-1][1]>len(frames)-sum(y-x+1 for x,y in missed):return unavailable('picture_counts_inconsistent')
    events=[]
    for stamp,line in p['events']:
        m=RENDER.fullmatch(line)
        if not m:continue
        t=stamp_interval(stamp,clock)
        if not t:return unavailable('render_clock_invalid')
        events.append((*t,int(m[2]),int(m[3])))
    idr_units=[]
    if len(ep['gap_events'])==len(ep['gap_stamps']):
        for unit,stamp in zip(ep['gap_events'],ep['gap_stamps']):
            t=stamp_interval(stamp,clock)
            if unit[7]==1 and t:idr_units.append((unit[2],*t))
    rec={};resumes={};ends={}
    for line in lines:
        if m:=RESUME.fullmatch(line):
            if m[3]=='1':rec[int(m[1])]=(int(m[5]),int(m[2]))
        elif m:=PHASE3.fullmatch(line):
            val=rec.pop(int(m[2]),None)
            if val:resumes[int(m[1]),int(m[3])]=val
            ends[int(m[1])]=int(m[2])
    out=[single(s,events,samples,first,frame_utc,guard,missed,resumes,idr_units) for s in spans]
    wanted={ends[s['end_ms']] for s in spans if s['end_ms'] in ends}
    wire=next_wire(RECORD.iter_unpack(path.read_bytes()),wanted,first,frames) if wanted else {}
    for s,e in zip(spans,out):
        if (witness:=wire.get(ends.get(s['end_ms']))) is not None:e['first_host_video_after_refusal']=witness
    return dict(status='measured',phone_clock_offset_range_ms=list(clock[2:]),
                events=out)


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('run_folder',type=Path)
    print(json.dumps(report(ap.parse_args().run_folder),indent=2))
