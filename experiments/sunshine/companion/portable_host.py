"""Portable physical capture, no USB tooling, synthetic monitor, service or firewall change."""
from collections import deque
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlsplit
import hashlib,http.client,json,os,re,secrets,socket,struct,subprocess,threading,time
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding,NoEncryption,PrivateFormat,PublicFormat
from local_pair import Pair,HOST as NAME,TILE,HTTP as PORT
from display_targets import geometry

EXE_HASH="a8ddf74e93297529ca5aa9c59234a7043b94587e8d11ea24c521fa69d6f59fd3"
ROOT=(Path(os.environ["SESAME_STREAM_TEST_RUNTIME"])/"physical-screen-sunshine" if os.environ.get("SESAME_STREAM_TEST_RUNTIME")
      else Path(os.environ["LOCALAPPDATA"])/"SesameStreamCompanion"/"capture")

def event(value): print(value,flush=True)
def expect(ok,message):
    if not ok: raise RuntimeError(message)
def pwsh(command):
    shell=Path(os.environ["SystemRoot"])/"System32/WindowsPowerShell/v1.0/powershell.exe"
    result=subprocess.run([str(shell),"-NoProfile","-NonInteractive","-Command",command],capture_output=True,
                          text=True,errors="replace",timeout=20,creationflags=subprocess.CREATE_NO_WINDOW)
    expect(result.returncode==0,"windows_screen_probe_failed")
    return result.stdout.strip()
def primary():
    rows=[s for s in geometry() if s.primary]
    expect(len(rows)==1,"windows_primary_display_unknown")
    s=rows[0]; l,t,r,b=s.rect
    return s.name,r-l,b-t
def keypair():
    key=X25519PrivateKey.generate()
    return (key.private_bytes(Encoding.Raw,PrivateFormat.Raw,NoEncryption()).hex(),
            key.public_key().public_bytes(Encoding.Raw,PublicFormat.Raw).hex())
def media_args(pair,args,unused):
    key,iv=pair.launch(args.width,args.height,args.fps,args.kbps)
    v=pair.version.encode("ascii"); g=pair.gfe.encode("ascii")
    expect(len(v)<32 and len(g)<32,"session_version_rejected")
    return struct.pack("!4s6I16s16s32s32s",b"SCH1",args.width,args.height,args.fps,args.kbps,args.seconds,
                       1024,key,iv,v,g)
lan=SimpleNamespace(keypair=keypair)
f=SimpleNamespace(media_args=media_args)

class WindowsPair(Pair):
    def launch(self,w,h,fps,kbps):
        expect(self.appid is not None,"lan_physical_launch_before_pairing")
        key=secrets.token_bytes(16)
        ri_id=secrets.randbelow(2**31-1)+1
        iv=ri_id.to_bytes(4,"big")+bytes(12)
        reply=self.request("launch",{"appid":self.appid,"mode":f"{w}x{h}x{fps}",
            "additionalStates":"1","sops":"0","rikey":key.hex(),"rikeyid":str(ri_id),
            "localAudioPlayMode":"1","surroundAudioInfo":"196610","remoteControllersBitmap":"0",
            "gcpersist":"0","corever":"1"},timeout=15,secure=True)
        uri=urlsplit(reply.findtext("sessionUrl0",""))
        expect(reply.findtext("gamesession")=="1" and uri.scheme=="rtspenc" and
               uri.port==48010 and uri.hostname=="127.0.0.1" and uri.path in ("","/") and
               not any((uri.username,uri.password,uri.query,uri.fragment)), "lan_physical_encrypted_rtsp_required")
        return key,iv


class WindowsSunshine:
    physical=True
    readiness_seconds=28

    def __init__(self,runtime,display):
        self.runtime=runtime.resolve()
        self.desired=display
        self.timing=[]
        self.p=None
        self.thread=None
        self.rows=deque(maxlen=500)
        self.lock=threading.Lock()
        self.output_id=None
        self.session_at=0
        executables=list((ROOT/"portable").rglob("sunshine.exe"))
        expect(len(executables)==1,"windows_portable_executable_missing")
        self.exe=executables[0].resolve()
        with self.exe.open("rb") as image:
            expect(self.exe.is_relative_to((ROOT/"portable").resolve()) and hashlib.file_digest(image,"sha256").hexdigest()==EXE_HASH,"portable_sunshine_not_verified")

    def line(self,row):
        row=row.rstrip()
        with self.lock: self.rows.append((time.monotonic(),row))

    def drain(self):
        for raw in self.p.stdout:
            self.line(raw.decode("utf-8","replace"))

    def conf(self):
        config={
            "sunshine_name":NAME, "bind_address":"127.0.0.1", "external_ip":"127.0.0.1",
            "address_family":"ipv4","port":str(PORT),"upnp":"disabled","origin_web_ui_allowed":"pc",
            "lan_encryption_mode":"2","wan_encryption_mode":"2","keyboard":"disabled","mouse":"disabled",
            "controller":"disabled","native_pen_touch":"disabled","stream_audio":"enabled" if getattr(self,"stream_audio",False) else "disabled",
            "install_steam_audio_drivers":"disabled","system_tray":"disabled","min_log_level":"info",
            "notify_pre_releases":"disabled","encoder":"nvenc","capture":"ddx",
            "dd_configuration_option":"verify_only","dd_resolution_option":"disabled",
            "dd_refresh_rate_option":"disabled","dd_hdr_option":"disabled","max_bitrate":"50000",
            "minimum_fps_target":"1","hevc_mode":"1","av1_mode":"1","fec_percentage":"20",
            "file_apps":(self.runtime/"apps.json").as_posix(),"file_state":(self.runtime/"state.json").as_posix(),
            "credentials_file":(self.runtime/"credentials.json").as_posix(),
            "pkey":(self.runtime/"test-key.pem").as_posix(),"cert":(self.runtime/"test-cert.pem").as_posix(),
            "log_path":(self.runtime/"sunshine.log").as_posix(),
        }
        if self.output_id: config["output_name"]=self.output_id
        return "".join(f"{k} = {v}\n" for k,v in config.items())

    def start(self):
        test=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
        with test:
            test.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE,1)
            test.bind(("127.0.0.1",PORT))
        self.rows.clear()
        (self.runtime/"apps.json").write_text(json.dumps({"env":{},"apps":[
            {"name":TILE,"image-path":"desktop.png","exclude-global-prep-cmd":True}]}),encoding="utf-8")
        config=self.runtime/"sunshine.conf"
        config.write_text(self.conf(),encoding="utf-8")
        self.p=subprocess.Popen([str(self.exe),str(config),"-0","-1"],cwd=self.exe.parent,
                               stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                               creationflags=subprocess.CREATE_NO_WINDOW)
        self.thread=threading.Thread(target=self.drain,daemon=True)
        self.thread.start()
        until=time.monotonic()+self.readiness_seconds
        attempts=success_http=0;last_status=last_errno=0
        while time.monotonic()<until and self.p.poll() is None:
            attempts+=1
            try:
                conn=http.client.HTTPConnection("127.0.0.1",PORT,timeout=.5)
                with ExitStack() as s:
                    s.callback(conn.close)
                    conn.request("GET","/serverinfo")
                    response=conn.getresponse()
                    blob=response.read(50000)
                    last_status=response.status;success_http+=1
                    if response.status==200 and f"<hostname>{NAME}</hostname>".encode() in blob:
                        self.local_only()
                        return
            except (OSError,http.client.HTTPException) as exc:
                last_errno=getattr(exc,'winerror',None) or getattr(exc,'errno',None) or 0
            time.sleep(.45)
        with self.lock: log="\n".join(s for _,s in self.rows).lower()
        # Do not emit host rows, XML, TLS material, addresses, or account names.
        rc=self.p.poll()
        event(f'physical_start_observed target={int(bool(self.output_id))} alive={int(rc is None)} exit={rc if rc is not None else 0} attempts={attempts} http={success_http} status={last_status} socket_error={last_errno} rows={len(self.rows)} display={int("available display devices" in log)} nvenc={int("nvenc" in log)}')
        for kind,needles in (("driver_nvenc_unavailable",("encoder [nvenc] failed","no working encoder","failed to initialize nvenc")),
                             ("desktop_duplication_unavailable",("failed to capture","no display","duplicateoutput")),
                             ("host_network_bind_failed",("failed to bind","address already in use"))):
            if any(n in log for n in needles): event("lan_physical_setup_hint="+kind)
        raise RuntimeError("physical_sunshine_not_ready")

    def local_only(self):
        pid=self.p.pid
        s=pwsh(f"$a=@(Get-NetTCPConnection -OwningProcess {pid} -State Listen -ErrorAction SilentlyContinue);"
               f"$u=@(Get-NetUDPEndpoint -OwningProcess {pid} -ErrorAction SilentlyContinue);"
               "$bad=@($a+$u | Where-Object {$_.LocalAddress -notin @('127.0.0.1','::1')});"
               "if($a.LocalPort -notcontains 47989 -or $a.LocalPort -notcontains 47984 -or $bad.Count -gt 0){exit 3}; 'ok'")
        expect(s=="ok","physical_host_not_loopback_only")

    def detect_primary_id(self):
        until=time.monotonic()+6
        while time.monotonic()<until:
            with self.lock: log="\n".join(s for _,s in self.rows)
            for off in re.finditer(r"Currently available display devices\s*:\s*(\[)",log,re.I):
                try: values,_=json.JSONDecoder().raw_decode(log[off.start(1):])
                except json.JSONDecodeError: continue
                matches=[a for a in values if isinstance(a,dict) and a.get("display_name")==self.desired
                         and isinstance(a.get("info"),dict) and a["info"].get("primary")]
                if len(matches)!=1: continue
                info=matches[0]
                ident=info.get("device_id","")
                name=info.get("friendly_name","")
                expect(re.fullmatch(r"\{[0-9a-fA-F-]{36}\}",ident) and
                       not re.search(r"virtual|idd|remote|vdd|StarPaint|Mirage",name,re.I),
                       "physical_primary_not_verified")
                return ident
            time.sleep(.25)
        raise RuntimeError("physical_primary_display_id_not_verified")

    def stop(self):
        if self.p and self.p.poll() is None:
            self.p.terminate()
            self.p.wait(timeout=7)
        if self.thread: self.thread.join(timeout=3)
        if self.p:
            if self.p.stdin: self.p.stdin.close()
            if self.p.stdout: self.p.stdout.close()
        self.p=self.thread=None

    def mark_start(self):
        expect(primary()[0]==self.desired,"physical_primary_changed")
        self.session_at=time.monotonic()

    def capture_verified(self):
        with self.lock: lines=[x for t,x in self.rows if t>=self.session_at]
        text="\n".join(lines)
        nvenc=bool(re.search(r"\[h264_nvenc\]|NVENC:\s*(?:created|encoder)|nvenc.*H\.264",text,re.I))
        active=self.p is not None and self.p.poll() is None
        if nvenc and active:
            event("physical_primary_capture_nvenc_verified=1")
        return nvenc and active

    def sanitized_session_hints(self):
        if not self.session_at: return
        with self.lock: text="\n".join(x for t,x in self.rows if t>=self.session_at).lower()
        groups={
            "rtsp_seen":("rtsp","announce"),"encryption_error":("failed to decrypt","encryption is mandatory"),
            "nvenc_seen":("h264_nvenc",),"stream_start":("client connected","new streaming session"),
            "transport_error":("invalid request","connection reset","failed to bind","failed to accept"),
        }
        event("physical_host_stage "+ " ".join(
            f"{name}={int(any(k in text for k in needles))}" for name,needles in groups.items()))

    def scan(self,delay=.13):
        expect(self.p is not None and self.p.poll() is None,"physical_host_exited")
        time.sleep(delay)

    def send(self,pin):
        expect(re.fullmatch(r"\d{4}",pin),"physical_pair_pin_rejected")
        self.p.stdin.write((pin+"\n").encode("ascii"))
        self.p.stdin.flush()
