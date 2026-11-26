"""Opt-in lab witness. USB times each phone ping; the echo itself travels over Wi-Fi."""
import ipaddress
import json
import math
import re
import socket
import subprocess
import threading
import time

from tx_probe import TxProbes


def _windows_lan_route(local, peer):
    """Classify the *selected source*, not a Wi-Fi card merely present on the PC."""
    from portable_host import pwsh
    here,there=map(ipaddress.IPv4Address,(local,peer))
    if here==there or not any(here in n and there in n for n in map(ipaddress.IPv4Network,
            ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16'))):return 'unknown',None
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as route:
        route.connect((str(there),49152))  # OS route lookup only; sends no packet
        if route.getsockname()[0]!=str(here):return 'changed',None
    typ=pwsh("$local=[Net.IPAddress]::Parse('"+str(here)+"');"
             "$m=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()|Where-Object {"
             "$_.OperationalStatus -eq 'Up' -and @($_.GetIPProperties().UnicastAddresses|Where-Object "
             "{$_.Address.Equals($local)}).Count -eq 1});if($m.Count -eq 1){"
             "'{0}:{1}' -f [int]$m[0].NetworkInterfaceType,$m[0].GetIPProperties().GetIPv4Properties().Index}")
    m=re.fullmatch(r'(6|71):([1-9]\d{0,9})',typ)
    if not m or int(m[2])>=2**32:return 'unknown',None
    return {'71':'wifi','6':'ethernet'}[m[1]],int(m[2])


def windows_lan_medium(local,peer):
    return _windows_lan_route(local,peer)[0]


def checked_addresses(pc, mobile, gateway):
    pc, mobile, gateway = map(ipaddress.IPv4Address, (pc, mobile, gateway))
    lan = ipaddress.IPv4Network((pc, 24), strict=False)
    private = any(lan.subnet_of(ipaddress.IPv4Network(n)) for n in
                  ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))
    if (not private or len({pc, mobile, gateway}) != 3 or
            any(a not in lan or a in (lan.broadcast_address, lan.network_address) for a in (pc, mobile, gateway))):
        raise ValueError('witness_not_on_same_private_lan')
    return str(mobile), str(gateway)


def ping_result(raw, source, gateway):
    # Harmony hdc can exit 0 even when the shell command fails. Require both
    # the explicit source binding and the actual one-packet response summary.
    prefix = f'Ping {gateway} ({gateway}) from {source} ({source}):'
    if not raw.lstrip().startswith(prefix): return 0, 0
    if re.search(r'\b1 packets? transmitted, 0 received, 100% packet loss', raw): return 2, 0
    if not re.search(r'\b1 packets? transmitted, 1 received, 0% packet loss', raw): return 0, 0
    m = re.search(r'bytes from '+re.escape(gateway)+r':[^\n]*?\btime[=<]([0-9]+(?:\.[0-9]+)?)\s*ms', raw)
    return (1, math.ceil(float(m[1]))) if m else (0, 0)


def completed(rows, start, end):
    return [r for r in rows if start <= r[0] <= r[1] <= end and r[0] < end]


def tally(rows):
    return dict(ok=sum(r[2] == 1 for r in rows), timeout=sum(r[2] == 2 for r in rows),
                invalid=sum(r[2] not in (1, 2) for r in rows))


def rtt_range(rows):
    values=sorted(r[3] for r in rows if r[2]==1)
    return ({'p50_ms':values[(len(values)-1)//2],'p95_ms':values[math.ceil(.95*len(values))-1],
             'max_ms':values[-1]} if values else None)


def phy_range(rows):
    good = [r for r in rows if r[2] == 0]
    out = dict(samples=len(rows), valid=len(good), deltas=None)
    if len(good) < 2 or len(good) != len(rows): return out
    if any(any(bv < av for av, bv in zip(a[3:], b[3:])) for a, b in zip(good, good[1:])): return out
    delta = [b-a for a,b in zip(good[0][3:], good[-1][3:])]
    # Lots of drivers report success with all counters fixed at zero.
    if any(delta):
        out['deltas'] = dict(zip(('tx','failed','retry','tx_lifetime','ack_failed','rx','fcs'),delta))
    return out


def quality_range(rows):
    good=[r for r in rows if r[2]==0]
    return dict(samples=len(rows), valid=len(good),
                reported_quality_range=[min(r[3] for r in good),max(r[3] for r in good)] if good else None,
                association_tx_rate_range=[min(r[5] for r in good),max(r[5] for r in good)] if good else None)


def pc_tally(rows):
    return dict(ok=sum(r[2]==1 for r in rows),no_reply=sum(r[2]!=1 for r in rows),
                confirmed_timeout=sum(r[2]==2 for r in rows),unclassified=sum(r[2]==0 for r in rows),
                other_status=sum(r[2]==3 for r in rows),query_error=sum(r[2]==4 for r in rows))


def gateway_episodes(pc, phone, long, scans, radio=(), phy=()):
    episodes=[]
    group=[]
    for row in list(pc)+[None]:
        if row is not None and row[2]!=1: group.append(row);continue
        if group:
            a,b=group[0][0],group[-1][1]
            episodes.append(dict(begin_ms=a,end_ms=b,duration_ms=b-a,pc_gateway=pc_tally(group),
                phone_gateway=tally(completed(phone,a,b)),
                radio=radio_range(completed(radio,a,b)),phy=phy_range(completed(phy,a,b)),
                phone_ok_inside_individual_failed_ping=sum(any(lo<=s<=e<=hi for lo,hi,*_ in group)
                                                            for s,e,status,_ in phone if status==1),
                overlapping_media_refusals=sum(s['begin_ms']<b and
                    s.get('end_ms',s['begin_ms']+s['busy_ms'])>a for s in long),
                scan_complete_from_start_ms=[t-a for t in scans if a-750<=t<=b+750]))
            group=[]
    return episodes


def radio_range(rows):
    rssi=[r[3] for r in rows if r[2]==0 and -127<=r[3]<0]
    return dict(samples=len(rows), valid_rssi=len(rssi), rssi_dbm=[min(rssi),max(rssi)] if rssi else None,
                connected=sum(r[4]==0 and r[5]==1 for r in rows),
                disconnected_or_transitional=sum(r[4]==0 and r[5]!=1 for r in rows))


def describe(spans, phone, lan, observed, wlan, phy, quality=(), details=(), radio=()):
    ends = {r[0]: r[1] for r in observed}
    detail=dict(details)
    pc = [[r[0], ends[r[0]], detail.get(r[0],1 if r[1]==1 else 0), r[2]] for r in lan if r[0] in ends]
    scans = [r[0] for r in wlan if r[1] == 7]
    candidates = [s for s in spans if s['busy_ms'] >= 150 and s['recovered']]
    # busy_ms uses a monotonic clock; do not align UTC observations across a
    # wall-clock step. Older files may lack end_ms (estimated from duration).
    long = [s for s in candidates if 'end_ms' not in s or abs(s['end_ms']-s['begin_ms']-s['busy_ms'])<=50]
    windows, associated = [], set()
    for s in long:
        a, b = s['begin_ms'], s.get('end_ms', s['begin_ms']+s['busy_ms'])
        before, during, after = [tally(completed(phone, lo, hi)) for lo, hi in
                                 ((a-5000,a), (a,b), (b,b+5000))]
        host = pc_tally(completed(pc,a,b))
        near = [i for i,t in enumerate(scans) if a-750 <= t <= b+750]
        associated.update(near)
        # These observations localize a symptom, not a radio/driver root cause.
        separates = (before['ok'] and after['ok'] and during['ok'] and
                     host['no_reply'] and not host['query_error'] and not host['ok'] and
                     pc_tally(completed(pc,a-5000,a))['ok'] and pc_tally(completed(pc,b,b+5000))['ok'])
        windows.append(dict(begin_ms=a, end_ms=b, busy_ms=s['busy_ms'], attempts=s['attempts'],
            errno=s['errno'], pc_gateway=host, phone_gateway=during, phone_before=before, phone_after=after,
            phone_ok_during_pc_failure=bool(separates), phy=phy_range(completed(phy,a,b)),
            radio_quality=quality_range(completed(quality,a,b)),
            radio=radio_range(completed(radio,a,b)),
            scan_complete_from_start_ms=[scans[i]-a for i in near]))
    return dict(phone=tally(phone), pc_gateway=pc_tally(pc), phone_gateway_rtt=rtt_range(phone),
                pc_gateway_rtt=rtt_range(pc), phy=phy_range(phy),radio_quality=quality_range(quality),
                radio=radio_range(radio),
                clock_inconsistent_spans=len(candidates)-len(long),
                gateway_episodes=gateway_episodes(pc,phone,long,scans,radio,phy),
                scan_complete=len(scans), scan_complete_away_from_long_refusals=len(scans)-len(associated),
                long_refusals=windows)


class WifiWitness:
    def __init__(self, pc, mobile, hdc, medium='wifi'):
        if medium not in ('wifi','ethernet'):raise ValueError('unsupported_host_medium')
        self.filename='wifi-uplink.json' if medium=='wifi' else 'ethernet-phone-wifi.json'
        self.probes = TxProbes(pc, None, None, local_only=True,ethernet=medium=='ethernet')
        self.pc, self.mobile, self.hdc = pc, mobile, list(hdc)
        self.stop = threading.Event()
        self.worker = threading.Thread(target=self.observe, daemon=True)
        self.rows = []
        self.setup = 0
        self.tx_caps=None

    def start(self):
        from lan_tx_caps import query
        if self.filename=='ethernet-phone-wifi.json':
            medium,index=_windows_lan_route(self.pc,self.mobile)
            self.tx_caps=query(index if medium=='ethernet' else None)
        self.probes.start()
        self.worker.start()

    def close(self):
        self.stop.set()
        self.worker.join(4)
        self.probes.close()

    def observe(self):
        for _ in range(80):
            if self.probes.gateway: break
            if self.stop.wait(.1): return
        try: source, gw = checked_addresses(self.pc, self.mobile, self.probes.gateway)
        except (TypeError, ValueError): return
        self.setup = 1
        cmd = self.hdc+['shell', f'ping -4 -I {source} -c 1 -s 8 -W 1 {gw}']
        while not self.stop.is_set() and len(self.rows) < 1600:
            start=time.time_ns()//1_000_000
            tick=time.monotonic_ns()
            try:
                result=subprocess.run(cmd,capture_output=True,timeout=2.7,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
                status,rtt=ping_result(result.stdout.decode('ascii','replace'),source,gw)
            except (OSError, subprocess.TimeoutExpired): status,rtt=0,0
            end=(time.time_ns()+999_999)//1_000_000
            duration=(time.monotonic_ns()-tick+999_999)//1_000_000
            if abs((end-start)-duration)>20: status=0
            self.rows.append([start,end,status,rtt])
            self.stop.wait(.28)

    def save(self, folder, log):
        p=self.probes
        if self.tx_caps is not None:
            (folder/'lan-host-tx-capabilities.json').write_text(json.dumps(self.tx_caps),encoding='ascii')
        sampled=p.save(folder, log)
        evidence=describe(sampled['spans'],self.rows,p.lan,p.link_observed,p.wlan,p.phy,p.quality,p.ping_detail,p.radio)
        evidence['phone_source_bound']=bool(self.setup and evidence['phone']['ok'])
        evidence['wlan_registered']=bool(p.wlan_setup)
        (folder/self.filename).write_text(json.dumps(dict(summary=evidence,phone=self.rows,phy=p.phy,
                                                               quality=p.quality,ping_detail=p.ping_detail,radio=p.radio),
                                                           indent=2),encoding='ascii')
        return evidence


def reread(folder):
    # Works with both the first witness format and the later RSSI-aware one.
    host=json.loads((folder/'udp-send-probes.json').read_text(encoding='utf-8'))
    wifi=json.loads((folder/'wifi-uplink.json').read_text(encoding='utf-8'))
    return describe(host['summary']['spans'],wifi['phone'],host['lan'],host['link_observed'],
                    host['wlan'],wifi['phy'],wifi.get('quality',()),wifi.get('ping_detail',()),wifi.get('radio',()))


if __name__=='__main__':
    import argparse
    from pathlib import Path
    parser=argparse.ArgumentParser(description='Summarize numeric test observations only, offline.')
    parser.add_argument('run_folder',type=Path)
    print(json.dumps(reread(parser.parse_args().run_folder),indent=2))
