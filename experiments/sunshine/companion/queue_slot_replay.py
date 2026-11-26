"""Offline counterfactual for the compact 1.8M relay. No network, payloads or extra send slots."""
from collections import Counter, deque
from pathlib import Path
import argparse
import json
from idr_path import RECORD, report

AGE=125
RATE=1798*125   # independent probe reserved 2 kbps inside the 1.8M ceiling


class SlotQueue:
    def __init__(self, price, protect):
        self.price=price; self.capacity=RATE*AGE//1000//price; self.protect=protect
        self.queue=deque(); self.size=0; self.started=None; self.banned={}
        self.sent=Counter(); self.latest={}; self.retained=0

    def drop(self,f,now):
        self.banned[f]=now
        survivors=deque(p for p in self.queue if p[0]!=f)
        self.size-=len(self.queue)-len(survivors); self.queue=survivors
        if self.started==f:self.started=None

    def expire(self,now):
        while self.queue and now-self.queue[0][1]>=AGE:self.drop(self.queue[0][0],now)
        if len(self.banned)>32:
            self.banned={f:t for f,t in self.banned.items() if now-t<AGE}
            while len(self.banned)>32: del self.banned[next(iter(self.banned))]

    def push(self,f,now):
        self.expire(now)
        if f in self.banned and now-self.banned[f]<AGE:return
        while self.size>=self.capacity:
            head,at=self.queue[0]
            if self.protect and self.started==head and f!=head:
                # Only the already-started head can be protected. Budget the
                # remaining known bytes with 25% service margin and 5 ms guard.
                remaining=sum(1 for pf,_ in self.queue if pf==head)*self.price
                if (now-at+5)*RATE+remaining*1250 < AGE*RATE:
                    self.drop(f,now);self.retained+=1;return
            self.drop(head,now)
            if head==f:return
        at=next((t for pf,t in self.queue if pf==f),now)
        self.queue.append((f,at));self.size+=1

    def slot(self,now):
        self.expire(now)
        if not self.queue:return
        f,_=self.queue.popleft();self.size-=1;self.sent[f]+=1;self.latest[f]=now
        self.started=f if self.queue and self.queue[0][0]==f else None


def replay(folder):
    result=json.loads((folder/'result.json').read_bytes())
    if not (result.get('wire_cap_kbps')==1800 and result.get('profile')=='1080p60' and
            result.get('view_only') is True and result.get('verified_physical_nvenc_and_encrypted_playback') is True and
            result['playback']['route']=='relay' and result['attribution'].get('host_trace_complete') and
            result['attribution'].get('host_stream_epochs')==1 and
            result.get('host_udp',{}).get('media',{}).get('media_kbps')==1798):return dict(status='wrong_scope')
    audit=report(folder)
    if audit.get('status') not in ('observed','no_confirmed_phone_recovery'):return dict(status='invalid_diagnostic_session')
    # Old recordings can validate gross queue behavior; without an anchored
    # encoder frame they can never validate a recovery IDR comparison.
    episodes=[e for e in audit.get('episodes',[]) if e['encoder_evidence']=='matched']
    raw=(folder/'host-numeric.ssmeta').read_bytes()
    if not raw or len(raw)%RECORD.size:return dict(status='unsealed_trace')
    last=RECORD.unpack_from(raw,len(raw)-RECORD.size)
    if last[0]!=255 or last[3]!=len(raw)//RECORD.size-1 or last[4]:return dict(status='unsealed_trace')
    prices={tag for k,_,_,tag,_ in RECORD.iter_unpack(raw) if k==0}
    # A send row does not carry its own packet size. Never borrow a larger
    # slot for a cheaper datagram or invent the order of mixed-size fragments.
    if len(prices)!=1:return dict(status='mixed_size_trace')
    price=prices.pop()
    if not 80<=price<=1356:return dict(status='price_invalid')
    base,trial=(SlotQueue(price,v) for v in (False,True))
    source=Counter(); actual=Counter();first={}; last_time=0; last_frame=0
    for k,f,ms,_,_ in RECORD.iter_unpack(raw):
        if k==255:continue
        if k not in (0,1) or f<=0 or ms<last_time:return dict(status='trace_order_unknown')
        last_time=ms
        if k==0:
            if f<last_frame:return dict(status='source_interleaved_or_restarted')
            last_frame=f;source[f]+=1;first.setdefault(f,ms);base.push(f,ms);trial.push(f,ms)
        else:
            if f not in source or actual[f]>=source[f]:return dict(status='missing_source')
            actual[f]+=1
            base.slot(ms);trial.slot(ms)
    def complete(count,f):return count[f]==source[f] and source[f]>0
    spans=[]
    for e in episodes:
        ids=[x['frame'] for x in e['earlier_observed_idrs']]+[e['recovery_frame']]
        if any(f not in source for f in ids):return dict(status='missing_idr')
        spans.append(dict(recovery=e['recovery_frame'],candidates=len(ids),
            actual_complete=sum(complete(actual,f) for f in ids),
            reference_complete=sum(complete(base.sent,f) for f in ids),trial_complete=sum(complete(trial.sent,f) for f in ids),
            reference_first_complete_from_first_candidate_ms=min((base.latest[f]-first[ids[0]] for f in ids if complete(base.sent,f)),default=None),
            trial_first_complete_from_first_candidate_ms=min((trial.latest[f]-first[ids[0]] for f in ids if complete(trial.sent,f)),default=None)))
    return dict(status='model_not_network_test',actual_policy='compact_head' if result.get('compact_head_trial',{}).get('active') else 'stock',
        packet_wire_bytes=price,deadline_ms=AGE,video_slots=sum(actual.values()),
        reference_used=sum(base.sent.values()),trial_used=sum(trial.sent.values()),reference_mismatch_frames=sum(base.sent[f]!=actual[f] for f in source),
        trial_mismatch_frames=sum(trial.sent[f]!=actual[f] for f in source),
        source_frames=len(source),actual_complete=sum(complete(actual,f) for f in source),
        reference_complete=sum(complete(base.sent,f) for f in source),trial_complete=sum(complete(trial.sent,f) for f in source),
        trial_overflow_saves=trial.retained,anchored_freshness_episodes=len(spans),episodes=spans)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('folder',type=Path)
    print(json.dumps(replay(p.parse_args().folder),indent=2))
