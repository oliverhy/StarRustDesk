"""Portable Sunshine companion used by the isolated app build.

It never edits an installed Sunshine instance, installs a service, changes a
firewall rule, or looks for other machines. Public routes require an explicit
test broker and an existing valid pairing.
"""
import argparse
from contextlib import ExitStack
import ctypes
import datetime
import hashlib
import hmac
import importlib.util
import ipaddress
import os
from pathlib import Path
import re
import secrets
import select
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from stream_input import WindowsInput, serve as serve_input
from display_targets import capture_catalog, encode_catalog, geometry
from lan_startup_evidence import STEP as PROBE_STEP, SENDER as PROBE_SENDER, WAKE as PROBE_WAKE

HERE=Path(__file__).resolve().parent
WAN_PEER=(Path(sys.executable).resolve().parent/"sesame_wan_peer.exe" if getattr(sys,"frozen",False)
          else HERE.parent/"peer/target/release/sesame_wan_peer.exe")
def runtime_dir():
    # The developer's explicitly selected local fixture, never a value from the phone.
    # Reuse its sealed Windows identity in place; don't export or clone it into the repo.
    value=os.environ.get("SESAME_STREAM_TEST_RUNTIME")
    if value and not Path(value).is_absolute():
        raise ValueError("companion_runtime_absolute_directory_required")
    return Path(value).resolve() if value else Path(os.environ["LOCALAPPDATA"])/"SesameStreamCompanion"

PRIVATE=tuple(ipaddress.IPv4Network(x) for x in ("10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"))
FULL_HD={"1080p30":(1920,1080,30),"1080p60":(1920,1080,60)}
STANDARD_VIDEO=20_000
STANDARD_WIRE=30_000

def paired_video_rate(rate):
    return type(rate) is int and 2000<=rate<=50000 and rate%1000==0

def lan_wire_budget(rate):
    # A real calibrated video target needs space for 20% FEC, audio, UDP/WG
    # and nonuniform keyframes. This is the LAN probe ceiling, never WAN policy.
    return min(72000,((170 if rate>=STANDARD_VIDEO else 139)*rate+9999)//10000*100)
PUBLIC_COMPARE={"540p30":(960,540,30),"360p60":(640,360,60),**FULL_HD}

def add_output_options(parser):
    output=parser.add_mutually_exclusive_group()
    for name,(_,_,fps) in FULL_HD.items():
        output.add_argument("--output-"+name,dest="output_profile",action="store_const",const=name,
            help=f"Keep the encoded picture at 1920x1080/{fps}; bitrate stays bounded by the authorized path")

def full_hd_initial_kbps(authorized,fps=30):
    require(500<=authorized<=6400,"full_hd_budget_outside_authorized_range")
    require(fps in (30,60),"full_hd_cadence_invalid")
    # The first 1400 kbps is the legacy video budget. Above it only an
    # authenticated, separately probed short-queue relay can grant more.
    # On a physical path 68 ms of spaced output arrived in under 3 ms.
    # A five-minute run still clipped three reference pictures when 15.8KB
    # arrived within 0.5ms. Spend only a sixth of the *additional* grant
    # in the stability preset; do not lengthen the relay queue or raise credit.
    # At 30 FPS two full-size repair packets per frame alone can cost
    # about 0.54 Mbps with encapsulation. On the legacy 1.8M wire the
    # old 1100 video setting filled the sender's own queue despite zero
    # socket errors/relay clipping. Preserve repair, not an inflated target.
    budget=(authorized*3//5 if authorized<=1400 else 1400*4//5+(authorized-1400)//6)
    if fps==60:
        # 60 independently protected pictures need twice as many minimum
        # repair groups. Do not borrow relay-only headroom on direct or fallback.
        # The 550 kbps / 768-byte trial produced 3-4 x 876 wire bytes per
        # normal picture. Start at the permitted floor rather than interrupt
        # the stream to reclaim just 50 kbps.
        # Do not jump from 500 straight to 1100 at the first positive relay
        # vote. Add at most one video bit for three extra authorized bits;
        # keep the previously exercised high-rate ceiling as the second bound.
        budget=min(budget,500+max(0,authorized-1400)//3)
    return min(authorized,max(500,budget//50*50))

def full_hd_wan_packet_size(grant,rate,fps):
    if fps==60 and grant<=1400 and rate==500: return 640
    # Keep some repair headroom on a modest, independently probed relay.
    # The low and high formats stay unchanged, including the default FEC.
    if fps==60 and 1400<grant<=3200 and rate<=1400: return 768
    return 1024
SMOOTH_VIDEO_KBPS=650
SMOOTH_PACKET_SIZE=768
PEAK_VIDEO_KBPS=500
PEAK_PACKET_SIZE=768


def private(ip):
    addr=ipaddress.IPv4Address(ip)
    return int(addr)&255 not in (0,255) and any(addr in subnet for subnet in PRIVATE)


def same_lan(a,b):
    return a!=b and private(a) and private(b) and int(ipaddress.IPv4Address(a))>>8==int(ipaddress.IPv4Address(b))>>8


def choose_local(address=None):
    if address: return address
    local=sorted({row[4][0] for row in socket.getaddrinfo(socket.gethostname(),0,socket.AF_INET,socket.SOCK_STREAM)
                  if private(row[4][0])})
    if len(local)==1: return local[0]
    if local: event("本机候选：" + " / ".join(local))
    return input("请输入配对时使用的本机 IPv4 地址：").strip()


def event(value):
    print(value,flush=True)


def require(ok, code):
    if not ok:
        raise RuntimeError(code)


def read_exact(sock, size):
    out=bytearray()
    while len(out)<size:
        data=sock.recv(size-len(out))
        if not data:
            raise EOFError
        out.extend(data)
    return bytes(out)


class Blob(ctypes.Structure):
    _fields_=[("size",ctypes.c_uint32),("data",ctypes.POINTER(ctypes.c_ubyte))]


def dpapi(value, unprotect=False):
    material=ctypes.create_string_buffer(value)
    source=Blob(len(value),ctypes.cast(material,ctypes.POINTER(ctypes.c_ubyte)))
    result=Blob()
    api=ctypes.WinDLL("crypt32",use_last_error=True)
    fn=api.CryptUnprotectData if unprotect else api.CryptProtectData
    fn.argtypes=[ctypes.POINTER(Blob),ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,
                 ctypes.c_void_p,ctypes.c_uint32,ctypes.POINTER(Blob)]
    fn.restype=ctypes.c_int
    free=ctypes.WinDLL("kernel32").LocalFree
    free.argtypes=[ctypes.c_void_p]
    free.restype=ctypes.c_void_p
    try:
        require(fn(ctypes.byref(source),None,None,None,None,1,ctypes.byref(result))!=0,
                "companion_windows_protection_failed")
        require(0<result.size<65536,"companion_windows_protection_size")
        return ctypes.string_at(result.data,result.size)
    finally:
        ctypes.memset(material,0,len(material))
        if result.data:
            ctypes.memset(result.data,0,result.size)
            free(result.data)


class Identity:
    def __init__(self, directory):
        require(not directory.is_symlink(),"companion_state_directory_unsafe")
        directory.mkdir(parents=True,exist_ok=True)
        self.directory=directory.resolve()
        self.file=self.directory/"protected-companion.dat"
        self.device_hash=bytes(32)
        require(not self.file.is_symlink(),"companion_state_file_unsafe")
        if self.file.exists():
            require(0<self.file.stat().st_size<65536,"companion_state_invalid")
            clear=dpapi(self.file.read_bytes(),True)
            require(len(clear)>40 and clear[:4]==b"SSI1","companion_state_invalid")
            cert_size,key_size=struct.unpack("!HH",clear[4:8])
            require(0<cert_size<=4096 and 0<key_size<=4096 and 40+cert_size+key_size==len(clear),
                    "companion_state_invalid")
            self.device_hash=clear[8:40]
            self.cert=x509.load_der_x509_certificate(clear[40:40+cert_size])
            self.key=serialization.load_der_private_key(clear[40+cert_size:],password=None)
            require(self.cert.public_key().public_numbers()==self.key.public_key().public_numbers(),
                    "companion_state_identity_mismatch")
        else:
            require(not list(self.directory.iterdir()),"companion_state_directory_not_empty")
            self.key=ec.generate_private_key(ec.SECP256R1())
            name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,"Sesame Sunshine Companion")])
            now=datetime.datetime.now(datetime.timezone.utc)
            self.cert=(x509.CertificateBuilder().subject_name(name).issuer_name(name)
                       .public_key(self.key.public_key()).serial_number(x509.random_serial_number())
                       .not_valid_before(now-datetime.timedelta(days=1))
                       .not_valid_after(now+datetime.timedelta(days=365))
                       .sign(self.key,hashes.SHA256()))
            self.save(self.device_hash)

    def save(self, device_hash):
        der=self.cert.public_bytes(serialization.Encoding.DER)
        private_key=self.key.private_bytes(serialization.Encoding.DER,serialization.PrivateFormat.PKCS8,
                                            serialization.NoEncryption())
        sealed=dpapi(b"SSI1"+struct.pack("!HH",len(der),len(private_key))+device_hash+der+private_key)
        with tempfile.NamedTemporaryFile(dir=self.directory,prefix="sealed-",delete=False) as temp:
            name=Path(temp.name)
            temp.write(sealed)
        try:
            name.replace(self.file)
        finally:
            name.unlink(missing_ok=True)
        self.device_hash=device_hash

    def context(self):
        tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.minimum_version=ssl.TLSVersion.TLSv1_3
        tls.num_tickets=0
        with tempfile.TemporaryDirectory(prefix="sesame-companion-cert-") as folder:
            cert,key=Path(folder)/"public.pem",Path(folder)/"encrypted.pem"
            password=secrets.token_bytes(32)
            cert.write_bytes(self.cert.public_bytes(serialization.Encoding.PEM))
            key.write_bytes(self.key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,
                                                   serialization.BestAvailableEncryption(password)))
            tls.load_cert_chain(cert,key,password=password)
        return tls


def load_fixture():
    generated=runtime_dir()
    if str(generated) not in sys.path: sys.path.insert(0,str(generated))
    spec=importlib.util.spec_from_file_location(
        "companion_physical_fixture",generated/"physical-lan-capacity.py")
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def smooth_host_config(base, capture, video_cap=SMOOTH_VIDEO_KBPS):
    require(capture in ("wgc","ddx"),"companion_unknown_capture_backend")
    require(video_cap in (SMOOTH_VIDEO_KBPS,PEAK_VIDEO_KBPS),"companion_invalid_encoder_cap")
    values={"capture":capture,"max_bitrate":str(video_cap),
            "minimum_fps_target":"1","nvenc_vbv_increase":"0"}
    seen=set()
    lines=[]
    for line in base.splitlines():
        key, sep, _=line.partition(" = ")
        if sep and key in values:
            require(key not in seen,"companion_capture_config_duplicate")
            seen.add(key)
            lines.append(f"{key} = {values[key]}")
        else:
            lines.append(line)
    lines.extend(f"{key} = {value}" for key,value in values.items() if key not in seen)
    return "\n".join(lines)+"\n"


def remove_test_runtime(runtime):
    # Windows scanners/readers can briefly hold Sunshine's rotated log open
    # after the child exits. Never ignore a permanent failure or touch another
    # session: retry cleanup of only the TemporaryDirectory we created.
    for attempt in range(8):
        try:
            runtime.cleanup()
            return
        except PermissionError:
            if attempt==7: raise
            time.sleep(.25)


class PhysicalBackend:
    def __init__(self, scope, public_profile=None, smooth_capture=None, peak_shave=False, *, audio=False, output_profile=None, test_host_factory=None):
        require(public_profile is None or public_profile in PUBLIC_COMPARE,"companion_profile_invalid")
        require(output_profile is None or output_profile in FULL_HD and not public_profile,"invalid_output_profile")
        require(smooth_capture is None or (public_profile=="360p60" and smooth_capture in ("wgc","ddx")),
                "companion_smooth_profile_invalid")
        require(not peak_shave or smooth_capture is not None,"companion_narrow_profile_invalid")
        self.public_profile=public_profile
        self.output_profile=output_profile
        self.smooth_capture=smooth_capture
        self.peak_shave=peak_shave
        self.profile_replies=[]
        self.packet_sizes=[]
        import portable_host
        self.win=portable_host
        screen,w,h=self.win.primary()
        require(w>=1280 and h>=720,"companion_primary_display_unavailable")
        self.desktop_size=(w,h)
        root=self.win.ROOT.resolve()
        owned=tempfile.TemporaryDirectory(prefix="session-",dir=root)
        scope.callback(remove_test_runtime,owned)
        runtime=Path(owned.name)
        require(runtime.resolve().parent==root,"companion_runtime_not_owned")
        host_type=self.win.WindowsSunshine
        if test_host_factory is not None:  # supplied only by the local, view-only acceptance runner
            host_type=test_host_factory(host_type)
        if smooth_capture:
            video_cap=self.video_cap
            class SmoothHost(host_type):
                def conf(self): return smooth_host_config(super().conf(),smooth_capture,video_cap)
            host_type=SmoothHost
        self.host=host_type(runtime,screen)
        self.host.stream_audio=self.audio=audio
        scope.callback(self.host.stop)
        self.host.start()
        self.host.output_id=self.host.detect_primary_id()
        with self.host.lock: boot_log="\n".join(s for _,s in self.host.rows)
        self.screens=capture_catalog(boot_log,geometry())
        require(self.screens and self.screens[0].guid==self.host.output_id,"companion_monitor_identity_ambiguous")
        self.active_display=0
        self.video_size=None
        self.host.stop()
        self.host.start()
        self.pair=None
        self.pair_owned_process()
        event(f"companion_available_displays={len(self.screens)}")
        if smooth_capture: event(f"companion_smooth_capture={smooth_capture}")

    @property
    def video_cap(self):
        if getattr(self,"high_relay",False): return 6400
        return PEAK_VIDEO_KBPS if self.peak_shave else SMOOTH_VIDEO_KBPS if self.smooth_capture else 1400

    @property
    def media_packet_size(self):
        return PEAK_PACKET_SIZE if self.peak_shave else SMOOTH_PACKET_SIZE if self.smooth_capture else 1024

    @property
    def full_hd_profile(self):
        profile=self.public_profile or getattr(self,"output_profile",None)
        return profile if profile in FULL_HD else None

    def configuration(self, original, rate, seconds, wan=False):
        if original>=STANDARD_VIDEO and (self.full_hd_profile in (None,"1080p60")):
            require(rate==original and paired_video_rate(rate),"standard_video_downgrade_rejected")
            w,h,fps=FULL_HD["1080p60"]
        elif self.public_profile and getattr(self,"standard_wan",False) and wan:
            require(500<=rate<=original<STANDARD_VIDEO,"custom_video_outside_grant")
            w,h,fps=PUBLIC_COMPARE[self.public_profile]
        elif self.public_profile:
            require(500<=rate<=original<=(6400 if getattr(self,"high_relay",False) else 1400),"companion_compare_budget_invalid")
            w,h,fps=PUBLIC_COMPARE[self.public_profile]
        elif self.full_hd_profile:
            # This changes the encoded dimensions, never a route budget, bitrate
            # vote, desktop display mode, or decision to accept a paired client.
            w,h,fps=FULL_HD[self.full_hd_profile]
        elif wan:
            # More relay bandwidth is not consent to switch the default
            # resolution or frame rate. LAN retains its previous choices.
            w,h,fps=960,540,30
        else:
            w,h,fps=(1920,1080,60) if original>=8000 else (1280,720,60) if original>=4000 else (960,540,30)
        if self.smooth_capture:
            require(rate<=self.video_cap,"companion_smooth_rate_above_profile")
        chosen=SimpleNamespace(width=w,height=h,fps=fps,kbps=rate,seconds=seconds)
        reply=(b"SPK2" if self.peak_shave else b"SCH2")+self.win.f.media_args(self.pair,chosen,None)[4:]
        self.video_size=(w,h)
        if getattr(self,"screens",None): reply=encode_catalog(reply,self.screens,self.active_display)
        size=full_hd_wan_packet_size(original,rate,fps) if wan and self.full_hd_profile else self.media_packet_size
        if self.public_profile:
            require(struct.unpack_from("!6I",reply,4)==(w,h,fps,rate,seconds,1024),"companion_compare_profile_mismatch")
            self.profile_replies.append((w,h,fps,rate))
            self.packet_sizes.append(size)
        if size!=1024: reply=reply[:24]+struct.pack("!I",size)+reply[28:]
        return reply

    def launch(self, rate, seconds, wan=False):
        if getattr(self,"active_display",0): self.choose_display(0)
        self.host.mark_start()
        initial=min(rate,self.video_cap) if self.smooth_capture else rate
        if wan and self.full_hd_profile and rate<STANDARD_VIDEO and not getattr(self,"standard_wan",False):
            self.full_hd_launch_grant=initial
            initial=full_hd_initial_kbps(initial,FULL_HD[self.full_hd_profile][2])
        return self.configuration(rate,initial,seconds,wan)

    def available(self,index):
        if not 0<=index<len(self.screens): return False
        s=self.screens[index]
        return any((m.name,m.rect,m.primary)==(s.name,s.rect,s.primary) for m in geometry())

    def pair_owned_process(self):
        # Each freshly spawned isolation process may have a new certificate.
        # Authenticate that child via its private stdin + signed PIN transcript,
        # then pin it. Never accept a certificate mismatch on an existing pair.
        fresh=self.win.WindowsPair()
        pin=f"{secrets.randbelow(10000):04d}"
        self.host.send(pin)
        fresh.paired(pin)
        self.pair=fresh

    def choose_display(self,index):
        require(self.available(index),"companion_monitor_changed")
        target=self.screens[index]
        self.pair=None
        self.host.stop()
        self.host.output_id=target.guid
        self.host.start()
        with self.host.lock: log="\n".join(s for _,s in self.host.rows)
        require(target in capture_catalog(log,geometry()),"companion_monitor_identity_changed")
        self.pair_owned_process()
        self.active_display=index
        self.host.session_at=time.monotonic()

    def rebuild(self, original, proposed, seconds, wan=False):
        require(not self.peak_shave,"companion_narrow_rebuild_rejected")
        start=time.monotonic()
        self.cancel()
        cancelled=time.monotonic()
        result=self.configuration(original,proposed,seconds,wan)
        event(f"companion_switch_host cancel_ms={int(1000*(cancelled-start))} launch_ms={int(1000*(time.monotonic()-cancelled))}")
        return result

    def cancel(self):
        if self.pair is not None and self.pair.appid is not None:
            self.pair.request("cancel",timeout=4,secure=True)

    def open_peer(self, local, remote, remote_key, route_budget, trace_file=None, trace_salt=None):
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as reserve:
            reserve.bind((local,0))
            port=reserve.getsockname()[1]
        private_key,public_key=self.win.lan.keypair()
        # The external capture fixture supplies Sunshine, not the UDP sender.
        # Use the same build as this checkout's public helper on both paths.
        require(WAN_PEER.is_file(),"companion_local_peer_not_built")
        env={k:v for k,v in os.environ.items() if not k.startswith("SESAME_COMPANION_") and k!="SESAME_PHYSICAL_QUALITY_TRIAL"}
        env["SESAME_COMPANION_MANAGED_LAN"]="1"
        if trace_file is not None:
            require(trace_file.is_absolute() and trace_file.suffix=='.ssmeta' and isinstance(trace_salt,bytes)
                    and len(trace_salt)==16,"companion_lan_trace_invalid")
            env.update(SESAME_COMPANION_SOAK_TRACE=str(trace_file),SESAME_COMPANION_SOAK_TAG=trace_salt.hex())
        if getattr(self,'lan_ready_trial',False):
            require(trace_file is not None and 30000<=route_budget<=72000,'lan_ready_trial_requires_verified_budget_and_trace')
            env['SESAME_COMPANION_LAN_READY_TRIAL']='1'
        source_rx=getattr(self,'lan_source_rx',None)
        if source_rx is not None:
            require(source_rx in ('stock','bounded','auto') and env.get('SESAME_COMPANION_LAN_READY_TRIAL')=='1'
                    and route_budget==lan_wire_budget(STANDARD_VIDEO),'source_rx_requires_verified_lan')
            env['SESAME_COMPANION_LAN_SOURCE_RX']=source_rx
        process=subprocess.Popen([str(WAN_PEER),"--lan","--physical","--managed"],stdin=subprocess.PIPE,env=env,
                                 stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                                 creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            process.stdin.write(f"{local}:{port}\n{remote}\n{private_key}\n{remote_key.hex()}\n{route_budget}\n".encode("ascii"))
            process.stdin.flush()  # EOF is the managed helper's session-end signal.
        except OSError:
            try: process.stdin.close()
            except OSError: pass
            process.terminate()
            process.wait(timeout=3)
            raise
        return process,port,bytes.fromhex(public_key)


class Lease:
    def __init__(self, phone, wan=False):
        self.phone=phone
        self.wan=wan
        self.grant=secrets.token_bytes(32)
        self.open=True
        self.input_open=False
        self.launched=False
        self.proxy_count=0
        self.host_authenticated=False
        self.authenticated_event=threading.Event()
        self.rtsp_completed=0
        self.input_epoch=0
        self.switching=False


class InternetPeer:
    def __init__(self, companion, endpoint, backend_port, silent):
        ip, sep, port = endpoint.rpartition(":")
        server=ipaddress.IPv4Address(ip)
        require(sep and port=="23388" and server.is_global and not server.is_multicast,"companion_invalid_broker")
        self.owner,self.endpoint,self.port,self.silent = companion,endpoint,backend_port,silent
        self.stop=threading.Event()
        self.ready=threading.Event()
        self.video_ceiling=1400
        self.on_relay=False
        self.lock=threading.Lock()
        self.process=None
        self.thread=threading.Thread(target=self.run,daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop.is_set():
            with self.owner.mutex:
                root=self.owner.identity.device_hash
                local_busy=self.owner.lease is not None
            if not any(root) or local_busy:
                self.stop.wait(.20)
                continue
            self.ready.clear()
            self.video_ceiling=1400
            self.on_relay=False
            # Reuse the saved pairing and capture fixture, never a network
            # executable from another checkout with older scheduling logic.
            command=[str(WAN_PEER),"--companion-wan"]
            if self.silent: command.append("--test-silent-direct")
            env=os.environ.copy()
            for key in ("SESAME_COMPANION_SOAK_TRACE","SESAME_COMPANION_SOAK_TAG","SESAME_COMPANION_SMOOTH_360",
                        "SESAME_COMPANION_STANDARD_WAN","SESAME_COMPANION_LAN_READY_TRIAL","SESAME_COMPANION_LAN_SOURCE_RX",
                        "SESAME_COMPANION_TX_SOURCE","SESAME_COMPANION_FRESH_RECOVERY",
                        "SESAME_COMPANION_RELAY_SPACING","SESAME_COMPANION_TX_GUARD","SESAME_COMPANION_HIGH_RELAY",
                        "SESAME_COMPANION_FRAME_SPREAD","SESAME_COMPANION_SPREAD_FPS","SESAME_COMPANION_RELAY_SOCKET_TRIAL","SESAME_COMPANION_TX_PASSIVE","SESAME_COMPANION_COMPACT_HEAD"):
                env.pop(key,None)
            if self.owner.high_relay: env["SESAME_COMPANION_HIGH_RELAY"]="1"
            if self.owner.standard_wan: env["SESAME_COMPANION_STANDARD_WAN"]="1"
            if self.owner.tx_source: env["SESAME_COMPANION_TX_SOURCE"]=self.owner.tx_source
            if self.owner.tx_source and not self.owner.tx_guard and getattr(self.owner.backend,"full_hd_profile",None):
                env["SESAME_COMPANION_TX_PASSIVE"]="1"
            if self.owner.fresh_recovery: env["SESAME_COMPANION_FRESH_RECOVERY"]="1"
            if self.owner.relay_spacing: env["SESAME_COMPANION_RELAY_SPACING"]="1"
            if self.owner.frame_spread: env["SESAME_COMPANION_FRAME_SPREAD"]="1"
            if self.owner.frame_spread and getattr(self.owner.backend,"full_hd_profile",None)=="1080p60":
                env["SESAME_COMPANION_SPREAD_FPS"]="60"
            if self.owner.tx_guard: env["SESAME_COMPANION_TX_GUARD"]="1"
            if self.owner.relay_socket_trial: env["SESAME_COMPANION_RELAY_SOCKET_TRIAL"]="1"
            if self.owner.compact_head_trial: env["SESAME_COMPANION_COMPACT_HEAD"]="1"
            if self.owner.trace_file:
                env["SESAME_COMPANION_SOAK_TRACE"]=str(self.owner.trace_file)
                env["SESAME_COMPANION_SOAK_TAG"]=self.owner.trace_salt.hex()
            child=None
            try:
                with self.lock:
                    if self.stop.is_set(): break
                    child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW,env=env)
                    self.process=child
                    child.stdin.write(f"{self.endpoint}\n{root.hex()}\n{self.port}\n".encode("ascii"))
                    child.stdin.flush()
                del root
                for row in child.stdout:
                    safe=row.decode("ascii","ignore").strip()
                    if safe in ("stage=companion_host_direct_authenticated","stage=companion_host_relay_authenticated"):
                        self.on_relay=safe=="stage=companion_host_relay_authenticated"
                        self.ready.set()
                        self.owner.note(safe.removeprefix("stage=")+"=1")
                    elif safe in ("stage=companion_host_public_wait","stage=companion_host_direct_unreachable",
                                  "stage=companion_host_relay_attempt"):
                        self.owner.note(safe.removeprefix("stage=")+"=1")
                    elif re.fullmatch(r"bandwidth_result state=\d+ good_kbps=\d+ unstable_kbps=\d+ cap_kbps=\d+",safe):
                        self.owner.note("companion_host_"+safe)
                    elif plan:=re.fullmatch(r"relay_capacity_plan wire_kbps=(\d{4,5}) video_cap_kbps=(\d{4,5})",safe):
                        wire,video=map(int,plan.groups())
                        if (self.owner.high_relay or self.owner.standard_wan) and 1800<=wire<=(STANDARD_WIRE if self.owner.standard_wan else 8000) and 1400<=video<=wire*8//10:
                            self.video_ceiling=video
                            self.owner.note("companion_"+safe)
                    elif re.fullmatch(r"companion_direct_diag tx=\d+ rx=\d+ candidate=\d+ authenticated=[01]",safe):
                        self.owner.note("companion_host_"+safe.removeprefix("companion_"))
                    elif safe=="standard_pacer_bounded_catchup=1": self.owner.note("companion_host_standard_pacer=1")
                    elif safe=="wan_pacer_even_dispatch=1": self.owner.note("companion_host_even_dispatch=1")
                    elif safe=="wan_fresh_recovery=1": self.owner.note("companion_host_fresh_recovery=1")
                    elif safe=="wan_relay_spacing=1": self.owner.note("companion_host_relay_spacing=1")
                    elif self.owner.compact_head_trial and safe=="wan_compact_head_enabled=1": self.owner.note("companion_host_compact_head_enabled=1")
                    elif self.owner.compact_head_trial and re.fullmatch(r"wan_compact_head saves=\d{1,9}",safe):
                        self.owner.path_samples.append(safe)
                    elif safe=="wan_relay_frame_spread=1": self.owner.note("companion_host_relay_frame_spread=1")
                    elif safe=="wan_relay_spread_60fps=1": self.owner.note("companion_host_relay_spread_60fps=1")
                    elif re.fullmatch(r"wan_tx_guard before=\d+ actual=\d+ requested=8192 capped=[01] errno=\d+",safe):
                        self.owner.path_samples.append(safe)
                        self.owner.note("companion_host_"+safe)
                    elif re.fullmatch(r"wan_pacer_deadline_policy=1 mmcss=[01] precise=[01]",safe):
                        self.owner.note("companion_host_"+safe)
                    elif self.owner.trace_file and re.fullmatch(r"(?:wan_media_host|wan_media_backpressure|wan_media_offer|wan_pacer_timing|video_path|wan_tx_setup|wan_tx_event|wan_fresh_video|wan_recovery_queue|wan_trial_sndbuf)(?: [a-z_]+=[0-9]+){3,18}",safe):
                        self.owner.path_samples.append(safe)
                    elif re.fullmatch(r"stage=(media_direct_peer_unconfirmed|companion_relay_not_authenticated|companion_broker_[a-z_]+|companion_tcp_[a-z_]+)",safe):
                        self.owner.note("companion_host_peer_result "+safe)
            except (OSError,ValueError,subprocess.SubprocessError):
                self.owner.note("companion_host_public_worker_failed=1")
            finally:
                self.ready.clear()
                with self.lock:
                    if child:
                        if not child.stdin.closed: child.stdin.close()
                        if child.poll() is None:
                            try: child.wait(timeout=.6)
                            except subprocess.TimeoutExpired:
                                child.terminate()
                                child.wait(timeout=3)
                        child.stdout.close()
                    self.process=None
            self.stop.wait(.25)

    def end_lease(self):
        with self.lock:
            if self.process and not self.process.stdin.closed: self.process.stdin.close()

    def close(self):
        self.stop.set()
        self.end_lease()
        self.thread.join(3)
        if self.thread.is_alive():
            with self.lock:
                if self.process and self.process.poll() is None: self.process.terminate()
            self.thread.join(3)


def session_capabilities(packet, live, audio, *, exact_video=False):
    if not (live or audio or exact_video): return packet
    # These bytes follow the NUL in the fixed-width version string. Older
    # receivers see the same versions, layout, encryption keys and duration.
    require(len(packet)==124 and 0 in packet[60:84] and not any(packet[84:91]),"companion_version_padding_unavailable")
    return packet[:84]+b"SSC1"+bytes([int(live)|int(audio)<<1,20 if exact_video else 0,1 if exact_video else 0])+packet[91:]


def setup_timings(events):
    # Keep only bounded numeric markers. Never persist TLS, RTSP, peer
    # addresses or the general event stream.
    rows=[]
    for line in events:
        m=re.fullmatch(r"companion_setup_timing exchange=(\d{1,3}) peer_data=([01]) reply_ms=(-1|\d{1,6}) total_ms=(\d{1,6}) end=(io|local_end|peer_end|bound)",line)
        if m and len(rows)<160:
            rows.append(dict(exchange=int(m[1]),peer_data=bool(int(m[2])),
                first_reply_ms=None if m[3]=="-1" else int(m[3]),total_ms=int(m[4]),end=m[5]))
    return rows


class Companion:
    def __init__(self, ip, port, state, backend, seconds=50, new_invite=False, allowed_phone=None,
                 broker=None, silent_direct=False, trace_file=None, trace_salt=None, tx_source=None,
                 fresh_recovery=False, relay_spacing=False, tx_guard=False, allow_input=False,
                 input_fixture=0,high_relay=False,frame_spread=False,menu_fixture=False,sustained=False,relay_socket_trial=False,
                 compact_head_trial=False,standard_wan=False):
        require(private(ip),"companion_requires_private_ipv4")
        self.ip,self.identity,self.backend=ip,Identity(state),backend
        self.seconds=seconds
        require(not standard_wan or (broker and seconds<=30 and not sustained and not allow_input and not input_fixture
                and not high_relay and not compact_head_trial),"standard_trial_must_be_bounded_and_view_only")
        self.standard_wan=standard_wan
        if standard_wan and backend is not None: backend.standard_wan=True
        self.sustained=sustained
        self.allowed_phone=allowed_phone
        self.broker=broker
        self.silent_direct=silent_direct
        self.trace_file=trace_file
        self.tx_source=tx_source
        self.fresh_recovery=fresh_recovery
        self.high_relay=high_relay
        # This is a capability, not a request to force relay. The peer only
        # applies it after an authenticated relay route actually measures >1800.
        require(not frame_spread or (high_relay and relay_spacing and broker),"frame_spread_requires_high_relay_trial")
        self.frame_spread=frame_spread
        require(not relay_socket_trial or (high_relay and frame_spread and tx_source and not tx_guard),
                "socket_trial_requires_dedicated_high_relay_measurement")
        self.relay_socket_trial=relay_socket_trial
        require(not compact_head_trial or (broker and trace_file and tx_source and fresh_recovery and relay_spacing
                and getattr(backend,"full_hd_profile",None)=="1080p60"
                and not any((sustained,high_relay,allow_input,input_fixture,menu_fixture,tx_guard,relay_socket_trial))),
                "compact_head_requires_isolated_low_relay")
        self.compact_head_trial=compact_head_trial
        require(not menu_fixture or (broker is None and not allow_input and not input_fixture),"menu_fixture_requires_view_only_lan")
        self.menu_fixture=menu_fixture
        self.relay_spacing=relay_spacing
        self.tx_guard=tx_guard
        self.input_fixture=input_fixture
        self.input_test_blackhole=threading.Event()
        self.allow_input=allow_input or bool(input_fixture)
        self.trace_salt=trace_salt
        self.path_samples=[]
        self.wan=None
        self.wan_listener=None
        self.invite=secrets.token_bytes(32) if self.identity.device_hash==bytes(32) or new_invite else None
        self.invite_until=time.monotonic()+180
        self.context=self.identity.context()
        self.mutex=threading.Lock()
        self.lease=None
        self.input_owner=None
        self.live=threading.Event()
        self.stop_requested=threading.Event()
        self.exchanges=set()
        self.workers=[]
        self.limit=threading.BoundedSemaphore(8)
        self.events=[]
        self.listener=socket.socket()
        try:
            self.listener.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE,1)
            self.listener.bind((ip,port))
            self.listener.listen(6)
            self.listener.settimeout(.4)
            self.port=self.listener.getsockname()[1]
            if broker:
                require(backend is not None,"companion_public_backend_missing")
                self.wan_listener=socket.socket()
                self.wan_listener.bind(("127.0.0.1",0))
                self.wan_listener.listen(8)
                self.wan_listener.settimeout(.4)
        except OSError:
            self.listener.close()
            if self.wan_listener: self.wan_listener.close()
            raise

    def note(self, value):
        self.events.append(value)
        event(value)

    def invitation(self):
        if self.invite is None:
            return ""
        return f"ss1-{self.ip}-{self.port}-{self.identity.cert.fingerprint(hashes.SHA256()).hex()}-{self.invite.hex()}"

    def start(self):
        self.acceptor=threading.Thread(target=self.accept,args=(self.listener,False),daemon=True)
        self.acceptor.start()
        self.live.wait(2)
        if self.wan_listener:
            self.wan=InternetPeer(self,self.broker,self.wan_listener.getsockname()[1],self.silent_direct)
            self.wan_acceptor=threading.Thread(target=self.accept,args=(self.wan_listener,True),daemon=True)
            self.wan_acceptor.start()

    def accept(self, listener, wan):
        self.live.set()
        while not self.stop_requested.is_set():
            try: conn,source=listener.accept()
            except TimeoutError: continue
            except OSError: break
            permitted=source[0]=="127.0.0.1" if wan else same_lan(self.ip,source[0]) and (
                not self.allowed_phone or source[0]==self.allowed_phone)
            if not permitted or not self.limit.acquire(False):
                conn.close()
                continue
            with self.mutex:
                self.workers=[w for w in self.workers if w.is_alive()]
                thread=threading.Thread(target=self.client,args=(conn,source[0],wan),daemon=True)
                self.workers.append(thread)
                thread.start()

    def client(self, raw, ip, wan):
        ssl_conn=None
        try:
            with raw:
                raw.settimeout(7 if wan else 4)
                with self.context.wrap_socket(raw,server_side=True) as tls:
                    ssl_conn=tls
                    with self.mutex: self.exchanges.add(tls)
                    tag=read_exact(tls,4)
                    if tag==b"PAI1" and not wan: self.enroll(tls)
                    elif tag==(b"CTL2" if wan else b"CTL1"): self.control(tls,ip,wan)
                    elif tag==b"RTS1": self.rtsp(tls,ip,wan)
                    elif tag==b"INP1": self.input(tls,ip,wan)
        except ssl.SSLError:
            self.note("companion_tls_rejected=1")
        except (OSError,EOFError,RuntimeError,ValueError,subprocess.SubprocessError):
            pass
        finally:
            with self.mutex: self.exchanges.discard(ssl_conn)
            self.limit.release()

    def enroll(self, tls):
        invite=read_exact(tls,32)
        with self.mutex:
            if self.lease is not None or not self.invite or time.monotonic()>=self.invite_until or not hmac.compare_digest(invite,self.invite):
                tls.sendall(b"NOPE")
                self.note("companion_invitation_rejected=1")
                return
            token=secrets.token_bytes(32)
            self.identity.save(hashlib.sha256(token).digest())
            self.invite=None
        tls.sendall(b"OKP1"+token)
        if self.wan: self.wan.end_lease()
        self.note("companion_enrolled=1")

    def control(self, tls, ip, wan=False):
        author=read_exact(tls,32)
        if wan:
            rate=struct.unpack("!I",read_exact(tls,4))[0]
            high=self.high_relay and self.wan is not None and self.wan.on_relay
            route_valid=self.wan is not None and self.wan.ready.is_set() and 500<=rate<=(24000 if self.standard_wan else 6400 if high else 1400)
            insufficient=self.standard_wan and rate>=STANDARD_VIDEO and self.wan is not None and rate>self.wan.video_ceiling
            if self.standard_wan and self.wan is not None and rate<STANDARD_VIDEO: rate=min(rate,self.wan.video_ceiling)
            if high:
                # Never encode faster than our own measurement, including
                # when the last probe acknowledgement was lost on one side.
                rate=min(rate,self.wan.video_ceiling)
        else:
            key=read_exact(tls,32)
            phone_port,rate=struct.unpack("!HI",read_exact(tls,6))
            route_valid=paired_video_rate(rate) and phone_port>=1024 and any(key)
            if self.menu_fixture and route_valid:
                rate=min(rate,2000)  # 540p30 real primary; GUI acceptance is not a bandwidth benchmark.
        with self.mutex:
            valid=self.backend is not None and route_valid and self.lease is None and (
                self.identity.device_hash!=bytes(32) and
                hmac.compare_digest(hashlib.sha256(author).digest(),self.identity.device_hash))
            if not valid:
                tls.sendall(b"NOPE")
                self.note("companion_control_rejected=1")
                return
            if wan and insufficient:
                tls.sendall(b"CAP2")
                self.note("companion_standard_video_budget_insufficient=1")
                return
            lease=Lease(ip,wan)
            self.lease=lease
        peer, drain = None,None
        phase="peer_prepare"
        try:
            def watch():
                for row in peer.stdout:
                    safe=row.decode("ascii","ignore").strip()
                    if safe=="stage=host_media_lan_authenticated":
                        lease.host_authenticated=True
                        lease.authenticated_event.set()
                        self.note("companion_host_udp_authenticated=1")
                    elif re.fullmatch(r"bandwidth_result state=\d+ good_kbps=\d+ unstable_kbps=\d+ cap_kbps=\d+",safe):
                        self.note("companion_host_"+safe)
                    elif safe=='standard_pacer_bounded_catchup=1': self.note('companion_host_standard_pacer=1')
                    elif safe in ('lan_fresh_recovery=1','lan_pacer_even_dispatch=1','lan_tx_writable_trial=1'): self.note('companion_host_'+safe)
                    elif self.trace_file and len(self.path_samples)<12000 and (PROBE_STEP.fullmatch(safe) or PROBE_SENDER.fullmatch(safe) or PROBE_WAKE.fullmatch(safe)):
                        self.path_samples.append(safe)
                    elif self.trace_file and len(self.path_samples)<12000 and re.fullmatch(
                            r"(?:video_path|wan_media_host|wan_media_backpressure|wan_tx_setup|wan_tx_event|lan_fresh_video|lan_tx_resume|lan_tx_clock|lan_source_rx_setup|lan_source_rx_seq|lan_source_rx_gap)(?: [a-z_]+=[0-9]+){3,18}",safe):
                        self.path_samples.append(safe)
            if wan:
                tls.sendall(b"OKC2"+lease.grant)
                self.note("companion_control_public_granted=1")
            else:
                budget=lan_wire_budget(rate)
                peer,udp,pub=self.backend.open_peer(self.ip,f"{ip}:{phone_port}",key,budget,self.trace_file,self.trace_salt)
                drain=threading.Thread(target=watch,daemon=True)
                drain.start()
                tls.sendall(b"OKC1"+pub+struct.pack("!H",udp)+lease.grant)
            phase="media_ready"
            self.note("companion_control_granted=1")
            tls.settimeout(14)
            require(read_exact(tls,4)==b"RDY1" and
                    (self.wan.ready.is_set() if wan else lease.authenticated_event.wait(2)),
                    "companion_no_verified_media_link")
            phase="desktop_start"
            self.note("companion_media_ready=1")
            initial=self.backend.launch(rate,self.seconds,wan)
            with self.mutex: lease.launched=True
            phase="setup_reply"
            caps=lambda packet:session_capabilities(packet,self.sustained,getattr(self.backend,"audio",False) is True,
                exact_video=struct.unpack_from('!I',packet,16)[0]>=STANDARD_VIDEO)
            tls.sendall(caps(initial))
            self.note("companion_setup_served=1")
            phase="established"
            tls.settimeout(self.seconds+10)
            until=time.monotonic()+self.seconds+8
            hard_stop=time.monotonic()+4*3600
            last_renewal=0
            # The narrow trial chooses a conservative encode budget at launch
            # and retains that stream; no simulated hot bitrate change.
            quality_changes=screen_changes=0
            while time.monotonic()<until:
                if time.monotonic()>=until: break
                tag=read_exact(tls,4)
                if tag==b"LIV1":
                    now=time.monotonic()
                    require(self.sustained and now<until and now<hard_stop and now-last_renewal>=3,
                            "companion_session_renewal_rejected")
                    child=self.wan.process if wan else peer
                    require(child is not None and child.poll() is None,"companion_transport_closed")
                    child.stdin.write(b"L")
                    child.stdin.flush()
                    until=min(hard_stop,now+45)
                    tls.settimeout(max(.1,until-now))
                    tls.sendall(b"ALV1")
                    if not last_renewal: self.note("companion_live_lease_active=1")
                    last_renewal=now
                    continue
                require(tag in (b"QRY2",b"DSP2"),"companion_quality_request_invalid")
                proposed=struct.unpack("!I",read_exact(tls,4))[0]
                display=tag==b"DSP2"
                if display:
                    switch_rate=struct.unpack("!I",read_exact(tls,4))[0]
                    require(500<=switch_rate<=struct.unpack_from("!I",initial,16)[0],"companion_display_rate_invalid")
                    if (screen_changes>=12 or proposed==self.backend.active_display or not self.backend.available(proposed)):
                        tls.sendall(b"NOD2")
                        continue
                    with self.mutex:
                        lease.switching=True
                        lease.input_epoch+=1
                    screen_changes+=1
                else:
                    require(rate<STANDARD_VIDEO and not self.backend.peak_shave and quality_changes<4 and 500<=proposed<=rate and
                            proposed%50==0,"companion_quality_request_invalid")
                    quality_changes+=1
                tls.sendall(b"RDY2")
                tls.settimeout(5)
                require(read_exact(tls,4)==b"RUN2","companion_quality_commit_missing")
                if display:
                    phase="display_release"
                    end_release=time.monotonic()+2
                    while lease.input_open and time.monotonic()<end_release: time.sleep(.02)
                    require(not lease.input_open,"companion_prior_input_not_closed")
                    self.backend.cancel()
                    phase="display_capture"
                    self.backend.choose_display(proposed)
                    phase="display_launch"
                    packet=self.backend.configuration(rate,switch_rate,self.seconds,wan)
                    with self.mutex:
                        lease.rtsp_completed=0
                        lease.switching=False
                else: packet=self.backend.rebuild(rate,proposed,self.seconds,wan)
                initial=packet
                tls.sendall(caps(packet))
                phase="established"
                self.note(f"companion_display_selected={proposed+1}" if display else "companion_quality_rebuild=1")
                tls.settimeout(max(1,until-time.monotonic()))
            # The final accepted stream must not outlive this local lease.
            tls.settimeout(max(1,until-time.monotonic()))
            if time.monotonic()<until: tls.recv(1)
        except (OSError,EOFError,RuntimeError,ValueError,subprocess.SubprocessError) as exc:
            if phase!="established":
                # No raw response, address, URL, key or invitation.
                code=str(exc) if isinstance(exc,RuntimeError) and re.fullmatch(r"[a-z_]{4,72}",str(exc)) else type(exc).__name__
                self.note(f"companion_setup_error phase={phase} reason={code}")
            raise
        finally:
            with self.mutex: lease.open=False
            if lease.launched:
                try: self.backend.cancel()
                except (OSError,RuntimeError): pass
            if peer is not None:
                try: peer.stdin.close()
                except OSError: pass
                try: peer.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    peer.terminate(); peer.wait(timeout=4)
                if drain is not None: drain.join(2)
                peer.stdout.close()
            if wan: self.wan.end_lease()
            with self.mutex: self.lease=None
            self.note(f"companion_closed rtsp_exchanges={lease.rtsp_completed}")

    def input(self,tls,ip,wan=False):
        grant=read_exact(tls,32)
        with self.mutex:
            lease=self.lease
            valid=self.allow_input and lease and lease.open and not lease.switching and lease.launched and (
                lease.rtsp_completed>0 and self.input_owner is None and not lease.input_open
                and ip==lease.phone and wan==lease.wan
                and hmac.compare_digest(lease.grant,grant))
            if valid:
                lease.input_open=True
                self.input_owner=lease
                epoch=lease.input_epoch
        if not valid:
            tls.sendall(b"NOPE")
            self.note("companion_input_rejected=1")
            return
        try:
            # Only the authenticated, short-message input connection needs
            # immediate delivery; leave bulk/video paths alone.
            tls.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
            target=self.backend.screens[self.backend.active_display] if getattr(self.backend,"screens",None) else None
            serve_input(tls,lambda: lease.open and epoch==lease.input_epoch and not self.stop_requested.is_set(),
                        WindowsInput(self.input_fixture,target,getattr(self.backend,"video_size",None)),self.note,
                        lambda: bool(self.input_fixture) and self.input_test_blackhole.is_set())
        finally:
            with self.mutex:
                lease.input_open=False
                if self.input_owner is lease: self.input_owner=None

    def rtsp(self, tls, ip, wan=False):
        grant=read_exact(tls,32)
        with self.mutex:
            lease=self.lease
            if not lease or not lease.open or lease.switching or not lease.launched or ip!=lease.phone or wan!=lease.wan or (
                lease.proxy_count>=160 or not hmac.compare_digest(lease.grant,grant)):
                tls.sendall(b"NOPE")
                return
            lease.proxy_count+=1
            attempt=lease.proxy_count
            epoch=lease.input_epoch
        start=time.monotonic(); request=False; first=None; end_kind="io"
        try:
            with socket.create_connection(("127.0.0.1",48010),timeout=2) as backend:
                tls.sendall(b"OKR1")
                end=time.monotonic()+10
                moved=0
                while time.monotonic()<end and lease.open and moved<512*1024:
                    readable,_,_=select.select([tls,backend],[],[],0 if tls.pending() else .15)
                    if tls.pending() and tls not in readable: readable.append(tls)
                    for source in readable:
                        data=source.recv(8192)
                        if not data:
                            end_kind="local_end" if source is backend else "peer_end"
                            if first is not None and lease.input_epoch==epoch and not lease.switching:
                                lease.rtsp_completed+=1
                            return
                        moved+=len(data)
                        if source is backend and first is None:first=time.monotonic()
                        if source is tls:request=True
                        (tls if source is backend else backend).sendall(data)
                end_kind="bound"
        finally:
            if self.trace_file:
                duration=round((time.monotonic()-start)*1000)
                self.note(f"companion_setup_timing exchange={attempt} peer_data={int(request)} reply_ms={-1 if first is None else round(1000*(first-start))} total_ms={duration} end={end_kind}")

    def close(self):
        self.stop_requested.set()
        self.listener.close()
        if self.wan_listener: self.wan_listener.close()
        if hasattr(self,"acceptor"): self.acceptor.join(1)
        if hasattr(self,"wan_acceptor"): self.wan_acceptor.join(1)
        if self.wan: self.wan.close()
        with self.mutex: sockets=list(self.exchanges)
        for sock in sockets:
            try: sock.shutdown(socket.SHUT_RDWR)
            except OSError: pass
        for thread in self.workers: thread.join(5)


def network_summary(lines):
    profiles=re.findall(r"^interface=[0-9]+ profile=(Private|Public|DomainAuthenticated)\r?$",lines,re.M)
    records=re.findall(r"^program=(SesameStreamCompanion\.exe|sesame_wan_peer\.exe) matching_inbound_block=([0-9]+) matching_inbound_allow=([0-9]+)\r?$",lines,re.M)
    if len(profiles)!=1 or len(records)!=2 or len({r[0] for r in records})!=2: return "unknown",()
    return profiles[0],tuple("助手" if n=="SesameStreamCompanion.exe" else "媒体进程" for n,b,_ in records if int(b))


def show_local_network(ip):
    exe=Path(sys.executable).resolve()
    profile,blocked="unknown",()
    if getattr(sys,"frozen",False):
        ps=Path(os.environ["SystemRoot"])/"System32/WindowsPowerShell/v1.0/powershell.exe"
        try:
            script=Path(sys._MEIPASS)/"Test-LocalNetwork.ps1"
            r=subprocess.run([str(ps),"-NoProfile","-NonInteractive","-File",str(script),
                              "-HelperPath",str(exe),"-ListenAddress",ip],capture_output=True,timeout=12,
                             creationflags=subprocess.CREATE_NO_WINDOW)
            if not r.returncode: profile,blocked=network_summary(r.stdout.decode("ascii","ignore"))
        except (OSError,subprocess.SubprocessError): pass
    labels={"Private":"专用网络","DomainAuthenticated":"域网络","Public":"公用网络","unknown":"未能确认网络类型"}
    event(f"companion_network_profile={profile} explicit_blocked_programs={len(blocked)}")
    event("局域网入站检查："+labels[profile]+"。")
    if blocked: event("发现与当前安装路径匹配的入站阻止规则："+ "、".join(blocked)+"。手机可能无法首次配对或出画；不必清除已有配对。")
    elif profile=="Public": event("公用网络可能阻止手机首次配对或出画；请在可信的专用局域网复测，不必清除配对。")
    else: event("未确认是否允许入站；请以同一可信局域网的实际配对和出画为准。")
    event("未更改网络类型或防火墙。")


def main():
    p=argparse.ArgumentParser()
    p.add_argument("--listen-ip",help="This PC's explicit private IPv4 address")
    p.add_argument("--port",type=int,default=47837)
    p.add_argument("--state-dir",type=Path,default=runtime_dir()/"windows-companion-state")
    p.add_argument("--new-invite",action="store_true")
    p.add_argument("--owner-stdin",action="store_true",help="Stop this instance when its launching process closes stdin")
    action=p.add_mutually_exclusive_group()
    action.add_argument("--prepare-sunshine",type=Path,metavar="OFFICIAL_ZIP")
    action.add_argument("--self-check",action="store_true")
    action.add_argument("--check-network",action="store_true",help="Read-only inbound diagnostic for the selected interface")
    action.add_argument("--provision-relay",metavar="USER@IP")
    p.add_argument("--replace-relay-ticket",action="store_true")
    p.add_argument("--relay-wire-kbps",type=int,choices=(1800,8000),default=1800)
    p.add_argument("--broker",help="Explicit authorized companion broker IPv4:23388")
    p.add_argument("--allow-input",action="store_true",
                   help="Opt in to keyboard and mouse from the existing pairing for this run")
    p.add_argument("--no-audio",action="store_true",help="Do not capture the Windows playback device")
    add_output_options(p)
    args=p.parse_args()
    require(not args.replace_relay_ticket or args.provision_relay,"replace_requires_provision")
    if args.prepare_sunshine or args.self_check or args.provision_relay:
        import delivery
        if args.prepare_sunshine:
            delivery.prepare(args.prepare_sunshine); event("sunshine_portable_verified=1")
        elif args.self_check: delivery.self_check()
        else: delivery.provision(args.provision_relay,args.state_dir,args.replace_relay_ticket); event("relay_tickets_installed=1")
        return
    args.listen_ip=choose_local(args.listen_ip)
    if args.check_network:
        show_local_network(args.listen_ip)
        return
    require(args.relay_wire_kbps==1800 or args.broker,"high_rate_requires_explicit_relay")
    require(1024<=args.port<=65535 and private(args.listen_ip),"companion_listener_options_invalid")
    with ExitStack() as scope:
        server=Companion(args.listen_ip,args.port,args.state_dir,PhysicalBackend(scope,audio=not args.no_audio,output_profile=args.output_profile),new_invite=args.new_invite,sustained=True,
                         broker=args.broker,allow_input=args.allow_input,high_relay=args.relay_wire_kbps==8000,
                         fresh_recovery=bool(args.broker),relay_spacing=bool(args.broker),
                         frame_spread=args.relay_wire_kbps==8000)
        scope.callback(server.close)
        server.start()
        if getattr(sys,"frozen",False):
            threading.Thread(target=show_local_network,args=(args.listen_ip,),daemon=True).start()
        if args.owner_stdin:
            def owner():
                try: sys.stdin.buffer.read(1)
                finally: server.stop_requested.set()
            threading.Thread(target=owner,daemon=True).start()
        event("companion_application_ready=1")
        if args.output_profile: event(f"输出：{args.output_profile}；码率仍由已授权链路决定。")
        event("Windows 助手已就绪。仅接受已配对手机。" if args.broker else
              "Windows 助手已就绪。只接收同一局域网中的已授权手机，不会安装系统服务。")
        invitation=server.invitation()
        if invitation:
            event("请只把以下一次性配对码粘贴到你自己手机的配对框。")
            event(invitation)  # explicit, local-only deliverable; never used by automated logging
        else:
            event("已保留配对，可从手机直接连接。")
        event("本次允许已配对手机手动开启键鼠控制。" if args.allow_input else
              "本次仅查看画面；如要允许键鼠，可用 --allow-input 启动。")
        event("电脑播放声音：关闭。" if args.no_audio else "将传输电脑的播放声音，不使用麦克风；可用 --no-audio 关闭。")
        try:
            while not server.stop_requested.wait(.5): pass
        except KeyboardInterrupt:
            pass


if __name__=="__main__":
    try: main()
    except (RuntimeError,OSError,ValueError,EOFError,subprocess.SubprocessError) as error:
        result=str(error)
        event(result if re.fullmatch(r"[a-z_]{4,75}",result) else "companion_start_failed")
        raise SystemExit(4)
