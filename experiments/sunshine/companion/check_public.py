"""Authorized isolated VPS + real screen acceptance, not a production deployment."""
import argparse
import base64
from contextlib import ExitStack
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import hmac
import json
from pathlib import Path
import queue
import re
import secrets
import shlex
import socket
import subprocess
import threading
import time
import zlib

import check_device as ui
from capture_audit import CaptureAudit
from idr_path import HostMarkers, save_markers
from burst_timing import compare_peaks
from long_metrics import Recorder,output_acceptance
from tx_probe import TxProbes
from phone_socket_observation import observe as observe_phone_socket, gap_windows
import udp_broker
import public_target
import windows_companion as wc


def high_trial_plan(events,replies,expect_spread):
    plans={tuple(map(int,m.groups())) for line in events if
           (m:=re.fullmatch(r"companion_relay_capacity_plan wire_kbps=(\d{4}) video_cap_kbps=(\d{4})",line))}
    wc.require(len(plans)==1,"missing_or_conflicting_relay_capacity_plan")
    wire,video=plans.pop()
    fallback=(wire,video)==(1800,1400)
    spread="companion_host_relay_frame_spread=1" in events
    wc.require((fallback or 1800<wire<=8000 and 1400<video<wire) and bool(replies) and
               all(500<=r[3]<=video for r in replies) and spread==(expect_spread and not fallback),
               "frame_spread_or_safe_fallback_not_confirmed")
    return dict(selected_wire_kbps=wire,video_ceiling_kbps=video,conservative_fallback=fallback,
                frame_spread_active=spread)

def measured_budget(route,high_offer,events,replies,spread):
    if high_offer and route=="relay":
        plan=high_trial_plan(events,replies,spread)
        return plan["selected_wire_kbps"],plan["video_ceiling_kbps"],plan
    wc.require(route in ("direct","relay") and replies and all(500<=r[3]<=1400 for r in replies),
               "direct_or_legacy_over_budget")
    if route=="direct":
        wc.require(not any(x.startswith("companion_relay_capacity_plan ") or x in
            ("companion_host_relay_frame_spread=1","companion_host_relay_spacing=1") for x in events),
            "direct_used_relay_only_features")
    return 1800,1400,None

class TemporaryBroker:
    def __init__(self, scope, deps):
        import paramiko
        self.deps=deps
        self.ip,port,self.allowed_cap=public_target.read_profile()
        self.endpoint=f"{self.ip}:{port}"
        self.client=paramiko.SSHClient()
        scope.callback(self.client.close)
        self.client.load_host_keys(str(Path.home()/".ssh/known_hosts"))
        self.client.set_missing_host_key_policy(paramiko.RejectPolicy())
        wc.require(bool(self.client.get_host_keys().lookup(self.ip)),"companion_vps_host_key_not_pinned")
        source=deps.SERVER_AUTH
        wc.require(source.is_file() and source.stat().st_size<=4096,"companion_vps_credential_unavailable")
        password=source.read_text(encoding="utf-8-sig").rstrip("\r\n")
        wc.require(bool(password) and not any(c in password for c in "\r\n\0"),"companion_vps_credential_format")
        self.client.connect(self.ip,username="root",password=password,allow_agent=False,look_for_keys=False,
                            timeout=8,auth_timeout=9,banner_timeout=8)
        del password
        self.baseline=self.services()
        wc.require(self.port_free(),"companion_authorized_udp_port_busy")
        self.channel=None
        self.buffer=queue.Queue(maxsize=300)
        self.latest=(0,0,0)
        self.registration=""
        self.trace={}
        self.peaks=[]
        self.trace_truncated=None
        self.trace_count=None
        self.trace_stale_time=None
        self.shape_active=False
        self.high_active=False
        self.standard_active=False
        self.trial_bytes=None
        self.shape=None
        wc.event("companion_vps_readonly_baseline_and_port_verified=1")

    def read(self, command):
        stdin,stdout,stderr=self.client.exec_command(command,timeout=7)
        stdin.close()
        try:
            value=stdout.read(8000)
            wc.require(stdout.channel.recv_exit_status()==0,"companion_vps_readonly_check_failed")
            return value.strip()
        finally:
            stdout.channel.close()
            stdout.close()
            stderr.close()

    def services(self):
        # A dedicated test VPS need not run RustDesk. Compare all containers
        # actually on this host, including stopped ones, without starting any.
        # Propagate failed inventory/inspect before the hash pipeline.
        out=self.read("set -eu; ids=$(docker ps -aq --no-trunc); rows=''; "
                      "if [ -n \"$ids\" ]; then rows=$(docker inspect --type container "
                      "--format '{{.Id}}|{{.State.StartedAt}}|{{.State.Running}}' $ids); fi; "
                      "printf '%s\\n' \"$rows\" | LC_ALL=C sort | sha256sum")
        wc.require(re.fullmatch(rb"[a-f0-9]{64}  -",out),"companion_service_baseline_unavailable")
        return out

    def port_free(self):
        return not self.read("ss -H -uan sport = :23388")

    def watch(self):
        try:
            for raw in self.channel.makefile("rb"):
                raw=raw.decode("ascii","ignore").strip()
                if raw in ("companion_broker_listening=1","companion_broker_stopped=1","companion_broker_unavailable=1"):
                    self.buffer.put_nowait(raw)
                elif raw=="companion_broker_shape_active=1":
                    self.shape_active=True
                    wc.event(raw)
                elif raw=="companion_broker_wire_cap_kbps=8000":
                    self.high_active=True
                    wc.event(raw)
                elif raw=="companion_broker_wire_cap_kbps=30000":
                    self.standard_active=True
                    wc.event(raw)
                elif m:=re.fullmatch(r"companion_broker_trial_wire_bytes=(\d+)",raw):
                    self.trial_bytes=int(m[1])
                    wc.event(raw)
                elif re.fullmatch(r"companion_broker_shape queued=\d+ sent=\d+ expired=\d+ cancelled=\d+ "
                                  r"peak_bytes=\d+ max_wait_us=\d+ downlink_limited=\d+ immediate_limited=\d+"
                                  r"(?: limit_bytes=\d+ limit_count=\d+ limit_deadline=\d+ limit_ingress_peak_bytes=\d+)?",raw):
                    self.shape=dict((k,int(v)) for k,v in re.findall(r"([a-z_]+)=(\d+)",raw))
                    wc.event(raw)
                elif m:=re.fullmatch(r"companion_broker_forward rx=(\d+) tx=(\d+) limited=(\d+)",raw):
                    self.latest=tuple(map(int,m.groups()))
                elif re.fullmatch(r"companion_broker_register (?:[a-z]+_[hp]=\d+\s?){8}",raw):
                    self.registration=raw
                elif m:=re.fullmatch(r"companion_broker_peak data=([A-Za-z0-9+/=]{1,2400})",raw):
                    if len(self.peaks)<68: self.peaks.append(base64.b64decode(m[1],validate=True))
                elif m:=re.fullmatch(r"companion_broker_trace tag=(\d{1,20}) data=([A-Za-z0-9+/=]{1,340000})",raw):
                    scan=zlib.decompressobj()
                    data=scan.decompress(base64.b64decode(m[2],validate=True),udp_broker.TRACE_LIMIT+1)
                    if scan.eof and len(data)<=udp_broker.TRACE_LIMIT and all(x<=4 for x in data):
                        self.trace[int(m[1])]=data
                elif m:=re.fullmatch(r"companion_broker_trace_done epochs=(\d+) truncated=(\d+)",raw):
                    self.trace_count,self.trace_truncated=map(int,m.groups())
                elif m:=re.fullmatch(r"companion_broker_shaping_stale_clock=(\d+)",raw):
                    self.trace_stale_time=int(m[1])
        except (OSError,queue.Full,ValueError,zlib.error):
            pass

    def wait(self, expected, seconds):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            try: row=self.buffer.get(timeout=max(.1,end-time.monotonic()))
            except queue.Empty: break
            if row==expected:
                wc.event(row)
                return True
            if row=="companion_broker_unavailable=1": break
        return False

    def start(self, scope, root, salt=None, smooth=False, high=False, *, standard30=False):
        wc.require(not high or (self.allowed_cap==8000 and smooth),"companion_high_relay_not_enabled_for_target")
        wc.require(not standard30 or (self.allowed_cap==8000 and smooth and not high),
                   "one_shot_requires_known_isolated_test_target")
        src=(wc.HERE/"udp_broker.py").read_text(encoding="utf-8")
        self.channel=self.client.get_transport().open_session(timeout=7)
        mode=(" soak-shape" if salt else " shape") if smooth else (" soak" if salt else "")
        if high: mode+=" high8"
        if standard30: mode+=" short30"
        self.channel.exec_command("timeout --foreground -k 3s "+("115s" if standard30 else "805s" if salt else "595s")+
                                  " python3 -u -c "+shlex.quote(src)+mode)
        scope.callback(self.close)
        threading.Thread(target=self.watch,daemon=True).start()
        self.channel.sendall(b"".join(udp_broker.tickets(root))+(salt or b""))
        wc.require(self.wait("companion_broker_listening=1",9),"companion_broker_start_unconfirmed")
        wc.require(not smooth or self.shape_active,"companion_relay_shaper_not_active")
        wc.require(not high or self.high_active,"companion_high_relay_start_unconfirmed")
        wc.require(not standard30 or self.standard_active,"one_shot_cap_unconfirmed")

    def check_flow(self, route):
        deadline=time.monotonic()+4.5
        if route=="relay":
            while self.latest[1]<20 and time.monotonic()<deadline: time.sleep(.2)
            wc.require(self.latest[1]>=20,"companion_broker_relay_traffic_unconfirmed")
        else:
            wc.require(self.latest[1]==0,"companion_direct_forwarded_through_broker")
        wc.event("companion_broker_verified_flow route="+route+
                 f" forwarded={self.latest[1]} limited={self.latest[2]}")

    def close(self):
        if self.channel:
            try:
                self.channel.sendall(b"Q")
                self.wait("companion_broker_stopped=1",5)
            except OSError:
                pass
            finally:
                self.channel.close()
                self.channel=None
        if self.registration: wc.event(self.registration)
        if self.trace_stale_time is not None: wc.event(f"companion_broker_shaping_stale_clock={self.trace_stale_time}")
        until=time.monotonic()+4
        free=False
        while time.monotonic()<until:
            if self.port_free():
                free=True
                break
            time.sleep(.2)
        wc.require(free and self.services()==self.baseline,"companion_vps_cleanup_unconfirmed")
        self.cleanup_verified=True
        wc.event("companion_udp_listener_removed_and_existing_services_unchanged=1")


def check_endpoint(scope, deps):
    relay=TemporaryBroker(scope,deps)
    # Ephemeral tickets, no real pairing or media. A random reply, including
    # one from the correct IP, cannot pass as an authenticated round trip.
    root=secrets.token_bytes(32)
    key=udp_broker.tickets(root)[0]
    relay.start(scope,root)
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        s.connect((relay.ip,public_target.PORT))
        s.settimeout(1.2)
        for _ in range(5):
            nonce=secrets.token_bytes(16)
            header=b"SCB1"+bytes([0,udp_broker.RELAY,udp_broker.HELLO,0])+nonce+bytes(40)
            s.send(header+udp_broker.sign(key,header))
            try: reply=s.recv(256)
            except (TimeoutError,ConnectionResetError,ConnectionRefusedError): continue
            if (len(reply)==udp_broker.SIZE and reply[:6]==header[:6] and
                reply[6:8]==bytes([udp_broker.CHALLENGE,0]) and reply[8:24]==nonce and
                any(reply[24:40]) and hmac.compare_digest(reply[64:],udp_broker.sign(key,reply[:64]))):
                wc.event("companion_windows_to_new_broker_authenticated_udp=1")
                return
    wc.require(False,"companion_windows_to_broker_udp_unconfirmed")


def main():
    cli=argparse.ArgumentParser()
    cli.add_argument("--case",choices=("preflight","endpoint-check","natural","forced-relay"),required=True)
    cli.add_argument("--seconds",type=int,default=42)
    cli.add_argument("--profile",choices=tuple(wc.PUBLIC_COMPARE))
    cli.add_argument("--smooth-capture",choices=("wgc","ddx"))
    cli.add_argument("--peak-shave",action="store_true")
    cli.add_argument("--tx-diagnostics",action="store_true")
    cli.add_argument("--idr-path",action="store_true",help="Trace explicit recovery requests, reference invalidations and actual NVENC IDRs (view-only 1080p60)")
    cli.add_argument("--compact-head",action="store_true",help="Isolated 1.8M relay trial: finish a started frame if it still fits the existing short deadline")
    cli.add_argument("--relay-smoothing",action="store_true")
    cli.add_argument("--capture-audit",action="store_true")
    cli.add_argument("--fresh-recovery",action="store_true")
    cli.add_argument("--relay-spacing",action="store_true")
    cli.add_argument("--frame-spread",action="store_true")
    cli.add_argument("--phone-rx-audit",action="store_true")
    cli.add_argument("--tx-guard",action="store_true")
    cli.add_argument("--relay-socket-trial",action="store_true",help="Bound only the authenticated high relay test socket")
    cli.add_argument("--phone-socket-device",help="Read only the selected USB app socket's queue/drop counters")
    cli.add_argument("--check-input",action="store_true")
    cli.add_argument("--relay-8m",action="store_true",help="Explicit staged trial on the locally approved high-bandwidth relay")
    cli.add_argument("--require-high-sample",action="store_true",help="Skip this benchmark when the capacity vote selects the 1.8M fallback")
    cli.add_argument("--measure-natural-fallback",action="store_true",
                     help="Watch the actual authenticated route instead of aborting a direct-only comparison on fallback")
    args=cli.parse_args()
    wc.require(not args.compact_head or (args.idr_path and not args.relay_8m and
               (args.measure_natural_fallback or (args.case=="forced-relay" and args.relay_spacing))),
               "compact_head_requires_view_only_low_relay")
    wc.require(not args.idr_path or (args.profile=='1080p60' and args.fresh_recovery and args.tx_diagnostics and
               args.case in ('natural','forced-relay') and not (args.check_input or args.tx_guard or args.relay_socket_trial)),
               'idr_markers_require_view_only_trace')
    full_hd=args.profile in wc.FULL_HD
    natural_hd=args.case=="natural" and full_hd and args.measure_natural_fallback and args.fresh_recovery and not args.check_input
    wc.require(not args.require_high_sample or (args.relay_8m and full_hd and
               (args.case=="forced-relay" or natural_hd)),"require_high_sample_scope_invalid")
    wc.require(not args.measure_natural_fallback or (args.case=="natural" and full_hd and
               args.fresh_recovery and not args.check_input),"natural_route_scope_invalid")
    wc.require(not args.check_input or (args.case in ("natural","forced-relay") and args.seconds>=42),
               "input_check_requires_stream")
    wc.require(args.smooth_capture is None or args.profile=="360p60","companion_smooth_profile_invalid")
    wc.require(not args.peak_shave or args.smooth_capture is not None,"companion_narrow_profile_invalid")
    passive_full_hd=(args.case in ("natural","forced-relay") and full_hd and args.fresh_recovery and
                     not args.tx_guard and not args.relay_8m)
    wc.require(not args.tx_diagnostics or (args.peak_shave and args.profile=="360p60") or passive_full_hd or
               (args.relay_8m and not args.tx_guard),
               "companion_tx_diagnostics_scope_invalid")
    default_wan_trial=(args.profile=="540p30" or full_hd) and args.case in ("natural","forced-relay")
    wc.require(not args.relay_8m or (default_wan_trial and (args.case=="forced-relay" or natural_hd) and args.relay_spacing and
               args.relay_smoothing and args.fresh_recovery),"companion_high_relay_scope_invalid")
    wc.require(not args.relay_smoothing or (args.case=="forced-relay" and (args.peak_shave or default_wan_trial)) or
               (natural_hd and args.relay_8m),
               "companion_relay_smoothing_scope_invalid")
    wc.require(not args.capture_audit or args.peak_shave,"companion_capture_audit_scope_invalid")
    wc.require(not args.fresh_recovery or args.peak_shave or default_wan_trial,"companion_fresh_frame_scope_invalid")
    wc.require(not args.relay_spacing or args.relay_smoothing,"companion_relay_spacing_scope_invalid")
    wc.require(not args.frame_spread or args.relay_8m,"frame_spread_requires_high_relay_trial")
    wc.require(not args.relay_socket_trial or (args.relay_8m and args.frame_spread and args.tx_diagnostics and not args.tx_guard),
               "companion_relay_socket_trial_scope_invalid")
    if args.phone_socket_device:
        wc.require(args.relay_8m and args.tx_diagnostics and args.seconds<=180 and
            re.fullmatch(r"[A-Za-z0-9]+",args.phone_socket_device) and
            subprocess.check_output(["hdc","list","targets"],timeout=8,text=True).split()==[args.phone_socket_device],
            "phone_socket_requires_same_unique_usb_test_device")
    wc.require(not args.phone_rx_audit or args.peak_shave,"companion_phone_rx_audit_scope_invalid")
    wc.require(not args.tx_guard or (args.tx_diagnostics and args.fresh_recovery),"companion_tx_guard_scope_invalid")
    wc.require((not args.profile and (25<=args.seconds<=50 or args.seconds==600)) or
               (args.profile and args.case in ("natural","forced-relay") and
                (args.seconds in (120,180,600) or (full_hd and args.seconds==300))),
               "companion_measurement_duration_invalid")
    win=wc.load_fixture()
    if args.relay_8m or (passive_full_hd and args.tx_diagnostics):
        # Build the current numeric-trace writer in a separate directory
        # without replacing any running helper's peer. No network downloads.
        target=wc.HERE.parent/".generated"/"delivery-rust-target"
        subprocess.run([str(Path.home()/".cargo/bin/cargo.exe"),"build","--target-dir",str(target),
                        "--manifest-path",str(wc.HERE.parent/"peer/Cargo.toml"),"--locked","--offline",
                        "--release","--features","companion-soak","--bin","sesame_wan_peer","--quiet"],check=True)
        wc.WAN_PEER=target/"release/sesame_wan_peer.exe"
    import native_wan as deps
    if args.case in ("preflight","endpoint-check"):
        with ExitStack() as scope:
            if args.case=="endpoint-check": check_endpoint(scope,deps)
            else: TemporaryBroker(scope,deps)
        return
    d=win.d
    phone=d.CoverageApp()
    before=phone.debug_targets()
    phone.idle_preflight()
    ui.no_usb_forward(phone)
    pc,_=win.lan.wifi_pair(phone)
    state=wc.runtime_dir()/"windows-companion-state"
    wc.require((state/"protected-companion.dat").is_file(),"companion_saved_pairing_missing")
    recorder=None
    tx_probes=None
    phone_job=None
    capture=None
    idr_marks=HostMarkers() if args.idr_path else None
    folder=host_file=salt=metrics=server=None
    if args.seconds==600 or args.profile or args.check_input:
        stamp=datetime.now(timezone(timedelta(hours=8))).strftime("%Y%m%d-%H%M%S")
        label=args.case+("-"+args.profile if args.profile else "")+("-smooth-"+args.smooth_capture if args.smooth_capture else "")
        if args.peak_shave: label+="-peak"
        if args.tx_diagnostics: label+="-txdiag"
        if args.idr_path: label+="-idr"
        if args.compact_head: label+="-head"
        if args.relay_smoothing: label+="-shaped"
        if args.capture_audit: label+="-capture"
        if args.fresh_recovery: label+="-fresh"
        if args.relay_spacing: label+="-spacing"
        if args.phone_rx_audit: label+="-rx"
        if args.tx_guard: label+="-txguard"
        if args.relay_8m: label+="-8m"
        if args.frame_spread: label+="-frame"
        if args.relay_socket_trial: label+="-shortsock"
        if args.phone_socket_device: label+="-phoneq"
        if args.measure_natural_fallback: label+="-auto"
        if args.require_high_sample: label+="-requirehigh"
        folder=wc.HERE.parent/".generated"/("public-compare" if args.profile else "public-soak")/(stamp+"-"+label+"-"+secrets.token_hex(2))
        folder.mkdir(parents=True)
        host_file=folder/"host-numeric.ssmeta"
        salt=secrets.token_bytes(16)
        recorder=Recorder(label,folder,wc.PUBLIC_COMPARE[args.profile][2] if args.profile else 30)
    try:
        with ExitStack() as scope:
            pool=scope.enter_context(ThreadPoolExecutor(max_workers=1)) if args.phone_socket_device else None
            host=wc.PhysicalBackend(scope,args.profile,args.smooth_capture,args.peak_shave,
                                    test_host_factory=idr_marks.host_type if idr_marks else None)
            host.high_relay=args.relay_8m
            if args.capture_audit:
                capture=CaptureAudit(host.desktop_size,host.host.p.pid)
                scope.callback(capture.close)
            rendezvous=TemporaryBroker(scope,deps)
            root=wc.Identity(state).device_hash
            rendezvous.start(scope,root,salt,args.relay_smoothing or args.measure_natural_fallback,args.relay_8m)
            if args.tx_diagnostics:
                tx_probes=TxProbes(pc,rendezvous.endpoint,root)
            del root
            radio=deps.prepare_radio(scope)
            fixture=None
            if args.check_input:
                import input_ui_checks as control
                fixture=control.open_fixture(scope)
            server=wc.Companion(pc,47837,state,host,seconds=args.seconds,broker=rendezvous.endpoint,
                                silent_direct=args.case=="forced-relay",trace_file=host_file,trace_salt=salt,
                                tx_source=str(pc) if tx_probes else None,fresh_recovery=args.fresh_recovery,
                                relay_spacing=args.relay_spacing or args.measure_natural_fallback,tx_guard=args.tx_guard,
                                input_fixture=fixture.hwnd if fixture else 0,high_relay=args.relay_8m,frame_spread=args.frame_spread,
                                relay_socket_trial=args.relay_socket_trial,compact_head_trial=args.compact_head)
            scope.callback(server.close)
            if tx_probes: scope.callback(tx_probes.close)
            server.start()
            ui.open_page(phone,d)
            wc.require(ui.marker(phone,"companion_saved_host_loaded=1") and
                       ui.has(phone,lambda r:r.get("type","").lower() in ("web","webview"),25),
                       "companion_reconnect_saved_profile_missing")
            wc.event("companion_public_saved_pair_used=1")
            x,y=phone.button_spot()
            phone.tap_start(x,y)
            def start_observation():
                nonlocal phone_job
                if pool is not None and phone_job is None:
                    phone_job=pool.submit(observe_phone_socket,args.phone_socket_device,folder,args.seconds)
                if tx_probes: tx_probes.start()
                if capture: capture.start()
                if fixture: control.exercise(phone,d,server,fixture)
            try:
                route=ui.watch_stream(phone,win,server,args.seconds,
                    "relay" if args.case=="forced-relay" else "public" if args.measure_natural_fallback else
                    "direct" if recorder or args.check_input else "public",recorder,
                    on_first_frame=start_observation if tx_probes or capture or fixture else None,
                    require_high_sample=args.require_high_sample)
            except Exception:
                host.host.sanitized_session_hints()
                raise
            rendezvous.check_flow(route)
            if args.compact_head:
                wc.require(("companion_host_compact_head_enabled=1" in server.events)==(route=="relay"),"compact_head_route_mismatch")
            wc.require("companion_host_even_dispatch=1" in server.events and
                       any(s.startswith("companion_host_wan_pacer_deadline_policy=1 ") for s in server.events),
                       "companion_wan_scheduler_not_active")
            if route=="relay" and (args.relay_spacing or args.measure_natural_fallback):
                if args.frame_spread:
                    if high_trial_plan(server.events,host.profile_replies,True)["conservative_fallback"]:
                        wc.event("companion_high_trial_verified_low_fallback=1")
                wc.require(route=="relay" and "companion_host_relay_spacing=1" in server.events,
                           "companion_relay_spacing_not_active")
            ui.no_usb_forward(phone)
            if args.profile:
                w,h,fps=wc.PUBLIC_COMPARE[args.profile]
                video_cap=host.video_cap
                if full_hd:
                    grant=host.full_hd_launch_grant
                    wc.require(host.desktop_size[0]>=w and host.desktop_size[1]>=h,"primary_below_full_hd")
                    initial_ok=(500<=grant<=video_cap and bool(host.profile_replies) and
                        host.profile_replies[0]==(w,h,fps,wc.full_hd_initial_kbps(grant,fps)) and
                        host.packet_sizes==[wc.full_hd_wan_packet_size(grant,v[3],fps) for v in host.profile_replies] and
                        all(later[3]<=earlier[3] for earlier,later in zip(host.profile_replies,host.profile_replies[1:])))
                else:
                    initial_ok=bool(host.profile_replies) and (host.profile_replies[0][:3]==(w,h,fps) and
                        500<=host.profile_replies[0][3]<=video_cap if args.relay_8m else host.profile_replies[0]==(w,h,fps,video_cap))
                wc.require(initial_ok and
                           all(v[:3]==(w,h,fps) and 500<=v[3]<=video_cap for v in host.profile_replies),
                           "companion_compare_profile_not_confirmed")
                if args.smooth_capture:
                    wc.require("companion_host_even_dispatch=1" in server.events and
                               any(row.startswith("companion_host_wan_pacer_deadline_policy=1 ") for row in server.events) and
                               host.packet_sizes==[host.media_packet_size]*len(host.profile_replies),
                               "companion_smooth_path_not_active")
                if args.peak_shave:
                    wc.require(len(host.profile_replies)==1 and "companion_quality_rebuild=1" not in server.events and
                               len(recorder.epochs)==1,"companion_narrow_stream_was_rebuilt")
                effective_wire_cap,effective_video_cap,plan=measured_budget(route,args.relay_8m,server.events,host.profile_replies,args.frame_spread)
                if args.require_high_sample and route=="relay":wc.require(plan and not plan["conservative_fallback"],"high_sample_unavailable_fallback_preserved")
                if args.profile=="1080p60":
                    wc.require(bool(plan and plan["frame_spread_active"])==("companion_host_relay_spread_60fps=1" in server.events),
                               "sixty_fps_relay_spacing_mismatch")
                if not plan:effective_video_cap=min(video_cap,effective_video_cap)
                wc.event(f"companion_compare_profile profile={args.profile} width={w} height={h} fps={fps} "
                         f"video_cap_kbps={effective_video_cap} wire_cap_kbps={effective_wire_cap} fixture_video_cap_kbps={video_cap}")
        wifi_restored=radio.is_set()
        if recorder:
            # Preserve hop observations even if freezes or restarts make the
            # stream fail the playback sample-duration requirement below.
            (folder/"host-path-numeric.txt").write_text("\n".join(server.path_samples),encoding="utf-8")
            truncated=rendezvous.trace_truncated if len(rendezvous.trace)==rendezvous.trace_count else None
            cause=recorder.attribute(route,host_file,rendezvous.trace,truncated)
            if rendezvous.trace:
                (folder/"relay-packet-status.json").write_text(json.dumps(
                    {k:base64.b64encode(zlib.compress(v)).decode("ascii") for k,v in rendezvous.trace.items()}),
                    encoding="utf-8")
            wc.event("companion_soak_record="+folder.name)
            metrics=recorder.summary(route,args.seconds)
            out=dict(playback=metrics, attribution=cause, wifi_restored=wifi_restored, relay_counts=dict(
                received=rendezvous.latest[0],forwarded=rendezvous.latest[1],shaped=rendezvous.latest[2],
                shaping_stale_clock=rendezvous.trace_stale_time))
            if args.profile:
                out.update(profile=args.profile,wire_cap_kbps=effective_wire_cap,video_cap_kbps=effective_video_cap,
                           configured_wire_cap_kbps=8000 if args.relay_8m else 1800,configured_video_cap_kbps=video_cap,setup_replies=host.profile_replies,
                           packet_sizes=host.packet_sizes,smooth_capture=args.smooth_capture,peak_shave=args.peak_shave)
                if args.compact_head:
                    totals=[int(m[1]) for s in server.path_samples if (m:=re.fullmatch(r"wan_compact_head saves=(\d+)",s))]
                    wc.require(bool(totals)==(route=="relay"),"compact_head_observation_missing")
                    out["compact_head_trial"]=dict(active=route=="relay",overflow_protections_observed=max(totals,default=0))
                if full_hd:
                    out["full_hd"]=output_acceptance(recorder.epochs,metrics,w,h,fps,args.seconds,cause if fps==60 else None)
                    out["launch_grant_kbps"]=host.full_hd_launch_grant
                    out["source_desktop_size"]=host.desktop_size
                    out["view_only"]=not server.allow_input
                    out["verified_physical_nvenc_and_encrypted_playback"]=True # enforced by watch_stream above
                    wc.event("companion_full_hd_acceptance="+json.dumps(out["full_hd"],separators=(",",":")))
                out["relay_spacing"]="companion_host_relay_spacing=1" in server.events
                out["route_selection"]="unanswered_by_test" if args.case=="forced-relay" else "natural"
                out["frame_spread_requested"]=args.frame_spread
                out["frame_spread"]="companion_host_relay_frame_spread=1" in server.events
                if args.relay_8m:
                    out["capacity_plan"]=[s for s in server.events if s.startswith(("companion_host_bandwidth_result ","companion_relay_capacity_plan "))]
                    out["negotiated_relay"]=plan
            if args.smooth_capture:
                out["pacer_policy"]=next(row.removeprefix("companion_host_") for row in server.events
                    if row.startswith("companion_host_wan_pacer_deadline_policy=1 "))
            if route=="relay" and (args.relay_smoothing or args.measure_natural_fallback):
                wc.require(rendezvous.shape is not None,"companion_relay_shaper_metrics_missing")
                out["relay_smoothing"]=rendezvous.shape
                if args.relay_8m:
                    out["limited_ingress_peak"]=(compare_peaks(rendezvous.peaks,host_file) if
                        rendezvous.peaks or not rendezvous.shape.get("downlink_limited") else {"status":"peak_not_captured"})
            if tx_probes:
                obs=tx_probes.save(folder,server.path_samples)
                out["host_udp"]=obs
                if phone_job is not None:
                    out["phone_socket"]=phone_job.result()
                    data=json.loads((folder/"phone-socket-numeric.json").read_bytes())
                    out["phone_socket_gap_windows"]=gap_windows(data["samples"],recorder.epochs,data.get("utc_offset_minutes"))
                wc.event(f"companion_tx_diagnostics same_source={obs['media'].get('same_source',0)} "
                         f"sndbuf={obs['media'].get('sndbuf',0)} udp_ok={obs['udp_ok']} "
                         f"udp_samples={obs['udp_samples']} lan_ok={obs['lan_ok']} "
                         f"lan_samples={obs['lan_samples']} busy_spans={len(obs['spans'])} "
                         f"wlan_setup={obs['wlan_setup']} wlan_samples={obs['wlan_samples']}")
            if capture:
                audit=capture.save(folder,host_file,recorder)
                out["capture_audit"]=audit
                wc.event("companion_capture_audit "+" ".join(f"{k}={int(v)}" for k,v in audit.items()))
            (folder/"result.json").write_text(json.dumps(out,indent=2),encoding="utf-8")
        wc.require(wifi_restored,"companion_original_wifi_not_restored")
        wc.require(metrics is None or metrics["coverage_ok"],"companion_soak_insufficient_verified_duration")
        if args.phone_rx_audit:
            wc.require(cause.get("phone_packet_audit_frames",0)>=128,"companion_phone_packet_audit_unconfirmed")
        if (args.relay_8m or passive_full_hd) and args.tx_diagnostics:
            wc.require(out["host_udp"]["media"].get("same_source")==1 and out["host_udp"]["udp_samples"]>0,
                       "companion_test_tx_observation_unconfirmed")
        if args.tx_guard:
            wc.require(out["host_udp"]["guard"].get("capped")==1,"companion_tx_guard_buffer_unconfirmed")
        if args.relay_socket_trial:
            trial=out["host_udp"]["relay_socket_trial"]
            wc.require((not trial if out["negotiated_relay"]["conservative_fallback"] else
                trial.get("capped")==1 and 4096<=trial["actual"]<=trial["requested"]<=12288 and
                trial["actual"]==out["host_udp"]["media"].get("sndbuf")),"companion_relay_socket_trial_unconfirmed")
        if full_hd:wc.require(out["full_hd"]["passed"],"full_hd_output_not_stable")
        wc.event(f"companion_public_acceptance case={args.case} path={route} usb_forward=0 screenshots_taken=0")
    finally:
        try:
            if recorder:
                recorder.save_phone()
                if idr_marks:
                    try: save_markers(folder,idr_marks)
                    except OSError: wc.event('companion_idr_markers_not_saved=1')
                if server and full_hd:
                    (folder/"setup-numeric.json").write_text(json.dumps(wc.setup_timings(server.events)),encoding="ascii")
                if server and args.check_input:
                    # Preserve the host's reason even if the UI assertion
                    # ends the run early. No raw TLS, input or hdc logs.
                    report=[s for s in server.events if re.fullmatch(
                        r"companion_input_closed reason=(?:closed|watchdog|stale|focus|transport|protocol)"
                        r" move=\d+ button=\d+ wheel=\d+ key=\d+ text=\d+ released=\d+ residual=\d+ heartbeats=\d+ max_heartbeat_ms=\d+"
                        r" phase=(?:grant|write_tick|read_reply|wait_reply|test_blackhole)"
                        r" ack_silence_ms=\d+ rx_silence_ms=\d+ unanswered=\d+ partial=[01] read_waits=\d+ host_loop_peak_ms=\d+ injected=[01]",s)]
                    (folder/"input-health.txt").write_text("\n".join(report),encoding="ascii")
            phone.shell("aa force-stop "+d.APP)
            phone.shell("aa start -a EntryAbility -b "+d.APP)
        finally:
            ui.no_usb_forward(phone)
            wc.require(phone.debug_targets()==before,"other_apps_changed")
            wc.event("companion_two_moonlights_and_test_sibling_unchanged=1")


if __name__=="__main__":
    try: main()
    except Exception as exc:
        reason=str(exc)
        wc.event("companion_public_failed="+(reason if re.fullmatch(r"[a-z_]{4,79}",reason) else type(exc).__name__))
        raise SystemExit(4) from None
