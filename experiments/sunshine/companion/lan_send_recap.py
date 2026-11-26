"""Offline: correlate actual Windows send refusals, both gateway observations, and phone playback."""
import argparse
import json
from pathlib import Path
import re
from wifi_uplink import reread
from lan_encoder_witness import utc_base


def load(p):return json.loads(p.read_text(encoding='utf-8'))


def recap(folder):
    evidence=reread(folder); run=load(folder/'result.json') if (folder/'result.json').is_file() else {}
    epochs=load(folder/'phone-numeric.json')['epochs']
    active=[e for e in epochs if e.get('samples')]
    sample=None
    if len(active)==1 and (steady:=[s for s in active[0]['samples'] if s[0]>=8000]) and len(steady)>=2:
        a,b=steady[0],steady[-1];dt=b[0]-a[0]
        if dt>0:sample=dict(fps=round((b[3]-a[3])*1000/dt,2),mbps=round((b[4]-a[4])*.008/dt,3),
                            gaps=b[5],longest_ms=b[8],render_errors=b[7],measured_seconds=round(dt/1000,2))
    events=load(folder/'udp-send-probes.json')['summary']['spans']
    resumepat=re.compile(r'lan_tx_resume elapsed_ms=(\d+) busy_us=(\d+) ready_seen=([01]) noticed_us=(\d+) to_send_us=(\d+) false_ready=(\d+) attempts=(\d+) holds=(\d+)')
    src=folder/'host-path-numeric.txt'
    lines=src.read_text('utf8').splitlines() if src.is_file() else []
    anchor=utc_base(lines)
    resumes=[tuple(map(int,m.groups())) for line in lines
             if (m:=resumepat.fullmatch(line))]
    long=[]
    for r in evidence['long_refusals']:
        ev=next((s for s in events if s['begin_ms']==r['begin_ms'] and s.get('recovered')), {})
        # Never associate two independent episodes based just on a similar duration.
        recovered=[x for x in resumes if anchor is not None and abs(anchor+x[0]-r['end_ms'])<=25
                   and x[6]==r['attempts'] and abs(x[1]/1000-r['busy_ms'])<=2]
        x=recovered[0] if len(recovered)==1 else None
        long.append(dict(begin_ms=r['begin_ms'],ms=r['busy_ms'],attempts=r['attempts'],errno=r['errno'],
                         holds=ev.get('guard_holds'),not_writable_observations=ev.get('reported_not_writable'),
                         pc_timeouts=r['pc_gateway']['confirmed_timeout'],pc_ok=r['pc_gateway']['ok'],
                         phone_ok=r['phone_gateway']['ok'],phone_timeout=r['phone_gateway']['timeout'],
                         pc_only=r['phone_ok_during_pc_failure'],scan_complete_offset_ms=r['scan_complete_from_start_ms'],
                         writable_to_send_us=x[4] if x and x[2] else None,false_writable=x[5] if x else None))
    return dict(playback=sample,authenticated_route_report=run.get('route'),ready_trial=run.get('lan_ready_trial'),
                refusals=long,scan_completions=evidence['scan_complete'],
                scans_away_from_long_refusals=evidence['scan_complete_away_from_long_refusals'],
                measured_encoder_phone=run.get('encoder_phone'))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('folder',type=Path)
    print(json.dumps(recap(p.parse_args().folder),indent=2))
