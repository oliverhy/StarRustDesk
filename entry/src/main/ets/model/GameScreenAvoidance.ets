import { ScreenGameKey } from './GameScreenControls';
import { VirtualGamepadRect, virtualGamepadRects } from './VirtualGamepadGeometry';

export interface ScreenKeyPlacement { id: number; x: number; y: number; size: number }
export interface ScreenKeyAvoidanceResult { fits: boolean; moved: number; resized: number; placements: ScreenKeyPlacement[] }

function overlaps(a: ScreenKeyPlacement, b: VirtualGamepadRect, gap: number): boolean {
  return a.x < b.x + b.size + gap && b.x < a.x + a.size + gap &&
    a.y < b.y + b.size + gap && b.y < a.y + a.size + gap;
}

function candidateCoordinates(desired: number, limit: number, size: number,
  obstacles: VirtualGamepadRect[], horizontal: boolean): number[] {
  const values: number[] = [];
  const add = (value: number): void => {
    const clamped: number = Math.max(0, Math.min(limit, value));
    if (!values.some((item: number): boolean => Math.abs(item - clamped) < 0.01)) values.push(clamped);
  };
  add(desired); add(0); add(limit);
  for (const rect of obstacles) {
    const start: number = horizontal ? rect.x : rect.y;
    add(start - size - 2); add(start + rect.size + 2);
  }
  const step: number = Math.max(12, size / 2);
  for (let value: number = 0; value < limit; value += step) add(value);
  values.sort((a: number, b: number): number => Math.abs(a - desired) - Math.abs(b - desired));
  return values;
}

// Nearby controls often form a WASD or action-button cluster. Move each
// cluster as a unit when possible so avoidance does not scramble its layout.
function tryMoveGroups(original: ScreenKeyPlacement[], pad: VirtualGamepadRect[], width: number,
  height: number): ScreenKeyPlacement[] | undefined {
  const groups: number[][] = [];
  const visited: boolean[] = original.map((): boolean => false);
  for (let i: number = 0; i < original.length; i++) {
    if (visited[i]) continue;
    const group: number[] = [i]; visited[i] = true;
    for (let cursor: number = 0; cursor < group.length; cursor++) {
      const a: ScreenKeyPlacement = original[group[cursor]];
      for (let j: number = 0; j < original.length; j++) {
        if (visited[j]) continue;
        const b: ScreenKeyPlacement = original[j];
        const gap: number = Math.max(8, Math.min(a.size, b.size) * 0.25);
        if (overlaps(a, { id: '', x: b.x, y: b.y, size: b.size }, gap)) {
          visited[j] = true; group.push(j);
        }
      }
    }
    groups.push(group);
  }
  // A narrower viewport can make the saved normalized positions overlap.
  // Moving that whole cluster would leave its buttons impossible to press.
  for (const group of groups) for (let i: number = 0; i < group.length; i++) {
    const a: ScreenKeyPlacement = original[group[i]];
    for (let j: number = i + 1; j < group.length; j++) {
      const b: ScreenKeyPlacement = original[group[j]];
      if (overlaps(a, { id: '', x: b.x, y: b.y, size: b.size }, 0)) return undefined;
    }
  }
  const occupied: VirtualGamepadRect[] = pad.slice();
  const movedGroups: number[][] = [];
  for (const group of groups) {
    const collides: boolean = group.some((index: number): boolean =>
      pad.some((rect: VirtualGamepadRect): boolean => overlaps(original[index], rect, 2)));
    if (collides) movedGroups.push(group);
    else for (const index of group) {
      const key: ScreenKeyPlacement = original[index];
      occupied.push({ id: `screen-${key.id}`, x: key.x, y: key.y, size: key.size });
    }
  }
  movedGroups.sort((a: number[], b: number[]): number => b.length - a.length);
  const result: ScreenKeyPlacement[] = original.map((key: ScreenKeyPlacement): ScreenKeyPlacement =>
    ({ id: key.id, x: key.x, y: key.y, size: key.size }));
  for (const group of movedGroups) {
    let left: number = width, top: number = height, right: number = 0, bottom: number = 0;
    for (const index of group) {
      const key: ScreenKeyPlacement = original[index];
      left = Math.min(left, key.x); top = Math.min(top, key.y);
      right = Math.max(right, key.x + key.size); bottom = Math.max(bottom, key.y + key.size);
    }
    const groupWidth: number = right - left, groupHeight: number = bottom - top;
    const xs: number[] = candidateCoordinates(left, width - groupWidth, groupWidth, occupied, true);
    const ys: number[] = candidateCoordinates(top, height - groupHeight, groupHeight, occupied, false);
    let bestX: number = left, bestY: number = top, bestDistance: number = Number.POSITIVE_INFINITY;
    for (const x of xs) {
      const dx: number = x - left;
      if (dx * dx > bestDistance) break;
      for (const y of ys) {
        const dy: number = y - top, distance: number = dx * dx + dy * dy;
        if (distance >= bestDistance) break;
        const collides: boolean = group.some((index: number): boolean => {
          const key: ScreenKeyPlacement = original[index];
          const candidate: ScreenKeyPlacement = { id: key.id, x: key.x + dx, y: key.y + dy, size: key.size };
          return occupied.some((rect: VirtualGamepadRect): boolean => overlaps(candidate, rect, 2));
        });
        if (!collides) { bestX = x; bestY = y; bestDistance = distance; }
      }
    }
    if (!Number.isFinite(bestDistance)) return undefined;
    for (const index of group) {
      const key: ScreenKeyPlacement = original[index];
      const next: ScreenKeyPlacement = { id: key.id, x: key.x + bestX - left, y: key.y + bestY - top, size: key.size };
      result[index] = next;
      occupied.push({ id: `screen-${next.id}`, x: next.x, y: next.y, size: next.size });
    }
  }
  return result;
}

// Reflow is render-only: never mutate the saved normalized positions or sizes.
// If the viewport cannot fit all controls, the caller must avoid drawing both
// layers on top of each other and clearly indicate the temporary fallback.
function tryAvoidVirtualGamepad(keys: ScreenGameKey[], width: number, height: number, maxSize: number): ScreenKeyAvoidanceResult {
  const original: ScreenKeyPlacement[] = keys.map((key: ScreenGameKey): ScreenKeyPlacement => ({
    id: key.id, x: key.x * Math.max(0, width - Math.min(key.size, maxSize)),
    y: key.y * Math.max(0, height - Math.min(key.size, maxSize)), size: Math.min(key.size, maxSize)
  }));
  if (width <= 0 || height <= 0 || original.some((key: ScreenKeyPlacement): boolean => key.size > width || key.size > height)) {
    return { fits: false, moved: 0, resized: 0, placements: original };
  }
  const pad: VirtualGamepadRect[] = virtualGamepadRects(width, height);
  const grouped: ScreenKeyPlacement[] | undefined = tryMoveGroups(original, pad, width, height);
  if (grouped) {
    const moved: number = grouped.filter((key: ScreenKeyPlacement, index: number): boolean =>
      Math.abs(key.x - original[index].x) > 0.01 || Math.abs(key.y - original[index].y) > 0.01).length;
    const resized: number = keys.filter((key: ScreenGameKey): boolean => key.size > maxSize).length;
    return { fits: true, moved, resized, placements: grouped };
  }
  const occupied: VirtualGamepadRect[] = pad.slice();
  const result: ScreenKeyPlacement[] = original.map((key: ScreenKeyPlacement): ScreenKeyPlacement => ({
    id: key.id, x: key.x, y: key.y, size: key.size
  }));
  const displaced: number[] = [];
  for (let i: number = 0; i < original.length; i++) {
    const key: ScreenKeyPlacement = original[i];
    if (pad.some((rect: VirtualGamepadRect): boolean => overlaps(key, rect, 2))) displaced.push(i);
    else occupied.push({ id: `screen-${key.id}`, x: key.x, y: key.y, size: key.size });
  }
  displaced.sort((a: number, b: number): number => original[b].size - original[a].size);
  for (const index of displaced) {
    const key: ScreenKeyPlacement = original[index];
    const xs: number[] = candidateCoordinates(key.x, width - key.size, key.size, occupied, true);
    const ys: number[] = candidateCoordinates(key.y, height - key.size, key.size, occupied, false);
    let best: ScreenKeyPlacement | undefined;
    let bestDistance: number = Number.POSITIVE_INFINITY;
    for (const x of xs) {
      const dx: number = x - key.x;
      if (dx * dx > bestDistance) break;
      for (const y of ys) {
        const dy: number = y - key.y;
        const distance: number = dx * dx + dy * dy;
        if (distance >= bestDistance) break;
        const candidate: ScreenKeyPlacement = { id: key.id, x, y, size: key.size };
        if (!occupied.some((rect: VirtualGamepadRect): boolean => overlaps(candidate, rect, 2))) {
          best = candidate; bestDistance = distance;
        }
      }
    }
    if (!best) return { fits: false, moved: 0, resized: 0, placements: original };
    result[index] = best;
    occupied.push({ id: `screen-${best.id}`, x: best.x, y: best.y, size: best.size });
  }
  const resized: number = keys.filter((key: ScreenGameKey): boolean => key.size > maxSize).length;
  return { fits: true, moved: displaced.length, resized, placements: result };
}

export function avoidVirtualGamepad(keys: ScreenGameKey[], width: number, height: number): ScreenKeyAvoidanceResult {
  const full: ScreenKeyAvoidanceResult = tryAvoidVirtualGamepad(keys, width, height, Number.POSITIVE_INFINITY);
  if (full.fits) return full;
  // Keep existing sizes whenever possible. Compact viewports may temporarily
  // render the keys smaller, but their saved sizes stay untouched.
  const compact: ScreenKeyAvoidanceResult = tryAvoidVirtualGamepad(keys, width, height, 44);
  if (compact.fits) return compact;
  const minimum: ScreenKeyAvoidanceResult = tryAvoidVirtualGamepad(keys, width, height, 36);
  return minimum.fits ? minimum : full;
}
