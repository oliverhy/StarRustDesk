"""Read only the owned app layout; send events only to the dedicated fixture."""
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

import check_device as ui
from input_fixture_windows import PROBE_TEXT
import windows_companion as wc

_shared_fixture=None


def open_fixture(scope):
    if _shared_fixture:
        _shared_fixture.reset()
        return _shared_fixture
    return Fixture(scope)


def use_shared_fixture(fixture):
    global _shared_fixture
    _shared_fixture=fixture


class Fixture:
    def __init__(self,scope):
        script=Path(__file__).with_name("input_fixture_windows.py")
        self.process=subprocess.Popen([sys.executable,"-B","-u",str(script)],stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,stdin=subprocess.PIPE,creationflags=subprocess.CREATE_NO_WINDOW)
        scope.callback(self.close)
        self.identity={}
        self.counts={}
        self.user=ctypes.WinDLL("user32",use_last_error=True)
        self.user.GetForegroundWindow.restype=wintypes.HWND
        self.thread=threading.Thread(target=self.read,daemon=True)
        self.thread.start()
        self.wait(lambda: bool(self.identity),"input_fixture_window_missing")
        if not self.is_focused(): wc.event("companion_input_waiting_for_owned_window_focus=1")
        self.wait(self.is_focused,"input_fixture_window_not_foreground",32)
        self.hwnd=int(self.identity["hwnd"])
        wc.event("companion_input_owned_window_ready=1")

    def read(self):
        for line in self.process.stdout:
            r=line.decode("ascii","ignore").strip()
            tag,_,blob=r.partition(" ")
            try: data=json.loads(blob)
            except ValueError: continue
            if isinstance(data,dict) and all(isinstance(v,int) for v in data.values()):
                if tag=="fixture": self.identity=data
                if tag=="counts": self.counts=data

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=4)
        self.thread.join(1)
        self.process.stdin.close()
        self.process.stdout.close()

    def reset(self):
        # Switching the phone's route and starting the Windows capture helper
        # can deactivate the fixture. This is before the media lease starts.
        self.await_focus(45)
        previous=self.counts.get("epoch",0)
        self.process.stdin.write(b"reset\n")
        self.process.stdin.flush()
        self.wait(lambda: self.counts.get("epoch",0)>previous,"input_fixture_reset_failed")

    def is_focused(self):
        return self.user.GetForegroundWindow()==self.identity.get("hwnd")

    def await_focus(self, seconds):
        # The Windows test runner may lose focus during route setup. Never
        # click/type in another application. Allow time to raise this fixture.
        if not self.is_focused():
            wc.event("companion_input_waiting_for_owned_window_focus=1")
            self.wait(self.is_focused,"input_fixture_focus_lost",seconds)

    def wait(self,pred,code,seconds=5):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            if pred(): return
            if self.process.poll() is not None: break
            time.sleep(.05)
        wc.require(False,code)


def owned_node(phone,key):
    matches=[n for n in phone.layout() if key in (n.get("key"),n.get("resource-id"))]
    wc.require(len(matches)==1,"input_test_ui_missing_"+key.removeprefix("sunshine-").replace("-","_"))
    return matches[0]


def close_ime(phone):
    # Return to the player, not the system launcher. Keyboard dismissal keeps
    # the same visible App page and the phone input lease.
    phone.control("sunshine-keyboard-launcher")
    wc.require(ui.has(phone,lambda n:"sunshine-menu-keyboard" in (n.get("key"),n.get("resource-id")),5),
               "input_test_keyboard_not_dismissed")


def exercise(phone,d,server,fixture):
    wc.require(ui.marker(phone,"ui_native_remote_controls_visible=1",8),"input_test_native_toolbar_missing")
    fixture.await_focus(12)
    phone.control("sunshine-menu-input")
    wc.require(ui.has(phone,lambda n:n.get("text")=="现在只看画面",5),"input_not_view_only_by_default")
    phone.control("glass-segment-mode-touch")
    phone.control("glass-action-controlAccess")
    wc.require(ui.marker(phone,"ui_companion_input_state=2",10),"input_test_grant_not_active")
    phone.control("sunshine-menu-input")

    if getattr(fixture,"release_only",False):
        check_held_key_disconnect(phone,server,fixture)
        return

    viewport=owned_node(phone,"sunshine-touch-surface")
    x1,y1,x2,y2=d.box(viewport)
    wc.require(phone.focused_id()==str(viewport.get("hostWindowId")) and fixture.is_focused(),
               "input_test_touch_focus_changed")
    wc.require(x2-x1>200 and y2-y1>100,"input_test_viewport_invalid")
    p=fixture.identity
    x=x1+round((x2-x1)*p["x"]/p["width"])
    y=y1+round((y2-y1)*p["y"]/p["height"])
    wc.require(x1<x<x2 and y1<y<y2,"input_test_touch_point_invalid")
    phone.shell(f"uitest uiInput click {x} {y}")
    fixture.wait(lambda: fixture.counts.get("clicks",0)>0 and fixture.counts.get("ups",0)>0,
                 "input_test_touch_not_received")
    wc.event("companion_input_real_touch_click_and_release=1")

    phone.control("sunshine-keyboard-launcher")
    wc.require(ui.marker(phone,"ui_remote_soft_keyboard_visible=1",6),"input_test_soft_keyboard_not_visible")
    ime=owned_node(phone,"sunshine-native-ime")
    wc.require(phone.focused_id()==str(ime.get("hostWindowId")) and fixture.is_focused(),
               "input_test_soft_keyboard_focus_changed")
    x1,y1,x2,y2=d.box(ime)
    wc.require(x2>x1 and y2>y1,"input_test_soft_keyboard_field_missing")
    # The OS injects this fixed test string into the real ArkUI IME field,
    # through the same onChange path as the software keyboard.
    phone.shell(f"uitest uiInput inputText {(x1+x2)//2} {(y1+y2)//2} {PROBE_TEXT}")
    fixture.wait(lambda: fixture.counts.get("text_ok")==1,"input_test_soft_text_not_received",7)
    wc.event("companion_input_native_ime_text_received_exactly=1")
    close_ime(phone)
    idle=getattr(fixture,"idle_seconds",0)
    if idle:
        start=time.monotonic()
        while time.monotonic()-start<idle:
            wc.require(fixture.is_focused(),"input_fixture_focus_lost")
            wc.require(not any(s.startswith("companion_input_closed ") for s in server.events),
                       "input_test_unexpected_channel_close")
            time.sleep(.15)
        wc.event(f"companion_input_idle_lane_still_open_s={idle}")
    check_held_key_disconnect(phone,server,fixture)


def check_held_key_disconnect(phone,server,fixture):
    fixture.await_focus(8)
    phone.control("sunshine-menu-keyboard")
    phone.control("glass-key-Shift")
    fixture.wait(lambda: fixture.counts.get("shift_held")==1 and fixture.counts.get("shift_down")==1,
                 "input_test_modifier_not_held")
    before=time.monotonic()
    server.input_test_blackhole.set()
    try:
        fixture.wait(lambda: fixture.counts.get("shift_held")==0 and fixture.counts.get("shift_up")==1,
                     "input_test_modifier_not_released",3)
        elapsed=round((time.monotonic()-before)*1000)
        wc.require(elapsed<=1200 and any("reason=watchdog" in n and "residual=0" in n
                   for n in server.events if n.startswith("companion_input_closed ")),
                   "input_test_watchdog_not_confirmed")
    finally:
        server.input_test_blackhole.clear()
    wc.require(ui.marker(phone,"ui_companion_input_state=4",5) and fixture.counts.get("shift_down")==1,
               "input_test_late_input_was_not_blocked")
    wc.event(f"companion_input_watchdog_release_ms={elapsed} replay=0 residual=0")
