// Visual contract extracted from the approved 2026-10-13 six-menu prototype.
// Dimensions are logical vp. Only large fonts/small windows override the baseline.
export class RemoteGlassMenuState {
  category: string = 'screens';
  items: string[] = [];
  keyboardItems: string[] = [];
  displayCount: number = 1;
  currentDisplay: number = 0;
  displaySwipe: boolean = true;
  inputMode: string = 'mouse';
  virtualMouse: boolean = false;
  clipboard: boolean = false;
  pan: boolean = false;
  edgePan: boolean = false;
  zoom: number = 100;
  fullscreen: boolean = false;
  pip: boolean = false;
  recording: boolean = false;
  privacy: boolean = false;
  privacyPending: boolean = false;
  monitor: boolean = false;
  transferBusy: boolean = false;
  canSendCtrlAltDel: boolean = false;
  modifiers: number = 0;
  keyboardTab: string = 'more';
  keyboardOpen: boolean = false;
  desktop: boolean = false;
  desktopViewMode: string = 'adaptive';
  desktopPercent: number = 100;
  desktopCustomPercent: number = 100;
  immersive: boolean = false;
  windowBusy: boolean = false;
  followSystem: boolean = true;
  orientation: string = 'auto';
  projection: boolean = false;
  orientationError: string = '';
}

export interface RemoteGlassMenuMetrics {
  width: number;
  height: number;
  rowHeight: number;
  contentHeight: number;
  bodyHeight: number;
  padding: number;
  headerHeight: number;
  segmentHeight: number;
  screenHeight: number;
  displayWidth: number;
  footerHeight: number;
  stacked: boolean;
}

export interface RemoteGlassMenuPlacement {
  x: number;
  y: number;
  arrowX: number;
  arrowAbove: boolean;
  arrowVisible: boolean;
}

export function glassMenuMetrics(state: RemoteGlassMenuState, width: number, height: number,
  fontScale: number, labelWidth: number = 0, measuredFooterHeight: number = 0): RemoteGlassMenuMetrics {
  const vw = Number.isFinite(width) && width > 0 ? width : 360;
  const vh = Number.isFinite(height) && height > 0 ? height : 640;
  const scale = Number.isFinite(fontScale) ? Math.max(1, Math.min(3.2, fontScale)) : 1;
  const margin = Math.min(8, Math.min(vw, vh) / 4);
  const padding = 12;
  const baselineRow = state.category === 'more' ? 25 : state.category === 'keyboard' ? 28 : state.category === 'view' ? 32 : 36;
  const rowHeight = Math.ceil(baselineRow + 22 * (scale - 1));
  const headerHeight = Math.ceil(Math.max(26, 20 * scale + 6));
  const segmentHeight = Math.ceil((state.category === 'keyboard' ? 32 : 40) + 24 * (scale - 1));
  const screenHeight = Math.ceil(Math.max(62, 28 * scale + 34));
  const displayWidth = Math.ceil(70 + 50 * (scale - 1));
  const footerHeight = Math.ceil(Math.max(18 * scale,
    Number.isFinite(measuredFooterHeight) ? measuredFooterHeight : 0));
  let preferredWidth = state.category === 'screens' ? Math.max(224, Math.min(3, Math.max(1, state.displayCount)) * 76 + 24) :
    state.category === 'more' ? 204 : state.category === 'orientation' ? 244 : 224;
  preferredWidth += Math.max(0, scale - 1) * 74;
  if (state.desktop && state.category === 'view') preferredWidth = Math.max(248, preferredWidth);
  if (Number.isFinite(labelWidth) && labelWidth > 0) preferredWidth = Math.max(preferredWidth, labelWidth + 94);
  const menuWidth = Math.max(1, Math.min(Math.ceil(preferredWidth), 380, vw - margin * 2));
  const stacked = menuWidth - padding * 2 < (state.category === 'orientation' ? 150 : 162) * scale;
  let content = headerHeight;
  switch (state.category) {
    case 'screens': content += screenHeight + 8 + rowHeight; break;
    case 'input': content += (stacked ? segmentHeight * 2 + 4 : segmentHeight) + 8 +
      Math.max(0, state.items.length - 1) * rowHeight + 2 * rowHeight + 9; break;
    case 'view': content += (state.items.length - (state.items.includes('zoomOut') ? 1 : 0)) * rowHeight + 9;
      if (state.desktop) content += segmentHeight + rowHeight * (state.desktopViewMode === 'custom' ? 5 : 4) + 9;
      break;
    case 'more': content += (state.items.length + 2) * rowHeight + 18 + 20; break;
    case 'keyboard': content += segmentHeight + 8;
      if (state.keyboardTab === 'more') {
        // The initial viewport matches the prototype. Additional legacy keys
        // remain available by scrolling without making the first view taller.
        content += Math.ceil(12 / (stacked ? 2 : 3)) * (rowHeight + 4) +
          2 * (rowHeight + 4) + 9;
      } else if (state.keyboardTab === 'function') content += Math.ceil(12 / (stacked ? 2 : 3)) * (rowHeight + 4) + 9;
      else content += (stacked ? 4 : 2) * (rowHeight + 4) + rowHeight + 9;
      break;
    case 'orientation':
      // Toggle bottom margin and description top margin are separate, including
      // the follow-system branch where there are no direction segments.
      if (!state.projection) content += rowHeight + 10;
      if (!state.followSystem || state.projection) content += stacked ? segmentHeight * 3 + 4 : segmentHeight;
      content += 10 + footerHeight + (state.orientationError ? Math.max(rowHeight * 2, Math.ceil(72 * scale)) : 0);
      break;
  }
  const contentHeight = content;
  const maxHeight = Math.max(1, vh - margin * 2 - 8);
  const menuHeight = Math.min(contentHeight + padding * 2 + 2, maxHeight,
    Math.max(headerHeight + padding * 2, vh * 0.72));
  return { width: menuWidth, height: menuHeight, rowHeight, contentHeight,
    bodyHeight: Math.max(1, menuHeight - padding * 2 - 2), padding, headerHeight,
    segmentHeight, screenHeight, displayWidth, footerHeight, stacked };
}

export function glassOrientationDescription(state: RemoteGlassMenuState): string {
  return state.projection ? '仅调整本地投屏方向' : state.followSystem ?
    '遵循系统旋转设置' : '独立旋转，不受系统锁定影响';
}

export function placeGlassMenu(metrics: RemoteGlassMenuMetrics, viewportWidth: number, viewportHeight: number,
  anchorX: number, anchorY: number, anchorWidth: number, anchorHeight: number): RemoteGlassMenuPlacement {
  const vw = Number.isFinite(viewportWidth) && viewportWidth > 0 ? viewportWidth : 360;
  const vh = Number.isFinite(viewportHeight) && viewportHeight > 0 ? viewportHeight : 640;
  const margin = Math.min(8, Math.min(vw, vh) / 4), gap = 10;
  const centre = anchorX + anchorWidth / 2;
  const x = Math.max(margin, Math.min(centre - metrics.width / 2, vw - metrics.width - margin));
  const below = anchorY - metrics.height - gap < margin && anchorY + anchorHeight + gap + metrics.height <= vh - margin;
  const desiredY = below ? anchorY + anchorHeight + gap : anchorY - metrics.height - gap;
  const y = Math.max(margin, Math.min(desiredY, vh - metrics.height - margin));
  const arrowX = Math.max(18, Math.min(centre - x, metrics.width - 18));
  return { x, y, arrowX, arrowAbove: below,
    arrowVisible: metrics.width >= 48 && (below ? y >= anchorY + anchorHeight : y + metrics.height <= anchorY) };
}
