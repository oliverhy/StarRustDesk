"""Offline numeric analysis of the *first* missing frame vs delivered frames.

Lost dependent pictures after a first miss are not independent events. Never
use their sizes or the ending IDR size as evidence about what triggered it.
"""
import argparse
import json
import math
from pathlib import Path
from struct import Struct

ROW=Struct('<BIIQQ')


def analyze(trace,gaps):
    length=trace.stat().st_size
    if length<3*ROW.size or length%ROW.size or length>100_000_025:raise ValueError('unsealed_numeric_trace')
    frames={};last=[0,0];overlap=[set(),set()]
    with trace.open('rb') as f:
        f.seek(-ROW.size,2)
        if ROW.unpack(f.read())!=(255,0,0,length//ROW.size-1,0):raise ValueError('unsealed_numeric_trace')
        f.seek(0);left=length-ROW.size
        while left:
            data=f.read(min(left,16384*ROW.size));left-=len(data)
            if not data or len(data)%ROW.size:raise ValueError('partial_trace')
            for kind,frame,t,cost,_ in ROW.iter_unpack(data):
                if kind not in (0,1) or not 1<=frame<=65536:raise ValueError('unexpected_epoch')
                # Counts, first/last millisecond of sending, wire size only.
                a=frames.setdefault(frame,[0,0,0,None,None,None])
                if frame<last[kind]:overlap[kind].add(frame)
                last[kind]=max(frame,last[kind])
                a[kind]+=1
                if not kind:
                    if not 1<=cost<=2048:raise ValueError('wire_count_missing')
                    a[2]+=cost
                    if a[5] is None:a[5]=t
                else:
                    if a[3] is None:a[3]=t
                    a[4]=t
    if not frames or len(frames)!=max(frames)-min(frames)+1:raise ValueError('noncontiguous_source')
    missing=set();heads=set()
    for row in gaps:
        prev,end,n=row[1:4]
        if n==0:continue
        if not (0<n<=20000 and end==prev+n+1 and prev in frames and end in frames):
            raise ValueError('invalid_gap')
        ids=set(range(prev+1,end))
        if missing & ids:raise ValueError('overlapping_gaps')
        missing|=ids;heads.add(prev+1)
    def group(ids):
        def stats(v):
            s=sorted(v);return {k:s[math.ceil(len(s)*p)-1] if s else None for k,p in [('p50',.5),('p95',.95),('max',1)]}
        v=[frames[i] for i in ids]
        return dict(n=len(v),source_packets=stats([a[0] for a in v]),source_packets_exactly64=sum(a[0]==64 for a in v),wire_bytes=stats([a[2] for a in v]),
                    wire_ge64KiB=sum(a[2]>=65536 for a in v),source_packets_ge64=sum(a[0]>=64 for a in v),
                    send_span_ms=stats([a[4]-a[3] for a in v if a[3] is not None]),
                    short_at_sender=sum(a[0]!=a[1] for a in v),
                    tail_after_later_source=len(ids&overlap[0]),tail_after_later_send=len(ids&overlap[1]))
    # Only compare the range with actual receiver callback coverage. Pre/post
    # captures cannot show whether an unobserved frame was delivered.
    return group,frames,heads,missing


def summary(folder):
    report=json.loads((folder/'result.json').read_text('utf-8'))
    phone=json.loads((folder/'phone-numeric.json').read_text('utf-8'))
    a=report['attribution']
    if (report.get('route')!='lan' or a.get('host_trace_complete')!=1 or a.get('host_stream_epochs')!=1
        or len(phone['epochs'])!=1 or a.get('mapped_missing')!=a.get('reported_missing')):raise ValueError('not_one_complete_lan_epoch')
    epoch=phone['epochs'][0];gaps=epoch['gap_events']
    ingress={}
    if obs:=report.get('host_source_rx'):
        from lan_rate_control import source_rx_gap_overlap
        lines=(folder/'host-path-numeric.txt').read_text('ascii').splitlines()
        ingress['windows_source_counter']=obs
        ingress['first_frame_overlap']=source_rx_gap_overlap(lines,obs,[epoch])
    group,frames,heads,missing=analyze(folder/'host-numeric.ssmeta',gaps)
    if len(missing)!=a['reported_missing']:raise ValueError('gap_count_incomplete')
    # Even if no video frame was lost, count whether large input bursts
    # actually occurred in this run. This is host coverage, not receiver proof.
    ingress['source_frames_observed']=len(frames)
    ingress['source_frames_over64_packets']=sum(v[0]>64 for v in frames.values())
    ingress['source_max_packets_in_frame']=max(v[0] for v in frames.values())
    first=min(v[5] for v in frames.values() if v[5] is not None)
    active={}
    for f,v in frames.items():
        if v[5] is None:continue
        minute=(v[5]-first)//60_000
        bucket=active.setdefault(minute,[0,0,0,0])
        bucket[0]+=1;bucket[1]+=v[0]>64;bucket[2]+=v[0]==64;bucket[3]+=f in heads
    ingress['source_minutes']=[dict(minute=k,frames=v[0],over64=v[1],exactly64=v[2],gap_heads=v[3])
                                for k,v in sorted(active.items())]
    if not heads:return {'status':'no_reported_gap',**ingress}
    # First/last known received boundaries, not all source frames outside them.
    lo=min(r[1] for r in gaps if r[3]);hi=max(r[2] for r in gaps if r[3])
    delivered=set(range(lo,hi+1))-missing
    return {'status':'matched','first_missing':group(heads),'received_between_gaps':group(delivered),**ingress}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder',type=Path)
    print(json.dumps(summary(parser.parse_args().folder),indent=2))
