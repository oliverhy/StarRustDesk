"""Join three independently observed boundaries. A local send is not a core read."""
import json
from pathlib import Path
import re
from collections import Counter

HEAD='f n raw old bad auth reject flags need late lag waitn failn fulln'.split()
END='reads gaps invalid unknown buf peak samples drops'.split()
def regex(prefix,keys):
    return re.compile(prefix+' '+' '.join(k+(r'=(-1|\d{1,10})' if k=='drops' else r'=(\d{1,10})') for k in keys))
ROW=regex('lan_core_head',HEAD);TAIL=regex('lan_core_end',END)
def parse(line):
    if m:=ROW.fullmatch(line):
        d=dict(zip(HEAD,map(int,m.groups())))
        if not (1<=d['f']<=65536 and 1<=d['n']<=2000 and d['f']+d['n']<=65537 and
                d['flags']<=127 and max(d[k] for k in ('need','lag','raw'))<=65535 and
                d['raw']==d['old']+d['bad']+d['auth'] and d['reject']<=d['auth'] and d['late']<=d['old'] and
                max(d[k] for k in ('waitn','failn','fulln'))<=d['n']):return None
        return ('head',d)
    if m:=TAIL.fullmatch(line):
        d=dict(zip(END,map(int,m.groups())))
        if d['gaps']>96 or max(d.values())>0xffffffff or d['drops']< -1:return None
        return ('end',d)

def join(epochs,events,paths):
    if len(epochs)!=1 or len(paths)!=1:return {'status':'unknown_epochs'}
    wanted={g[1]+1:g[3] for g in epochs[0].get('gap_events',[]) if g[3]}
    ends=[];heads={};ordered=[]
    for _,line in events:
        pair=parse(line)
        if pair is None:continue
        typ,d=pair
        if typ=='end':ends.append(d);continue
        if d['f'] in heads:return {'status':'duplicate_head'}
        heads[d['f']]=d
    if len(ends)!=1:return {'status':'missing_or_multiple_end','heads_observed':len(heads)}
    e=ends[0]
    if (not e['reads'] or e['invalid'] or e['unknown'] or e['gaps']!=len(wanted) or
        {f:h['n'] for f,h in heads.items()}!=wanted):
        return {'status':'incomplete','socket':e,'heads_observed':len(heads),'expected':len(wanted)}
    counts=Counter()
    for f,d in sorted(heads.items()):
        x=paths[0].get(str(f),{})
        src,sent,verified,local=(x.get(k) for k in ('source_packets','sent_packets','phone_authenticated','phone_loopback'))
        if any(type(v)!=int for v in (src,sent,verified,local)) or not 0<=local<=verified<=sent<=src or not src:
            return {'status':'unmatched_outer_path','frame':f}
        if d['raw']>local:return {'status':'inconsistent_core_count','frame':f}
        if sent<src:boundary='host_unsent'
        elif verified<sent:boundary='short_before_phone_auth'
        elif local<verified:boundary='short_at_local_send'
        elif d['raw']<local:boundary='short_at_core_read'
        else:boundary='all_read_by_core'
        flags=d['flags']
        if flags&3: decision='withheld_complete_for_reference'
        elif flags&64:decision='abandoned_fec'
        elif flags&32:decision='fec_complete_other'
        elif flags&16:decision='declared_loss'
        elif flags&8:decision='speculative_only'
        else:decision='unobserved'
        counts[boundary]+=1;counts[decision]+=1
        if d['late']:counts['post_abandon_late_heads']+=1
        ordered.append(dict(**d,local=local,verified=verified,sent=sent,source=src,boundary=boundary,decision=decision))
    return dict(status='matched',socket=e,head_counts=dict(counts),heads=ordered,
        missing_frames=sum(wanted.values()),complete_wait_frames=sum(d['waitn'] for d in heads.values()),
        abandoned_frames=sum(d['failn'] for d in heads.values()),fec_complete_frames=sum(d['fulln'] for d in heads.values()),
        head_auth_failures=sum(d['bad'] for d in heads.values()))

def from_folder(folder):
    d=json.loads((folder/'phone-numeric.json').read_text('utf-8'))
    p=json.loads((folder/'missing-frame-path.json').read_text('utf-8'))
    return join(d['epochs'],d['events'],p)

if __name__=='__main__':
    import argparse
    ap=argparse.ArgumentParser();ap.add_argument('folder',type=Path)
    print(json.dumps(from_folder(ap.parse_args().folder),indent=2))
