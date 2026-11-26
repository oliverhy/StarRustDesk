"""Read-only per-stall evidence. Never treat a truncated trace as a full run."""
import argparse,base64,json,re,struct,zlib
from collections import Counter,defaultdict
from pathlib import Path
from phone_socket_observation import gap_windows

def restart_windows(events):
    """Join a single quality transition's own monotonic timings, never wall clocks."""
    spans=[]; pending=None
    for _,msg in events:
        phase=re.fullmatch(r"switch_timing phase=(core_stopped|setup_received|first_render) ms=(\d{1,6})",msg)
        if phase and phase[1]=="core_stopped":
            pending={"stopped":int(phase[2])};continue
        if pending is None:continue
        rate=re.fullmatch(r"quality_restart from_kbps=(\d+) to_kbps=(\d+)",msg)
        total=re.fullmatch(r"render_across_restart_ms=(\d+)",msg)
        if rate:
            if "rate" in pending or "setup" in pending: pending=None;continue
            pending["rate"]=(int(rate[1]),int(rate[2]))
        elif phase and phase[1]=="setup_received":
            if "rate" not in pending or "setup" in pending:pending=None;continue
            pending["setup"]=int(phase[2])
        elif total:
            if "setup" not in pending or "total" in pending:pending=None;continue
            pending["total"]=int(total[1])
        elif phase and phase[1]=="first_render":
            first=int(phase[2]);p=pending;pending=None
            if "total" in p and p["stopped"]<=p["setup"]<=first<=p["total"]:
                spans.append(dict(from_kbps=p["rate"][0],to_kbps=p["rate"][1],
                    last_to_first_ms=p["total"],before_request_ms=p["total"]-first,
                    request_to_setup_ms=p["setup"],setup_to_present_ms=first-p["setup"],
                    request_to_present_ms=first))
    return spans

def freshness_windows(events):
    """Separate the silence before stale data arrives from time to a rendered fresh IDR.
    Only join counters with the same monotonic origin; do not persist frame IDs or PTS."""
    out=[];pending=None
    for _,msg in events:
        if msg.startswith(("decoder_setup_code=", "quality_restart ", "core_connection_end=")):
            pending=None
        req=re.fullmatch(r"freshness_request at=(\d+) frame=\d+ gap_ms=(\d+) extra_ms=(\d+) request=1",msg)
        if req:
            pending=tuple(map(int,req.groups()));continue
        render=re.fullmatch(r"freshness_render at=(\d+) wait_ms=(\d+) pts_ms=\d+",msg)
        if render and pending:
            at,silence,extra=pending; pending=None
            end,wait=map(int,render.groups())
            if end>=at and end-at==wait:
                out.append(dict(prior_unit_silence_ms=silence,stale_above_floor_ms=extra,
                                recovery_to_fresh_present_ms=wait))
    return out

def multi_report(folder,p,relayed):
    # The host join already separates media sequence-number resets. Phone packet
    # ledgers in old recordings do not: never use a later decoder's row for an
    # earlier frame just because both have the same number.
    meta=json.loads((folder/"result.json").read_bytes())["attribution"]
    epochs=[e for e in p["epochs"] if e.get("samples")]
    paths=json.loads((folder/"missing-frame-path.json").read_bytes())
    if not (meta.get("host_trace_complete") and meta.get("relay_trace_complete") and
            meta.get("host_stream_epochs")==len(paths)==len(epochs)): raise ValueError("epoch_alignment_not_verified")
    spans=sorted(((i,g) for i,e in enumerate(epochs) for g in e["gap_events"]),key=lambda item:-item[1][4])[:5]
    for i,(at,lo,hi,n,ms,*_) in spans:
        if not 0<hi-lo<=4096 or hi-lo!=n+1: continue
        if not n:
            print("epoch",i+1,"gap_ms",ms,"consecutive_frames_no_skipped_sequence");continue
        counts=Counter(); times=[]
        for frame in range(lo+1,hi):
            r=paths[i].get(str(frame),{}); source=r.get("source_packets",0); sent=r.get("sent_packets",0)
            if source: times.append(r["first_source_ms"])
            if not source: key="no_host_source_record"
            elif sent!=source: key="host_send_short"
            elif not relayed: key="sent_by_host_phone_unverified"
            elif r.get("relay_rate_limited"): key="relay_limited"
            elif r.get("relay_forwarded",0)==sent: key="forwarded_by_relay_phone_unverified"
            else: key="not_confirmed_forwarded"
            counts[key]+=1
        waits=sum(msg.startswith("core_wait_idr at=") and at-ms<=int(msg.split("=")[1])<=at for _,msg in p["events"])
        print("epoch",i+1,"gap_ms",ms,"missing",n,"host_max_spacing_inside_gap_ms",
              max((b-a for a,b in zip(times,times[1:])),default=None),"path",dict(counts),"phone_wait_samples",waits)

def report(folder):
    load=lambda name:json.loads((folder/name).read_bytes())
    p=load("phone-numeric.json")
    for transition in restart_windows(p["events"]):print("quality_transition",transition)
    for window in freshness_windows(p["events"]):print("fresh_picture",window)
    if (folder/"phone-socket-numeric.json").is_file():
        socket=load("phone-socket-numeric.json")
        windows=gap_windows(socket["samples"],p["epochs"],socket.get("utc_offset_minutes"))
        print("phone_socket_observed_ms",socket["summary"]["covered_ms"],"covered_gap_windows",windows)
    result=load("result.json"); cause=result.get("attribution",{})
    relayed=result["playback"]["route"]=="relay"
    if not cause.get("host_trace_complete") or (relayed and not cause.get("relay_trace_complete")):
        print("incomplete_hop_trace_attribution_withheld");return
    if len(p["epochs"])!=1: return multi_report(folder,p,relayed)
    rx=load("phone-packet-counts.json") if (folder/"phone-packet-counts.json").is_file() else dict(valid=False,status=[0],blocks={})
    blocks={int(k):bytes.fromhex(v) for k,v in rx["blocks"].items()}
    relay={int(k):zlib.decompress(base64.b64decode(v)) for k,v in load("relay-packet-status.json").items()} if relayed else {}
    spans=sorted(p["epochs"][0]["gap_events"],key=lambda g:-g[4])[:5]
    wanted={i for _,lo,hi,*_ in spans if 0<hi-lo<=4096 for i in range(lo,hi+1)}
    rows=defaultdict(Counter); times=defaultdict(list); end_frame=0
    for kind,frame,ms,tag,counter in struct.iter_unpack("<BIIQQ",(folder/"host-numeric.ssmeta").read_bytes()):
        if kind==0: end_frame=max(end_frame,frame)
        if frame not in wanted:continue
        if kind==0: rows[frame]["source"]+=1;times[frame].append(ms)
        if kind==1:
            rows[frame]["sent"]+=1
            states=relay.get(tag,b"")
            rows[frame][states[counter] if counter<len(states) else 0]+=1
    for at,lo,hi,n,ms,*_ in spans:
        if not n and hi==lo+1:
            print("gap_ms",ms,"consecutive_frames_no_skipped_sequence");continue
        if hi>=end_frame or not 0<hi-lo<=4096:
            print("gap_ms",ms,"missing",n,"outside_host_trace");continue
        tots=Counter();packets=Counter();all_observed=True
        for f in range(lo+1,hi):
            r=rows[f]; off=(f-1)%128; block=blocks.get(f-off,b"")
            packets["source"]+=r["source"];packets["sent"]+=r["sent"]
            if relayed: packets["relay_forwarded"]+=r[1]
            observed=rx["valid"] and not any(rx["status"][1:]) and len(block)>=2*off+2
            all_observed &= bool(observed)
            if observed:
                packets["authenticated"]+=block[2*off];packets["loopback"]+=block[2*off+1]
            if not r["source"]: tots["no_host_source_record"]+=1
            elif r["sent"]!=r["source"]: tots["host_send_short"]+=1
            elif relayed and (r[2] or r[4]): tots["relay_limited"]+=1
            elif relayed and r[1]!=r["sent"]:tots["unconfirmed_relay_delivery"]+=1
            elif not observed:tots["phone_unobserved"]+=1
            elif block[2*off]!=r["sent"]: tots["missing_on_phone_ingress"]+=1
            elif block[2*off+1]!=block[2*off]:tots["phone_local_delivery_short"]+=1
            else:tots["all_packets_delivered"]+=1
        source=[min(times[f]) for f in range(lo,hi+1) if times[f]]
        events=Counter()
        for _,msg in p["events"]:
            for key in ("core_wait_idr","freshness_request","freshness_submit","freshness_render"):
                if msg.startswith(key+" at=") and at-ms<=int(msg.split("at=")[1].split()[0])<=at:events[key]+=1
        print("gap_ms",ms,"missing",n,"host_max_spacing_ms",max((b-a for a,b in zip(source,source[1:])),default=None),
              "path",dict(tots),"phone_events",dict(events),"packets",
              {k:v for k,v in packets.items() if all_observed or k not in ("authenticated","loopback")})
if __name__=="__main__":
    ap=argparse.ArgumentParser();ap.add_argument("folder",type=Path);report(ap.parse_args().folder)
