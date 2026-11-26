"""Real-screen acceptance: native App UI, Wi-Fi setup, no USB forwards.

USB is used only to tap our debug App and read sanitized counters. The
invitation simulates a local paste; it is never printed by the test process.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from pathlib import Path
from math import ceil
import re
import statistics
import subprocess
import threading
import time
import traceback

import windows_companion as wc

DIGEST_RE=re.compile(r"[0-9a-f]{64}")
DIRECTED=re.compile(r"ss1-(\d{1,3}\.){3}\d{1,3}-\d{4,5}-[0-9a-f]{64}-[0-9a-f]{64}")


def no_usb_forward(phone):
    data=phone.command("fport","ls")
    wc.require(not re.search(r"\btcp:(48331|33523|33510|48010)\b",data),"companion_usb_forward_still_present")


def open_page(phone,d):
    phone.shell("aa force-stop "+d.APP)
    wc.require("start ability successfully" in phone.shell("aa start -a EntryAbility -b "+d.APP),
               "companion_app_launch_failed")
    until=time.monotonic()+12
    phone.pid=None
    while time.monotonic()<until:
        pid=phone.shell("pidof "+d.APP)
        if re.fullmatch(r"[1-9][0-9]{0,7}",pid):
            phone.pid=pid
            if phone.focused_id():
                break
        time.sleep(.2)
    wc.require(phone.focused_id(),"companion_app_not_foreground")
    wc.event("companion_phone_foreground_ready=1")
    phone.tab(d.SETTINGS)
    phone.control(d.SWITCH)
    phone.tab(d.CONNECT)
    phone.control(d.ENTRY)
    phone.stream_opened=True
    wc.event("companion_phone_page_open=1")


def has(phone, test, seconds=8):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        try:
            if any(test(node) for node in phone.layout()): return True
        except (OSError,RuntimeError,ValueError,subprocess.SubprocessError):
            pass
        time.sleep(.3)
    return False


def marker(phone, value, seconds=24):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        try:
            rows=phone.shell("hilog -P "+phone.pid+" -T SesameSunshineUi -z 70")
            if any(row.endswith(value) for row in rows.splitlines()): return True
        except (OSError,RuntimeError,subprocess.SubprocessError):
            pass
        time.sleep(.35)
    return False


def input_invite(phone,d,code):
    wc.require(DIRECTED.fullmatch(code) is not None,"companion_test_invitation_invalid")
    rows=[n for n in phone.layout() if "sunshine-companion-invitation" in (n.get("key"),n.get("resource-id"))]
    wc.require(len(rows)==1,"companion_pairing_field_missing")
    n=rows[0]
    x1,y1,x2,y2=d.box(n)
    wc.require(phone.focused_id()==str(n.get("hostWindowId")),"companion_pairing_focus_changed")
    # One-use lab credential is sent only to this owned debug UI input.
    script=f"uitest uiInput inputText {(x1+x2)//2} {(y1+y2)//2} {code}"
    try:
        result=subprocess.run(phone.hdc+["shell",script],capture_output=True,timeout=34,
                              creationflags=subprocess.CREATE_NO_WINDOW)
    except subprocess.TimeoutExpired:
        raise RuntimeError("companion_invitation_ui_input_timeout") from None
    wc.require(result.returncode==0,"companion_invitation_ui_input_failed")
    wc.event("companion_phone_invitation_entered=1")
    time.sleep(.6)
    phone.control("sunshine-companion-pair")


def pair_ui(phone,d,pc,device,state,port):
    server=wc.Companion(pc,port,state,None,allowed_phone=device)
    server.start()
    try:
        wc.event("companion_pc_pair_listener_ready=1")
        code=server.invitation()
        wc.require(bool(code),"companion_test_pair_state_already_present")
        open_page(phone,d)
        wc.require(has(phone,lambda x:x.get("text")=="配对 Windows 电脑"),"companion_native_pairing_page_missing")
        wc.event("companion_pairing_panel_verified=1")
        bad=code.split("-")
        wc.require(len(bad)==5 and DIGEST_RE.fullmatch(bad[3]),"companion_test_pin_format")
        bad[3]=("1" if bad[3][0]=="0" else "0")+bad[3][1:]
        input_invite(phone,d,"-".join(bad))
        wc.event("companion_bad_certificate_attempt_started=1")
        wc.require(has(phone,lambda x:x.get("text")=="电脑身份不匹配，已停止。"),
                   "companion_bad_pin_ui_rejection_unconfirmed")
        wc.require("companion_enrolled=1" not in server.events,"companion_pin_failure_enrolled")
        wc.event("phone_rejected_incorrect_certificate_without_enrolling=1")
        input_invite(phone,d,code)
        wc.event("companion_correct_certificate_attempt_started=1")
        wc.require(marker(phone,"companion_pairing_saved=1"),
                   "companion_pair_and_secure_save_unconfirmed")
        wc.require("companion_enrolled=1" in server.events,"companion_enrollment_unconfirmed_on_pc")
        wc.event("phone_companion_pairing_saved_in_app=1")
    finally:
        server.close()


def watch_stream(phone, win, server, seconds, expected="lan", recorder=None, on_first_frame=None, require_high_sample=False,
                 retry_usb_reads=False, route_tap=None, startup_only=False):
    # UI exercise may take tens of seconds. Keep sampling throughout and join
    # before closing the lease/fixture. Only this one worker sends UI actions.
    with ThreadPoolExecutor(max_workers=1) as worker:
        return _watch_stream(phone,win,server,seconds,expected,recorder,on_first_frame,worker,require_high_sample,retry_usb_reads,route_tap,startup_only)


def split_window(rows,peaks):
    """Counters include startup. Attribute deltas to precisely (a, b]."""
    tail=[rows[t] for t in sorted(rows) if t>=8000]
    wc.require(len(tail)>=12,"companion_phone_frame_window_missing")
    a,b=tail[0],tail[-1]
    complete=all(v[0] in peaks and 0<v[0]-p[0]<=1700 for p,v in zip(tail,tail[1:]))
    return tail,b[5]-a[5],b[7]-a[7],max((peaks[v[0]] for v in tail[1:]),default=0) if complete else None


AUTH_MARKERS=frozenset(('companion_wifi_udp_authenticated=1','companion_wan_direct_authenticated=1',
                        'companion_wan_relay_authenticated=1'))


def route_proofs(raw):
    return {msg for line in raw.splitlines() if (msg:=line.partition('SesameWanProbe: ')[2].strip()) in AUTH_MARKERS}

class RouteTap:
    """Listen before starting this test; keep only exact native path-auth events."""
    def __init__(self, phone):
        wc.require(bool(re.fullmatch(r'[1-9][0-9]{0,7}',phone.pid)),'invalid_lan_observer_pid')
        self.cmd="hilog -P "+phone.pid+" -T SesameWanProbe -e 'companion_.*_authenticated=1'"
        wc.require(not route_proofs(phone.shell(self.cmd+' -x')),'lan_observer_pid_has_previous_route')
        self.events=set()
        self.lock=threading.Lock()
        self.proc=subprocess.Popen(phone.hdc+['shell',self.cmd],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
        self.worker=threading.Thread(target=self._read,daemon=True)
        self.worker.start()

    def _read(self):
        for line in self.proc.stdout:
            events=route_proofs(line.decode('utf-8','replace'))
            if events:
                with self.lock:self.events.update(events)

    def snapshot(self):
        with self.lock:return set(self.events)

    def close(self):
        if self.proc.poll() is None:self.proc.terminate()
        try:self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=3)
        self.worker.join(2)
        if not self.worker.is_alive():self.proc.stdout.close()


def retry_lan_diagnostic_read(enabled,route,markers,consecutive,total):
    return bool(enabled and route=='lan' and consecutive<=2 and total<=3 and
                {'companion_wifi_udp_authenticated=1','ui_player_first_decoded_frame=1'}<=markers)


def _watch_stream(phone,win,server,seconds,expected,recorder,on_first_frame,worker,require_high_sample=False,retry_usb_reads=False,route_tap=None,startup_only=False):
    rows={}
    peaks={}
    action=None
    native=set()
    requested=set()
    probe=set()
    first=None
    missed=consecutive=0
    deadline=time.monotonic()+seconds+25
    proof_deadline=time.monotonic()+30
    while time.monotonic()<deadline:
        if route_tap is not None:
            for v in route_tap.snapshot()-native:
                wc.event('phone_'+v);native.add(v)
        if require_high_sample and "companion_relay_capacity_plan wire_kbps=1800 video_cap_kbps=1400" in server.events:
            # End this benchmark only. Never override the authenticated path's
            # decision or count another five minutes of fallback as a high run.
            raise RuntimeError("high_sample_unavailable_fallback_preserved")
        if action and action.done(): action.result()
        server.backend.host.scan(.15)
        try:
            raw=phone.shell("hilog -P "+phone.pid+" -T SesameSecureClient,SesameSunshineUi,SesameWanProbe -z 140")
        except subprocess.TimeoutExpired:
            # The USB diagnostics channel may be busy with a native layout
            # dump. A failed read is never evidence of a rendered frame.
            missed+=1;consecutive+=1
            if retry_lan_diagnostic_read(retry_usb_reads,expected,native,consecutive,missed):
                wc.event(f'lan_usb_diagnostic_timeout total={missed} consecutive={consecutive}')
                continue
            if not on_first_frame: raise
            continue
        consecutive=0
        if recorder: recorder.observe(raw)
        # Intense frame diagnostics can evict a one-off route marker from a
        # mixed-tag tail. This is the same freshly restarted App PID and the
        # same original native authentication event, not an inferred route.
        if recorder and expected=='lan' and not native.intersection(AUTH_MARKERS) and time.monotonic()<proof_deadline:
            try:
                proof=phone.shell("hilog -P "+phone.pid+" -T SesameWanProbe -e 'companion_.*_authenticated=1' -x")
            except subprocess.TimeoutExpired:proof=''
            for v in route_proofs(proof)-native:
                wc.event('phone_'+v);native.add(v)
        for row in raw.splitlines():
            for value in ("ui_local_layout_kept_during_video_restart=1","ui_local_view_pan_enabled=1","ui_local_view_pan_enabled=0"):
                if row.endswith(value) and value not in native:
                    wc.event("phone_"+value); native.add(value)
            key=row.partition("SesameSecureClient: ")[2]
            m=win.f.REPORT.fullmatch(key)
            if m: rows[int(m[1])]=tuple(map(int,m.groups()))
            if m:=re.fullmatch(r"render_window ms=(\d+) peak_ms=(\d+)",key):
                peaks[int(m[1])]=int(m[2])
            if m:=re.fullmatch(r"input_lane_end phase=[a-z_]+ replies=\d+ last_reply_ms=\d+ peak_tick_ms=\d+ peak_loop_ms=\d+",key):
                if key not in native:
                    wc.event("phone_"+key)
                    native.add(key)
            tests=("companion_encrypted_setup_ready=1","ui_player_first_decoded_frame=1",
                   "companion_narrow_fixed_profile=1","companion_narrow_repair_floor=1",
                   "companion_fresh_frame_recovery=1","quality_full_hd_wan_hold_upshift=1",
                   "decoder_setup_code=0 enc_video=1 enc_audio=1","companion_wifi_udp_authenticated=1",
                   "companion_lan_to_public=1","companion_cellular_binding_verified=1","companion_wan_direct_attempt=1",
                   "companion_wan_direct_no_reply=1","companion_wan_relay_attempt=1","companion_wan_direct_authenticated=1",
                   "companion_wan_relay_authenticated=1","companion_wan_tls_and_pair_verified=1",
                   "secure_result=secure_phone_decode_completed")
            for value in tests:
                if row.endswith(value) and value not in native:
                    wc.event("phone_"+value)
                    native.add(value)
                    if value=="ui_player_first_decoded_frame=1" and on_first_frame:
                        action=worker.submit(on_first_frame)
                    if recorder and ((expected=="direct" and value=="companion_wan_relay_authenticated=1") or
                                     (expected=="relay" and value=="companion_wan_direct_authenticated=1")):
                        raise RuntimeError("companion_soak_wrong_route_before_playback")
            if match:=re.search(r"\b(?:companion_route_result|secure_result)=[a-z_]+(?: code=-?\d+)?$",row):
                if match[0] not in native:
                    wc.event("phone_"+match[0])
                    native.add(match[0])
            if match:=re.search(r"\bbandwidth_video requested_kbps=\d+ applied_kbps=\d+$",row):
                if match[0] not in requested:
                    wc.event("phone_"+match[0])
                    requested.add(match[0])
            if match:=re.search(r"\bbandwidth_result state=\d+ good_kbps=\d+ unstable_kbps=\d+ cap_kbps=\d+$",row):
                if match[0] not in probe:
                    wc.event("phone_"+match[0])
                    probe.add(match[0])
            if match:=re.search(r"\b(?:rtsp_stage=[a-z_]+ error=-?\d+|core_stage_failed=\d+ error=-?\d+|"
                                r"direct_path_diag tx=\d+ tx_errors=\d+ rx=\d+ source_filtered=\d+ "
                                r"non_handshake=\d+ candidate_rx=\d+ receive_network_errors=\d+ authenticated=[01])$",row):
                if match[0] not in probe:
                    wc.event("phone_"+match[0])
                    probe.add(match[0])
        if rows and first is None:
            rendered=[t for t,v in rows.items() if v[3]]
            if rendered: first=min(rendered)
        if "secure_result=secure_phone_decode_completed" in native:
            break
        if any("secure_result=" in x for x in native): break
        if any(x.startswith("companion_route_result=") and x!="companion_route_result=companion_session_ended"
               for x in native): break
        time.sleep(1.2 if recorder else .55)
    if action: action.result()
    wc.require({"companion_encrypted_setup_ready=1","decoder_setup_code=0 enc_video=1 enc_audio=1",
                "ui_player_first_decoded_frame=1",
                "secure_result=secure_phone_decode_completed"}.issubset(native),
               "companion_verified_encrypted_playback_missing")
    flags={"lan":"companion_wifi_udp_authenticated=1","direct":"companion_wan_direct_authenticated=1",
           "relay":"companion_wan_relay_authenticated=1"}
    matched=[path for path,value in flags.items() if value in native]
    wc.require(len(matched)==1,"companion_route_selection_unconfirmed")
    route=matched[0]
    wc.require(route==expected or (route in ("direct","relay") and expected=="public"),"companion_unexpected_media_route")
    if route=="lan":
        wc.require("companion_wan_direct_attempt=1" not in native,"companion_lan_should_not_attempt_public")
        pc_verified="companion_host_udp_authenticated=1"
    else:
        wc.require({"companion_lan_to_public=1","companion_cellular_binding_verified=1",
                    "companion_wan_direct_attempt=1","companion_wan_tls_and_pair_verified=1"}.issubset(native),
                   "companion_cellular_authorization_unconfirmed")
        if route=="relay":
            wc.require({"companion_wan_direct_no_reply=1","companion_wan_relay_attempt=1"}.issubset(native),
                       "companion_no_automatic_relay_transition")
        else:
            wc.require("companion_wan_relay_attempt=1" not in native,"companion_direct_should_not_use_relay")
        high=route=="relay" and getattr(server,"high_relay",False)
        standard=getattr(server,"standard_wan",False)
        ceiling=1400
        if high or standard:
            plans=[m for row in server.events if (m:=re.fullmatch(
                r"companion_relay_capacity_plan wire_kbps=(\d+) video_cap_kbps=(\d+)",row))]
            wc.require(bool(plans),"companion_high_relay_budget_not_confirmed")
            wire,ceiling=map(int,plans[-1].groups())
            wc.require(1800<=wire<=(30000 if standard else 8000) and 1400<=ceiling<=wire*8//10,
                       "companion_high_relay_budget_outside_policy")
        if standard:
            wc.require(requested=={"bandwidth_video requested_kbps=20000 applied_kbps=20000"},
                       "standard_requested_applied_mismatch")
        wc.require(bool(requested) and all(all(int(x)<=ceiling for x in re.findall(r"\d+",value)) for value in requested),
                   "companion_public_video_budget_not_confirmed")
        if server.backend.public_profile:
            suffix=" cap_kbps="+str(30000 if standard else 8000 if high else 1800)
            wc.require(any(x.startswith("bandwidth_result ") and x.endswith(suffix) for x in probe) and
                       any(x.startswith("companion_host_bandwidth_result ") and x.endswith(suffix) for x in server.events),
                       "companion_compare_wire_budget_not_confirmed")
        if server.backend.peak_shave:
            wc.require({"companion_narrow_fixed_profile=1","companion_narrow_repair_floor=1"}.issubset(native) and
                       requested=={"bandwidth_video requested_kbps=500 applied_kbps=500"},
                       "companion_narrow_profile_not_confirmed")
        if server.fresh_recovery:
            wc.require("companion_fresh_frame_recovery=1" in native and
                       "companion_host_fresh_recovery=1" in server.events,
                       "companion_fresh_frame_recovery_missing")
        if server.backend.public_profile in wc.FULL_HD and not standard:
            wc.require("quality_full_hd_wan_hold_upshift=1" in native,"full_hd_client_policy_unconfirmed")
        pc_verified=f"companion_host_{route}_authenticated=1"
    wc.require(pc_verified in server.events and
               "companion_setup_served=1" in server.events and server.backend.host.capture_verified(),
               "companion_desktop_actual_capture_unconfirmed")
    if startup_only:
        # A startup result is never a cadence/payload acceptance result.
        wc.require(route=="lan" and seconds==20 and not server.allow_input and server.wan is None and
                   requested=={"bandwidth_video requested_kbps=20000 applied_kbps=20000"},
                   "startup_rate_or_route_not_verified")
        return route
    if recorder and (seconds>50 or len([e for e in recorder.epochs if e["samples"]])!=1):
        # Never subtract samples from two decoder lifetimes; the recorder
        # reports separately measured epochs for adaptive quality changes.
        return route
    tail,steady_gaps,steady_errors,steady_peak=split_window(rows,peaks)
    wc.require(first is not None,"companion_phone_frame_window_missing")
    a,b=tail[0],tail[-1]
    span=(b[0]-a[0])/1000
    wc.require(span>10 and b[3]>a[3],"companion_real_screen_sustained_frames_missing")
    rtts=sorted(v[9] for v in tail if v[9]>0)
    timing=(f" rtt_median_ms={statistics.median(rtts):g} rtt_p95_ms={rtts[ceil(len(rtts)*.95)-1]}"
            if rtts else " rtt_unavailable=1")
    windows=[]
    for begin,end in zip(tail,tail[1:]):
        if 700<=end[0]-begin[0]<=1700 and end[3]>=begin[3] and end[4]>=begin[4]:
            sec=(end[0]-begin[0])/1000
            windows.append(((end[3]-begin[3])/sec,(end[4]-begin[4])*8e-6/sec,end[5]-begin[5]))
    wc.event(f"companion_playback route={route} sample_s={span:.2f} rendered_fps={(b[3]-a[3])/span:.2f} "
             f"payload_mbps={(b[4]-a[4])*8e-6/span:.3f} frame_gaps={steady_gaps} render_errors={steady_errors} "
             f"first_rendered_sample_ms={first} steady_peak_ms={steady_peak if steady_peak is not None else 'unknown'} "
             f"sample_from_ms={a[0]} gaps_before_sample={a[5]} session_frame_gaps={b[5]} "
             f"session_render_errors={b[7]} session_peak_ms={b[8]}"+timing)
    if windows:
        rates=sorted(v[1] for v in windows)
        wc.event(f"companion_windows route={route} count={len(windows)} "
                 f"fps_min={min(x[0] for x in windows):.2f} gapfree={sum(x[2]==0 for x in windows)} "
                 f"payload_p10_mbps={rates[max(0,ceil(len(rates)*.10)-1)]:.3f} "
                 f"payload_p90_mbps={rates[ceil(len(rates)*.90)-1]:.3f}")
    return route


def main():
    p=argparse.ArgumentParser()
    p.add_argument("--pair-only",action="store_true")
    p.add_argument("--use-saved",action="store_true")
    p.add_argument("--saved-ui-only",action="store_true")
    panel=p.add_mutually_exclusive_group()
    panel.add_argument("--check-input",action="store_true")
    panel.add_argument("--check-toolbar",action="store_true")
    p.add_argument("--details-only",action="store_true")
    p.add_argument("--port",type=int,default=47837)
    args=p.parse_args()
    wc.require(not args.details_only or args.check_toolbar,"details_requires_toolbar")
    wc.require(not (args.check_input or args.check_toolbar) or (args.use_saved and not args.saved_ui_only and not args.pair_only),
               "input_check_requires_preserved_pair")
    win=wc.load_fixture()
    d=win.d
    phone=d.CoverageApp()
    before=phone.debug_targets()
    phone.idle_preflight()
    no_usb_forward(phone)
    pc,device=win.lan.wifi_pair(phone)
    state=wc.runtime_dir()/"windows-companion-state"
    try:
        if args.saved_ui_only:
            open_page(phone,d)
            pid=phone.pid
            web_confirmed=False
            for _ in range(9):
                if (phone.shell("pidof "+d.APP)!=pid):
                    wc.event("companion_process_ended_during_saved_test=1")
                    break
                try:
                    layout=phone.layout()
                    visible=any(x.get('type','').lower() in ('web','webview') for x in layout)
                    web_confirmed=web_confirmed or visible
                    wc.event(f"companion_view paired_header={int(any(x.get('text')=='配对 Windows 电脑' for x in layout))} "
                             f"web={int(visible)}")
                except (RuntimeError,OSError,ValueError,subprocess.SubprocessError):
                    wc.event("companion_view_unavailable=1")
                time.sleep(.55)
            raw=phone.shell("hilog -P "+pid+" -z 1800")
            for line in raw.splitlines():
                for fixed in ("companion_saved_host_loaded=1","ui_approved_page_loaded=1",
                              "JsError","AppCrash","SIGSEGV","SIGABRT","SIGKILL","ArkUIError","FATAL"):
                    if fixed in line:
                        wc.event("companion_diagnostic_"+fixed)
                if m:=re.search(r"\b(?:ErrorType|Error name|ErrorName):\s*([A-Za-z][A-Za-z0-9_-]{2,60})",line):
                    wc.event("companion_error_name="+m[1])
                if "WebviewController must be associated with a Web component" in line:
                    wc.event("companion_ui_fault=web_controller_not_attached")
                if m:=re.search(r"\b(?:Error code|ErrorCode):\s*(-?\d{1,10})\s*$",line,re.I):
                    wc.event("companion_ui_error_code="+m[1])
                if m:=re.search(r"\b(SunshineStreamPage\.ets|SunshineCompanionStore\.ets):(\d{1,5})",line):
                    wc.event("companion_ui_stack="+m[0])
            wc.require(web_confirmed and phone.shell("pidof "+d.APP)==pid,"companion_saved_ui_not_stable")
            return
        if not args.use_saved: pair_ui(phone,d,pc,device,state,args.port)
        if args.pair_only: return
        with ExitStack() as scope:
            backend=wc.PhysicalBackend(scope)
            fixture=None
            if args.check_input:
                import input_ui_checks as control
                fixture=control.open_fixture(scope)
            seconds=180 if args.details_only else 300 if args.check_toolbar else 50 if fixture else 34
            server=wc.Companion(pc,args.port,state,backend,seconds=seconds,allowed_phone=device,
                                input_fixture=fixture.hwnd if fixture else 0,menu_fixture=args.details_only)
            scope.callback(server.close)
            wc.require(not server.invitation(),"companion_pc_pairing_not_persisted")
            server.start()
            open_page(phone,d)
            wc.require(marker(phone,"companion_saved_host_loaded=1") and
                       has(phone,lambda row:row.get("type","").lower() in ("web","webview"),seconds=25),
                       "companion_saved_host_not_loaded_after_app_restart")
            wc.event("companion_restarted_pc_and_phone_loaded_paired_state=1")
            x,y=phone.button_spot()
            phone.tap_start(x,y)
            action=None
            if fixture: action=lambda: control.exercise(phone,d,server,fixture)
            if args.check_toolbar:
                import toolbar_ui_checks
                action=lambda: toolbar_ui_checks.exercise(phone,d,server,details_only=args.details_only)
            watch_stream(phone,win,server,seconds,on_first_frame=action)
            no_usb_forward(phone)
            wc.event("companion_real_screen_and_saved_reconnect_verified=1 usb_forward=0 "+
                     ("capture_policy=local_controls_only" if args.check_toolbar else "screenshots_taken=0"))
    finally:
        try:
            phone.shell("aa force-stop "+d.APP)
            phone.shell("aa start -a EntryAbility -b "+d.APP)
        finally:
            no_usb_forward(phone)
            wc.require(phone.debug_targets()==before,"other_apps_changed")
            wc.event("companion_two_moonlights_and_test_sibling_unchanged=1")


if __name__=="__main__":
    try: main()
    except (OSError,RuntimeError,ValueError,subprocess.SubprocessError) as exc:
        value=str(exc)
        wc.event("companion_device_failed="+(value if re.fullmatch(r"[a-z_]{4,75}",value) else type(exc).__name__))
        failure=exc
        for _ in range(4):
            frames=traceback.extract_tb(failure.__traceback__)[-4:]
            fixed=str(failure) if re.fullmatch(r"[a-z_]{4,75}",str(failure)) else type(failure).__name__
            wc.event("test_failure_origin="+fixed+" "+" ".join(Path(f.filename).name+":"+str(f.lineno) for f in frames))
            failure=failure.__cause__ or failure.__context__
            if failure is None: break
        raise SystemExit(4)
