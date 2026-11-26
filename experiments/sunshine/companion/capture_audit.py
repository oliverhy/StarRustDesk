"""Opt-in activity/encoder correlation for this authenticated real-display trial."""
from bisect import bisect_left, bisect_right
from collections import defaultdict
import json
from pathlib import Path
import re
import subprocess
import threading

from long_metrics import RECORD, percentile

GUARD_MS=15
GAP_MS=250


def read_source_trace(path):
    stamp=path.stat()
    anchor=getattr(stamp,"st_birthtime_ns",None)
    if anchor is None: anchor=stamp.st_ctime_ns
    data=path.read_bytes()
    if len(data)<RECORD.size or len(data)%RECORD.size:
        return None, [], []
    gaps,frames=[],[]
    previous=None
    complete=False
    for kind,frame,ms,a,b in RECORD.iter_unpack(data):
        if kind==255:
            complete=b==0 and a==len(data)//RECORD.size-1
        if kind!=0: continue
        if previous:
            before,time=previous
            step=(frame-before)&0xffffffff
            if not 0<step<0x80000000: continue
            if ms-time>=GAP_MS:
                gaps.append(dict(previous_frame=before,frame=frame,missing_indices=step-1,
                    source_from_ms=time,source_to_ms=ms,duration_ms=ms-time))
        previous=(frame,ms)
        frames.append(ms)
    return (anchor//1_000_000,gaps,frames) if complete else (None,[],[])


def covered_presents(samples,times,begin,end):
    first=bisect_left(times,begin)
    last=bisect_right(times,end)
    # Each DXGI poll reports presents since its preceding poll. Only use
    # polls from intervals lying fully inside the source gap.
    inner=samples[first+1:last] if first<last else []
    usable=[row for i,row in enumerate(inner,first+1)
            if row[0]+(row[1]+999)//1000<=end and row[4]==1 and row[1]<=10000
            and samples[i-1][4]==1 and row[0]-samples[i-1][0]<=170]
    return first,inner,usable


def classify(gap, anchor, samples, times):
    begin=anchor+gap["source_from_ms"]+GUARD_MS
    end=anchor+gap["source_to_ms"]-GUARD_MS
    first,inner,usable=covered_presents(samples,times,begin,end)
    updates=sum(row[2] for row in usable if begin<=row[3]<=end)
    if updates>=2:
        result="desktop_updates"
    elif (len(usable)>=2 and len(usable)==len(inner) and not gap["missing_indices"]
          and usable[-1][0]-samples[first][0]>=gap["duration_ms"]*.40
          and samples[first][0]-begin<=120 and end-usable[-1][0]<=120
          and all(row[2]==0 for row in usable)):
        result="quiet"
    else:
        result="unclassified"
    return dict(activity=result, samples=len(usable), desktop_presents=updates,
                desktop_updated_polls=sum(begin<=row[3]<=end and row[2]>0 for row in usable))


def thread_evidence(rows, begin, end):
    """A few samples can show repeated ready-but-not-running, not ETW CPU time."""
    recent=[r for r in rows if begin<=r[0] and r[0]+(r[1]+999)//1000<=end and r[1]<=20000]
    best=0
    first=last=None
    # .NET ThreadState: Ready=1, Standby=3, Wait=5. Only compare
    # consecutive observable samples with matching monotonic CPU counters.
    for row in recent:
        if row[3] not in (1,3):
            first=last=None
            continue
        if first is None or row[0]-last[0]>170 or not 0<=row[5]-last[5]<=1000:
            first=row
        last=row
        best=max(best,row[0]-first[0])
    return dict(samples=len(recent), wait_samples=sum(row[3]==5 for row in recent),
                ready_observed_ms=best)


def cadence_minutes(frames, anchor, samples, times, threads, encoder):
    """Only complete minutes; approximate compositor counts are not video FPS."""
    if len(frames)<2: return []
    out=[]
    for minute in range((frames[-1]-frames[0])//60000):
        begin=anchor+frames[0]+minute*60000
        end=begin+60000
        _,_,usable=covered_presents(samples,times,begin,end)
        encoded=bisect_left(frames,end-anchor)-bisect_left(frames,begin-anchor)
        nv=[r for r in encoder if begin<=r[0]<end and r[1]<=10000]
        out.append(dict(minute=minute+1, source_fps=round(encoded/60,2),
            desktop_present_count=sum(row[2] for row in usable if begin<=row[3]<end),
            desktop_polls=len(usable), desktop_updated_polls=sum(row[2]>0 for row in usable),
            nvenc_samples=len(nv), nvenc_fps_p50=percentile([r[2] for r in nv],.5),
            nvenc_latency_p95_us=percentile([r[3] for r in nv],.95),
            thread_samples=sum(begin<=r[0]<end and r[1]<=20000 for rows in threads.values() for r in rows)))
    return out


class CaptureAudit:
    def __init__(self, desktop_size, sunshine_pid=0, *, lan_1080=False):
        self.process=None
        self.reader=None
        self.screen=None
        self.desktop_size=tuple(desktop_size)
        self.sunshine_pid=sunshine_pid
        self.samples=[]
        self.threads=defaultdict(list)
        self.encoder=[]
        self.dwm=[]
        self.dwm_ok=None
        self.workers=defaultdict(list)
        self.lan_1080=lan_1080
        self.clock_ok=True
        self.probe_failed=False

    def start(self):
        if self.process: return
        script=Path(__file__).with_name("capture_activity_windows.ps1")
        try:
            self.process=subprocess.Popen(["powershell.exe","-NoProfile","-NonInteractive","-File",str(script),
                "-SunshinePid",str(self.sunshine_pid)]+(["-Lan1080","-MaxSamples","18000"] if self.lan_1080 else []),
                stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW)
        except OSError:
            return
        self.reader=threading.Thread(target=self.read,daemon=True)
        self.reader.start()

    def read(self):
        for raw in self.process.stdout:
            line=raw.decode("ascii","ignore").strip()
            if line in ("capture_dwm_capability 0","capture_dwm_capability 1"):
                self.dwm_ok=line.endswith("1")
                continue
            if line=="capture_clock_invalid 1":
                self.clock_ok=False
                continue
            if line=="capture_setup 0 0 0":
                self.probe_failed=True
                continue
            if m:=re.fullmatch(r"capture_setup 1 (\d+) (\d+)",line):
                self.screen=tuple(map(int,m.groups()))
                continue
            for prefix,count in (("capture_sample",5),("capture_thread",6),("capture_worker",6),("capture_encoder",4),("capture_dwm",6)):
                if re.fullmatch(prefix+rf"(?: \d{{1,16}}){{{count}}}",line) is None: continue
                row=list(map(int,line.split()[1:]))
                if prefix=="capture_dwm" and self.dwm_ok is not True: break
                if prefix in ("capture_thread","capture_worker"):
                    if row[2] not in (1,2,3,4): break
                    group=(self.threads if prefix=="capture_thread" else self.workers)[row[2]]
                else:
                    group=self.samples if prefix=="capture_sample" else self.dwm if prefix=="capture_dwm" else self.encoder
                if len(group)<(18000 if self.lan_1080 else 7200) and (not group or row[0]>group[-1][0]):
                    group.append(row)
                break

    def save_lan(self,folder,stages):
        if not self.lan_1080:raise ValueError('not_lan_observer')
        summary=dict(primary_verified=self.screen==self.desktop_size,clock_ok=self.clock_ok,probe_failed=self.probe_failed,
                     polls=len(self.samples),worker_roles=len(self.workers),nvenc_samples=len(self.encoder),
                     host_stage_reports=len(stages),dwm_polls=len(self.dwm),dwm_capable=self.dwm_ok)
        data=dict(summary=summary,desktop=self.samples,threads=self.threads,workers=self.workers,
                  nvenc=self.encoder,host_stages=stages,dwm=self.dwm)
        (folder/'lan-capture-samples.json').write_text(json.dumps(data,separators=(',',':')),'ascii')
        return summary

    def close(self):
        if not self.process: return
        # Only the child opened in start(). Cleanup must never mask the playback
        # exception. Do not close a buffered pipe under a blocked reader.
        try:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=4)
        except (OSError,subprocess.TimeoutExpired):
            self.probe_failed=True
        if self.reader:
            self.reader.join(2)
            if self.reader.is_alive():
                self.probe_failed=True
                return
        try:
            self.process.stdout.close()
        except OSError:
            self.probe_failed=True

    def save(self, folder, host_trace, recorder):
        anchor,gaps,frames=read_source_trace(host_trace) if host_trace.is_file() else (None,[],[])
        exact=self.screen==self.desktop_size
        samples=self.samples if exact and anchor is not None else []
        times=[r[0] for r in samples]
        end_frames={row[2]:row for e in recorder.epochs for row in e["gap_events"]}
        for gap in gaps:
            gap.update(classify(gap,anchor,samples,times))
            begin=anchor+gap["source_from_ms"]+GUARD_MS
            end=anchor+gap["source_to_ms"]-GUARD_MS
            roles={str(role):thread_evidence(rows,begin,end) for role,rows in self.threads.items()}
            gap["thread_observations"]=roles
            nv=[r for r in self.encoder if begin<=r[0]<=end and r[1]<=10000]
            gap["nvenc_samples"]=len(nv)
            gap["nvenc_observed_max_average_us"]=max((r[3] for r in nv),default=0)
            unit=end_frames.get(gap["frame"])
            if unit and unit[1]==gap["previous_frame"]:
                gap.update(unit_gap_ms=unit[4],assembly_ms=unit[5],
                           callback_wait_ms=unit[6],host_01ms=unit[8])
        summary=dict(screen_verified=exact,source_trace_verified=anchor is not None,
            samples=len(samples),observer_p95_us=percentile([r[1] for r in samples],.95),
            updated_samples=sum(r[2]>0 and r[4]==1 for r in samples), source_gaps=len(gaps),
            quiet_gaps=sum(g["activity"]=="quiet" for g in gaps),
            updated_gaps=sum(g["activity"]=="desktop_updates" for g in gaps),
            unclassified_gaps=sum(g["activity"]=="unclassified" for g in gaps),
            thread_roles=len(self.threads), encoder_samples=len(self.encoder),
            thread_p95_us=percentile([r[1] for rows in self.threads.values() for r in rows],.95),
            nvenc_query_p95_us=percentile([r[1] for r in self.encoder],.95),
            longest_ms=max((g["duration_ms"] for g in gaps),default=0))
        # Only times, frame numbers and compositor presents. No pixels,
        # window titles or reproducible image fingerprint are persisted.
        (folder/"capture-audit.json").write_text(json.dumps(dict(summary=summary,gaps=gaps,
            source_start_utc_ms=anchor,samples=samples,threads=self.threads,encoder=self.encoder,
            minutes=cadence_minutes(frames,anchor,samples,times,self.threads,self.encoder)),
            separators=(",",":")),encoding="utf-8")
        return summary
