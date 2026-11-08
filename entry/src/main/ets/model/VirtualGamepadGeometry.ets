// Shared by the virtual controller and the temporary screen-key avoidance layout.
export interface VirtualGamepadRect { id: string; x: number; y: number; size: number }

export function virtualGamepadButtonSize(width: number, height: number): number {
  return Math.max(20, Math.min(48, width / 11, (height - 85) / 4));
}

export function virtualGamepadStickSize(width: number, height: number): number {
  const button: number = virtualGamepadButtonSize(width, height);
  return Math.max(44, Math.min(116, width * 0.22, height * 0.27, height - button * 4 - 24));
}

export function virtualGamepadPadTop(width: number, height: number): number {
  const button: number = virtualGamepadButtonSize(width, height);
  const stick: number = virtualGamepadStickSize(width, height);
  return Math.max(button + 8, height - stick - button * 3 - 16);
}

export function virtualGamepadFaceLeft(width: number, height: number): number {
  return Math.max(0, width - virtualGamepadButtonSize(width, height) * 3 - 12);
}

export function virtualGamepadRect(id: string, width: number, height: number): VirtualGamepadRect {
  const b: number = virtualGamepadButtonSize(width, height);
  const s: number = virtualGamepadStickSize(width, height);
  const p: number = virtualGamepadPadTop(width, height);
  const face: number = virtualGamepadFaceLeft(width, height);
  const bottom: number = Math.max(0, height - b - 12);
  switch (id) {
    case 'LT': return { id, x: 8, y: 8, size: b };
    case 'LB': return { id, x: 12 + b, y: 8, size: b };
    case 'Select': return { id, x: Math.max(0, width / 2 - b * 1.6), y: 8, size: b };
    case 'Home': return { id, x: Math.max(0, width / 2 - b / 2), y: 8, size: b };
    case 'Start': return { id, x: width / 2 + b * 0.6, y: 8, size: b };
    case 'RB': return { id, x: width - b * 2 - 12, y: 8, size: b };
    case 'RT': return { id, x: width - b - 8, y: 8, size: b };
    case 'up': return { id, x: 8 + b, y: p, size: b };
    case 'left': return { id, x: 8, y: p + b, size: b };
    case 'right': return { id, x: 8 + b * 2, y: p + b, size: b };
    case 'down': return { id, x: 8 + b, y: p + b * 2, size: b };
    case 'Y': return { id, x: face + b, y: p, size: b };
    case 'X': return { id, x: face, y: p + b, size: b };
    case 'B': return { id, x: face + b * 2, y: p + b, size: b };
    case 'A': return { id, x: face + b, y: p + b * 2, size: b };
    case 'leftStick': return { id, x: 12, y: Math.max(0, height - s - 12), size: s };
    case 'rightStick': return { id, x: Math.max(0, width - s - 12), y: Math.max(0, height - s - 12), size: s };
    case 'L3': return { id, x: s + 20, y: bottom, size: b };
    case 'R3': return { id, x: Math.max(0, width - s - b - 20), y: bottom, size: b };
    case 'C': return { id, x: Math.max(0, width / 2 - b / 2), y: bottom, size: b };
    default: return { id, x: 0, y: 0, size: 0 };
  }
}

export function virtualGamepadRects(width: number, height: number): VirtualGamepadRect[] {
  const ids: string[] = ['LT', 'LB', 'Select', 'Home', 'Start', 'RB', 'RT', 'up', 'left', 'right', 'down',
    'Y', 'X', 'B', 'A', 'leftStick', 'rightStick', 'L3', 'R3', 'C'];
  return ids.map((id: string): VirtualGamepadRect => virtualGamepadRect(id, width, height));
}
