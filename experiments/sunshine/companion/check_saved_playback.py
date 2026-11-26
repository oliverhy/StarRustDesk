"""Recompute only end-device playback from an existing numeric recording.

Retains omitted evidence as unknown. Never overwrites an online acceptance
record or implies a broker/host trace that the original process did not save.
"""
import argparse,json,tempfile
from pathlib import Path
from long_metrics import Recorder

def recover(folder,seconds,fps,route):
    folder=folder.resolve()
    root=(Path(__file__).resolve().parents[1]/".generated"/"public-compare").resolve()
    if folder.parent!=root: raise ValueError("not_local_compare_record")
    source=folder/"phone-numeric.json"
    if not source.is_file() or not 0<source.stat().st_size<=32*1024*1024: raise ValueError("invalid_phone_record")
    p=json.loads(source.read_bytes())
    with tempfile.TemporaryDirectory(prefix="sesame-playback-summary-") as temp:
        out=Path(temp); recorder=Recorder("offline-numeric-only",out,fps)
        recorder.epochs=p["epochs"]; recorder.events=p["events"]
        for e in recorder.epochs: e["peaks"]={int(k):v for k,v in e.get("peaks",{}).items()}
        playback=recorder.summary(route,seconds)
        for filename,value in [("phone-only-windows.json",(out/"windows.json").read_text(encoding="utf-8")),
            ("phone-only-result.json",json.dumps(dict(origin="saved_numeric_phone_telemetry",
                    full_live_acceptance=False,host_relay_attribution=None,playback=playback),indent=2))]:
            path=folder/filename
            if path.exists():
                if path.read_text(encoding="utf-8")!=value: raise ValueError("different_existing_summary")
            else:
                with path.open("x",encoding="utf-8") as f: f.write(value)

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("folder",type=Path)
    p.add_argument("--seconds",type=int,choices=(120,600),required=True)
    p.add_argument("--fps",type=int,choices=(30,60),required=True)
    p.add_argument("--route",choices=("direct","relay"),required=True,
                   help="Supply only the authenticated route reported by the original run")
    a=p.parse_args();recover(a.folder,a.seconds,a.fps,a.route)
