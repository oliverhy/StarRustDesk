export type DesktopViewMode = 'adaptive' | 'original' | 'custom';

export interface DesktopWindowFrame {
  left: number;
  top: number;
  width: number;
  height: number;
}

export function desktopFitScale(width: number, height: number, remoteWidth: number, remoteHeight: number): number {
  if (![width, height, remoteWidth, remoteHeight].every((value: number) => Number.isFinite(value) && value > 0)) return 1;
  return Math.min(width / remoteWidth, height / remoteHeight);
}

export function desktopScalePercent(value: number): number {
  return Number.isFinite(value) ? Math.max(25, Math.min(300, Math.round(value))) : 100;
}

// Layout is in vp; 100% means one remote pixel per local physical pixel.
// Retain the common fit-sized surface and apply the final scale to its parent.
export function desktopZoomScale(mode: DesktopViewMode, percent: number, fit: number, density: number): number {
  if (mode === 'adaptive') return 1;
  const safeDensity: number = Number.isFinite(density) && density > 0 ? density : 1;
  const safeFit: number = Number.isFinite(fit) && fit > 0 ? fit : 1;
  return (mode === 'original' ? 1 : desktopScalePercent(percent) / 100) / safeDensity / safeFit;
}

// Fit the outer window to the remote aspect, accounting for title/sidebar
// chrome. Keep the entire result in the display's available (non-dock) area.
export function desktopWindowFrame(remoteWidth: number, remoteHeight: number, chromeWidth: number,
  chromeHeight: number, current: DesktopWindowFrame, available: DesktopWindowFrame): DesktopWindowFrame | undefined {
  const values: number[] = [remoteWidth, remoteHeight, current.width, current.height, available.width, available.height];
  if (!values.every((value: number) => Number.isFinite(value) && value > 0) ||
    ![chromeWidth, chromeHeight, current.left, current.top, available.left, available.top]
      .every((value: number) => Number.isFinite(value))) return undefined;
  const chromeX: number = Math.max(0, chromeWidth);
  const chromeY: number = Math.max(0, chromeHeight);
  const usableWidth: number = available.width - chromeX;
  const usableHeight: number = available.height - chromeY;
  if (usableWidth < 160 || usableHeight < 100) return undefined;
  const scale: number = Math.min(1, usableWidth / remoteWidth, usableHeight / remoteHeight);
  const width: number = Math.floor(remoteWidth * scale + chromeX);
  const height: number = Math.floor(remoteHeight * scale + chromeY);
  // Tiny windows are rejected rather than stretched or falsely reported as fit.
  if (width < 320 || height < 240) return undefined;
  return {
    left: Math.round(Math.max(available.left, Math.min(current.left + (current.width - width) / 2,
      available.left + available.width - width))),
    top: Math.round(Math.max(available.top, Math.min(current.top + (current.height - height) / 2,
      available.top + available.height - height))),
    width: width,
    height: height
  };
}
