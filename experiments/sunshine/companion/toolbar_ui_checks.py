"""Native toolbar checks on the USB phone; the Windows helper must refuse input.

Read only foreground UI nodes and tap only positively identified LOCAL controls.
No taps on the decoded video, remote keys, input grants or settings resets.
"""
import secrets
import subprocess
import tempfile
import time
from pathlib import Path
from PIL import Image
import windows_companion as wc


def keyed(rows,key):
    matches=[r for r in rows if key in (r.get("key"),r.get("resource-id"))]
    return matches[0] if len(matches)==1 else None


def snapshot(phone):
    # Retry only a read. Never repeat a tap whose result is unknown.
    for attempt in range(3):
        try: return phone.layout()
        except subprocess.TimeoutExpired:
            if attempt==2: raise RuntimeError("toolbar_local_tree_unavailable") from None
            time.sleep(.3)


def node(phone,key):
    for _ in range(4):
        r=keyed(snapshot(phone),key)
        if r is not None: return r
        time.sleep(.15)
    visible=[n.get("key","") for n in snapshot(phone)]
    wc.event("toolbar_failure_local_nodes="+",".join(k for k in visible if
        k.startswith(("sunshine-menu-","sunshine-detail-","glass-action-","glass-display-","glass-segment-"))))
    safe_key="".join(c.lower() if c.isascii() and c.isalnum() else "_" for c in key)
    raise RuntimeError("toolbar_missing_"+safe_key)


def crop_local(phone,d,rows):
    # Save only the local glass controls, and only if entirely outside video.
    video=keyed(rows,"sunshine-touch-surface")
    if not video: return
    vx,vy,vr,vb=d.box(video)
    regions={}
    for name,key in (("toolbar","sunshine-remote-toolbar"),("keyboard","sunshine-glass-menu")):
        row=keyed(rows,key)
        if not row: continue
        x,y,r,b=d.box(row)
        if r>x and b>y and (r<=vx or b<=vy or x>=vr or y>=vb):
            regions[name]=(x,y,r,b)
    if not regions: return
    target=Path(__file__).resolve().parents[1]/".generated"/"toolbar-acceptance"
    target.mkdir(parents=True,exist_ok=True)
    remote="/data/local/tmp/sesame-toolbar-"+secrets.token_hex(8)+".png"
    with tempfile.TemporaryDirectory() as directory:
        local=Path(directory)/"temporary.png"
        try:
            wc.require(phone.focused_id(),"toolbar_capture_focus_changed")
            wc.require("fail" not in phone.shell("uitest screenCap -p "+remote).lower(),"toolbar_capture_failed")
            wc.require("FileTransfer finish" in phone.command("file","recv",remote,str(local)),"toolbar_capture_receive_failed")
            with Image.open(local) as img:
                for name,bounds in regions.items():
                    if bounds[0]>=0 and bounds[1]>=0 and bounds[2]<=img.width and bounds[3]<=img.height:
                        img.crop(bounds).save(target/(name+".png"))
                        wc.event("toolbar_local_control_crop="+name)
        finally:
            phone.shell("rm -f -- "+remote)


def exercise(phone,d,server,details_only=False):
    wc.require(not server.allow_input and not server.input_fixture,"toolbar_requires_view_only_host")
    collapsed=bool(keyed(snapshot(phone),"sunshine-remote-control-handle"))
    if collapsed:
        phone.control("sunshine-remote-control-handle")
        if keyed(snapshot(phone),"sunshine-remote-control-handle"): phone.control("sunshine-remote-control-handle")
    def select(name): phone.own_tap(node(phone,name))
    def anchored(category):
        rows=snapshot(phone)
        button=keyed(rows,"sunshine-menu-"+category); panel=keyed(rows,"sunshine-glass-menu")
        wc.require(button and panel,"toolbar_anchor_nodes_missing")
        x,y,r,b=d.box(button); px,py,pr,pb=d.box(panel); cx=(x+r)/2
        wc.require(px<cx<pr and (pb<=y or py>=b),"toolbar_popup_overlaps_or_misses_button")
        pointer=keyed(rows,"sunshine-menu-pointer")
        if pointer:
            l,_,rr,_=d.box(pointer)
            delta=round(abs((l+rr)/2-cx))
            wc.require(delta<=max(5,(r-x)*.35),"toolbar_pointer_not_aligned")
            wc.event(f"toolbar_anchor={category} pointer_error_px={delta}")
        else: wc.event("toolbar_popup_aligned="+category)
        return rows
    def present_text(value):
        return any(value==r.get("text") for r in snapshot(phone))

    if not details_only:
        select("sunshine-menu-keyboard")
        rows=anchored("keyboard")
        node(phone,"glass-action-release"); node(phone,"glass-key-Shift")
        # A one-key last row still occupies one of three columns.
        mod1=d.box(node(phone,"glass-key-Ctrl")); mod4=d.box(node(phone,"glass-key-Win/Cmd"))
        wc.require(abs((mod1[2]-mod1[0])-(mod4[2]-mod4[0]))<=4,"toolbar_incomplete_key_row_widened")
        soft=d.box(node(phone,"glass-action-softKeyboard")); tab=d.box(node(phone,"glass-segment-tab-modifiers"))
        wc.require(soft[3]>soft[1] and soft[3]<=tab[1]+2,"toolbar_modifier_keyboard_action_clipped")
        crop_local(phone,d,rows)
        select("glass-segment-tab-function"); node(phone,"glass-key-F1")
        select("glass-segment-tab-more"); node(phone,"glass-key-Esc")
        wc.event("toolbar_keyboard_three_tabs_and_release_verified=1")
        select("sunshine-menu-view"); anchored("view")
        select("glass-zoom-in"); wc.require(present_text("125%"),"toolbar_zoom_in_did_not_apply")
        pan_action=node(phone,"glass-action-pan")
        wc.event("toolbar_pan_action_enabled="+str(pan_action.get("enabled","unknown")).lower())
        phone.own_tap(pan_action)
        pan=node(phone,"sunshine-local-pan")
        wc.require(not keyed(snapshot(phone),"sunshine-glass-menu") and phone.focused_id(),"toolbar_pan_focus_uncertain")
        x,y,r,b=d.box(pan); cx,cy=(x+r)//2,(y+b)//2
        # Positively identified local-only pan layer; helper refuses all input.
        describe=lambda item:item.get("description") or item.get("accessibilityDescription","")
        wc.require(r-x>100 and b-y>100 and describe(pan)=="画面居中","toolbar_pan_not_centered")
        before_box=node(phone,"sunshine-touch-surface").get("origBounds")
        phone.shell(f"uitest uiInput swipe {cx} {cy} {cx+(r-x)//7} {cy+(b-y)//12} 500")
        wc.require(describe(node(phone,"sunshine-local-pan"))=="画面已平移","toolbar_pan_did_not_move")
        after_box=node(phone,"sunshine-touch-surface").get("origBounds")
        if before_box and after_box: wc.require(before_box!=after_box,"toolbar_pan_surface_bounds_did_not_move")
        wc.event("toolbar_actual_local_pan_swipe_verified=1")
        select("sunshine-menu-view")
        select("glass-zoom-reset"); wc.require(present_text("100%"),"toolbar_zoom_reset_did_not_apply")
        wc.require(not keyed(snapshot(phone),"sunshine-local-pan"),"toolbar_pan_routing_not_restored")
        select("glass-zoom-out"); wc.require(present_text("75%"),"toolbar_zoom_out_did_not_apply")
        select("glass-zoom-reset")
        def fullscreen_label():
            rows=snapshot(phone)
            title=keyed(rows,"glass-action-fullscreen")
            options={"退出全屏","全屏"}
            if title and title.get("accessibilityText") in options: return title["accessibilityText"]
            found=options.intersection(n.get("text","") for n in rows)
            wc.require(len(found)==1,"toolbar_fullscreen_label_unknown")
            return found.pop()
        full=fullscreen_label()
        select("glass-action-fullscreen"); select("sunshine-menu-view")
        wc.require(full!=fullscreen_label(),"toolbar_fullscreen_did_not_change")
        select("glass-action-fullscreen"); select("sunshine-menu-view")
        wc.require(fullscreen_label()==full,"toolbar_fullscreen_did_not_restore")
        wc.event("toolbar_zoom_reset_and_fullscreen_roundtrip=1")
        select("glass-action-orientation"); node(phone,"glass-follow-system")
        wc.require(phone.focused_id(),"toolbar_back_focus_changed")
        phone.shell("uitest uiInput keyEvent Back"); time.sleep(.4)
        wc.require(not keyed(snapshot(phone),"sunshine-glass-menu") and not present_text("是否断开当前游戏串流？"),"toolbar_back_did_not_dismiss_menu")
    def input_rows():
        rows=snapshot(phone)
        if not keyed(rows,"sunshine-glass-menu") and not keyed(rows,"sunshine-detail-done"):
            # The real stream can reconnect. Reopen ONLY the identified local
            # button; never use a cached point on a newly rendered desktop.
            select("sunshine-menu-input")
            wc.event("toolbar_opened_input_from_bar=1")
        return anchored("input")
    select("sunshine-menu-input"); rows=input_rows()
    wc.require(any(r.get("text")=="现在只看画面" for r in rows),"toolbar_not_view_only")
    wc.require(keyed(rows,"glass-action-controlAccess") and keyed(rows,"glass-segment-mode-touch"),"toolbar_input_controls_missing")
    for detail,child in (("gestureHelp",None),("mouseSettings","sunshine-gain-1.5"),("keyboardSettings","sunshine-submit-close")):
        if not keyed(snapshot(phone),"glass-action-"+detail): input_rows()
        select("glass-action-"+detail)
        node(phone,"sunshine-detail-"+detail)
        if child: node(phone,child)
        select("sunshine-detail-done")
        wc.require(not keyed(snapshot(phone),"sunshine-detail-done"),"toolbar_local_done_did_not_close_dialog")
        node(phone,"glass-action-"+detail)
        wc.event("toolbar_detail_roundtrip="+detail)
    select("sunshine-menu-screens"); anchored("screens"); node(phone,"glass-display-0")
    wc.require(not keyed(snapshot(phone),"glass-action-displaySwipe"),"toolbar_advertised_an_unavailable_screen_action")
    select("sunshine-menu-more"); anchored("more")
    select("glass-action-sort"); node(phone,"sunshine-key-down-Esc"); select("sunshine-detail-done")
    select("glass-action-monitor"); node(phone,"sunshine-monitor-close")
    words=[n.get("text","") for n in snapshot(phone)]
    for prefix in ("实际帧率","初始视频请求","已应用视频码率","画面接收","累计视频帧缺口"):
        wc.require(any(t.startswith(prefix) for t in words),"toolbar_missing_live_metric")
    wc.event("toolbar_local_pan_three_input_details_sort_separate_rates=1")
    select("sunshine-monitor-close")
    wc.require(not keyed(snapshot(phone),"sunshine-monitor"),"toolbar_monitor_close_did_not_apply")
    select("sunshine-menu-disconnect")
    keep=[n for n in snapshot(phone) if n.get("text")=="继续远控"]
    wc.require(len(keep)==1,"toolbar_disconnect_keep_not_unique")
    phone.own_tap(keep[0]); node(phone,"sunshine-menu-view")
    wc.event("toolbar_disconnect_cancel_kept_stream=1")
    select("sunshine-collapse-controls"); node(phone,"sunshine-remote-control-handle")
    if not collapsed: select("sunshine-remote-control-handle"); node(phone,"sunshine-menu-keyboard")
    wc.require(not any(e.startswith("companion_input_granted") for e in server.events),"toolbar_unexpected_input")
    wc.event("toolbar_local_screens_modes_monitor_back_collapse_verified=1 remote_input_allowed=0")
