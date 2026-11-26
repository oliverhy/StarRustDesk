"""Test-only Windows path comparison. Logs contain times/counters, not peers or keys."""
import hmac
import ipaddress
import json
from pathlib import Path
import re
import secrets
import select
import socket
import subprocess
import threading
import time

import udp_broker


def hello(key, nonce):
    message=b"SCB1\x00\x01\x01\x00"+nonce+bytes(40)
    return message+udp_broker.sign(key,message)


def is_challenge(key, nonce, data):
    return (len(data)==udp_broker.SIZE and data[:8]==b"SCB1\x00\x01\x03\x00"
            and data[8:24]==nonce and not any(data[40:64])
            and hmac.compare_digest(data[64:],udp_broker.sign(key,data[:64])))


def rows_named(log, prefix):
    return [dict((key,int(value)) for key,value in re.findall(r"([a-z_]+)=(\d+)",line))
            for line in log if line.startswith(prefix+" ")]


def intersect_events(events, udp, lan, wlan=(), link_observed=()):
    spans=[]
    active=None
    for row in events:
        if row["phase"]==1:
            active=[row]
        elif active is not None:
            active.append(row)
            if row["phase"]==3:
                spans.append((active,True))
                active=None
    if active: spans.append((active,False))
    out=[]
    # "lan" was historically indexed by the ICMP start, not by the time
    # the adapter counters and neighbor cache were actually sampled.
    observed={row[0]:row for row in link_observed}
    for rows,recovered in spans:
        start,end=rows[0]["utc_ms"],rows[-1]["utc_ms"]
        # Older recordings carry RTT for success, but only the *configured*
        # 360-ms timeout for failures. A stalled Windows thread can finish
        # considerably later. Keep old estimates labelled as such.
        echo=[row for row in udp if start<=row[0]<end and
              row[0]+(row[4] if len(row)>4 else row[2] if row[1]==1 else 360 if row[1]==2 else 0)<=end]
        link=[row for row in lan if start<=row[0]<end]
        link_full=[row for row in link if row[0] in observed and observed[row[0]][1]<=end]
        samples=[(observed[row[0]],row) for row in lan if row[0] in observed and
                 start<=observed[row[0]][1]<=end]
        interval={}
        if len(samples)>=2:
            (at1,first),(at2,last)=samples[0],samples[-1]
            changes=[last[i]-first[i] for i in range(4,8)]
            if all(row[3] for _,row in samples) and min(changes)>=0:
                interval=dict(first_ms=at1[1]-start, last_ms=at2[1]-start,
                              discards=changes[0], errors=changes[1],
                              tx_bytes=changes[2], rx_bytes=changes[3])
        out.append(dict(begin_ms=start, end_ms=end, busy_ms=rows[-1]["busy_ms"],
            errno=rows[0]["errno"], recovered=recovered,
            reported_not_writable=sum(row["phase"]!=3 and row["ready"]==0 for row in rows),
            attempts=rows[-1]["attempts"], udp_measured_completions=sum(len(row)>4 for row in echo),
            udp_legacy_estimates=sum(len(row)<=4 for row in echo),udp_success=sum(row[1]==1 for row in echo),
            udp_timeout=sum(row[1]==2 for row in echo), udp_error=sum(row[1]>2 for row in echo),
            gateway_success=sum(row[1]==1 for row in link), gateway_timeout=sum(row[1]!=1 for row in link),
            gateway_peak_ms=max((row[2] for row in link if row[1]==1),default=0),
            gateway_full_success=sum(row[1]==1 for row in link_full),
            gateway_full_failures=sum(row[1]!=1 for row in link_full),
            link_interval=interval,
            gateway_cache_states=sorted({(m[3],m[4]) for m,_ in samples if m[2]==0}),
            gateway_cache_errors=sorted({m[2] for m,_ in samples if m[2]!=0}),
            guard_holds=rows[-1].get("holds",0),
            wlan_notifications=[[at-start,code] for at,code in wlan if start-750<=at<=end+750]))
    return out


class TxProbes:
    def __init__(self, local_ip, endpoint, root, *, local_only=False, ethernet=False):
        self.address=str(ipaddress.IPv4Address(local_ip))
        self.local_only=local_only
        if ethernet and not local_only:raise ValueError('ethernet_observation_requires_local_route')
        self.ethernet=ethernet
        self.gateway=None
        self.phy=[]
        self.quality=[]
        self.radio=[]
        self.ping_detail=[]
        if local_only:
            if endpoint is not None or root is not None: raise ValueError("unexpected_public_probe")
            self.endpoint=self.key=None
        else:
            ip,sep,port=endpoint.rpartition(":")
            dst=ipaddress.IPv4Address(ip)
            if not sep or port!="23388" or not dst.is_global or dst.is_multicast:
                raise ValueError("tx_probe_endpoint_invalid")
            self.endpoint=(str(dst),int(port))
            # A HELLO alone never changes a session/candidate.
            self.key=udp_broker.tickets(root)[0]
        self.stopped=threading.Event()
        self.workers=[]
        self.process=None
        self.udp,self.lan=[],[]
        self.wlan=[]
        self.link_observed=[]
        self.started=False
        self.echo_setup_error=0
        self.lan_setup=0
        self.wlan_setup,self.wlan_setup_error=0,0

    def start(self):
        if self.started: return
        self.started=True
        if not self.local_only:
            self.workers.append(threading.Thread(target=self.echo_run,daemon=True))
        try:
            script=Path(__file__).with_name("tx_link_windows.ps1")
            args=["powershell.exe","-NoProfile","-File",str(script),self.address]
            if self.local_only: args.append("-CompareEthernet" if self.ethernet else "-CompareWifi")
            self.process=subprocess.Popen(args,
                stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
            self.workers.append(threading.Thread(target=self.link_run,daemon=True))
        except OSError:
            pass
        for worker in self.workers: worker.start()

    def close(self):
        self.stopped.set()
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=4)
        for worker in self.workers: worker.join(1)
        if self.process: self.process.stdout.close()

    def echo_run(self):
        try:
            with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
                sock.bind((self.address,0))
                sock.connect(self.endpoint)
                sock.setblocking(False)
                while not self.stopped.is_set() and len(self.udp)<1500:
                    self.udp.append(self.exchange(sock))
                    # Do not send bursts to catch up after a scheduling slip.
                    self.stopped.wait(.5)
        except (OSError,ValueError) as exc:
            self.echo_setup_error=getattr(exc,"winerror",0) or getattr(exc,"errno",0) or 1

    def exchange(self,sock):
        nonce=secrets.token_bytes(16)
        stamp=time.time_ns()//1_000_000
        start_ns=time.monotonic_ns()
        started=time.monotonic()
        def result(status,rtt=0,error=0):
            # Round up for containment at millisecond boundaries; never count
            # a late timeout/reply as completed before the path recovered.
            elapsed=(time.monotonic_ns()-start_ns+999_999)//1_000_000
            return [stamp,status,rtt,error,elapsed]
        try:
            if sock.send(hello(self.key,nonce))!=udp_broker.SIZE: return result(3)
        except OSError as exc:
            return result(3,error=getattr(exc,"winerror",None) or exc.errno or 0)
        try:
            for _ in range(6):
                remaining=.36-(time.monotonic()-started)
                if remaining<=0 or not select.select([sock],[],[],remaining)[0]: break
                if is_challenge(self.key,nonce,sock.recv(udp_broker.SIZE+1)):
                    return result(1,round((time.monotonic()-started)*1000))
        except OSError as exc:
            return result(4,error=getattr(exc,"winerror",None) or exc.errno or 0)
        return result(2)

    def link_run(self):
        for raw in self.process.stdout:
            line=raw.decode("ascii","ignore").strip()
            if match:=re.fullmatch(r"link_setup (\d) (\d)",line):
                self.lan_setup=int(match[1])
            elif self.local_only and (match:=re.fullmatch(r"private_gateway ([0-9.]{7,15})",line)):
                # Private handoff only. Never serialize the address or the command.
                try: self.gateway=str(ipaddress.IPv4Address(match[1]))
                except ValueError: pass
            elif self.local_only and len(self.phy)<1650 and re.fullmatch(r"wlan_phy(?: \d{1,20}){10}",line):
                self.phy.append(list(map(int,line.split()[1:])))
            elif self.local_only and len(self.quality)<1650 and re.fullmatch(r"wlan_quality(?: \d{1,16}){6}",line):
                self.quality.append(list(map(int,line.split()[1:])))
            elif self.local_only and len(self.radio)<1650 and re.fullmatch(r"wlan_radio \d{12,16} \d{12,16} \d{1,10} -?\d{1,3} \d{1,10} [0-7]",line):
                self.radio.append(list(map(int,line.split()[1:])))
            elif self.local_only and len(self.ping_detail)<3300 and re.fullmatch(r"link_ping_detail \d{12,16} [1-4]",line):
                self.ping_detail.append(list(map(int,line.split()[1:])))
            elif match:=re.fullmatch(r"wlan_setup ([01]) (\d{1,10})",line):
                self.wlan_setup,self.wlan_setup_error=map(int,match.groups())
            elif len(self.wlan)<2048 and re.fullmatch(r"wlan_event \d{12,16} (?:7|8|9|10|11|20|21|26|27)",line):
                self.wlan.append(list(map(int,line.split()[1:])))
            elif len(self.lan)<3300 and re.fullmatch(r"link(?: \d+){8}",line):
                self.lan.append(list(map(int,line.split()[1:])))
            elif len(self.link_observed)<3300 and re.fullmatch(
                    r"link_observed \d{12,16} \d{12,16} \d{1,10} [0-6] [01]",line):
                self.link_observed.append(list(map(int,line.split()[1:])))

    def save(self, folder, log):
        events=rows_named(log,"wan_tx_event")
        setups=rows_named(log,"wan_tx_setup")
        guards=rows_named(log,"wan_tx_guard")
        trial=rows_named(log,"wan_trial_sndbuf")
        recovery=rows_named(log,"wan_recovery_queue")
        out=dict(media=setups[-1] if setups else {}, guard=guards[-1] if guards else {},
                 relay_socket_trial=trial[-1] if trial else {}, recovered_queue=recovery[-1] if recovery else {},
                 echo_setup_error=self.echo_setup_error,
                 link_setup=self.lan_setup, udp_samples=len(self.udp),
                 udp_ok=sum(row[1]==1 for row in self.udp), lan_samples=len(self.lan),
                 lan_ok=sum(row[1]==1 for row in self.lan),
                 link_observed_samples=len(self.link_observed),
                 gateway_cache_ok=sum(row[2]==0 for row in self.link_observed),
                 wlan_setup=self.wlan_setup,wlan_setup_error=self.wlan_setup_error,
                 wlan_samples=len(self.wlan),
                 spans=intersect_events(events,self.udp,self.lan,self.wlan,self.link_observed))
        # Numeric data only: independent UDP [UTC, status, RTT, errno, elapsed ms],
        # LAN [probe UTC, status, RTT, up, discards, errors, sent, received].
        # Link observations [probe UTC, counter UTC, cache error, state, unreachable].
        (folder/"udp-send-probes.json").write_text(
            json.dumps(dict(summary=out,udp=self.udp,lan=self.lan,wlan=self.wlan,
                            link_observed=self.link_observed,media_events=events),indent=2),encoding="utf-8")
        return out
