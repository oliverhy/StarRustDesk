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

export function clampControlMenuAxis(value: number, extent: number, available: number): number {
  return Math.max(8, Math.min(value, Math.max(8, available - extent - 8)));
}
