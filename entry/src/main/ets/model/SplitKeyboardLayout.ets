// "Picture above keyboard" layout for handheld remote control: the remote
// picture is fitted completely above a split line and the system IME owns the
// area below it. Pure geometry only, so it can be transpiled and exercised
// outside ArkUI. The switch is manual; no fold angle is observed.
export const SPLIT_KEYBOARD_OPTION: string = 'remote-split-keyboard';
// A crease must span (almost) the whole window width to divide it into halves.
export const SPLIT_KEYBOARD_CREASE_MIN_WIDTH_RATIO: number = 0.8;

export interface SplitKeyboardRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

// Window and crease rectangles are both in display pixels. Returns the top of
// the first horizontal crease that crosses the window, or -1 when there is none.
export function findHorizontalCreaseTopPx(windowRect: SplitKeyboardRect | undefined,
  creaseRects: SplitKeyboardRect[] | undefined): number {
  if (!windowRect || !Array.isArray(creaseRects)) return -1;
  const windowTop: number = Number(windowRect.top);
  const windowWidth: number = Number(windowRect.width);
  const windowHeight: number = Number(windowRect.height);
  if (!Number.isFinite(windowTop) || !Number.isFinite(windowWidth) || !Number.isFinite(windowHeight) ||
    windowWidth <= 0 || windowHeight <= 0) return -1;
  const windowBottom: number = windowTop + windowHeight;
  for (const crease of creaseRects) {
    if (!crease) continue;
    const top: number = Number(crease.top);
    const width: number = Number(crease.width);
    const height: number = Number(crease.height);
    if (!Number.isFinite(top) || !Number.isFinite(width) || !Number.isFinite(height)) continue;
    if (width <= height) continue;
    if (width < windowWidth * SPLIT_KEYBOARD_CREASE_MIN_WIDTH_RATIO) continue;
    if (top <= windowTop || top >= windowBottom) continue;
    return top;
  }
  return -1;
}

// Split line in page vp. A crease inside the page wins; otherwise half height.
export function splitKeyboardLineVp(creaseTopPx: number, windowTopPx: number, density: number,
  pageOriginY: number, fullPageHeight: number): number {
  const pageHeight: number = Number.isFinite(fullPageHeight) && fullPageHeight > 0 ? fullPageHeight : 0;
  const half: number = pageHeight / 2;
  if (!Number.isFinite(creaseTopPx) || creaseTopPx < 0 || !Number.isFinite(density) || density <= 0) return half;
  const windowTop: number = Number.isFinite(windowTopPx) ? windowTopPx : 0;
  const origin: number = Number.isFinite(pageOriginY) ? pageOriginY : 0;
  const line: number = (creaseTopPx - windowTop) / density - origin;
  if (!Number.isFinite(line) || line <= 0 || line >= pageHeight) return half;
  return line;
}

// Height available to the picture: the split line, or the IME top when higher.
export function splitKeyboardViewportHeight(lineVp: number, fullPageHeight: number, imeInsetVp: number): number {
  const pageHeight: number = Number.isFinite(fullPageHeight) && fullPageHeight > 0 ? fullPageHeight : 0;
  const line: number = Number.isFinite(lineVp) && lineVp > 0 ? lineVp : pageHeight / 2;
  const inset: number = Number.isFinite(imeInsetVp) && imeInsetVp > 0 ? imeInsetVp : 0;
  return Math.max(1, Math.min(line, pageHeight - inset));
}
