"""Numeric-only sustained playback and per-missing-frame path analysis."""
from collections import Counter
from bisect import bisect_left
import json
import math
from pathlib import Path
import re
import statistics
import struct
import phone_burst_metrics
import phone_dispatch
import core_rx_diag

from windows_companion import event, require

STAMP=re.compile(r"\b\d{2}:\d{2}:\d{2}\.\d{3,6}\b")
SAMPLE=re.compile(r"secure_sample ms=(\d+) received=(\d+) submitted=(\d+) rendered=(\d+) "
                  r"bytes=(\d+) gaps=(\d+) idr=(\d+) render_fail=(\d+) max_gap_ms=(\d+) "
                  r"rtt=(\d+) var=(\d+)")
GAP=re.compile(r"unit_gap at=(\d+) previous_frame=(\d+) frame=(\d+) missing=(\d+) gap=(\d+) "
               r"assembly=(\d+) callback_wait=(\d+) idr=([01]) host_01ms=(\d+)")
RATE=re.compile(r"bandwidth_video requested_kbps=(\d+) applied_kbps=(\d+)")
PATH=re.compile(r"video_path stage=[23] ms=\d+ packets=\d+ event_gap=\d+ peak_gap=\d+ "
                r"previous_frame=\d+ frame=\d+ loop_peak=\d+")
PAIR=re.compile(r'rx_ledger_gap_pair ms=(\d{1,10}) f0=(\d{1,10}) f1=(\d{1,10}) c0=(\d{1,20}) c1=(\d{1,20}) '
                r'auth=(\d{1,8}) kernel=(\d{1,8}) read=(\d{1,8}) q0=(\d{1,7}) q1=(\d{1,7}) p0=(\d{1,7}) p1=(\d{1,7})')
PAIR_END=re.compile(r'rx_ledger_gap_pair_end gaps=(\d{1,10}) matched=(\d{1,2})')
META=re.compile(r"(?:companion_bench_lan_candidate saved_address_matches=[01]|video_recovery request=\d+ idle_ms=\d+ delivered=\d+|"
                r"lan_key_phase f=\d{1,10} first=\d{1,16} loss=\d{1,16} wait=\d{1,16} kind=[012] queue=\d{1,16} sent=\d{1,16} last=\d{1,16} nq=\d{1,7} ns=\d{1,7}|"
                r"lan_key_out f=\d{1,10} first=\d{1,16} unit=\d{1,16} surface=\d{1,16} exact=[01] idr=[01] backup=\d{1,16} tries=[012]|"
                r"lan_key_shard_policy=1|lan_key_shard f=\d{1,10} first=\d{1,16} lf=\d{1,10} loss=\d{1,16} why=[012] floor=\d{1,10} nf=\d{1,10} admit=\d{1,16} parity=[01] reloss=[01]|"
                r"rx_ledger_ahead packets=\d{1,10} blocks=\d{1,10} oldest_us=\d{1,10}|"
                r"lan_key_reject f=\d{1,10} why=[1234] at=\d{1,16} idr=[01]|lan_key_censored first=\d{1,16} source=[1234] sent=\d{1,7} tries=[012]|"
                r"lan_key_slot f=\d{1,10} wait_us=\d{1,12} pushed=[01] idr=[01]|lan_key_slot_end tries=\d{1,10} pushed=\d{1,10}|lan_key_slot_policy=1|"
                r"lan_slot_return f=\d{1,10} us=\d{1,12} seen=[01]|lan_slot_return_end kept=\d{1,3} overflow=\d{1,10}|"
                r"lan_key_policy=[01]|lan_rx_recovery_ready=1|lan_loss_idr_retry=1|lan_loss_recovered unit_ms=\d{1,10} surface_ms=\d{1,10} idr=[01] retry=[01](?: source=[1234])?|"
                r"input_lane_end phase=[a-z_]+ replies=\d+ last_reply_ms=\d+ peak_tick_ms=\d+ peak_loop_ms=\d+|"
                r"freshness_request at=\d+ frame=\d+ gap_ms=\d+ extra_ms=\d+ request=\d+|"
                r"freshness_submit at=\d+ frame=\d+ skipped=\d+ extra_ms=\d+ wait_ms=\d+ requests=\d+|"
                r"freshness_render at=\d+ wait_ms=\d+ pts_ms=\d+|"
                r"host_pipeline_meta ms=\d+ nonzero=\d+ avg_01ms=\d+ max_01ms=\d+|"
                r"render_gap at=\d+ count=\d+ gap=\d+ call=\d+ backlog=\d+|"
                r"core_wait_idr at=\d+|confirmed_idr_retry wait_ms=\d+ attempt=[12]|compact_idr_retry wait_ms=\d+|render_across_restart_ms=\d+|"
                r"rtsp_stage=(?:wait_response|read_response|send_request|options|describe|setup_audio|setup_video|setup_control|announce|play) error=-?\d{1,10}|"
                r"core_stage_failed=-?\d{1,3} error=-?\d{1,10}|"
                r"quality_high_probe_safe_fallback_no_upshift=1|quality_restart from_kbps=\d+ to_kbps=\d+)")
RX_CHUNK=re.compile(r"rx_ledger first=(\d{1,5}) pairs=([0-9a-f]{512})")
RX_STATUS=re.compile(r"rx_ledger_status covered=(\d{1,5}) late=(\d{1,10}) untracked=(\d{1,10})")
RX_SOCKET=re.compile(r"rx_ledger_socket before=(\d{1,9}) effective=(\d{1,9}) qualified=([01]) drops=(-1|\d{1,10})")
RECORD=struct.Struct("<BIIQQ")


def percentile(values,p):
    return sorted(values)[max(0,math.ceil(len(values)*p)-1)] if values else 0


def output_acceptance(epochs,metrics,width,height,fps,seconds,source=None):
    """A requested size, a short clean window, and a padded buffer are not proof of stable output."""
    pictures=[e.get("presented_pictures",[]) for e in epochs]
    verified=bool(pictures) and all(bool(e.get("samples")) and bool(sizes) and
        all(tuple(s)==(width,height) for s in sizes) for e,sizes in zip(epochs,pictures))
    observed=sorted({tuple(s) for sizes in pictures for s in sizes})
    longest=metrics.get("longest_including_restart_ms")
    measured=metrics["windows"]
    checks=dict(decoded_dimensions=verified,coverage=bool(metrics["coverage_ok"] and
        metrics["secs"]>=seconds*.88 and measured>=max(1,seconds//10-2)),
        average_fps=metrics["rendered_fps"]>=fps*.97,
        clean_windows=measured>0 and metrics["clean_windows"]>=math.ceil(measured*.90),
        frame_loss=metrics["frame_gaps"]<=math.floor(seconds*fps*.001),
        decode_errors=metrics["render_errors"]==0,no_long_pause=longest is not None and longest<=250)
    if source is not None:
        # One count per new encoded picture at the host, not UDP fragments,
        # display refreshes, or the frame rate in the requested configuration.
        checks["host_source_cadence"]=(source.get("host_trace_complete")==1 and
            source.get("host_frame_span_ms",0)>=seconds*880 and source.get("host_observed_fps",0)>=fps*.97)
    return dict(expected=[width,height,fps],observed_pictures=observed,checks=checks,passed=all(checks.values()))


class Recorder:
    def __init__(self, case, folder, target_fps=30):
        self.case,self.folder=case,folder
        self.target_fps=target_fps
        self.epochs=[]
        self.seen=set()
        self.events=[]
        self.path=[]
        self.rate=None
        self.next=60_000
        self.rx_blocks={}
        self.rx_status=(0,0,0)
        self.rx_invalid=False
        self.rx_socket=None
        self.rx_admission=None
        self.rx_bursts=[]
        self.rx_dispatch=[]
        self.rx_margin=[]
        self.rx_margin_comparison=0
        self.rx_headroom=[]

    def observe(self, raw):
        for row in raw.splitlines():
            _,sep,msg=row.partition("SesameSecureClient: ")
            if not sep: _,sep,msg=row.partition("SesameWanProbe: ")
            if not sep: continue
            msg=msg.strip()
            stamp=STAMP.search(row)
            key=(stamp[0] if stamp else "",msg)
            if key in self.seen: continue
            if match:=RATE.fullmatch(msg):
                self.rate=tuple(map(int,match.groups()))
            elif msg=="decoder_setup_code=0 enc_video=1 enc_audio=1":
                self.epochs.append(dict(samples=[],gap_events=[],gap_stamps=[],sample_stamps=[],peaks={},rate=self.rate))
            elif (match:=re.fullmatch(r"presented_picture width=(\d{1,4}) height=(\d{1,4})",msg)) and self.epochs:
                sizes=self.epochs[-1].setdefault("presented_pictures",[])
                size=tuple(map(int,match.groups()))
                if size not in sizes:sizes.append(size)
            elif (match:=re.fullmatch(r"render_window ms=(\d+) peak_ms=(\d+)",msg)) and self.epochs:
                self.epochs[-1]["peaks"][int(match[1])]=int(match[2])
            elif (match:=SAMPLE.fullmatch(msg)) and self.epochs:
                value=tuple(map(int,match.groups()))
                target=self.epochs[-1]["samples"]
                if not target or value[0]>target[-1][0]:
                    target.append(value)
                    self.epochs[-1]["sample_stamps"].append(key[0])
            elif (match:=GAP.fullmatch(msg)) and self.epochs:
                self.epochs[-1]["gap_events"].append(tuple(map(int,match.groups())))
                self.epochs[-1]["gap_stamps"].append(key[0])
            elif PATH.fullmatch(msg):
                self.path.append((key[0],msg))
            elif (msg.startswith('lan_core_') and core_rx_diag.parse(msg) is not None) or META.fullmatch(msg) or PAIR.fullmatch(msg) or PAIR_END.fullmatch(msg) or re.fullmatch(r"switch_timing phase=(?:core_stopped|setup_received|first_render) ms=\d{1,6}",msg):
                self.events.append((key[0],msg))
            elif match:=RX_CHUNK.fullmatch(msg):
                frame=int(match[1])
                if frame<1 or frame>65536 or (frame-1)%128: continue
                pairs=bytes.fromhex(match[2])
                if any(pairs[i+1]>pairs[i] for i in range(0,len(pairs),2)): continue
                previous=self.rx_blocks.setdefault(frame,pairs)
                if previous!=pairs: self.rx_invalid=True
            elif match:=RX_STATUS.fullmatch(msg):
                status=tuple(map(int,match.groups()))
                if status[0]<=65536 and status[0]>=self.rx_status[0]:
                    self.rx_status=status
            elif match:=RX_SOCKET.fullmatch(msg):
                before,effective,qualified,drops=map(int,match.groups())
                if not (0<before<=268435456 and 0<effective<=268435456 and drops<=0xffffffff): continue
                self.rx_socket=dict(before_bytes=before,effective_bytes=effective,high_rate_seen=bool(qualified),
                                    counted_drops=drops if drops>=0 else None)
            elif match:=re.fullmatch(r"rx_ledger_admission reason=([12]) base=(\d{1,9})",msg):
                reason,base=map(int,match.groups())
                if not (0<base<=268435456):continue
                self.rx_admission=dict(cause=('observed_rate' if reason==1 else 'standard_lan_offer'),base_bytes=base)
            elif match:=re.fullmatch(r"rx_ledger_headroom state=([123]) base=(\d{1,8}) effective=(\d{1,8})",msg):
                state,base,effective=map(int,match.groups())
                if len(self.rx_headroom)>=4 or not (0<base<=1024*1024 and 0<effective<=1024*1024):continue
                self.rx_headroom.append(dict(time=key[0] or None,state=state,base_bytes=base,effective_bytes=effective))
            elif msg=='rx_ledger_margin_comparison=1':
                self.rx_margin_comparison=min(2,self.rx_margin_comparison+1) if key[0] and not self.rx_margin else 2
            elif match:=re.fullmatch(r"rx_ledger_margin state=([1-4]) before=(\d{1,9}) effective=(\d{1,9})",msg):
                state,before,after=map(int,match.groups())
                if len(self.rx_margin)>=2 or not (0<after<=268435456):continue
                if (state in (1,3) and (self.rx_margin or before!=1048576)) or (state in (2,4) and
                    (not self.rx_margin or self.rx_margin[-1]['state']!=1 or before!=1572864)):continue
                if (state==1 and after!=1572864) or (state==2 and after!=1048576) or (state==3 and after==1572864) or (state==4 and after==1048576):continue
                self.rx_margin.append(dict(state=state,before=before,effective=after,time=key[0] or None))
            elif msg.startswith("rx_ledger_dispatch "):
                r=phone_dispatch.parse(msg)
                if not r or len(self.rx_dispatch)>=800 or (self.rx_dispatch and r['t']<=self.rx_dispatch[-1]['t']):continue
                self.rx_dispatch.append(r)
            elif msg.startswith("rx_ledger_burst "):
                r=phone_burst_metrics.parse(msg)
                if not r or len(self.rx_bursts)>=800 or self.rx_bursts and r['t']<=self.rx_bursts[-1]['t']:continue
                r['log_time']=key[0] or None
                # A read-ahead worker reports after the main loop tick. Never
                # align it with that later drop count when it supplied its own.
                if 'socket_counter' not in r:r['socket_counter']=self.rx_socket['counted_drops'] if self.rx_socket else None
                self.rx_bursts.append(r)
            elif msg=="rx_ledger_invalid=1":
                self.rx_invalid=True
            else:
                continue
            self.seen.add(key)
        elapsed=sum(e["samples"][-1][0] for e in self.epochs if e["samples"])
        if elapsed>=self.next:
            e=self.epochs[-1]
            if e["samples"]:
                last=e["samples"][-1]
                first=next((x for x in e["samples"] if x[0]>=max(0,last[0]-60_000)),last)
                span=max(1,last[0]-first[0])
                total_gaps=sum(x["samples"][-1][5] for x in self.epochs if x["samples"])
                event(f"companion_soak_progress case={self.case} elapsed_s={elapsed//1000} "
                      f"recent_fps={(last[3]-first[3])*1000/span:.2f} "
                      f"recent_payload_mbps={(last[4]-first[4])*.008/span:.3f} frame_gaps={total_gaps}")
                if self.rx_dispatch:
                    dispatch=phone_dispatch.summarize(self.rx_dispatch)
                    n=dispatch['counts']
                    event(f"lan_reader_progress windows={dispatch['windows']} counter_rises={n['inc']} "
                          f"pool={n['dp']} ready={n['dr']} mixed={n['dm']} other={n['du']}")
            self.next=(elapsed//60_000+1)*60_000

    def summary(self, route, seconds):
        all_samples=[e["samples"] for e in self.epochs if e["samples"]]
        span_ms=frames=recorded_bytes=steady_gaps=steady_errors=steady_peak=0
        peak_covered=True
        windows=[]
        rtts=[]
        rates=[]
        duration_ms=sum(rows[-1][0] for rows in all_samples)
        gaps=sum(rows[-1][5] for rows in all_samples)
        errors=sum(rows[-1][7] for rows in all_samples)
        longest=max((rows[-1][8] for rows in all_samples),default=0)
        for e in self.epochs:
            samples=[r for r in e["samples"] if r[0]>=8_000]
            if len(samples)<2: continue
            a,b=samples[0],samples[-1]
            steady_gaps+=b[5]-a[5]
            steady_errors+=b[7]-a[7]
            peaks=e.get("peaks",{})
            for prev,r in zip(samples,samples[1:]):
                if r[0] not in peaks or not 0<r[0]-prev[0]<=1700: peak_covered=False
                else: steady_peak=max(steady_peak,peaks[r[0]])
            rates.append(e["rate"])
            span_ms+=b[0]-a[0]
            frames+=b[3]-a[3]
            recorded_bytes+=b[4]-a[4]
            rtts.extend(r[9] for r in samples if 0<r[9]<30000)
            current=a
            for end in samples[1:]:
                diff=end[0]-current[0]
                if diff<9_980: continue
                if diff>0 and diff<=11_550:
                    windows.append(dict(seconds=diff/1000, fps=(end[3]-current[3])*1000/diff,
                        payload_mbps=(end[4]-current[4])*.008/diff, gaps=end[5]-current[5],
                        decoder_errors=end[7]-current[7], applied_kbps=e["rate"][1] if e["rate"] else 0))
                current=end
        short=seconds<=50
        min_windows=max(1,(seconds-12)//10) if short else 49 if seconds==600 else max(4,(seconds-58)//10)
        coverage_ok=(duration_ms>=(seconds-(3 if short else 18))*1000 and
                     span_ms>=(seconds-(12 if short else 65))*1000 and len(windows)>=min_windows)
        require(span_ms>0 and bool(windows),"companion_no_measured_windows")
        threshold=self.target_fps*.95
        healthy=[w for w in windows if w["fps"]>=threshold and w["gaps"]==0 and w["decoder_errors"]==0]
        near=[w for w in windows if w["applied_kbps"] and w["payload_mbps"]*1000>=w["applied_kbps"]*.90]
        simultaneous=[w for w in healthy if w in near]
        result=dict(route=route, target_fps=self.target_fps, secs=round(span_ms/1000,2), rendered_fps=round(frames*1000/span_ms,2),
                    video_mbps=round(recorded_bytes*.008/span_ms,3), frame_gaps=gaps,
                    render_errors=errors, largest_gap_ms=longest, steady_frame_gaps=steady_gaps,
                    steady_render_errors=steady_errors, steady_peak_ms=steady_peak if peak_covered else None,
                    gaps_outside_steady=gaps-steady_gaps, rtt50=statistics.median(rtts) if rtts else 0,
                    rtt95=percentile(rtts,.95), clean_windows=len(healthy), near_requested_windows=len(near),
                    clean_near_requested_windows=len(simultaneous), windows=len(windows), segments=len(all_samples),
                    payload_p10=round(percentile([w["payload_mbps"] for w in windows],.10),3),
                    payload_p90=round(percentile([w["payload_mbps"] for w in windows],.90),3),
                    clean_payload_p10=round(percentile([w["payload_mbps"] for w in healthy],.10),3),
                    clean_payload_p90=round(percentile([w["payload_mbps"] for w in healthy],.90),3),
                    window_fps_p10=round(percentile([w["fps"] for w in windows],.10),2),
                    minimum_window_fps=round(min(w["fps"] for w in windows),2), rates=rates,
                    usable_decode_seconds=round(duration_ms/1000,2), coverage_ok=coverage_ok)
        result["by_rate"]={}
        # No padding, parity or retransmissions count as encoded video. Test
        # cadence and payload in the same window, not on different averages.
        if self.target_fps==60:
            standard=[w for w in windows if w["applied_kbps"]>=20000 and w["fps"]>=58.2 and
                      w["payload_mbps"]>=20 and not w["gaps"] and not w["decoder_errors"]]
            result["clean_20mbps_60fps_windows"]=len(standard)
            result["sustained_20mbps_60fps"]=(coverage_ok and len(windows)>=10 and
                len(standard)>=math.ceil(len(windows)*.9) and errors==0)
        cross=[int(msg.partition("=")[2]) for _,msg in self.events if msg.startswith("render_across_restart_ms=")]
        # Old HAPs do not report last-present to next-present across a restart.
        result["max_across_restart_ms"]=max(cross,default=None)
        result["longest_including_restart_ms"]=(max([longest,*cross]) if len(all_samples)==1 or len(cross)==len(all_samples)-1 else None)
        result["confirmed_idr_retries_observed"]=sum(msg.startswith("confirmed_idr_retry ") for _,msg in self.events)
        result["compact_idr_retries_observed"]=sum(msg.startswith("compact_idr_retry ") for _,msg in self.events)
        result["safe_probe_fallback_hold_observed"]=any(msg=="quality_high_probe_safe_fallback_no_upshift=1" for _,msg in self.events)
        for rate in sorted({w["applied_kbps"] for w in windows}):
            samples=[w for w in windows if w["applied_kbps"]==rate]
            output=[w["payload_mbps"] for w in samples]
            clean=[w for w in samples if w["fps"]>=threshold and not w["gaps"] and not w["decoder_errors"]]
            result["by_rate"][rate]=dict(windows=len(samples),clean_windows=len(clean),
                seconds=round(sum(w["seconds"] for w in samples),1),
                payload_p10=round(percentile(output,.1),3),payload_p90=round(percentile(output,.9),3))
            event(f"companion_soak_rate applied_kbps={rate} windows={len(samples)} clean_windows={len(clean)} "
                  f"payload_p10_mbps={percentile(output,.1):.3f} payload_p90_mbps={percentile(output,.9):.3f}")
        (self.folder/"windows.json").write_text(json.dumps(windows,indent=2),encoding="utf-8")
        event("companion_soak_result "+" ".join(f"{k}={v}" for k,v in result.items() if k not in ("rates","by_rate")))
        return result

    def save_phone(self):
        if self.rx_bursts:
            (self.folder/"phone-burst-windows.json").write_text(json.dumps(self.rx_bursts,separators=(",",":")),encoding="ascii")
        value=dict(epochs=self.epochs,path=self.path,events=self.events)
        (self.folder/"phone-numeric.json").write_text(json.dumps(value,separators=(",",":")),encoding="utf-8")
        if self.rx_blocks or self.rx_status[0] or self.rx_invalid:
            (self.folder/"phone-packet-counts.json").write_text(json.dumps(dict(status=self.rx_status,
                valid=not self.rx_invalid, blocks={i:v.hex() for i,v in self.rx_blocks.items()}),
                separators=(",",":")),encoding="utf-8")

    def phone_counts(self, frame):
        covered,late,untracked=self.rx_status
        if self.rx_invalid or late or untracked or not 1<=frame<=covered:
            return None
        block, i=divmod(frame-1,128)
        pairs=self.rx_blocks.get(128*block+1)
        return (pairs[2*i],pairs[2*i+1]) if pairs is not None else None

    def count_missing_frames(self, route, host, details, cause):
        """Correlate authenticated receive and local UDP acceptance, not mere sendto success."""
        waits=sorted(int(msg.split("at=",1)[1]) for _,msg in self.events if msg.startswith("core_wait_idr at="))
        totals=Counter()
        for frame,record in details.items():
            pair=self.phone_counts(frame)
            if pair is None: continue
            received,forwarded=pair
            record.update(phone_authenticated=received,phone_loopback=forwarded)
            expected=record["relay_forwarded"] if route=="relay" else record["sent_packets"]
            if received>expected:
                totals["phone_counts_unmatched_frames"]+=1
                continue
            totals["phone_traced_missing_frames"]+=1
            if received<expected:
                totals["phone_missing_before_authenticated_receive"]+=1
            if forwarded<received:
                totals["phone_local_delivery_short_frames"]+=1
            if forwarded==record["source_packets"] and forwarded>0:
                totals["phone_complete_missing_frames"]+=1
        for at,prev,after,n,gap,*rest in host["gap_events"]:
            if not n or n>20000 or after!=prev+n+1: continue
            totals["gap_runs"]+=1
            if route=="relay" and details.get(prev+1,{}).get("relay_rate_limited",0):
                totals["gap_runs_start_relay_limited"]+=1
            if rest[2]:
                totals["gap_runs_end_idr"]+=1
            wc=bisect_left(waits,at+1)-bisect_left(waits,at-gap+1)
            if wc:
                totals["gap_runs_observed_idr_wait"]+=1
                totals["core_wait_idr_samples_in_gaps"]+=wc
                totals["phone_complete_missing_during_idr_wait"]+=sum(
                    details[f].get("phone_loopback",0)>0 and
                    details[f]["phone_loopback"]==details[f]["source_packets"]
                    for f in range(prev+1,after) if f in details)
        keys=("gap_runs","gap_runs_start_relay_limited","gap_runs_end_idr","gap_runs_observed_idr_wait",
              "core_wait_idr_samples_in_gaps","phone_counts_unmatched_frames","phone_traced_missing_frames",
              "phone_missing_before_authenticated_receive","phone_local_delivery_short_frames",
              "phone_complete_missing_frames","phone_complete_missing_during_idr_wait")
        cause.update({k:totals[k] for k in keys})
        cause.update(phone_packet_audit_frames=sum(len(v)//2 for first,v in self.rx_blocks.items()
                if self.phone_counts(first) is not None and self.phone_counts(first+127) is not None),
                phone_packet_audit_late=self.rx_status[1],phone_packet_audit_untracked=self.rx_status[2])

    def attribute(self, route, host_file, relay, relay_truncated):
        valid=host_file.is_file() and 0<host_file.stat().st_size<=(100_000_025 if route=="lan" else 40_000_025)
        data=host_file.read_bytes() if valid else b""
        valid=bool(data and len(data)%RECORD.size==0)
        last=RECORD.unpack_from(data,len(data)-RECORD.size) if valid else None
        valid=bool(last and last[0]==255 and last[3]==len(data)//RECORD.size-1 and last[4]==0)
        completed_epochs=[q for q in self.epochs if q["samples"]]
        relay_complete=route!="relay" or (relay_truncated==0 and bool(relay))
        cause=dict(host_trace_complete=int(valid),relay_trace_complete=int(relay_complete),
                   stream_epochs=len(completed_epochs))
        if not valid or not completed_epochs or not relay_complete:
            event("companion_soak_attribution_incomplete "+" ".join(f"{k}={v}" for k,v in cause.items()))
            return cause
        # GameStream restarts at a small frame number when quality is rebuilt.
        # WireGuard rekeys do not reset this number. Keep a separate mapping
        # per video segment, never use the same frame ID across two segments.
        source_ranges=[]
        peak=0
        last_new=0
        window_breaks=[]
        for kind,frame,ms,_,_ in RECORD.iter_unpack(data):
            if kind!=0: continue
            if not source_ranges or (frame<=32 and peak>=frame+64):
                if source_ranges: window_breaks.append(ms-source_ranges[-1][1])
                source_ranges.append([ms,ms,frame,0,0])
                peak=0
                last_new=ms
            if frame>peak:
                source_ranges[-1][3]+=1
                source_ranges[-1][4]=max(source_ranges[-1][4],ms-last_new)
                last_new=ms
            peak=max(peak,frame)
            source_ranges[-1][1:3]=[ms,peak]
        cause["host_stream_epochs"]=len(source_ranges)
        cause["host_max_frame_supply_gap_ms"]=max((r[4] for r in source_ranges),default=0)
        cause["host_max_supply_gap_on_quality_restart_ms"]=max(window_breaks,default=0)
        # Also require compatible durations before attributing missing IDs.
        matched=(len(source_ranges)==len(completed_epochs) and all(
            abs(e["samples"][-1][0]-(rng[1]-rng[0]))<12_000 for e,rng in zip(completed_epochs,source_ranges)))
        if not matched:
            event("companion_soak_attribution_incomplete "+" ".join(f"{k}={v}" for k,v in cause.items()))
            return cause
        span=source_ranges[-1][1]-source_ranges[0][0]
        count=sum(r[3] for r in source_ranges)
        if span>0 and count>1:
            cause.update(host_distinct_frames=count,host_frame_span_ms=span,
                         host_observed_fps=round((count-1)*1000/span,2))
        groups=[]
        for epoch in completed_epochs:
            missing=set()
            for _,prev,last_frame,count,*_ in epoch["gap_events"]:
                if 0<count<=20000 and ((prev+count+1)&0xffffffff)==last_frame:
                    missing.update((prev+i)&0xffffffff for i in range(1,count+1))
            groups.append({frame:Counter() for frame in missing})
        index=0
        matched_wire=0
        wire=0
        offered_by_frame=[Counter() for _ in source_ranges]
        offered_by_second=[Counter() for _ in source_ranges]
        source_costs_known=True
        for kind,frame,ms,tag,counter in RECORD.iter_unpack(data):
            if kind not in (0,1): continue
            while index+1<len(source_ranges) and ms>=source_ranges[index+1][0]: index+=1
            if kind==0:
                if 0<tag<=4096:
                    offered_by_frame[index][frame]+=tag
                    offered_by_second[index][(ms-source_ranges[index][0])//1000]+=tag
                else:
                    source_costs_known=False  # historical traces only have packet counts
            state=0
            if kind==1 and route=="relay":
                segment=relay.get(tag,b"")
                state=segment[counter] if counter<len(segment) else 0
                wire+=1
                matched_wire+=int(state!=0)
            if frame not in groups[index]: continue
            record=groups[index][frame]
            if kind==0:
                if not record.get("source_packets"): record["first_source_ms"]=ms
                record["source_packets"]+=1
            else:
                record["sent_packets"]+=1
                if not record.get("first_wire_ms"): record["first_wire_ms"]=ms
                if route=="relay":
                    field=("not_seen_at_relay","relay_forwarded","relay_rate_limited","relay_send_failed",
                           "relay_limited_stale_clock")[state]
                    record[field]+=1
                    if state==4: record["relay_rate_limited"]+=1
        if source_costs_known:
            costs=[cost for frames in offered_by_frame for cost in frames.values()]
            if costs:
                cause.update(host_frame_wire_p95_bytes=percentile(costs,.95),host_frame_wire_max_bytes=max(costs))
            # Only complete one-second intervals, measured before pacing/FEC
            # packets can be dropped. Wire demand includes existing repair and
            # tunnel overhead; it is not encoded video bitrate or proof of loss.
            bins=[b.get(i,0) for b,r in zip(offered_by_second,source_ranges) for i in range((r[1]-r[0])//1000)]
            if bins:
                cause.update(host_video_wire_seconds=len(bins),host_video_wire_avg_kbps=round(sum(bins)*.008/len(bins)),
                             host_video_wire_p95_kbps=round(percentile(bins,.95)*.008),
                             host_video_wire_peak_kbps=round(max(bins)*.008))
        if route=="relay":
            cause.update(wire_trace_packets=wire, relay_matched_packets=matched_wire)
            if not wire or not matched_wire:
                event("companion_soak_attribution_incomplete "+" ".join(f"{k}={v}" for k,v in cause.items()))
                return cause
        reported=sum(s["samples"][-1][5] for s in completed_epochs)
        details=[record for group in groups for record in group.values()]
        cause.update(reported_missing=reported, mapped_missing=len(details), source_not_seen=sum(d["source_packets"]==0 for d in details),
                     some_packets_not_sent=sum(d["source_packets"]>d["sent_packets"] for d in details),
                     relay_missing_before_receive=sum(d["not_seen_at_relay"]>0 for d in details),
                     relay_limited_frames=sum(d["relay_rate_limited"]>0 for d in details),
                     relay_limited_packets=sum(d["relay_rate_limited"] for d in details),
                     relay_stale_clock_frames=sum(d["relay_limited_stale_clock"]>0 for d in details),
                     relay_send_error_frames=sum(d["relay_send_failed"]>0 for d in details),
                     all_sent_packets_forwarded=sum(route=="relay" and d["source_packets"]>0 and
                         d["source_packets"]==d["relay_forwarded"] for d in details),
                     all_source_packets_sent=sum(d["source_packets"]>0 and d["source_packets"]==d["sent_packets"] for d in details))
        if len(groups)==1:
            self.count_missing_frames(route,completed_epochs[0],groups[0],cause)
            cause["phone_audit_source_frame_last"]=source_ranges[0][2]
        (self.folder/"missing-frame-path.json").write_text(json.dumps(groups,indent=2),encoding="utf-8")
        event("companion_soak_attribution "+" ".join(f"{k}={v}" for k,v in cause.items()))
        return cause
