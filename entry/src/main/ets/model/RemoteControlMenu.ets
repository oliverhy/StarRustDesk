// The compact bar and the fixed PC sidebar share the same categories. Existing
// per-action ordering is retained inside each menu; no remote input is changed.
export const REMOTE_CONTROL_CATEGORIES: string[] = ['screens', 'input', 'keyboard', 'view', 'more', 'disconnect'];

export function remoteControlCategoryLabel(category: string): string {
  switch (category) {
    case 'screens': return '屏幕';
    case 'input': return '输入';
    case 'keyboard': return '键盘';
    case 'view': return '画面';
    case 'more': return '更多';
    case 'disconnect': return '断开';
    default: return '';
  }
}

export function remoteControlCategoryItems(category: string, order: string[]): string[] {
  let keys: string[] = [];
  switch (category) {
    case 'screens': keys = ['displays']; break;
    case 'input': keys = ['input', 'virtualMouse', 'mobileActions', 'gestureHelp', 'clipboard']; break;
    case 'view': keys = ['edgePan', 'pan', 'zoomIn', 'zoomOut', 'fullscreen', 'pip', 'orientation']; break;
    case 'more': keys = ['chat', 'upload', 'uploadFolder', 'download', 'recording', 'recordings', 'privacy']; break;
  }
  return order.filter((item: string) => keys.includes(item));
}

function remoteControlMenuItemWidthLabels(item: string): string[] {
  switch (item) {
    case 'edgePan': return ['边缘跟随', '边缘跟随开'];
    case 'pan': return ['移动画面', '结束移动'];
    case 'zoomIn': return ['+'];
    case 'zoomOut': return ['-'];
    case 'fullscreen': return ['全屏', '退出全屏', '切换中…'];
    case 'pip': return ['画中画', '关闭小窗', '切换中…'];
    case 'orientation': return ['固定竖屏', '固定横屏', '自动适配', '跟随系统'];
    case 'chat': return ['聊天', '通话中'];
    case 'upload': return ['发送文件'];
    case 'uploadFolder': return ['发送文件夹'];
    case 'download': return ['取回文件'];
    case 'recording': return ['录像', '停止录像'];
    case 'recordings': return ['录像列表'];
    case 'privacy': return ['隐私屏', '关闭隐私屏', '隐私屏处理中'];
    default: return [];
  }
}

// Include both state labels so toggling an option does not resize the menu.
export function remoteControlMenuWidthLabels(category: string, items: string[], desktopView: boolean): string[] {
  if (category !== 'view' && category !== 'more') return [];
  let labels: string[] = [];
  for (const item of items) labels = labels.concat(remoteControlMenuItemWidthLabels(item));
  if (category === 'more') labels = labels.concat(['连接信息', '工具栏排序']);
  if (desktopView) labels = labels.concat(['适应窗口', '原始比例', '自定义', '显示比例',
    '调整中…', '调整窗口', '退出沉浸', '沉浸窗口']);
  return labels;
}

// Conservative fallback only when the owning window's text measurement fails.
export function estimateControlMenuTextWidth(text: string, fontScale: number): number {
  const scale = Number.isFinite(fontScale) ? Math.max(1, Math.min(3.2, fontScale)) : 1;
  let width = 0;
  for (let index = 0; index < text.length; index++) width += text.charCodeAt(index) <= 0x7F ? 8 : 13;
  return width * scale;
}

export function clampControlMenuAxis(value: number, extent: number, available: number): number {
  const margin = Math.min(8, Math.max(0, available) / 4);
  return Math.max(margin, Math.min(value, Math.max(margin, available - extent - margin)));
}

export interface RemoteMenuAnchor {
  category: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface RemoteMenuMetrics {
  width: number;
  height: number;
  viewportWidth: number;
  viewportHeight: number;
  padding: number;
  actionPadding: number;
  gap: number;
  rowHeight: number;
  displayWidth: number;
  contentHeight: number;
  frameInset: number;
  contentWidth: number;
  bodyHeight: number;
  inputSelectorStacked: boolean;
  inputSegmentWidth: number;
  inputSelectorHeight: number;
}

export interface RemoteMenuPosition {
  x: number;
  y: number;
}

export interface RemoteInputSelectorMetrics {
  stacked: boolean;
  segmentWidth: number;
  height: number;
}

export function compactInputSelectorMetrics(width: number, fontScale: number, rowHeight: number): RemoteInputSelectorMetrics {
  const available = Number.isFinite(width) ? Math.max(1, width) : 206;
  const scale = Number.isFinite(fontScale) ? Math.max(1, Math.min(3.2, fontScale)) : 1;
  const row = Number.isFinite(rowHeight) ? Math.max(38, rowHeight) : 44;
  // Keep the conservative label allowance after the visual size reduction so
  // large fonts/translations retain the existing stacked-layout fallback.
  const minimumSegmentWidth = 42 + 45 * scale;
  const stacked = available < minimumSegmentWidth * 2 + 4;
  return { stacked, segmentWidth: stacked ? available : (available - 4) / 2,
    height: stacked ? row * 2 + 4 : row };
}

// Logical window dimensions, not model names or physical display pixels.
export function compactControlMenuMetrics(category: string, width: number, height: number,
  fontScale: number, displayCount: number, itemCount: number, handheld: boolean,
  desktopView: boolean, customScale: boolean, labelWidth: number = 0): RemoteMenuMetrics {
  const viewportWidth = Number.isFinite(width) && width > 0 ? width : 360;
  const viewportHeight = Number.isFinite(height) && height > 0 ? height : 640;
  const scale = Number.isFinite(fontScale) ? Math.max(1, Math.min(3.2, fontScale)) : 1;
  const padding = 8;
  // ArkUI's 1 vp border consumes layout space on both sides of the Scroll.
  const frameInset = padding * 2 + 2;
  const gap = category === 'screens' ? 6 : 2;
  const rowHeight = Math.ceil(Math.max(handheld ? 44 : 38, 26 * scale + 12));
  const displayWidth = Math.ceil(56 + (scale - 1) * 32);
  const displays = Number.isFinite(displayCount) ? Math.max(1, Math.floor(displayCount)) : 1;
  const rows = Number.isFinite(itemCount) ? Math.max(0, Math.floor(itemCount)) : 0;
  const compactActions = category === 'view' || category === 'more';
  const actionPadding = compactActions ? 8 : 12;
  // Fit labels instead of retaining a fixed menu-width floor. Only a minimum
  // click target and the PC scale/slider section reserve non-text width.
  const textWidth = compactActions && Number.isFinite(labelWidth) && labelWidth > 0 ? labelWidth : 0;
  const desktopReserve = category === 'view' && desktopView ? Math.ceil(224 + (scale - 1) * 64) : 0;
  const actionWidth = compactActions ? Math.max((handheld ? 44 : 38) + frameInset,
    textWidth + frameInset + actionPadding * 2 + 4, desktopReserve) : Math.ceil(224 + (scale - 1) * 64);
  const preferredWidth = category === 'screens' ?
    displays * displayWidth + Math.max(0, displays - 1) * gap + frameInset :
    Math.ceil(actionWidth);
  const menuWidth = Math.max(1, Math.min(preferredWidth, category === 'screens' ? 360 : 380,
    viewportWidth - Math.min(8, viewportWidth / 4) * 2));
  const contentWidth = Math.max(1, menuWidth - frameInset);
  const inputSelector = compactInputSelectorMetrics(contentWidth, scale, rowHeight);
  // Desktop options render six fixed-height rows, one optional slider and a divider.
  const desktopRows = customScale ? 7 : 6;
  const desktopHeight = desktopView ? desktopRows * rowHeight + desktopRows * gap + 1 : 0;
  const contentHeight = category === 'screens' ? rowHeight :
    Math.max(rowHeight, rows * rowHeight + Math.max(0, rows - 1) * gap +
      desktopHeight + (desktopView && rows > 0 ? gap : 0) +
      (category === 'input' && rows > 0 ? inputSelector.height - rowHeight : 0));
  const availableHeight = Math.max(1, viewportHeight - Math.min(8, viewportHeight / 4) * 2);
  const maxHeight = category === 'screens' ? availableHeight : Math.min(availableHeight,
    Math.max(rowHeight + frameInset, Math.min(handheld ? 420 : 480, availableHeight * 0.6)));
  const menuHeight = Math.min(contentHeight + frameInset, maxHeight);
  return { width: menuWidth, height: menuHeight,
    viewportWidth, viewportHeight, padding, actionPadding, gap, rowHeight, displayWidth, contentHeight,
    frameInset, contentWidth, bodyHeight: Math.max(1, menuHeight - frameInset),
    inputSelectorStacked: inputSelector.stacked, inputSegmentWidth: inputSelector.segmentWidth,
    inputSelectorHeight: inputSelector.height };
}

export function placeCompactControlMenu(metrics: RemoteMenuMetrics, anchor: RemoteMenuAnchor,
  sideMenu: boolean): RemoteMenuPosition {
  const gap = 8;
  let x = anchor.x;
  let y = anchor.y - metrics.height - gap;
  if (sideMenu) {
    x = anchor.x - metrics.width - gap;
    if (x < gap && anchor.x + anchor.width + gap + metrics.width <= metrics.viewportWidth - gap) {
      x = anchor.x + anchor.width + gap;
    }
    y = anchor.y;
  } else if (y < gap && anchor.y + anchor.height + gap + metrics.height <= metrics.viewportHeight - gap) {
    y = anchor.y + anchor.height + gap;
  }
  return { x: clampControlMenuAxis(x, metrics.width, metrics.viewportWidth),
    y: clampControlMenuAxis(y, metrics.height, metrics.viewportHeight) };
}
