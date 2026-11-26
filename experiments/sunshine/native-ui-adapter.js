  // The approved view, panels, and easing above are reused. Nothing in this
  // adapter can run the demo transport, produce a fake first frame, or
  // provision an endpoint. Only the native, independently authorized client can start.
  const bridge = () => globalThis.SesameLink;
  const fixedHost = { name:"游戏主机", address:"Sunshine · USB 授权隔离主机" };
  Object.assign(hosts[0], fixedHost);
  let transport = 0;
  let triedLan = false;
  let busy = false;
  let timerId = 0;
  let data = Array(12).fill(0);
  let boxKey = "";
  let geometryTick = 0;

  errors.fixture = ["测试环境未就绪", "当前没有可用的 USB 授权会话。", "测试版只连接隔离的 Sunshine 主机，请从 USB 测试端重新准备。", "info"];
  errors.stream = ["串流未能启动", "本次会话已安全停止，没有启用不加密的备用方式。", "请检查测试端后重试。", "monitor"];
  errors.offline = ["暂时无法连接", "可用的直连和中继路线均未建立，未开始串流。", "请检查主机和网络后重试。", "wifi-off"];
  stageCopy.lan = ["正在尝试局域网直连", "优先连接同一局域网内已配对的主机。", "radio"];
  stageCopy.direct = ["正在尝试公网 UDP 打洞", "先尝试与已配对主机建立加密直连。", "radio"];
  stageCopy.bandwidth = ["正在检测可用带宽", "在这条加密路线短测可跑稳的速率，再选择起流码率。", "gauge"];
  word.skipped = "不可达";
  const isPrepared = () => bridge()?.prepared() === 1;
  const isCompanion = () => bridge()?.mode?.() === 1;
  const initialRelay8 = false;
  if (initialRelay8) ui.limit=8;
  const validMbps = n => Number.isInteger(n) && n >= 2 && n <= 50;
  const selectedMbps = () => {
    const n = Number(bridge()?.preferredVideoRate?.()) / 1000;
    return validMbps(n) ? n : 20;
  };
  // USB single-use tickets keep their separate 2/4/8 menu. A remembered
  // choice belongs only to real paired sessions and never changes the route.
  if (isCompanion()) ui.limit = selectedMbps();
  errors.bandwidth = ["带宽不足，未按低码率启动", "当前线路不能提供所选的视频目标。", "可在串流偏好中明确选择较低的自定义码率，或切换网络后重试。", "gauge"];
  errors.hostProfile = ["请更新 Windows 串流助手", "已配对的助手未确认所选的视频编码目标。", "更新测试助手后重试，或在串流偏好中自行选择较低的码率。", "monitor"];
  const realHub = hubPanel;
  panels.hub = () => {
    if (isCompanion() && !busy) ui.limit = selectedMbps();
    const markup = realHub().replace("540p · 30 FPS · 请求上限",
      isCompanion() && ui.limit >= 20 ? "1080p · 60 FPS · 视频目标" : "自动选路 · 请求上限");
    if (isPrepared()) return isCompanion()
      ? markup.replace("Sunshine · USB 授权隔离主机", "Sunshine · 已配对 Windows 助手") : markup;
    return markup.replace(tag("已配对","is-good","link-2"), tag("等待 USB 授权","is-neutral"))
      .replace("Sunshine · USB 授权隔离主机", "本独立测试版不读取正式版连接");
  };
  const realConnecting = panels.connecting;
  panels.connecting = () => {
    let markup = realConnecting();
    const local = transport === 10 || transport === 11 || (transport === 12 && ui.route === "lan");
    const directStage = ui.directMissed ? "skipped" : ui.stage === "direct" ? "active" : "done";
    const route = local ? "局域网直连" : ui.route === "relay" ? "UDP 中继" : "公网 UDP 直连";
    markup = markup.replace(/(<div class="ss-lane-track"><strong>)[^<]+/, (_, open) => open + route);
    markup = markup.replace(step("UDP 直连", directStage), local
      ? step("局域网直连", transport === 10 ? "active" : "done")
      : (triedLan ? step("局域网直连", "skipped") : "") + step("公网 UDP 打洞", directStage));
    return markup.replace("只在网络不可达时自动尝试中继。", "仅网络不可达才换路线，身份或加密验证失败会停止。")
      .replace(/低带宽模式 · 中继转发上限 [^<]+ Mbps/, "加密中继 · 正在检测本次线路");
  };
  // Keep protocol types separate. The approved connection entry intentionally
  // never opens or reads the installed production app.
  const previewPlayer = playerPanel;
  panels.player = () => previewPlayer().replace(
    /<span class="ss-frame-tag">[\s\S]*?<\/span>/, "").replace("低带宽中继 · 已自动限制转发速率","加密中继 · 按实测带宽限速");
  const originalInfo = sheets.info[1];
  const displayRate = (kbps) => (kbps / 1000).toFixed(2) + " Mbps";
  const sampledLimit = () => {
    const [state,good,upper,cap] = data.slice(8);
    if (state === 2 && good) return `至少 ${displayRate(good)}（探测封顶 ${displayRate(cap)}）`;
    if (state === 3 && upper) return good
      ? `${displayRate(good)} 跑稳；${displayRate(upper)} 未跑稳`
      : `最低 ${displayRate(upper)} 档未跑稳`;
    const suffix = good ? `（已验证 ${displayRate(good)}）` : "";
    if (state === 4) return "主机供包受限，未测出上限" + suffix;
    return "暂未测出" + suffix;
  };
  sheets.info[1] = () => originalInfo()
    .replace("转发限速（含封装）", "本次探测上限（含封装）")
    .replace("此处为演示数值。", "带宽为起流前对这条路线的短测结果。")
    .replace(/<div><dt>画面规格<\/dt><dd>[^<]+<\/dd><\/div>/, "")
    .replace("</dl>", `<div><dt>可用带宽（短测）</dt><dd>${sampledLimit()}</dd></div>
      <div><dt>应用后的视频请求</dt><dd>${data[7] > 0 ? displayRate(data[7]) : "—"}</dd></div></dl>`);
  actions.add = () => {
    if (!busy && isCompanion()) bridge()?.manageCompanion?.();
    else if (!busy) toHub("本测试版仅使用 USB 授权、已经校验配对的主机。");
  };
  actions.paired = () => {}; // never auto-approve another identity in this test app
  const originalPrefs=sheets.prefs[1];
  sheets.prefs[1]=() => !isCompanion() ? originalPrefs() : `<section data-form="prefs">
    <fieldset><legend>游戏串流视频目标</legend><div class="ss-radio-row">
    <label class="ss-radio"><input type="radio" name="rate-mode" value="standard" ${ui.limit===20?"checked":""}>标准 · 1080p60 · 20 Mbps</label>
    <label class="ss-radio"><input type="radio" name="rate-mode" value="custom" ${ui.limit!==20?"checked":""}>自定义</label>
    </div><label>自定义码率（Mbps） <input name="custom-rate" type="number" min="2" max="50" step="1" value="${ui.limit}"></label></fieldset>
    <p class="ss-dim ss-small">默认请求 20 Mbps 视频。总带宽还需容纳声音、纠错和封装；标准档不会自动降为低码率。</p>
    ${notice("直连优先 · 仅网络故障转中继 · 强制加密", "note", "shield-check")}${btn("save-prefs","保存偏好","","primary fill")}</section>`;
  const saveOldPrefs=actions["save-prefs"];
  actions["save-prefs"]=() => {
    if (!isCompanion()) return saveOldPrefs();
    const standard=overlay.querySelector('input[name="rate-mode"]:checked')?.value==="standard";
    const field=overlay.querySelector('input[name="custom-rate"]');
    const n=standard?20:Number(field?.value);
    if (!validMbps(n)) {field?.reportValidity(); return;}
    if (bridge()?.saveVideoRate?.(n*1000)!==1) {toHub("偏好未保存，请重试");return;}
    ui.limit=n;toHub("串流偏好已保存");
  };
  actions["save-add"] = () => {};

  const rawMetrics = metrics;
  metrics = function () {
    const base = rawMetrics();
    return { ...base,
      path: transport === 11 ? "局域网直连" : transport === 4 ? "公网 UDP 直连" : base.path,
      ask: data[6] > 0 ? (data[6] / 1000).toString() : "—",
      wire: data[11] > 0 ? (data[11] / 1000).toString() : "—",
      received: data[2] > 0 ? (data[2] / 1000).toFixed(2) : "—",
      rtt: data[5] > 0 ? String(data[5]) : "—",
      fps: data[3] > 0 ? (data[3] / 100).toFixed(1) : "—", seq: String(data[4]) };
  };

  function reportFrame() {
    const node = ui.screen === "player" && !ui.sheet ? surface.querySelector(".ss-frame") : null;
    const w = window.innerWidth, h = window.innerHeight;
    const rect = node?.getBoundingClientRect();
    const args = !rect || rect.bottom < 0 || rect.top >= h
      ? [0,0,0,0] : [rect.x/w,rect.y/h,rect.width/w,rect.height/h];
    const key = args.map(x=>x.toFixed(5)).join(",");
    if (key !== boxKey) {
      boxKey = key;
      bridge()?.frame(...args);
    }
  }
  drawPreview = function (canvas) {
    canvas.dataset.deviceVideo = "1";
    // ResizeObserver does not fire for the approved page's translation.
    // Follow the same video slot during the entrance and at its final box.
    cancelAnimationFrame(geometryTick);
    const until = performance.now() + (reducedMotion.matches ? 0 : 350);
    const sync = (now) => {
      reportFrame();
      if (now < until && canvas.isConnected) geometryTick = requestAnimationFrame(sync);
    };
    geometryTick = requestAnimationFrame(sync);
  };
  new ResizeObserver(() => reportFrame()).observe(app);
  root.addEventListener("animationend", reportFrame);
  window.addEventListener("scroll", reportFrame, {passive:true});
  window.addEventListener("resize", reportFrame, {passive:true});
  const originalOpen = openSheet, originalDismiss = dismiss, originalRender = render;
  openSheet = (name) => { originalOpen(name); reportFrame(); };
  dismiss = (restoreFocus) => { originalDismiss(restoreFocus); reportFrame(); };
  const testButtonBox = () => {
    const button = surface.querySelector('[data-action="start"]');
    if (!button || !isPrepared() || ui.screen !== "hub" || ui.sheet) return;
    const r = button.getBoundingClientRect();
    bridge()?.buttonSpot((r.x+r.width/2)/innerWidth,(r.y+r.height/2)/innerHeight);
  };
  render = () => {
    originalRender();
    requestAnimationFrame(() => { reportFrame(); testButtonBox(); });
  };

  function end() {
    if (timerId) window.clearInterval(timerId);
    timerId = 0;
    if (busy) bridge()?.halt();
    busy = false;
  }
  const baseStop = stop;
  stop = () => { baseStop(); end(); };
  const fault = (kind) => { end(); fail(kind); reportFrame(); };
  function setPhase(phase) {
    if (ui.screen === "connecting" && ui.stage === phase) return;
    ui.screen = "connecting";
    ui.stage = phase;
    render();
    announce(stageCopy[phase][0]);
  }
  function updateReadout() {
    if (!busy) return;
    const status = bridge()?.snapshot();
    if (typeof status !== "string" || !/^\d+(,\d+){12}$/.test(status)) return;
    const next = status.split(",").map(Number);
    transport = next[0];
    data = next.slice(1);
    if (data[0] === 7) return fault("bandwidth");
    if (data[0] === 8) return fault("hostProfile");
    if (transport === 6) return fault("offline");
    if (transport === 7) return fault("fixture");
    if (transport === 9) return fault("identity");
    if (data[0] === 4) return fault("encryption");
    if (data[0] === 5) return fault("stream");
    if (data[0] === 6) {
      if (ui.screen === "player") {
        end();
        return toHub("本次加密串流已结束");
      }
      return fault("stream");
    }
    if (transport === 8) return fault("stream");
    if (transport === 10) {
      triedLan = true;
      ui.route = "lan";
      return setPhase("lan");
    }
    if (transport === 1) {
      ui.route = "direct";
      return setPhase("direct");
    }
    if (transport === 12) return setPhase("bandwidth");
    if ([2,3,5].includes(transport)) {
      ui.directMissed = true;
      ui.route = "relay";
    }
    if (transport === 2) return setPhase("fallback");
    if (transport === 3) return setPhase("relay");
    if (transport !== 4 && transport !== 5 && transport !== 11) return;
    if (transport === 11) { triedLan = true; ui.route = "lan"; }
    if (transport === 4) ui.route = "direct";
    ui.relayReady = transport === 5;
    if (data[0] < 2) return setPhase("secure");
    ui.verified = true;
    if (data[0] < 3 || data[1] < 1) return setPhase("frame");
    if (ui.screen !== "player") {
      ui.screen = "player";
      render();
      bridge()?.event("native_first_frame");
      announce(`${metrics().path}，强制加密画面已就绪`);
    } else {
      const stats = surface.querySelector(".ss-statline .ss-dim");
      const m = metrics();
      if (stats) stats.textContent = `${m.rtt} ms · ${m.fps} FPS`;
    }
  }
  launch = function () {
    if (busy) return;
    if (!isPrepared()) return fault("fixture");
    data = Array(12).fill(0);
    ui.notice = "";
    triedLan = false;
    ui.low = ui.directMissed = ui.relayReady = ui.verified = false;
    ui.route = "direct";
    transport = 1;
    if (bridge()?.launch(ui.limit * 1000) !== 1) return fault("fixture");
    busy = true;
    setPhase("direct");
    timerId = window.setInterval(updateReadout, 115);
  };
  actions.start = launch;
  actions.home = () => bridge()?.back();
  window.sesameNativeRefresh = () => { if (!busy && !ui.sheet) render(); };
  window.sesameNativeSuspend = () => {
    if (busy || ui.sheet) toHub(busy ? "已结束本次串流" : "");
  };
  window.sesameNativeBack = () => {
    if (ui.sheet) dismiss();
    else if (ui.screen === "player") actions.disconnect();
    else if (ui.screen === "connecting" || ui.screen === "error") actions.cancel();
    else if (ui.screen === "hub") actions.home();
    return true;
  };
