"""Offline association of passive WLAN observations with host UDP refusals, not a causal test."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re


def classify(record):
    summary=record['summary']
    if summary.get('wlan_setup')!=1: return None
    spans=[(s['begin_ms'],s.get('end_ms',s['begin_ms']+s['busy_ms'])) for s in summary['spans']
           if s.get('recovered') and s['errno']==10035 and s['busy_ms']>=500]
    scans=sorted(at for at,code in record['wlan'] if code==7)
    result=Counter(runs=1,complete=len(scans),refusals=len(spans),
                   refusals_near_complete=sum(any(a-750<=t<=b+750 for t in scans) for a,b in spans))
    for i,t in enumerate(scans):
        dt=t-scans[i-1] if i else None
        name=('first' if dt is None else 'short' if dt<45000 else
              'regular' if 55000<=dt<=65000 else 'other')
        result[name+'_all']+=1
        result[name+'_near_refusal']+=int(any(a-750<=t<=b+750 for a,b in spans))
    return result


def summarize(folders,days):
    total=Counter()
    seen=set()
    for root in folders:
        for day in days:
            if not re.fullmatch(r'\d{8}',day): raise ValueError('invalid_day')
            for f in sorted(root.glob(day+'-*/udp-send-probes.json')):
                if f.parent.name in seen: continue
                seen.add(f.parent.name)
                result=classify(json.loads(f.read_text(encoding='utf-8')))
                if result is not None: total.update(result)
    return total


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--days',nargs='+',required=True)
    p.add_argument('--roots',nargs='+',type=Path,required=True)
    a=p.parse_args()
    print(json.dumps(summarize(a.roots,a.days),indent=2,sort_keys=True))
