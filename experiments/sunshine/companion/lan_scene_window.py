"""Compare source packet cadence at the same playback cue, not PC/phone clocks."""
import argparse
import json
from pathlib import Path

from analyze_lan_capture import clock, source_frames


def archive(folder):
    load = lambda name: json.loads((folder / name).read_text(encoding="utf-8"))
    start = load("player-start-observed.json")
    cue = load("playback-cue.json")["utc_ms"]
    delta = start.get("absolute_delta_ms")
    if not (type(cue) is int and type(delta) is int and 0 <= delta <= 250 and
            start.get("was_paused") is True and start.get("media_quality_1080p60") is True and
            start.get("displayed_start") == "06:07"):
        raise ValueError("no_comparable_playback_cue")
    base = clock((folder / "host-path-numeric.txt").read_text("ascii").splitlines())
    if base is None:
        raise ValueError("no_reliable_host_clock")
    frames = source_frames(folder / "host-numeric.ssmeta")
    return frames, base - cue, delta


def window(frames, offset, begin, end):
    """Count frame starts in [begin,end); packetless spans intersecting its interior."""
    begin, end = begin - offset, end - offset
    if not (frames[0][1] <= begin < end <= frames[-1][2]):
        raise ValueError("scene_window_not_fully_recorded")
    starts = sum(begin <= first < end for _, first, _ in frames)
    spans = [b[1]-a[2] for a, b in zip(frames,frames[1:]) if a[2] < end and begin < b[1]]
    return dict(starts=starts, longest_intersecting_source_gap_ms=max(spans,default=0))


def compare(reference, before, after, others):
    frames, ref_offset, delta = archive(reference)
    pair = [(a,b) for a,b in zip(frames,frames[1:]) if (a[0],b[0]) == (before,after)]
    if len(pair)!=1:
        raise ValueError("no_unique_adjacent_source_frames")
    a,b = pair[0]
    begin,end = ref_offset+a[2],ref_offset+b[1]
    output = {}
    for folder in [reference,*others]:
        f,offset,d = (frames,ref_offset,delta) if folder == reference else archive(folder)
        output[folder.name] = dict(cue_error_ms=d, exact=window(f,offset,begin,end),
                                    padded_by_1s=window(f,offset,begin-1000,end+1000))
    return dict(from_cue_ms=[round(begin,2),round(end,2)], archives=output)


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("reference",type=Path)
    p.add_argument("previous_frame",type=int)
    p.add_argument("following_frame",type=int)
    p.add_argument("other",nargs="*",type=Path)
    args=p.parse_args()
    print(json.dumps(compare(args.reference,args.previous_frame,args.following_frame,args.other),indent=2))
