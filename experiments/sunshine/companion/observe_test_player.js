// Test-only. One visible HTML video; never reads pixels, audio, URLs or titles.
// Rows: callback Unix ms, submission Unix ms, media ms, presented frame count.
({ seconds, requireFullscreen=false }) => new Promise((resolve) => {
  const visible = v => {
    const r = v.getBoundingClientRect();
    return document.visibilityState === 'visible' && r.width > 200 && r.height > 100 &&
      r.right > 0 && r.bottom > 0 && r.left < innerWidth && r.top < innerHeight;
  };
  const candidates = [...document.querySelectorAll('video')].filter(visible);
  const v = candidates.length === 1 ? candidates[0] : null;
  // Wired Windows bench only: primary desktop origin is (0,0). Do not
  // keep attributing frames if the fullscreen test window moves/loses focus.
  const placed = () => !requireFullscreen || (document.fullscreenElement===v && document.hasFocus() &&
    Math.abs(window.screenX)<=2 && Math.abs(window.screenY)<=2);
  if (!v || !placed() || typeof v.requestVideoFrameCallback !== 'function' ||
      v.paused || v.seeking || v.playbackRate !== 1)
    return resolve({state:'not_one_playing_video'});
  const utc = t => Math.round((performance.timeOrigin + t) * 10) / 10;
  const rows = [];
  let done = false, id = 0, timer;
  function finish(state) {
    if (done) return;
    done = true; clearTimeout(timer); v.cancelVideoFrameCallback(id);
    for (const e of ['seeking','pause','emptied','ratechange','resize']) v.removeEventListener(e, changed);
    document.removeEventListener('visibilitychange', changed);
    document.removeEventListener('fullscreenchange', changed);
    window.removeEventListener('blur', changed);
    resolve({state, width:v.videoWidth, height:v.videoHeight, rows});
  }
  const changed = () => finish('player_changed');
  for (const e of ['seeking','pause','emptied','ratechange','resize']) v.addEventListener(e, changed);
  document.addEventListener('visibilitychange', changed);
  if (requireFullscreen) {
    document.addEventListener('fullscreenchange', changed);
    window.addEventListener('blur', changed);
  }
  function tick(now, m) {
    if (!v.isConnected || !visible(v) || !placed() || !Number.isSafeInteger(m.presentedFrames) ||
        !Number.isFinite(m.presentationTime) || !Number.isFinite(m.mediaTime) ||
        Math.abs(utc(now) - Date.now()) > 12 || rows.length >= 50000) return finish('invalid_clock_or_player');
    rows.push([utc(now), utc(m.presentationTime), Math.round(m.mediaTime*1000), m.presentedFrames]);
    id=v.requestVideoFrameCallback(tick);
  }
  timer=setTimeout(()=>finish('complete'), Math.min(660, Math.max(1, seconds))*1000);
  id=v.requestVideoFrameCallback(tick);
})
