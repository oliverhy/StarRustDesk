export interface SecondaryPoint { x: number; y: number }

// Pointer coordinates and displayed size use the same viewport unit. Map only
// the actual image area, never the letterbox. A held drag may clamp at edges.
export function secondaryRemotePoint(x: number, y: number, areaWidth: number, areaHeight: number,
  remoteWidth: number, remoteHeight: number, clampDrag: boolean, zoom: number = 1,
  panX: number = 0, panY: number = 0): SecondaryPoint | undefined {
  if (![x, y, areaWidth, areaHeight, remoteWidth, remoteHeight, zoom, panX, panY].every((n: number) => Number.isFinite(n)) ||
    areaWidth <= 0 || areaHeight <= 0 || remoteWidth <= 0 || remoteHeight <= 0 || zoom <= 0) return undefined;
  const scale: number = Math.min(areaWidth / remoteWidth, areaHeight / remoteHeight) * zoom;
  const width: number = remoteWidth * scale;
  const height: number = remoteHeight * scale;
  const left: number = (areaWidth - width) / 2 + panX;
  const top: number = (areaHeight - height) / 2 + panY;
  if (!clampDrag && (x < left || y < top || x >= left + width || y >= top + height)) return undefined;
  return { x: Math.max(0, Math.min(remoteWidth - 1, (x - left) / scale)),
    y: Math.max(0, Math.min(remoteHeight - 1, (y - top) / scale)) };
}
