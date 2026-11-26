"""Bounded per-interval receiver counters only: never accept addresses or packet contents."""
import re

FIELDS='t active ts ov packets stamped calls full burst age aged bad loss lossburst lossage lossgap turn probes service cpu offcpu slowwait waitover'.split()
MEM_FIELDS='mem mempeak mempct'.split()
LINE=re.compile('rx_ledger_burst '+' '.join(k+r'=(\d{1,10})' for k in FIELDS)+'(?: '+
                ' '.join(k+r'=(\d{1,10})' for k in MEM_FIELDS)+r')?(?: socket_drops=(-1|\d{1,10}))?')

def parse(line):
    match=LINE.fullmatch(line)
    if not match:return None
    r={k:int(v) for k,v in zip(FIELDS+MEM_FIELDS,match.groups()) if v is not None}
    if match.groups()[-1] is not None:
        count=int(match.groups()[-1])
        if count>0xffffffff:return None
        r['socket_counter']=None if count<0 else count
    if (any(r[k]>1 for k in ('active','ts','ov')) or r['stamped']+r['bad']!=r['packets']
            or r['aged']>r['stamped'] or r['burst']>256 or r['lossburst']>r['burst']
            or r['lossage']>r['age'] or r['full']>r['calls'] or r['calls']>r['packets']
            or r['offcpu']>r['service'] or r['lossgap']>r['turn']):return None
    return r

def largest_socket_drop_cluster(rows):
    """Largest count over consecutive observed rising intervals, not exact drop instants."""
    best=run=None
    for a,r in zip(rows,rows[1:]):
        before,after=a.get('socket_counter'),r.get('socket_counter')
        if before is None or after is None or after<=before or not 0<r['t']-a['t']<=3500:
            run=None
            continue
        if run is None:
            run=dict(start_ms=a['t'],end_ms=a['t'],drops=0,windows=0,queue_age_us=None,queue_pct=None)
        run['end_ms']=r['t'];run['windows']+=1;run['drops']+=after-before
        if r.get('stamped',0)>0:
            run['queue_age_us']=max(run['queue_age_us'] or 0,r['age'])
        if r.get('mem',0)>0:
            run['queue_pct']=max(run['queue_pct'] or 0,r['mempct'])
        if best is None or run['drops']>best['drops']:
            best=run.copy()
    return best

def summary(rows):
    if not rows:return None
    loss=[r for r in rows if r['loss']]
    changes=[(r,r['socket_counter']-a['socket_counter']) for a,r in zip(rows,rows[1:])
             if a.get('socket_counter') is not None and r.get('socket_counter') is not None
             and a['socket_counter']<r['socket_counter'] and 0<r['t']-a['t']<=3500]
    intervals=[r for r,_ in changes]
    def peak(key,group=rows):return max((r[key] for r in group),default=None)
    memory=[r for r in rows if r.get('mem',0)>0]
    return dict(windows=len(rows),live_ms=rows[-1]['t'],active_windows=sum(r['active'] for r in rows),
        largest_observed_socket_drop_cluster=largest_socket_drop_cluster(rows),
        sampled_kernel_queue_bytes=peak('mempeak',memory),sampled_kernel_queue_percent=peak('mempct',memory),
        stamp_windows=sum(r['ts'] for r in rows),overflow_option_windows=sum(r['ov'] for r in rows),
        datagrams=sum(r['packets'] for r in rows),kernel_stamped=sum(r['stamped'] for r in rows),
        queue_age_ge5ms=sum(r['aged'] for r in rows),peak_kernel_queue_age_us=peak('age'),
        max_kernel_arrivals_in_1ms=peak('burst'),positive_read_syscalls=sum(r['calls'] for r in rows),
        full_24_reads=sum(r['full'] for r in rows),worst_turn_us=peak('turn'),
        sampled_batch_service_wall_us=peak('service'),sampled_batch_service_cpu_us=peak('cpu'),
        sampled_batch_offcpu_us=peak('offcpu'),poll_timeout_overrun_us=peak('waitover'),
        drop_marker_increase=sum(r['loss'] for r in loss),drop_windows=len(loss),
        drop_marker_peak_kernel_age_us=peak('lossage',loss),drop_marker_peak_arrivals_1ms=peak('lossburst',loss),
        worker_gap_before_drop_marker_us=peak('lossgap',loss),
        socket_counter_at_first_window=rows[0].get('socket_counter'),
        socket_counter_at_last_window=rows[-1].get('socket_counter'),
        socket_increase_in_covered_windows=sum(d for _,d in changes),socket_loss_intervals=len(intervals),
        socket_loss_window_max_arrivals_1ms=peak('burst',intervals),socket_loss_window_max_age_us=peak('age',intervals),
        socket_loss_window_max_turn_us=peak('turn',intervals),socket_loss_window_max_service_us=peak('service',intervals),
        socket_loss_window_max_offcpu_us=peak('offcpu',intervals),socket_loss_window_max_poll_over_us=peak('waitover',intervals))
