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
    return { x: position.x, y: position.y };
  } catch (_error) {
    return undefined;
  }
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
