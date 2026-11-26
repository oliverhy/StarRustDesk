"""Offline only. Compare a scoped same-adapter ETW trace with actual media refusal timestamps."""
import argparse
import json
from pathlib import Path
import re


def compare(text, host):
    event=re.compile(r'scan_etw_event utc_100ns=(\d+) id=(20022|20023) status=(\d+)')
    rows=[tuple(map(int,m.groups())) for line in text.splitlines() if (m:=event.fullmatch(line))]
    finish=re.findall(r'^scan_etw_finish stop=0 process=0 early=0 events=(\d+) lost=0 buffer_lost=0 capped=0$',
                      text, flags=re.M)
    if (len(re.findall(r'^scan_etw_setup stage=5 error=0 pid=\d+ seconds=\d+$',text,flags=re.M))!=1 or
            len(finish)!=1 or int(finish[0])!=len(rows) or
            len(rows)!=sum(line.startswith('scan_etw_event') for line in text.splitlines()) or
            any(b[0]<a[0] for a,b in zip(rows,rows[1:]))):
        return dict(status='trace_incomplete',order=[])
    summary=host['summary']
    wlan=[t for t,c in host['wlan'] if c==7]
    coverage=[r[1] for r in host['link_observed']]
    if summary.get('wlan_setup')!=1 or len(coverage)<2: return dict(status='no_independent_coverage',order=[])
    low,high=min(coverage),max(coverage)
    pairs=[]
    start=None
    ambiguous=False
    for tick,kind,status in rows:
        if kind==20022:
            if start is not None: return dict(status='trace_overlapping_scans',order=[])
            ambiguous=status!=0
            start=tick
        else:
            if start is not None and not ambiguous and status==0 and low*10000<=start<=tick<=high*10000:
                acm=[t for t in wlan if abs(t*10000-tick)<=250*10000]
                if len(acm)==1: pairs.append((start,tick,acm[0]))
            start=None;ambiguous=False
    spans=[s for s in summary['spans'] if s['recovered'] and s['errno']==10035 and s['busy_ms']>=500]
    order=[]
    for s in spans:
        a=s['begin_ms'];b=s.get('end_ms',a+s['busy_ms'])
        if abs(b-a-s['busy_ms'])>50: continue
        hits=[p for p in pairs if a-750<=p[2]<=b+750]
        if len(hits)!=1: continue
        start,tick,acm=hits[0]
        # Require an unambiguous completion-to-refusal association in both
        # directions. Keep a 5-ms guard for timestamp granularity/conversion.
        if sum(x['begin_ms']-750<=acm<=x.get('end_ms',x['begin_ms']+x['busy_ms'])+750 for x in spans)!=1: continue
        delta=(start-10000*a)/10000
        order.append(dict(refusal_begin_ms=a,busy_ms=s['busy_ms'],scan_minus_refusal_ms=round(delta,2),
                          order='scan_first' if delta < -5 else 'refusal_first' if delta > 5 else 'too_close',
                          scan_duration_ms=round((tick-start)/10000,2)))
    return dict(status='paired' if order else 'no_matched_fault',matched_scan_pairs=len(pairs),order=order)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('trace',type=Path);p.add_argument('run_folder',type=Path)
    args=p.parse_args()
    host=json.loads((args.run_folder/'udp-send-probes.json').read_text(encoding='utf-8'))
    print(json.dumps(compare(args.trace.read_text(encoding='ascii'),host),indent=2))
