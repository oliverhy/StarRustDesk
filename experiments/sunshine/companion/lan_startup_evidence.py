"""Interpret numerical 34 Mbps, four-step LAN diagnostics; never infer a path capacity."""
import re

STEP=re.compile(r'lan_probe_step step=([0-3]) rate=(\d{1,5}) planned=(\d{1,5}) sent=(\d{1,5}) tx_us=(\d{1,10}) ack=([01]) received=(\d{1,5}) rx_us=(\d{1,10}) idle_us=(\d{1,10}) state=([2-5])',re.ASCII)
FINAL=re.compile(r'bandwidth_result state=([2-5]) good_kbps=(\d{1,5}) unstable_kbps=(\d{1,5}) cap_kbps=34000',re.ASCII)
SENDER_FIELDS='attempts no_data block no_buffer other short waits slow_waits wait_us wait_max seal_us seal_max udp_us udp_max'.split()
SENDER=re.compile(r'lan_probe_sender step=([0-3])'+''.join(' '+k+r'=(\d{1,10})' for k in SENDER_FIELDS),re.ASCII)
OUTCOMES='signal timeout arm_fail wait_fail no_timer'.split()
SLOW='slow_signal slow_timeout slow_arm slow_fail slow_none'.split()
WAKE_FIELDS=OUTCOMES+SLOW+'sleep_us peak_kind peak_arm peak_wait peak_sleep'.split()
WAKE=re.compile(r'lan_probe_wake step=([0-3])'+''.join(' '+k+r'=(\d{1,10})' for k in WAKE_FIELDS),re.ASCII)

def observe_endpoint(summary,msg):
    if msg in ('secure_result=standard_video_budget_insufficient','companion_route_result=standard_video_budget_insufficient'):
        summary['budget_denial_seen']=True
    elif (m:=FINAL.fullmatch(msg)):
        s,good,upper=map(int,m.groups())
        if max(good,upper)<=34000:summary['sample']={'state':s,'good_kbps':good,'upper_kbps':upper}

def explain(lines):
    rows=[]; stopped=False
    for line in lines:
        if line.startswith('lan_probe_wake '):
            m=WAKE.fullmatch(line.rstrip('\r\n'))
            if not m:return {'status':'invalid_trace'}
            i,*values=map(int,m.groups())
            if not rows or i!=len(rows)-1 or 'windows' not in rows[-1]:return {'status':'inconsistent_trace'}
            w=rows[-1]['windows']; d=dict(zip(WAKE_FIELDS,values)); kind=d['peak_kind']
            peak=sum(d[k] for k in ('peak_arm','peak_wait','peak_sleep'))
            if ('wake' in w or kind>=len(OUTCOMES) or (w['waits'] and not d[OUTCOMES[kind]]) or
                sum(d[k] for k in OUTCOMES)!=w['waits'] or sum(d[k] for k in SLOW)!=w['slow_waits'] or
                any(d[s]>d[k] for k,s in zip(OUTCOMES,SLOW)) or not 0<=w['wait_max']-peak<=2 or
                not d['peak_sleep']<=d['sleep_us']<=w['wait_us'] or (kind==0 and d['peak_sleep']) or
                (d['signal']==w['waits'] and d['sleep_us'])):return {'status':'inconsistent_trace'}
            w['wake']=d
            continue
        if line.startswith('lan_probe_sender '):
            m=SENDER.fullmatch(line.rstrip('\r\n'))
            if not m:return {'status':'invalid_trace'}
            i,*values=map(int,m.groups())
            if i!=len(rows)-1 or not rows or 'windows' in rows[-1]:return {'status':'inconsistent_trace'}
            row=rows[-1]; d=dict(zip(SENDER_FIELDS,values))
            errors=sum(d[k] for k in ('no_data','block','no_buffer','other','short'))
            measured=sum(d[k+'_us'] for k in ('wait','seal','udp'))
            if (d['attempts']!=row['sent']+errors or d['slow_waits']>d['waits'] or
                any(d[k+'_max']>d[k+'_us'] for k in ('wait','seal','udp')) or measured>row['send_us']):
                return {'status':'inconsistent_trace'}
            # Same local catch-up limit as the sender (1244 wire bytes per probe).
            per_wake=min((row['rate_kbps']*98//100)*2200//(1244*8000)+1,22)
            d['round_packet_ceiling']=d['waits']*per_wake
            if row['sent']>d['round_packet_ceiling']:return {'status':'inconsistent_trace'}
            d['outside_phases_us']=row['send_us']-measured
            row['windows']=d
            continue
        if not line.startswith('lan_probe_step '):continue
        m=STEP.fullmatch(line.rstrip('\r\n'))
        if not m:return {'status':'invalid_trace'}
        i,rate,plan,tx,ts,ack,rx,rs,idle,state=map(int,m.groups())
        if stopped or i!=len(rows) or rate!=8500*(i+1) or not 0<=tx<=plan or not plan:
            return {'status':'inconsistent_trace'}
        why=[]
        if not ack:
            if rx or rs or idle:return {'status':'inconsistent_trace'}
            why.append('sample_reply_missing');expected=5
        elif tx==0 or tx*100<plan*95 or not 300000<=ts<=335000:
            if tx==0 or tx*100<plan*95:why.append('sender_packet_count')
            if not 300000<=ts<=335000:why.append('sender_duration')
            expected=4
        elif rx>tx:
            why.append('inconsistent_receiver_count');expected=5
        else:
            if rx*100<tx*97:why.append('receiver_packet_count')
            if rs>ts*5//4:why.append('receiver_duration')
            if idle>55000:why.append('receiver_read_gap')
            expected=3 if why else 2 if i==3 else 5
        if state!=expected:return {'status':'grade_disagrees_with_counts'}
        rows.append(dict(step=i,rate_kbps=rate,planned=plan,sent=tx,send_us=ts,reply=bool(ack),
                         received=rx if ack else None,receive_us=rs if ack else None,
                         max_read_gap_us=idle if ack else None,reasons=why))
        stopped=bool(why) or i==3
    return dict(status='no_samples' if not rows else 'grade_observed' if stopped else 'incomplete_trace',steps=rows)
