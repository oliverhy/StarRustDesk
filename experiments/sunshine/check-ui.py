"""Exercise the actual packed UI with a test double; never starts networking."""
from pathlib import Path
import re

from playwright.sync_api import expect, sync_playwright

HERE = Path(__file__).resolve().parent
PACKED = HERE.parents[1] / "entry/src/sunshineTest/resources/rawfile/sunshine/sesame-sunshine.html"
layout = re.search(r"<style>(.*?)</style>", (HERE / "approved-ui.html").read_text(encoding="utf-8"), re.S)
assert layout and layout.group(0) in PACKED.read_text(encoding="utf-8"), "approved UI styles changed"

with sync_playwright() as engine:
    browser = engine.chromium.launch()
    page = browser.new_page(viewport={"width": 375, "height": 780})
    errors = []
    navigation = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("request", lambda request: navigation.append(request.url)
            if request.url.startswith(("http://","https://","ws:","wss:")) else None)
    page.goto(PACKED.as_uri())
    expect(page.locator(".ss-lab")).to_be_hidden()
    page.locator('[data-action="start"]').click()
    expect(page.locator('main [role="alert"]')).to_be_visible()
    expect(page.locator(".ss-frame")).to_have_count(0)

    test_request=8000 if "const initialRelay8 = true;" in PACKED.read_text(encoding="utf-8") else 4000
    page.add_init_script("window.expectedRequest="+str(test_request)+";"+"""window.state = '1,0,0,0,0,0,0,0';
      window.halted=0; window.returned=0;
      window.SesameLink={
        prepared:()=>1, launch:(limit)=>limit===window.expectedRequest ? 1 : 0,
        snapshot:()=>window.state.split(',').length === 8 ? window.state + ',0,0,0,0,0' : window.state,
        frame:()=>{}, buttonSpot:()=>{}, event:()=>{}, halt:()=>window.halted++,
        back:()=>window.returned++
      };""")
    page.reload()
    page.locator('[data-action="home"]').click()
    assert page.evaluate("window.returned") == 1
    page.locator('[data-action="start"]').click()
    page.evaluate("window.state = '10,0,0,0,0,0,0,0'")
    expect(page.locator("li.is-active").get_by_text("局域网直连")).to_be_visible()
    page.evaluate("window.state = '1,0,0,0,0,0,0,0'")
    expect(page.locator("li.is-active").get_by_text("公网 UDP 打洞")).to_be_visible()
    page.evaluate("window.state = '2,0,0,0,0,0,0,0'")
    expect(page.locator("li.is-skipped")).to_have_count(2)
    page.evaluate("window.state = '5,2,0,0,0,0,0,1400'")
    expect(page.locator(".ss-frame")).to_have_count(0)
    page.evaluate("window.state = '5,3,101,722,2997,0,40,1400'")
    expect(page.locator("canvas[data-device-video]")).to_be_visible()
    page.locator('[data-action="info"]').click()
    expect(page.locator('[role="dialog"]').get_by_text("0.72 Mbps", exact=True)).to_be_visible()
    page.locator('[data-action="close"]').click()
    page.evaluate("window.state = '5,3,900,3500,2990,0,40,5650,5650,2,7504,0,8000'")
    page.wait_for_function("window.state.split(',').length===13")
    # Reopen after the native snapshot tick; never show the prototype's 1.8 as a real probe.
    page.wait_for_timeout(250)
    page.locator('[data-action="info"]').click()
    for value in ("8 Mbps","至少 7.50 Mbps（探测封顶 8.00 Mbps）","3.50 Mbps","5.65 Mbps"):
        expect(page.locator('[role="dialog"]').get_by_text(value,exact=True).first).to_be_visible()
    page.locator('[data-action="close"]').click()
    page.evaluate("window.sesameNativeSuspend()")
    expect(page.locator(".ss-frame")).to_have_count(0)
    assert page.evaluate("window.halted") == 1

    page.reload()
    page.locator('[data-action="start"]').click()
    page.evaluate("window.state = '12,0,0,0,0,0,0,0'")
    expect(page.get_by_role("heading", name="正在检测可用带宽", exact=True)).to_be_visible()
    expect(page.locator(".ss-frame")).to_have_count(0)
    page.evaluate("window.state = '11,2,0,0,0,0,0,30000'")
    expect(page.locator(".ss-frame")).to_have_count(0)
    page.evaluate("window.state = '11,3,101,16500,6000,0,10,30000,22400,2,28000,0,30000'")
    expect(page.locator("canvas[data-device-video]")).to_be_visible()
    page.locator('[data-action="info"]').click()
    expect(page.locator('[role="dialog"]').get_by_text("局域网直连", exact=True)).to_be_visible()
    expect(page.locator('[role="dialog"]').get_by_text("至少 28.00 Mbps（探测封顶 30.00 Mbps）", exact=True)).to_be_visible()
    expect(page.locator('[role="dialog"]').get_by_text("22.40 Mbps", exact=True)).to_be_visible()

    for native_failure in ("9,0,0,0,0,0,0,0", "5,4,0,0,0,0,0,1400"):
        page.reload()
        page.locator('[data-action="start"]').click()
        page.evaluate("value => { window.state = value; }", native_failure)
        expect(page.locator('main [role="alert"]')).to_be_visible()
        expect(page.locator(".ss-frame")).to_have_count(0)
        assert page.evaluate("window.halted") == 1

    # The paired application is independent of single-use USB ticket settings.
    # Earlier reload scripts also set up a single-use bridge; use a separate
    # page with only the paired bridge to avoid unspecified init script order.
    paired=browser.new_page(viewport={"width":375,"height":780})
    paired.on("pageerror",lambda e:errors.append(str(e)))
    paired.on("request",lambda r:navigation.append(r.url) if r.url.startswith(("http://","https://","ws:","wss:")) else None)
    paired.add_init_script("""window.SesameLink={mode:()=>1,prepared:()=>1,
        preferredVideoRate:()=>Number(sessionStorage.getItem('rate')||20000),
        saveVideoRate:n=>{sessionStorage.setItem('rate',String(n));return 1},
        launch:n=>{window.lastVideoRequest=n;return 1},snapshot:()=>window.nextResult||'1,0,0,0,0,0,0,0,0,0,0,0,0',
        frame:()=>{},buttonSpot:()=>{},event:()=>{},halt:()=>{}};""")
    paired.goto(PACKED.as_uri())
    expect(paired.locator('[data-action="prefs"]')).to_contain_text("20 Mbps")
    paired.locator('[data-action="prefs"]').click()
    expect(paired.locator('input[value="standard"]')).to_be_checked()
    paired.locator('input[value="custom"]').check()
    paired.locator('input[name="custom-rate"]').fill('51')
    paired.locator('[data-action="save-prefs"]').click()
    expect(paired.locator('[role="dialog"]')).to_be_visible()
    assert paired.evaluate("sessionStorage.getItem('rate')") is None
    paired.locator('input[name="custom-rate"]').fill('9')
    paired.locator('[data-action="save-prefs"]').click()
    paired.reload()
    expect(paired.locator('[data-action="prefs"]')).to_contain_text("9 Mbps")
    paired.locator('[data-action="prefs"]').click()
    paired.locator('input[value="standard"]').check()
    paired.locator('[data-action="save-prefs"]').click()
    paired.locator('[data-action="start"]').click()
    assert paired.evaluate("window.lastVideoRequest") == 20000
    paired.evaluate("window.nextResult='5,7,0,0,0,0,0,0,0,0,0,0,0'")
    expect(paired.get_by_role('heading',name='带宽不足，未按低码率启动')).to_be_visible()
    paired.reload()
    paired.locator('[data-action="start"]').click()
    paired.evaluate("window.nextResult='5,8,0,0,0,0,0,0,0,0,0,0,0'")
    expect(paired.get_by_role('heading',name='请更新 Windows 串流助手')).to_be_visible()
    assert not errors, errors
    assert not navigation, "packaged UI initiated network traffic"
    print("Sunshine packaged UI: approved CSS, native back, authorization, fallback, first frame, suspend and fail closed: OK")
