export interface RemoteToolbarRelativePosition {
  x: number;
  y: number;
}

export function decodeRemoteToolbarPosition(value: string): RemoteToolbarRelativePosition | undefined {
  if (!value || value.length > 256) return undefined;
  try {
    const position = JSON.parse(value) as RemoteToolbarRelativePosition | null;
    if (!position || !Number.isFinite(position.x) || !Number.isFinite(position.y) ||
      position.x < 0 || position.x > 1 || position.y < 0 || position.y > 1) return undefined;
    // Ignore any old dock field: position remains saved, but docking is an
    // explicit gesture in the current collapsed session.
    return { x: position.x, y: position.y };
  } catch (_error) {
    return undefined;
  }
}

// Dock only after the user releases the collapsed button near an edge. Keep
// free placement elsewhere, including on narrow or resizable windows.
export function toolbarDockEdge(position: number, viewport: number, extent: number): string {
  if (!Number.isFinite(position) || !Number.isFinite(viewport) || !Number.isFinite(extent) ||
    viewport <= 0 || extent <= 0 || extent > viewport) return '';
  const margin: number = Math.min(8, viewport / 2);
  const threshold: number = Math.min(32, Math.max(0, (viewport - extent - margin * 2) / 2));
  const left: number = Math.abs(position - margin);
  const right: number = Math.abs(viewport - margin - extent - position);
  if (left > threshold && right > threshold) return '';
  return left <= right ? 'left' : 'right';
}

// Fractions describe the available drag range, so edge choices stay at the
// same edge after window resize, folding, IME resize and expand/collapse.
export function toolbarAxisPosition(fraction: number, viewport: number, extent: number): number {
  const margin: number = Math.min(8, Math.max(0, viewport) / 2);
  const travel: number = Math.max(0, viewport - extent - margin * 2);
  const safe: number = Number.isFinite(fraction) ? Math.max(0, Math.min(1, fraction)) : 0.5;
  return margin + travel * safe;
}

export function toolbarAxisFraction(position: number, viewport: number, extent: number,
  fallback: number = 0.5): number {
  const margin: number = Math.min(8, Math.max(0, viewport) / 2);
  const travel: number = Math.max(0, viewport - extent - margin * 2);
  const fraction: number = travel > 0 ? (position - margin) / travel : fallback;
  return Number.isFinite(fraction) ? Math.max(0, Math.min(1, fraction)) : 0.5;
}
