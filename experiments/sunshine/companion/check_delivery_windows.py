"""Open the shipped Windows ZIP in an isolated user directory, then stream its real display to the paired phone."""
import argparse,hashlib,json,os,re,subprocess,tempfile,threading,time,zipfile
import socket
from pathlib import Path
from contextlib import ExitStack
import windows_companion as wc
import check_device as ui

def quiet_playback_check():
    # A short, low-volume test through the default Windows playback output.
    # Never use a microphone, change a device volume, or read/store user media.
    import array,io,math,wave,winsound
    rate=48000; count=rate//2
    pcm=array.array("h",(int(760*min(1,i/600,(count-i)/600)*math.sin(2*math.pi*i*440/rate)) for i in range(count)))
    buf=io.BytesIO()
    with wave.open(buf,"wb") as wav:
        wav.setparams((1,2,rate,0,"NONE","not compressed")); wav.writeframes(pcm.tobytes())
    winsound.PlaySound(buf.getvalue(),winsound.SND_MEMORY|winsound.SND_NODEFAULT)

def check_self_rejected(exe,env,local,tmp):
    """The binary refuses same-address enrollments even on a physical interface."""
    state=tmp/"disposable-pair"
    with socket.socket() as free:
        free.bind((local,0)); port=free.getsockname()[1]
    proc=subprocess.Popen([exe,"--listen-ip",local,"--port",str(port),"--state-dir",str(state),
        "--owner-stdin","--no-audio"],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
    ready=threading.Event()
    def watch():
        for row in proc.stdout:
            if row.strip()==b"companion_application_ready=1": ready.set()
    thread=threading.Thread(target=watch,daemon=True);thread.start()
    try:
        wc.require(ready.wait(45),"temporary_installed_listener_not_ready")
        # No invitation or other credential is ever read or sent. Prove the TCP
        # listener answers, but refuses its own address before accepting TLS.
        with socket.create_connection((local,port),timeout=4) as conn:
            try: eof=conn.recv(1)==b""
            except (ConnectionAbortedError,ConnectionResetError): eof=True
            wc.require(eof,"same_address_not_rejected")
        print("installed_same_address_pair_rejected_before_tls=1",flush=True)
    finally:
        proc.stdin.close()
        try: code=proc.wait(35)
        except subprocess.TimeoutExpired:
            proc.terminate();proc.wait(10);raise RuntimeError("temporary_installed_shutdown_timeout") from None
        thread.join(3);proc.stdout.close()
        wc.require(code==0,"temporary_installed_shutdown_failed")

def run(archive,sunshine,device,public=False,live_seconds=0,verify_audio_cue=False,check_self=False):
    with tempfile.TemporaryDirectory(prefix="sesame-windows-delivery-") as temp, ExitStack() as scope:
        root=Path(temp); kit=root/"kit"; kit.mkdir()
        env={k:v for k,v in os.environ.items() if not k.startswith(("SESAME_","PYTHON"))}
        env["LOCALAPPDATA"]=str(root/"profile")
        with zipfile.ZipFile(archive) as z:
            m=json.loads(z.read("SHA256.json"))
            for name in ("SesameStreamCompanion.exe","sesame_wan_peer.exe","Test-LocalNetwork.ps1"):
                content=z.read(name); wc.require(hashlib.sha256(content).hexdigest()==m[name],"archive_hash_failure")
                (kit/name).write_bytes(content)
            for name in ("Install-CurrentUser.ps1","SHA256.json"): (kit/name).write_bytes(z.read(name))
        exe=str(kit/"SesameStreamCompanion.exe")
        def command(*args,ok=True):
            p=subprocess.run([exe,*args],env=env,cwd=kit,capture_output=True,timeout=60,creationflags=subprocess.CREATE_NO_WINDOW)
            wc.require((p.returncode==0)==ok,"packaged_command_failed")
            return p.stdout
        wc.require(b"capture_ready=0" in command("--self-check"),"not_clean_profile")
        command("--prepare-sunshine",str(archive),ok=False)
        install=[str(Path(os.environ["SystemRoot"])/"System32/WindowsPowerShell/v1.0/powershell.exe"),
                 "-NoProfile","-NonInteractive","-File",str(kit/"Install-CurrentUser.ps1"),
                 "-SunshineArchive",str(sunshine),"-NoShortcut"]
        existing=Path(env["LOCALAPPDATA"])/"SesameStreamCompanion"/"versions"/"older-test"/"keep"
        existing.parent.mkdir(parents=True); existing.write_bytes(b"preserve")
        for _ in range(2):
            result=subprocess.run(install,env=env,cwd=kit,capture_output=True,timeout=90,creationflags=subprocess.CREATE_NO_WINDOW)
            if result.returncode:
                err=result.stderr.decode("ascii","ignore")
                codes=re.findall(r"(?:RuntimeError: |ValueError: |FullyQualifiedErrorId\s*:\s*)([a-zA-Z0-9_.]+)",err)
                symbols=re.findall(r"\(([A-Za-z][A-Za-z0-9-]+):String\)|'([A-Za-z][A-Za-z0-9-]+)'",err)
                line=re.findall(r"\.ps1\s*[:\s]+(\d+)",err)
                print("packaged_install_failure codes="+",".join(codes[:4])+" symbol="+",".join((a or b) for a,b in symbols[:5])+" line="+",".join(line[:3]),flush=True)
            wc.require(result.returncode==0 and existing.read_bytes()==b"preserve","isolated_windows_install_failed")
        installed=next(existing.parent.parent.glob("*/SesameStreamCompanion.exe"))
        wc.require(hashlib.sha256(installed.read_bytes()).hexdigest()==m["SesameStreamCompanion.exe"],"installed_executable_changed")
        exe=str(installed)
        wc.require(b"peer_ready=1 capture_ready=1" in command("--self-check"),"capture_not_imported")
        wc.require(b"--output-1080p30" in command("--help") and
                   b"peer_ready=1 capture_ready=1" in command("--output-1080p30","--self-check"),
                   "installed_1080_preset_missing")
        wc.require(b"--output-1080p60" in command("--help") and
                   b"peer_ready=1 capture_ready=1" in command("--output-1080p60","--self-check"),
                   "installed_1080_60_preset_missing")
        command("--output-1080p30","--output-1080p60","--self-check",ok=False)
        local=wc.choose_local()
        diagnostic=command("--check-network","--listen-ip",local)
        result=re.search(rb"companion_network_profile=(Private|Public|DomainAuthenticated|unknown) explicit_blocked_programs=([012])",diagnostic)
        wc.require(bool(result),"installed_network_diagnostic_missing")
        print("installed_network_profile="+result[1].decode()+" explicit_blocked_programs="+result[2].decode(),flush=True)
        if check_self: check_self_rejected(exe,env,local,root)
        if not device:
            print("windows_packaged_install_twice_wrong_zip_refused_prior_version_kept=verified")
            return
        win=wc.load_fixture(); d=win.d; phone=d.CoverageApp()
        wc.require(phone.hdc[-2:]==["-t",device],"unexpected_test_device")
        before=phone.debug_targets(); phone.idle_preflight(); ui.no_usb_forward(phone)
        pc,_=win.lan.wifi_pair(phone); state=wc.runtime_dir()/"windows-companion-state"
        wc.require((state/"protected-companion.dat").is_file() and any(wc.Identity(state).device_hash),"no_saved_pair")
        args=[exe,"--owner-stdin","--listen-ip",str(pc),"--state-dir",str(state)]
        if public:
            from check_public import TemporaryBroker
            import native_wan as deps
            broker=TemporaryBroker(scope,deps)
            broker.start(scope,wc.Identity(state).device_hash,None,True,False)
            radio=deps.prepare_radio(scope)
            args+=["--broker",broker.endpoint]
        proc=subprocess.Popen(args,cwd=kit,env=env,
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
        def stop():
            try: proc.stdin.close()
            except OSError: pass
            code=proc.wait(timeout=36)
            if ready.is_set(): wc.require(code==0,"packaged_helper_did_not_exit_cleanly")
            proc.stdout.close()
        scope.callback(stop)
        ready=threading.Event(); records=set(); host_errors=[]
        def watch():
            for raw in proc.stdout:
                line=raw.decode("ascii","ignore").strip()
                if line=="companion_application_ready=1": ready.set()
                if re.fullmatch(r"(?:companion|physical|windows|portable|lan|session|local|sunshine)_[a-z_]{2,72}",line): host_errors.append(line)
                if re.fullmatch(r"companion_(?:available_displays=\d+|setup_served=1|live_lease_active=1|host_(?:udp|direct|relay)_authenticated=1|input_granted=1)",line):
                    records.add(line)
        threading.Thread(target=watch,daemon=True).start()
        end=time.monotonic()+52
        while not ready.wait(.3) and proc.poll() is None and time.monotonic()<end: pass
        if not ready.is_set() and host_errors: print("packaged_host_safe_reason="+host_errors[-1],flush=True)
        wc.require(ready.is_set(),"packaged_host_not_ready")
        try:
            ui.open_page(phone,d); wc.require(ui.marker(phone,"companion_saved_host_loaded=1"),"pair_missing")
            phone.tap_start(*phone.button_spot())
            deadline=time.monotonic()+(65 if public else 38)+live_seconds; rendered=0; encrypted=cellular=False
            first_picture=last_picture=None; previous=None; cue_sent=False
            elapsed=decoded=played=audible=overflow=audio_errors=0
            while time.monotonic()<deadline:
                raw=phone.shell("hilog -P "+phone.pid+" -T SesameSecureClient,SesameWanProbe -z 260")
                encrypted|="decoder_setup_code=0 enc_video=1 enc_audio=1" in raw
                cellular|="companion_cellular_binding_verified=1" in raw
                sample=re.findall(r"secure_sample ms=(\d+) received=\d+ submitted=\d+ rendered=(\d+)",raw)
                if sample:
                    ms,count=map(int,sample[-1])
                    if count and (previous is None or (ms>=previous[0] and count>previous[1]) or ms<previous[0]):
                        now=time.monotonic(); last_picture=now
                        if first_picture is None: first_picture=now
                        elapsed=int((last_picture-first_picture)*1000)
                    previous=(ms,count); rendered=max(rendered,count)
                for a in re.findall(r"stream_audio_health decoded=(\d+) played_samples=(\d+) audible_blocks=(\d+) overflow=(\d+) errors=(\d+)",raw):
                    decoded,played,audible,overflow,audio_errors=map(int,a)
                if verify_audio_cue and elapsed>=25000 and decoded and played and not audible and not cue_sent:
                    quiet_playback_check(); cue_sent=True
                if encrypted and rendered>=30 and (not live_seconds or elapsed>=live_seconds*1000): break
                time.sleep(.4)
            route=("direct" if "companion_host_direct_authenticated=1" in records else "relay") if public else "udp"
            if public: wc.require(cellular,"cellular_not_confirmed")
            print(f"packaged_host_probe setup={int('companion_setup_served=1' in records)} encrypted={int(encrypted)} rendered={rendered}",flush=True)
            wc.require(encrypted and rendered>=30 and {"companion_setup_served=1",f"companion_host_{route}_authenticated=1"}<=records,"packaged_host_no_secure_picture")
            wc.require("companion_input_granted=1" not in records,"unexpected_input")
            if live_seconds:
                print(f"packaged_live_ms={elapsed} decoded_audio={decoded} played_samples={played} audible_blocks={audible} overflow_samples={overflow} decode_errors={audio_errors}",flush=True)
                print(f"packaged_low_volume_test_cue={int(cue_sent)}",flush=True)
                wc.require("companion_live_lease_active=1" in records and elapsed>=live_seconds*1000,
                           "sustained_session_not_verified")
                wc.require(decoded>0 and played>0 and audio_errors==0,"real_audio_playback_not_verified")
            if public: broker.check_flow(route)
            print(f"windows_packaged_clean_import_idempotent=1 route={route} real_frames={rendered} encrypted=1 usb_forward=0",flush=True)
        finally:
            phone.shell("aa force-stop "+d.APP); phone.shell("aa start -a EntryAbility -b "+d.APP)
            ui.no_usb_forward(phone); wc.require(phone.debug_targets()==before,"other_apps_changed")

if __name__=="__main__":
    p=argparse.ArgumentParser(); p.add_argument("archive",type=Path);p.add_argument("sunshine",type=Path);p.add_argument("device",nargs="?")
    p.add_argument("--public",action="store_true")
    p.add_argument("--live-seconds",type=int,choices=(0,150,180),default=0)
    p.add_argument("--verify-audio-cue",action="store_true",help="If decoded playback is silent after 25s, play one quiet half-second Windows reference tone")
    p.add_argument("--check-self",action="store_true",help="Verify the packaged app rejects same-address pairing before TLS")
    a=p.parse_args()
    if a.verify_audio_cue and not (a.device and a.live_seconds): p.error("A live playback check requires the selected phone")
    run(a.archive.resolve(),a.sunshine.resolve(),a.device,a.public,a.live_seconds,a.verify_audio_cue,a.check_self)
