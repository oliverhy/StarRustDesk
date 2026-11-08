// Screen-space geometry for floating controls. This is render-only and must
// never change a user's saved toolbar or keyboard position.
export interface FloatingControlRect { x: number; y: number; width: number; height: number }
export interface FloatingControlPlan {
  fits: boolean;
  toolbar: FloatingControlRect;
  keyboard: FloatingControlRect;
}

function overlaps(a: FloatingControlRect, b: FloatingControlRect, gap: number): boolean {
  return a.x < b.x + b.width + gap && b.x < a.x + a.width + gap &&
    a.y < b.y + b.height + gap && b.y < a.y + a.height + gap;
}

function candidateCoordinates(desired: number, limit: number, size: number,
  obstacles: FloatingControlRect[], horizontal: boolean): number[] {
  const values: number[] = [];
  const add = (value: number): void => {
    const clamped: number = Math.max(8, Math.min(Math.max(8, limit), value));
    if (!values.some((item: number): boolean => Math.abs(item - clamped) < 0.01)) values.push(clamped);
  };
  add(desired); add(8); add(limit);
  for (const rect of obstacles) {
    const start: number = horizontal ? rect.x : rect.y;
    const length: number = horizontal ? rect.width : rect.height;
    add(start - size - 4); add(start + length + 4);
  }
  values.sort((a: number, b: number): number => Math.abs(a - desired) - Math.abs(b - desired));
  return values;
}

function closestAvailable(original: FloatingControlRect, width: number, height: number,
  obstacles: FloatingControlRect[]): FloatingControlRect | undefined {
  if (original.width > width - 16 || original.height > height - 16) return undefined;
  const xs: number[] = candidateCoordinates(original.x, width - original.width - 8, original.width, obstacles, true);
  const ys: number[] = candidateCoordinates(original.y, height - original.height - 8, original.height, obstacles, false);
  let best: FloatingControlRect | undefined;
  let bestDistance: number = Number.POSITIVE_INFINITY;
  for (const x of xs) {
    const dx: number = x - original.x;
    if (dx * dx > bestDistance) break;
    for (const y of ys) {
      const dy: number = y - original.y, distance: number = dx * dx + dy * dy;
      if (distance >= bestDistance) break;
      const candidate: FloatingControlRect = { x, y, width: original.width, height: original.height };
      if (!obstacles.some((rect: FloatingControlRect): boolean => overlaps(candidate, rect, 4))) {
        best = candidate; bestDistance = distance;
      }
    }
  }
  return best;
}

// Try each ordering so one floating control does not needlessly block the
// other. If neither fits, the caller hides the gamepad rather than covering it.
export function avoidGamepadFloatingControls(width: number, height: number, toolbar: FloatingControlRect,
  keyboard: FloatingControlRect, hasKeyboard: boolean, obstacles: FloatingControlRect[]): FloatingControlPlan {
  const toolbarFirst: FloatingControlRect | undefined = closestAvailable(toolbar, width, height, obstacles);
  if (toolbarFirst) {
    const keyboardSecond: FloatingControlRect | undefined = hasKeyboard ?
      closestAvailable(keyboard, width, height, obstacles.concat([toolbarFirst])) : keyboard;
    if (keyboardSecond) return { fits: true, toolbar: toolbarFirst, keyboard: keyboardSecond };
  }
  if (hasKeyboard) {
    const keyboardFirst: FloatingControlRect | undefined = closestAvailable(keyboard, width, height, obstacles);
    if (keyboardFirst) {
      const toolbarSecond: FloatingControlRect | undefined =
        closestAvailable(toolbar, width, height, obstacles.concat([keyboardFirst]));
      if (toolbarSecond) return { fits: true, toolbar: toolbarSecond, keyboard: keyboardFirst };
    }
  }
  return { fits: false, toolbar, keyboard };
}
