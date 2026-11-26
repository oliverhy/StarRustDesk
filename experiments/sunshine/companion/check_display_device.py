"""USB UI + real LAN video; no screenshots and the PC never enables input."""
from contextlib import ExitStack
import sys,time,re
import check_device as ui
import toolbar_ui_checks as tb
import windows_companion as wc

def run(device):
    win=wc.load_fixture(); d=win.d; phone=d.CoverageApp()
    wc.require(phone.hdc[-2:]==["-t",device],"unexpected_device")
    before=phone.debug_targets(); phone.idle_preflight(); ui.no_usb_forward(phone)
    pc,ip=win.lan.wifi_pair(phone)
    try:
        with ExitStack() as scope:
            host=wc.PhysicalBackend(scope)
            wc.require(len(host.screens)>=2,"no_secondary_screen")
            server=wc.Companion(pc,47837,wc.runtime_dir()/"windows-companion-state",host,seconds=120,
                                allowed_phone=ip,menu_fixture=True)
            scope.callback(server.close); server.start()
            ui.open_page(phone,d); wc.require(ui.marker(phone,"companion_saved_host_loaded=1"),"pairing_missing")
            phone.tap_start(*phone.button_spot())
            wc.require(ui.has(phone,lambda r:r.get("key","") in ("sunshine-remote-toolbar","sunshine-remote-control-handle"),28),"no_rendered_controls")
            for _ in range(2):
                if tb.keyed(tb.snapshot(phone),"sunshine-remote-control-handle"):
                    phone.control("sunshine-remote-control-handle")
            for target in list(range(1,min(3,len(host.screens))))+[0]:
                phone.own_tap(tb.node(phone,"sunshine-menu-screens"))
                wc.require(all(tb.keyed(tb.snapshot(phone),"glass-display-"+str(i)) for i in range(len(host.screens))),"screen_cards_missing")
                phone.own_tap(tb.node(phone,"glass-display-"+str(target)))
                end=time.monotonic()+32
                selected=rendered=False
                stages=set()
                while time.monotonic()<end:
                    raw=phone.shell("hilog -P "+phone.pid+" -T SesameSecureClient -z 600")
                    _,sep,after=raw.rpartition("display_stream_selected slot="+str(target))
                    if sep: selected=True
                    if selected and re.search(r"switch_timing phase=first_render ms=\d+",after): rendered=True
                    stages.update(re.findall(r"(?:secure_result=[a-z_]+(?: code=-?\d+)?|rtsp_stage=[a-z_]+ error=-?\d+|core_stage_failed=-?\d+ error=-?\d+|switch_timing phase=[a-z_]+ ms=\d+|display_stream_selected slot=\d+|decoder_setup_code=-?\d+ enc_video=\d enc_audio=\d)",raw))
                    if selected and rendered and host.active_display==target:
                        break
                    time.sleep(.25)
                else:
                    for stage in sorted(stages): wc.event("display_check_phase "+stage)
                    raise RuntimeError("selected_display_not_rendered")
                wc.require(host.host.capture_verified(),"encoder_not_active")
                wc.event(f"screen_acceptance selected={target+1} count={len(host.screens)} encrypted_render=1 input_granted=0")
            wc.require(not any("input_granted=1" in e for e in server.events),"input_unexpected")
    finally:
        phone.shell("aa force-stop "+d.APP); phone.shell("aa start -a EntryAbility -b "+d.APP)
        ui.no_usb_forward(phone); wc.require(phone.debug_targets()==before,"other_apps_changed")

if __name__=="__main__":
    try: run(sys.argv[1])
    except Exception as e:
        wc.event("display_check_failed="+(str(e) if re.fullmatch("[a-z_0-9]{3,90}",str(e)) else type(e).__name__))
        sys.exit(1)
