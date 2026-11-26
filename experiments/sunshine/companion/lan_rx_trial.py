"""Summarize only allowlisted numeric witnesses. Missing events are unknown, not zero latency."""
import math
import re

_AHEAD=re.compile(r'rx_ledger_ahead packets=(\d{1,10}) blocks=(\d{1,10}) oldest_us=(\d{1,10})')
_END=re.compile(r'lan_loss_recovered unit_ms=(\d{1,10}) surface_ms=(\d{1,10}) idr=([01]) retry=([01])(?: source=([1234]))?')

def percent(values,p):
    return sorted(values)[max(0,math.ceil(len(values)*p)-1)] if values else None

def summarize(events):
    ages=[];totals=[0,0];completed=[];requests=0
    for row in events:
        if not isinstance(row,(list,tuple)) or len(row)!=2 or not isinstance(row[1],str):continue
        line=row[1]
        if line=='lan_loss_idr_retry=1':requests+=1;continue
        if m:=_AHEAD.fullmatch(line):
            packets,blocks,age=map(int,m.groups())
            if not 0<blocks<=packets<=24*blocks or age>120_000_000:continue
            totals[0]+=packets;totals[1]+=blocks;ages.append(age)
        elif m:=_END.fullmatch(line):
            unit,surface,idr,retry,source=m.groups()
            u,s=int(unit),int(surface)
            if not 0<=u<=s<=120000:continue
            completed.append((int(source or 1),u,s,int(idr),int(retry)))
    observed=[r for r in completed if r[0]!=3];decoder_only=[r for r in completed if r[0]==3]
    # Including source=3 in the loss-to-picture distribution would turn missed
    # early notifications into falsely fast recoveries. It still measures presentation.
    return dict(ahead_windows=len(ages),handed_datagrams=totals[0],
                avg_datagrams_per_batch=round(totals[0]/totals[1],2) if totals[1] else None,
                oldest_batch_p95_us=percent(ages,.95),oldest_batch_max_us=max(ages,default=None),
                repair_requests=requests,confirmed_recoveries=len(observed),decoder_only=len(decoder_only),
                loss_to_unit_max_ms=max((r[1] for r in observed),default=None),
                loss_to_surface_max_ms=max((r[2] for r in observed),default=None),
                submit_to_surface_max_ms=max((r[2]-r[1] for r in completed),default=None),
                recovered_via_keyframe=sum(r[3] for r in completed),
                observed_after_requested_repair=sum(r[4] for r in completed))

def gap_paths(epochs,frame_paths):
    """Match frames within each decoder lifetime only; a send count isn't proof of arrival."""
    if len(epochs)!=len(frame_paths):return []
    rows=[]
    for epoch,paths in zip(epochs,frame_paths):
        for at,prev,nxt,missing,span,assembly,callback,idr,_ in epoch.get('gap_events',[]):
            if not 0<missing<=2000 or nxt!=prev+missing+1:continue
            row=dict(first=prev+1,first_missing_path='unmatched',missing=missing,span_ms=span,assembly_ms=assembly,
                     callback_ms=callback,ends_in_keyframe=idr,unmatched=0,not_sent=0,
                     short_at_phone=0,short_at_loopback=0,all_entered_local_udp=0)
            for frame in range(prev+1,nxt):
                r=paths.get(str(frame),{})
                s,w,a,l=(r.get(k) for k in ('source_packets','sent_packets','phone_authenticated','phone_loopback'))
                if any(type(x) is not int for x in (s,w,a,l)) or not (0<s and 0<=l<=a<=w<=s):k='unmatched'
                elif w<s:k='not_sent'
                elif a<w:k='short_at_phone'
                elif l<a:k='short_at_loopback'
                else:k='all_entered_local_udp'
                if frame==prev+1:row['first_missing_path']=k
                row[k]+=1
            rows.append(row)
    return rows

if __name__=='__main__':
    import argparse,json
    from pathlib import Path
    ap=argparse.ArgumentParser();ap.add_argument('run',type=Path);folder=ap.parse_args().run
    phone=json.loads((folder/'phone-numeric.json').read_text('utf-8'))
    stats=summarize(phone['events']);path=folder/'missing-frame-path.json'
    if path.is_file():
        paths=gap_paths(phone['epochs'],json.loads(path.read_text('utf-8')))
        # One observation per gap, not one per dependent frame lost before recovery.
        # 'all_entered_local_udp' still does not prove a decoder or core queue received it.
        stats['first_missing_paths']={k:sum(r['first_missing_path']==k for r in paths)
            for k in ('unmatched','not_sent','short_at_phone','short_at_loopback','all_entered_local_udp')}
        stats['gap_paths']=paths
    print(json.dumps(stats))
