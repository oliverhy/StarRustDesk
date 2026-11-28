export interface FoldHoverRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface FoldHoverLayout {
  top: number;
  lowerStart: number;
  lowerHeight: number;
}

export type RemoteSplitInputMode = 'none' | 'hover' | 'manual';
export const MANUAL_SPLIT_KEYBOARD_OPTION: string = 'remote-split-keyboard';

export function manualSplitKeyboardLayout(width: number, height: number, imeInset: number,
  fold: FoldHoverLayout | undefined): FoldHoverLayout | undefined {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width < 240 || height < 200) return undefined;
  const inset = Number.isFinite(imeInset) ? Math.max(0, imeInset) : 0;
  const line = fold?.top ?? Math.floor(height / 2);
  const lowerStart = fold?.lowerStart ?? line;
  return { top: Math.max(1, Math.min(line, height - inset)), lowerStart, lowerHeight: height - lowerStart };
}

export function isFoldHoverPosture(half: boolean, inner: boolean, angles: number[], active: boolean): boolean {
  if (!half || !inner || angles.length > 1) return false;
  if (angles.length === 0) return true;
  const angle = angles[0];
  return Number.isFinite(angle) && angle >= (active ? 65 : 75) && angle <= (active ? 120 : 110);
}

// All dimensions are window-local vp, projected from the physical fold.
export function foldHoverLayout(width: number, height: number, crease: FoldHoverRect): FoldHoverLayout | undefined {
  if (![width, height, crease.x, crease.y, crease.width, crease.height].every((n: number) => Number.isFinite(n)) ||
    width < 320 || height <= 0 || crease.width <= 0 || crease.height < 0 ||
    crease.width < width * 0.8 || crease.width < crease.height * 4 ||
    crease.x > width * 0.1 || crease.x + crease.width < width * 0.9) return undefined;
  const top = Math.floor(crease.y - 4);
  const lowerStart = Math.ceil(crease.y + crease.height + 4);
  if (top < Math.max(140, height * 0.3) || height - lowerStart < Math.max(150, height * 0.3)) return undefined;
  return { top, lowerStart, lowerHeight: height - lowerStart };
}
