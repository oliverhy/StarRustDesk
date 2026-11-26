"""Attribute a LAN video silence without equating UDP send success with delivery."""
import re

from long_metrics import RECORD

class Stage(list):
    def __init__(self):
        super().__init__();self.first={};self.last={}
    def mark(self,frame,ms):
        if self and self[-1]==(frame,ms) and self.first.get(frame)!=len(self)-1:return  # keep evidence of two datagrams
        index=len(self);self.first.setdefault(frame,index);self.last[frame]=index;self.append((frame,ms))


def stages(path):
    # The sealed 10 min, high-bitrate LAN writer can produce 4M numeric records.
    if not path.is_file() or not 25<=path.stat().st_size<=100_000_025: return None
    data=path.read_bytes()
    if len(data)%RECORD.size: return None
    end=RECORD.unpack_from(data,len(data)-RECORD.size)
    if end!=(255,0,0,len(data)//RECORD.size-1,0): return None
    out=[Stage(),Stage()]; epochs=0; peak=0
    for kind,frame,ms,_,_ in RECORD.iter_unpack(memoryview(data)[:-RECORD.size]):
        if kind not in (0,1) or (out[kind] and ms<out[kind][-1][1]): return None
        if kind==0:
            if frame<=32 and peak>=frame+64: epochs+=1; peak=0
            peak=max(peak,frame)
        out[kind].mark(frame,ms)
    if epochs or not all(out): return None  # repeated frame IDs after a rebuild are ambiguous
    return out


def bounds(rows,prev,frame):
    # Only frame IDs (not packet sequence/contents) are exported by the phone.
    # Include BOTH entire boundary frames for the upper bound: a silence may
    # occur between fragments of one frame. The inner bound excludes both tails.
    if not 0<=frame-prev<=20_000: return None,None
    first=rows.first.get(prev) if isinstance(rows,Stage) else next((i for i,(f,_) in enumerate(rows) if f==prev),None)
    if first is None: return None,None
    last=rows.last.get(frame) if isinstance(rows,Stage) else next((i for i in range(len(rows)-1,first-1,-1) if rows[i][0]==frame),None)
    if last is None or last<=first or any(not prev<=f<=frame for f,_ in rows[first:last+1]): return None,None
    peak=lambda a,b:max((rows[i][1]-rows[i-1][1] for i in range(a+1,b+1)),default=0)
    outer=peak(first,last)
    if prev==frame: return None,outer
    a=first
    while a<last and rows[a+1][0]==prev: a+=1
    b=last
    while b>a and rows[b-1][0]==frame: b-=1
    return peak(a,b),outer


def locate(source,wire,phone,loop):
    smin,smax=source; wmin,wmax=wire
    if None in (smax,wmax) or loop>=phone*.65: return 'unresolved'
    if smax<phone*.5 and wmax<phone*.5: return 'after_host_udp_accept_before_phone_tunnel'
    if None in (smin,wmin): return 'unresolved'
    if smin>=phone*.7 and wmin>=phone*.7: return 'at_or_before_host_video_ingress'
    if smax<phone*.5 and wmin>=phone*.7: return 'between_host_ingress_and_udp_accept'
    return 'mixed_or_unresolved'


def timeline(trace,recorder):
    out=stages(trace); gaps=[]; by_frame=set()
    samples=[e['samples'] for e in recorder.epochs if e['samples']]
    clean_epoch=len(samples)==1
    matching=bool(out and clean_epoch and abs(samples[0][-1][0]-(out[0][-1][1]-out[0][0][1]))<12_000)
    for _,line in recorder.path:
        m=re.fullmatch(r'video_path stage=2 ms=(\d+) packets=\d+ event_gap=(\d+) peak_gap=\d+ previous_frame=(\d+) frame=(\d+) loop_peak=(\d+)',line)
        if not m: continue
        stamp,delay,prev,frame,loop=map(int,m.groups())
        if delay<140 or (stamp,prev,frame) in by_frame: continue
        by_frame.add((stamp,prev,frame))
        s,w=(bounds(x,prev,frame) for x in out) if matching else ((None,None),(None,None))
        gaps.append(dict(phone_elapsed_ms=stamp,previous_frame=prev,frame=frame,phone_packet_gap_ms=delay,
                         phone_loop_peak_ms=loop,host_ingress_peak_ms=s[1],host_udp_accept_peak_ms=w[1],
                         host_ingress_inner_ms=s[0],host_udp_accept_inner_ms=w[0],
                         first_observed_stage=locate(s,w,delay,loop)))
    peaks=[max((b[1]-a[1] for a,b in zip(rows,rows[1:])),default=0) for rows in out] if out else [None,None]
    return dict(complete_single_host_epoch=out is not None,single_phone_epoch=clean_epoch,matching_duration=matching,
                host_ingress_peak_ms=peaks[0],host_udp_accept_peak_ms=peaks[1],
                phone_gap_threshold_ms=140,gaps=gaps)
