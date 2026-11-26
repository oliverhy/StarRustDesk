"""Reader-owned, same-clock occupancy and dispatch evidence. No packet contents."""
import re

KEYS='t reads stamps cp rq cnt slow pool ready off runq inc dp dr dm du wp wr wo wq span overhead probe_us'.split()
PHASE='ph bc be bu dc dw db ds dx mc mw mo mb mx hb ha pb pa'.split()
RULE=re.compile('rx_ledger_dispatch '+' '.join(k+r'=(\d{1,10})' for k in KEYS)+r'(?: reader_qos=([1-5]))?'+
                '(?: phase_v=1' + ''.join(' '+k+r'=(\d{1,10})' for k in PHASE)+')?')
def parse(line):
    m=RULE.fullmatch(line)
    if not m:return None
    g=m.groups();x=dict(zip(KEYS,map(int,g[:len(KEYS)])))
    if g[len(KEYS)] is not None:x['reader_qos']=int(g[len(KEYS)])
    if g[len(KEYS)+1] is not None:
        x.update(zip(PHASE,map(int,g[len(KEYS)+1:])))
        if (any(x['ph']!=sum(x[k] for k in keys.split()) for keys in ('dp dr dm du','bc be bu','dc dw db ds dx'))
            or x['mc']>x['mw'] or x['mo']>x['mw'] or max(x['hb'],x['ha'])>x['ph']
            or max(x['pb'],x['pa'])>100 or (not x['ph'] and any(x[k] for k in PHASE[1:]))):return None
    if any(x[k]>x['reads'] for k in ('stamps','cp','rq','cnt','slow','inc')):return None
    if x['inc']>x['cnt'] or x['inc']>sum(x[k] for k in ('dp','dr','dm','du')):return None
    if any(x[l]>x[h] for l,h in (('off','ready'),('runq','ready'),('wp','pool'),('wr','ready'),('wo','off'),('wq','runq'),('wo','wr'),('wq','wr'),('overhead','probe_us'))):return None
    if not x['inc'] and any(x[k] for k in ('dp','dr','dm','du','wp','wr','wo','wq','span')):return None
    return x

def summarize(rows,total=None):
    if not rows:return None
    lk=('dp','dr','dm','du')
    nums={k:sum(r[k] for r in rows) for k in ('reads','stamps','cp','rq','cnt','slow','inc','probe_us',*lk)}
    peaks={k:max(r[k] for r in rows) for k in ('pool','ready','off','runq','wp','wr','wo','wq','span','overhead')}
    n=sum(nums[k] for k in lk)
    elapsed=rows[-1]['t']-rows[0]['t']
    # The first row has no saved predecessor. Compare complete following
    # intervals only; wall time in a diagnostic call is not a CPU percentage.
    observed_us=sum(r['probe_us'] for r in rows[1:])
    ext=[r for r in rows if 'ph' in r]
    phase_bounds=None
    if ext:
        phase_bounds=dict(windows=len(ext),all_windows_covered=len(ext)==len(rows),
                   counts={k:sum(r[k] for r in ext) for k in 'ph bc be bu dc dw db ds dx hb ha'.split()},
                   peaks={k:max(r[k] for r in ext) for k in 'mc mw mo mb mx pb pa'.split()})
    return dict(windows=len(rows),coverage='unknown' if total is None else 'matched' if n==total else 'partial' if n<total else 'inconsistent',
                observed_drops=n,socket_drops=total,counts=nums,peaks_us=peaks,
                probe_wall_pct=round(observed_us/(elapsed*10),3) if elapsed>0 else None,
                reader_qos_states=sorted({r.get('reader_qos',0) for r in rows}),phase_bounds=phase_bounds,
                dominant_interval='at least 75 percent of the drop-counter interval; not individual packet attribution')

def qualify(s,trial,seconds):
    if not s or s['windows']<seconds//3 or s['coverage']!='matched':return 'evidence_incomplete'
    q=s['reader_qos_states']
    if trial=='initiated':
        return 'reader_level_changed_and_read_back' if q==[1] else 'already_at_or_above' if q in ([2],[3]) else 'reader_level_not_confirmed'
    if trial=='phase':
        p=s['phase_bounds']
        return ('reader_phase_observed' if q==[0] and p and p['all_windows_covered']
                and p['counts']['ph']==s['observed_drops'] else 'phase_missing_or_mixed')
    return 'unknown_trial'

def margin_opportunities(dispatch,bursts):
    """Replay the criteria on genuinely co-sampled windows; never infer a socket resize."""
    if len(dispatch)!=len(bursts) or len(bursts)<2:return None
    valid=0;events=[]
    for i,(d,b) in enumerate(zip(dispatch,bursts)):
        if 'ph' not in d or abs(d['t']-b['t'])>12:return None
        if i==0:continue
        old=bursts[i-1];a,e=old.get('socket_counter'),b.get('socket_counter')
        if a is None or e is None or not 0<b['t']-old['t']<=3500 or e-a!=d['ph']:continue
        valid+=1;n=d['ph']
        if not n:continue
        phase=n>=8 and d['bc']==d['hb']==d['ha']==n and 4*(d['dc']+d['ds'])>=3*n
        fresh=(b['packets']>=256 and 10*b['stamped']>=9*b['packets'] and b['burst']>=16 and 2000<=b['age']<=60000)
        events.append(dict(at_ms=b['t'],count=n,phase=phase,other_pressure_checks=fresh,
             stamped_old_pct=round(100*b['aged']/b['stamped'],2) if b['stamped'] else None,
             age_us=b['age'],eligible=bool(phase and fresh and 4*b['aged']<=b['stamped'])))
    return dict(covered_intervals=valid,possible_intervals=len(bursts)-1,positive=events)
