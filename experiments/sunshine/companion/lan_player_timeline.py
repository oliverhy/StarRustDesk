"""Optional, same-Windows-clock evidence for a real, local-player LAN trial."""
from bisect import bisect_left, bisect_right
import json
import math
from pathlib import Path
from statistics import median

FILENAME = 'lan-player-submission.json'
# Host permits 10 ms anchor disagreement; player checks its own clock to
# 12 ms. Exclude both uncertain edges rather than matching the nearest frame.
EDGE_MS = 25


def cue(folder):
    data=json.loads((folder/'playback-cue.json').read_text('ascii'))
    if type(data.get('utc_ms')) is not int:
        raise ValueError('bad_player_cue')
    return data['utc_ms']


def live_binding(folder, now):
    folder=folder.resolve()
    base=Path(__file__).resolve().parents[1]/'.generated'/'lan-compare'
    if folder.parent!=base or (folder/'result.json').exists() or (folder/FILENAME).exists():
        raise ValueError('not_new_lan_trial')
    start=cue(folder)
    if not 0 < start-now <= 36000:
        raise ValueError('not_pending_playback_cue')
    return dict(run=folder.name,cue_utc_ms=start)


class Timeline:
    def __init__(self,status,rows=()):
        self.status=status
        self.rows=rows
        self.times=[r[1] for r in rows]

    @classmethod
    def load(cls,folder,host_begin,host_end):
        path=folder/FILENAME
        if not path.is_file():return cls('not_recorded')
        if host_begin is None:return cls('host_clock_unverified')
        try:
            if path.stat().st_size>8_000_000:return cls('invalid_record')
            d=json.loads(path.read_text('ascii'))
            start=cue(folder)
            if (d.get('binding')!={'run':folder.name,'cue_utc_ms':start} or d.get('schema')!=2
                or d.get('state')!='complete'):return cls('not_same_completed_trial')
            if (d.get('width'),d.get('height'))!=(1920,864):return cls('noncomparable_video')
            rows=d['rows']
            if not isinstance(rows,list) or not 2<=len(rows)<=50000:return cls('invalid_record')
            steps=[]
            for i,r in enumerate(rows):
                if (not isinstance(r,list) or len(r)!=4 or
                    not all(type(v) in (int,float) and math.isfinite(v) for v in r) or
                    type(r[3])!=int or r[3]<1 or r[2]<0 or r[1]>r[0]+1):
                    return cls('invalid_record')
                if i:
                    a=rows[i-1]
                    if r[3]<=a[3] or r[1]<a[1] or r[0]<a[0] or r[2]<a[2]:
                        return cls('nonmonotonic_record')
                    if r[3]==a[3]+1:steps.append(r[2]-a[2])
            if len(steps)<60 or not 15<=median(steps)<=18:return cls('noncomparable_cadence')
            # Reject a stale/copied ledger, including a different session at
            # the same movie time. A missing first/last second is not patched.
            if (not start-25<=rows[0][1]<=start+4000 or not 366000<=rows[0][2]<=371000
                or min(rows[-1][1],host_end)<=max(rows[0][1],host_begin)):
                return cls('different_time_window')
            return cls('observed',rows)
        except (OSError,ValueError,KeyError,TypeError,AttributeError,OverflowError):
            return cls('invalid_record')

    def gap(self,begin,end):
        if self.status!='observed':return {'signal':self.status}
        left,right=begin+EDGE_MS,end-EDGE_MS
        if left>=right or self.times[0]>left or self.times[-1]<right:
            return {'signal':'outside_coverage'}
        lo,hi=bisect_left(self.times,left),bisect_right(self.times,right)
        inside=hi-lo
        signal='partial_observation'
        if inside>=2:
            signal='player_submissions_within_gap'
        elif inside==0:
            # No callback is not proof of no submission. Only consecutive
            # submitted-frame IDs can establish that the interior was quiet.
            signal=('consecutive_submissions_span_gap' if self.rows[hi][3]==self.rows[lo-1][3]+1
                    else 'callbacks_skipped_unknown')
        return {'signal':signal,'observed_inside':inside,'edge_excluded_ms':EDGE_MS}
