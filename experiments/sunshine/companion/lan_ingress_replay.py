"""Encrypted LAN, offline only. Separate reader sample order, sender evidence and gateway RTT."""
import argparse
import json
import re
from pathlib import Path

from analyze_lan_bursts import host_density, since, tod
from lan_key_path import binding
from lan_recovery_witness import stamp_interval, wall_bounds
from long_metrics import RECORD, PAIR, PAIR_END
from phone_burst_metrics import summary
from phone_dispatch import summarize

AHEAD = re.compile(r'rx_ledger_ahead packets=(\d+) blocks=(\d+) oldest_us=(\d+)')
VIDEO = re.compile(r'video_path stage=2 ms=(\d+) packets=\d+ event_gap=(\d+) peak_gap=\d+ previous_frame=(\d+) frame=(\d+) loop_peak=\d+')


def loss_windows(bursts, dispatch, events):
    # Ahead::report takes the previous snapshot and requests a NEW one. The
    # hilog time on the burst line is its publication, not the reader's sample.
    ticks = [(tod(t), *map(int, m.groups())) for t, msg in events if (m := AHEAD.fullmatch(msg))]
    if not bursts or len(dispatch) != len(bursts) or bursts[0]['socket_counter'] != 0:
        raise ValueError('incomplete_reader_start')
    out = []
    for i, (b, p) in enumerate(zip(bursts, dispatch)):
        if abs(p['t'] - b['t']) > 12:
            raise ValueError('reader_phase_not_cosampled')
        if i == 0:
            if p['ph'] or b['loss']:
                raise ValueError('unbracketed_first_sample')
            continue
        prev = bursts[i-1]
        n = b['socket_counter'] - prev['socket_counter']
        if not 0 < b['t'] - prev['t'] <= 3500 or n < 0 or n != p['ph']:
            raise ValueError('missing_or_inconsistent_reader_interval')
        if not n:
            continue
        pub = tod(b['log_time'])
        if pub is None:
            raise ValueError('no_publication_clock')
        ix = [j for j, a in enumerate(ticks) if 0 <= since(pub, a[0]) <= 12]
        # Independent counts corroborate the previous delivery tick for this
        # specific interval. General rows can straddle producer/consumer ticks.
        row = None
        if len(ix) == 1 and ix[0] > 0:
            a = ticks[ix[0]-1]
            if (b['packets'], b['calls']) == a[1:3] and 1000 <= since(pub, a[0]) <= 3500:
                row = dict(delivery_to_publication_ms=since(pub, a[0]), handoff_max_us=a[3])
        out.append(dict(end_reader_ms=b['t'], drops=n, distinct_counter_rises=p['inc'],
                        kernel_peak_packets_per_ms=b['burst'], kernel_queue_max_us=b['age'],
                        age_ge5ms_pct=round(100*b['aged']/b['stamped'], 2) if b['stamped'] else None,
                        charged_queue_peak_pct=b['mempct'], spare_continuous=p['bc'],
                        syscall_dominant=p['dc'], mixed=p['dx'], peak_recv_call_us=p['mc'],
                        delivery_counter_match=row))
    return out


def video_gaps(path):
    out = []
    for t, msg in path:
        m = VIDEO.fullmatch(msg)
        if m is None:
            continue
        ms, gap, a, b = map(int, m.groups())
        if gap >= 140:
            if min(a,b)<1 or (out and ms <= out[-1][1]):
                raise ValueError('ambiguous_video_gap')
            out.append((t, ms, gap, a, b))
    return out


def sender_bounds(path, gaps, endpoints=None):
    # Even if adjacent survivors are in the SAME video frame, include ALL
    # successful sends for both frames: no need to guess a shard ordinal.
    wanted = {n for _, _, _, a, b in gaps for n in (a, b)}
    spans = {}
    size = path.stat().st_size
    if not RECORD.size*3 <= size <= 100_000_025 or size % RECORD.size:
        raise ValueError('invalid_sender_trace')
    with path.open('rb') as f:
        f.seek(-RECORD.size, 2)
        if RECORD.unpack(f.read()) != (255, 0, 0, size//RECORD.size-1, 0):
            raise ValueError('unsealed_sender')
        f.seek(0)
        left = size - RECORD.size
        last = -1
        while left:
            data = f.read(min(left, 8192*RECORD.size))
            if not data or len(data) % RECORD.size:
                raise ValueError('short_sender_trace')
            left -= len(data)
            for kind, frame, ms, epoch, seq in RECORD.iter_unpack(data):
                if kind not in (0, 1):
                    raise ValueError('unknown_sender_record')
                if kind != 1:
                    continue
                if ms < last:
                    raise ValueError('nonmonotonic_sender')
                last = ms
                if frame in wanted:
                    if frame not in spans:
                        spans[frame] = [ms, ms]
                    spans[frame][1] = ms
                    if endpoints is not None and (frame,seq) in endpoints:
                        endpoints[frame,seq].append((epoch,ms))
    return spans


def gap_rows(gaps, spans):
    out = []
    for _, ms, gap, a, b in gaps:
        if a not in spans or b not in spans:
            raise ValueError('unknown_endpoint_frame')
        # Integer milliseconds may round both observations. This is excess
        # inter-arrival spacing, NOT a network transit time or a dropped packet ID.
        upper = max(0, spans[b][1] - spans[a][0] + 1)
        lower = max(0, spans[b][0] - spans[a][1] - 1)
        out.append(dict(end_media_ms=ms, previous_frame=a, frame=b, phone_verified_gap_ms=gap,
                        windows_endpoint_span_upper_ms=upper, windows_endpoint_span_lower_ms=lower,
                        excess_spacing_floor_ms=max(0,gap-1-upper)))
    return out


def paired(rows, ends, gaps, endpoints):
    if not ends and not rows:
        return dict(status='not_in_archive',events=[])
    partial = not ends and bool(rows)
    if (not partial and (len(ends)!=1 or ends[0]!=(len(gaps),len(rows)))) or len(rows)>min(64,len(gaps)):
        return dict(status='incomplete_capture',events=[])
    if not gaps:
        return dict(status='no_video_silence',video_silences=0,phone_pairs=0,events=[])
    seen=set(); out=[]
    for ms,f0,f1,c0,c1,auth,kernel,read,q0,q1,p0,p1 in rows:
        k=(ms,auth//1000,f0,f1)
        if k in seen or k not in {tuple(g[1:]) for g in gaps[:64]}:
            raise ValueError('pair_identity')
        seen.add(k)
        if max(q0,q1,p0,p1)>2_000_000 or abs(auth-(read+p1-p0))>3 or abs(read-(kernel+q1-q0))>1002:
            raise ValueError('pair_clock')
        a,b=endpoints[f0,c0],endpoints[f1,c1]
        # Either clock may see reordered packets. A cross-rekey or duplicate
        # counter is not an exact Windows witness.
        obs=dict(ms=ms,frames=[f0,f1],phone_kernel_spacing_us=kernel,phone_batch_read_spacing_us=read,
                 phone_auth_spacing_us=auth,queue_age_us=[q0,q1],read_to_verified_us=[p0,p1],
                 socket_queue_spacing_change_us=q1-q0,post_read_spacing_change_us=p1-p0)
        if len(a)!=1 or len(b)!=1 or c0==c1 or a[0][0]!=b[0][0]:
            reason='different_send_epoch' if len(a)==len(b)==1 and a[0][0]!=b[0][0] else 'nonunique_or_missing'
            out.append(dict(obs,status='ambiguous_sender',reason=reason));continue
        accepted=b[0][1]-a[0][1]
        excess=kernel-accepted*1000
        # One host clock, truncated to milliseconds. Each difference can be
        # off by <1 ms; signed spacing is not propagation delay. No NIC time.
        out.append(dict(obs,status='matched',windows_send_spacing_ms=accepted,kernel_minus_windows_spacing_us=excess,
                        host_observation='socket_accept',egress_on_wire_observed=False,
                        kernel_minus_accept_spacing_interval_us=[excess-1000,excess+1000]))
    measured=any(x['status']=='matched' for x in out)
    return dict(status=('partial_exact_pairs' if partial else 'measured') if measured else 'no_exact_pair',
                coverage_sealed=not partial,
                video_silences=len(gaps),phone_pairs=len(rows),events=out)


def gateway_cluster(gaps, clocks, pings):
    if not gaps or not clocks:
        return None
    # Only report ONE cluster, and only whole probe brackets strictly inside
    # even the narrower clock envelope, not partial or neighboring probes.
    if gaps[-1][1]-gaps[0][1] > 8000:
        return None
    times = [stamp_interval(t, clocks) for t, *_ in gaps]
    if not all(times) or any(abs((b[0]-a[0])-(y[1]-x[1]))>12
                               for a,b,x,y in zip(times,times[1:],gaps,gaps[1:])):
        return None
    start, end = times[0][1]-gaps[0][2]+12, times[-1][0]-12
    rows = [r for r in pings if start <= r[0] <= r[1] <= end]
    return dict(whole_probes=len(rows), success_rtts_ms=[r[3] for r in rows if r[2]==1],
                timeouts=sum(r[2]==2 for r in rows), invalid=sum(r[2] not in (1,2) for r in rows))


def session(folder):
    read = lambda n: json.loads((folder/n).read_bytes())
    r, p, seal = read('result.json'), read('phone-numeric.json'), read('lan-key-host.json')
    if not (seal.get('version') == 1 and seal.get('sessions') == 1 and binding(folder) == seal['artifacts']
            and r.get('route')=='lan' and r.get('encrypted_video_audio') is True and r.get('usb_forward') is False
            and r.get('host_refuses_input') is True and r.get('primary_capture_confirmed') is True
            and r.get('windows_medium_at_boundaries')==['ethernet']*2 and r.get('ethernet_phone_wifi',{}).get('phone_source_bound')
            and r.get('host_setups')==[[1920,1080,60,20000]] and len(p['epochs'])==1
            and r['attribution']['host_trace_complete']==r['attribution']['host_stream_epochs']==1):
        raise ValueError('unverified_scope')
    return r,p


def packet_witness(folder,p):
    gaps = video_gaps(p['path'])
    trace = folder/'host-numeric.ssmeta'
    rows=[tuple(map(int,m.groups())) for _,s in p['events'] if (m:=PAIR.fullmatch(s))]
    ends=[tuple(map(int,m.groups())) for _,s in p['events'] if (m:=PAIR_END.fullmatch(s))]
    if len(rows)>64:raise ValueError('too_many_pair_rows')
    endpoints={k:[] for ms,a,b,c,e,*_ in rows for k in ((a,c),(b,e))}
    sg = gap_rows(gaps, sender_bounds(trace,gaps,endpoints))
    return gaps,sg,paired(rows,ends,gaps,endpoints)


def report(folder, pairs_only=False):
    read=lambda n: json.loads((folder/n).read_bytes())
    r,p=session(folder)
    gaps,sg,exact=packet_witness(folder,p)
    if pairs_only: return dict(encrypted_video_silences=sg,same_datagrams=exact)
    bursts, dispatch = read('phone-burst-windows.json'), read('phone-reader-dispatch.json')
    total = r['phone_authenticated_udp_socket']['counted_drops']
    if summary(bursts)!=r['phone_burst_receive'] or summarize(dispatch,total)!=r['phone_reader_dispatch']:
        raise ValueError('unmatched_supplemental_counters')
    loss = loss_windows(bursts, dispatch, p['events'])
    if sum(x['drops'] for x in loss)!=total:
        raise ValueError('incomplete_counter_coverage')
    gateway = read('ethernet-phone-wifi.json')
    if gateway['summary'] != r['ethernet_phone_wifi']:
        raise ValueError('unmatched_gateway_run')
    return dict(loss_windows=loss, encrypted_video_silences=sg, host_video_density=host_density(folder/'host-numeric.ssmeta'),
                phone_gateway_during_silences=gateway_cluster(gaps,wall_bounds(read('encoder-size-numeric.json')['clocks']),gateway['phone']),
                same_datagrams=exact)


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('folder',type=Path);ap.add_argument('--save',action='store_true')
    ap.add_argument('--pairs-only',action='store_true',help='Independent sealed data pairs; omit supplemental socket-window attribution')
    a=ap.parse_args();data=json.dumps(report(a.folder,a.pairs_only),indent=2,allow_nan=False)+'\n'
    if a.save:
        with (a.folder/('ingress-pairs-v2.json' if a.pairs_only else 'ingress-replay-v2.json')).open('x',encoding='ascii') as f:f.write(data)
    print(data,end='')
