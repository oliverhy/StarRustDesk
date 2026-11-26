"""Inspect ordering at the Windows helper for the phone's *first* missing pictures.
Reads an already sealed numeric trace offline. No PCAP, image, socket identifier or packet payload.
"""
from pathlib import Path
from struct import Struct
import json
ROW=Struct('<BIIQQ')

def abandonment_counts(heads):
    # "need" is max(required data shards - available shards, 0) at explicit
    # abandonment. Zero can mean an unobserved/missing whole block: never
    # label it a picture that disabling the debug self-test would have saved.
    seen=[h for h in heads if h['flags']&64]
    short=[h for h in seen if h['need']>0]
    return dict(explicit_abandon_heads=len(seen),below_normal_threshold_heads=len(short),
        eventually_all_read_but_short_at_abandon=sum(h['boundary']=='all_read_by_core' for h in short))

def scan(file,wanted):
    size=file.stat().st_size;whole=size//ROW.size
    if size%ROW.size or not 3<=whole<=4_000_001:raise ValueError('invalid_host_trace_length')
    if any(type(f)!=int or not 1<=f<=65536 for f in wanted):raise ValueError('unexpected_frame_id')
    heads=set(wanted);tracked=heads|{f+1 for f in heads}
    stats={};high=[0,0]
    with file.open('rb') as stream:
        stream.seek(-ROW.size,2)
        if ROW.unpack(stream.read())!=(255,0,0,whole-1,0):raise ValueError('host_trace_not_sealed')
        stream.seek(0);left=whole-1
        while left:
            n=min(32768,left);blob=stream.read(ROW.size*n)
            if len(blob)!=ROW.size*n:raise ValueError('partial_host_trace')
            for kind,f,ms,_,_ in ROW.iter_unpack(blob):
                if kind not in (0,1) or not 1<=f<=65536:raise ValueError('invalid_host_trace_row')
                if f in tracked:
                    row=stats.setdefault((f,kind),[0,ms,ms,0])
                    row[0]+=1;row[2]=ms;row[3]+=f<high[kind]
                if f>high[kind]:high[kind]=f
            left-=n
    out=[]
    for f in sorted(heads):
        row={'f':f}
        for tag,k in [('source',0),('send',1)]:
            a=stats.get((f,k));b=stats.get((f+1,k))
            row[tag]=None if a is None else dict(packets=a[0],tail_after_newer=a[3],span_ms=a[2]-a[1],
                next_frame_lead_ms=b[1]-a[2] if b else None)
        out.append(row)
    return out

def summarize(folder):
    c=json.loads((folder/'core-receive-numeric.json').read_text('utf-8'))
    if c.get('status')!='matched':raise ValueError('unmatched_phone_evidence')
    heads={h['f']:h for h in c['heads']}
    rows=scan(folder/'host-numeric.ssmeta',heads)
    for r in rows:
        h=heads[r['f']]
        if not r['source'] or not r['send'] or (r['source']['packets'],r['send']['packets'])!=(h['source'],h['sent']):
            raise ValueError('host_and_phone_trace_disagree')
        r.update(decision=h['decision'],boundary=h['boundary'],core_late=h['late'])
    return dict(heads=len(rows),send_tail_after_newer=sum(bool(r['send']['tail_after_newer']) for r in rows),
                source_tail_after_newer=sum(bool(r['source']['tail_after_newer']) for r in rows),
                **abandonment_counts(heads.values()),rows=rows)

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser();p.add_argument('folder',type=Path)
    print(json.dumps(summarize(p.parse_args().folder)))
