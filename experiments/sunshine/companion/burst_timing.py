"""Compare the SAME video datagrams at Windows send, relay ingress and relay read.

Only relative spans from each machine's own clock are comparable. They are
not one-way latency. No addresses, video data or absolute kernel timestamps.
"""
import struct
from udp_broker import BURST_ROW, SHAPE_MAX_DELAY

HOST=struct.Struct("<BIIQQ")


def compare_peaks(blobs, host_file):
    if not blobs: return {"status":"no_observed_limited_peak"}
    if len(blobs)>68: return {"status":"bad_peak"}
    windows=[]; ids=set()
    for blob in blobs:
        if not blob or len(blob)%BURST_ROW.size or len(blob)>64*BURST_ROW.size: return {"status":"bad_peak"}
        rows=list(BURST_ROW.iter_unpack(blob))
        keys={(tag,seq) for tag,seq,*_ in rows}
        if len(rows)!=len(keys) or any(not 80<=cost<=1356 or read>SHAPE_MAX_DELAY*1e6+1 or
                not -1<=kernel<=2_000_000 for _,_,cost,read,kernel in rows):
            continue  # duplicated datagrams cannot be individually timed
        windows.append(rows); ids.update(keys)
    if not host_file.is_file() or not 0<host_file.stat().st_size<=40_000_025:
        return {"status":"no_complete_host_trace"}
    data=host_file.read_bytes()
    if not data or len(data)%HOST.size: return {"status":"no_complete_host_trace"}
    kind,_,_,count,missed=HOST.unpack_from(data,len(data)-HOST.size)
    if kind!=255 or count!=len(data)//HOST.size-1 or missed: return {"status":"no_complete_host_trace"}
    sent={}
    for kind,_,ms,tag,seq in HOST.iter_unpack(data):
        if kind!=1 or (tag,seq) not in ids: continue
        if (tag,seq) in sent: return {"status":"ambiguous_host_counter"}
        sent[tag,seq]=ms
    matches=[summarize_window(rows,sent) for rows in windows]
    usable=[w for w in matches if w["status"]=="matched"]
    peak=max(usable,key=lambda w:w["video_wire_bytes"]) if usable else {"status":"no_verified_video_peak"}
    return dict(peak,sampled_windows=len(blobs),matched_windows=len(usable))


def summarize_window(rows,sent):
    selected=[(sent[tag,seq],read,kernel,cost) for tag,seq,cost,read,kernel in rows if (tag,seq) in sent]
    out=dict(window_packets=len(rows),matched_video_packets=len(selected),wire_bytes=sum(r[2] for r in rows))
    if len(selected)<4: return dict(out,status="too_few_matching_video_packets")
    host,read,kernel,wire=zip(*selected)
    out.update(status="matched",video_wire_bytes=sum(wire),host_span_ms=max(host)-min(host),
               relay_read_span_us=max(read)-min(read),kernel_span_us=None)
    if min(kernel)>=0: out["kernel_span_us"]=max(kernel)-min(kernel)
    return out
