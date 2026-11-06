// Gamepad input is translated into ordinary RustDesk keyboard/mouse events.
// Nothing here pretends to create a native controller on the remote machine.
export interface GamepadBinding { code: number; target: string }
export interface GamepadMapping {
  version: number;
  bindings: GamepadBinding[];
  leftStick: string;
  rightStick: string;
  deadzone: number;
  sensitivity: number;
}
export interface GamepadTarget { label: string; value: string }
interface GamepadStick { device: number; x: number; y: number }

export const GAMEPAD_CODES: number[] = [2301, 2302, 2304, 2305, 2303, 2307, 2308, 2309, 2310,
  2311, 2312, 2313, 2314, 2315, 2012, 2013, 2014, 2015];
export const GAMEPAD_LABELS: string[] = ['A', 'B', 'X', 'Y', 'C', 'LB', 'RB', 'LT', 'RT',
  'Select', 'Start', 'Home', 'L3', 'R3', '↑', '↓', '←', '→'];
export const GAMEPAD_TARGETS: GamepadTarget[] = [
  { label: '不映射', value: 'none' }, { label: '鼠标左键', value: 'mouse:left' },
  { label: '鼠标右键', value: 'mouse:right' }, { label: 'Space', value: 'k:44' },
  { label: 'Shift', value: 'm:16' }, { label: 'Ctrl', value: 'm:17' },
  { label: 'Alt', value: 'm:18' }, { label: 'Esc', value: 'k:41' },
  { label: 'Tab', value: 'k:43' }, { label: 'Enter', value: 'k:40' },
  { label: '↑', value: 'k:82' }, { label: '↓', value: 'k:81' },
  { label: '←', value: 'k:80' }, { label: '→', value: 'k:79' },
  { label: 'A', value: 'k:4' }, { label: 'B', value: 'k:5' }, { label: 'C', value: 'k:6' },
  { label: 'D', value: 'k:7' }, { label: 'E', value: 'k:8' }, { label: 'F', value: 'k:9' },
  { label: 'G', value: 'k:10' }, { label: 'H', value: 'k:11' }, { label: 'I', value: 'k:12' },
  { label: 'J', value: 'k:13' }, { label: 'K', value: 'k:14' }, { label: 'L', value: 'k:15' },
  { label: 'M', value: 'k:16' }, { label: 'N', value: 'k:17' }, { label: 'O', value: 'k:18' },
  { label: 'P', value: 'k:19' }, { label: 'Q', value: 'k:20' }, { label: 'R', value: 'k:21' },
  { label: 'S', value: 'k:22' }, { label: 'T', value: 'k:23' }, { label: 'U', value: 'k:24' },
  { label: 'V', value: 'k:25' }, { label: 'W', value: 'k:26' }, { label: 'X', value: 'k:27' },
  { label: 'Y', value: 'k:28' }, { label: 'Z', value: 'k:29' },
  { label: '1', value: 'k:30' }, { label: '2', value: 'k:31' }, { label: '3', value: 'k:32' },
  { label: '4', value: 'k:33' }, { label: '5', value: 'k:34' }, { label: '6', value: 'k:35' },
  { label: '7', value: 'k:36' }, { label: '8', value: 'k:37' }, { label: '9', value: 'k:38' },
  { label: '0', value: 'k:39' }
];

export function defaultGamepadMapping(): GamepadMapping {
  const targets: string[] = ['k:44', 'k:6', 'k:21', 'k:8', 'k:10', 'k:20', 'k:9', 'mouse:right',
    'mouse:left', 'k:43', 'k:41', 'none', 'm:16', 'k:25', 'k:82', 'k:81', 'k:80', 'k:79'];
  return { version: 1, bindings: GAMEPAD_CODES.map((code: number, index: number): GamepadBinding =>
    ({ code, target: targets[index] })), leftStick: 'wasd', rightStick: 'mouse', deadzone: 20, sensitivity: 100 };
}

export function validGamepadMapping(config: GamepadMapping): boolean {
  if (!config || typeof config !== 'object' || Array.isArray(config) || config.version !== 1 ||
    Object.keys(config).some((key: string) => !['version', 'bindings', 'leftStick', 'rightStick', 'deadzone', 'sensitivity'].includes(key)) ||
    !Array.isArray(config.bindings) || (config.bindings.length !== GAMEPAD_CODES.length &&
      config.bindings.length !== GAMEPAD_CODES.length - 1) ||
    !['wasd', 'arrows', 'off'].includes(config.leftStick) || !['mouse', 'arrows', 'off'].includes(config.rightStick) ||
    !Number.isInteger(config.deadzone) || config.deadzone < 5 || config.deadzone > 45 ||
    !Number.isInteger(config.sensitivity) || config.sensitivity < 25 || config.sensitivity > 200) return false;
  const seen: number[] = [];
  for (const binding of config.bindings) {
    if (!binding || typeof binding !== 'object' || Array.isArray(binding) ||
      Object.keys(binding).some((key: string) => !['code', 'target'].includes(key)) ||
      !GAMEPAD_CODES.includes(binding.code) || seen.includes(binding.code) ||
      !GAMEPAD_TARGETS.some((target: GamepadTarget) => target.value === binding.target)) return false;
    seen.push(binding.code);
  }
  // A mapping saved before Home was exposed remains valid and is upgraded on read.
  return GAMEPAD_CODES.every((code: number) => code === 2313 || seen.includes(code));
}

export function decodeGamepadMapping(value: string): GamepadMapping {
  if (!value || value.length > 2048) return defaultGamepadMapping();
  try {
    const config: GamepadMapping = JSON.parse(value) as GamepadMapping;
    if (validGamepadMapping(config)) {
      if (!config.bindings.some((binding: GamepadBinding) => binding.code === 2313)) {
        config.bindings.push({ code: 2313, target: 'none' });
      }
      return config;
    }
  } catch (_error) {}
  return defaultGamepadMapping();
}

export function validGamepadMappingValue(value: string): boolean {
  if (!value || value.length > 2048) return false;
  try { return validGamepadMapping(JSON.parse(value) as GamepadMapping); } catch (_error) { return false; }
}

export function gamepadMappingHasConflicts(config: GamepadMapping): boolean {
  const targets: string[] = [];
  if (config.leftStick === 'wasd') targets.push('k:4', 'k:7', 'k:26', 'k:22');
  if (config.leftStick === 'arrows') targets.push('k:80', 'k:79', 'k:82', 'k:81');
  if (config.rightStick === 'arrows') {
    if (config.leftStick === 'arrows') return true;
    targets.push('k:80', 'k:79', 'k:82', 'k:81');
  }
  for (const binding of config.bindings) {
    if (binding.target === 'none') continue;
    if (targets.includes(binding.target)) return true;
    targets.push(binding.target);
  }
  return false;
}

// One output is held until its last source releases it, including simultaneous
// virtual/physical controls. Axes are radial-deadzoned and direction edges use
// hysteresis. Call releaseDevice/releaseAll on disconnect, focus loss and stop.
export class GamepadMapper {
  private config: GamepadMapping = defaultGamepadMapping();
  private held: Map<string, string> = new Map<string, string>();
  private counts: Map<string, number> = new Map<string, number>();
  private right: GamepadStick[] = [];
  private lastTick: number = 0;
  private output: (target: string, down: boolean) => void;
  private move: (x: number, y: number) => void;

  constructor(output: (target: string, down: boolean) => void, move: (x: number, y: number) => void) {
    this.output = output;
    this.move = move;
  }

  setMapping(config: GamepadMapping): void {
    this.releaseAll();
    this.config = validGamepadMapping(config) ? config : defaultGamepadMapping();
  }

  button(device: number, code: number, down: boolean, source: string = 'button'): void {
    const binding = this.config.bindings.find((item: GamepadBinding) => item.code === code);
    if (!binding) return;
    this.setHeld(`${device}:${source}:${code}`, binding.target, down);
  }

  screenButton(id: number, target: string, down: boolean): void {
    if (!Number.isInteger(id) || id < 1 || id > 9999) return;
    if (down && !GAMEPAD_TARGETS.some((item: GamepadTarget) => item.value === target && target !== 'none')) return;
    this.setHeld(`-2:screen:${id}`, target, down);
  }

  axis(device: number, axis: number, x: number, y: number): void {
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    x = Math.max(-1, Math.min(1, x)); y = Math.max(-1, Math.min(1, y));
    if (axis === 0) {
      this.directions(device, 'dpad', x, y, ['2014', '2015', '2012', '2013'], true);
    } else if (axis === 1) {
      const xy = this.filteredStick(x, y);
      const keys: string[] = this.config.leftStick === 'wasd' ? ['k:4', 'k:7', 'k:26', 'k:22'] :
        this.config.leftStick === 'arrows' ? ['k:80', 'k:79', 'k:82', 'k:81'] : ['none', 'none', 'none', 'none'];
      this.directions(device, 'left', xy[0], xy[1], keys, false);
    } else if (axis === 2) {
      const xy = this.filteredStick(x, y);
      if (this.config.rightStick === 'mouse') {
        this.right = this.right.filter((stick: GamepadStick) => stick.device !== device);
        if (xy[0] !== 0 || xy[1] !== 0) this.right.push({ device, x: xy[0], y: xy[1] });
      } else {
        this.right = this.right.filter((stick: GamepadStick) => stick.device !== device);
        const keys: string[] = this.config.rightStick === 'arrows' ? ['k:80', 'k:79', 'k:82', 'k:81'] :
          ['none', 'none', 'none', 'none'];
        this.directions(device, 'right', xy[0], xy[1], keys, false);
      }
    } else if (axis === 3 || axis === 4) {
      const code: number = axis === 3 ? 2309 : 2310;
      const source: string = `${device}:trigger:${code}`;
      const down: boolean = x >= (this.held.has(source) ? 0.35 : 0.5);
      this.button(device, code, down, 'trigger');
    }
  }

  tick(now: number): void {
    if (!Number.isFinite(now) || now <= 0) return;
    const elapsed: number = this.lastTick > 0 && now >= this.lastTick ? Math.min(50, now - this.lastTick) : 16;
    this.lastTick = now;
    if (this.right.length === 0) return;
    let x: number = 0, y: number = 0;
    for (const stick of this.right) { x += stick.x; y += stick.y; }
    const magnitude: number = Math.sqrt(x * x + y * y);
    if (magnitude > 1) { x /= magnitude; y /= magnitude; }
    const speed: number = 14 * this.config.sensitivity / 100 * elapsed / 16;
    if (x !== 0 || y !== 0) this.move(x * speed, y * speed);
  }

  releaseDevice(device: number): void {
    const prefix: string = `${device}:`;
    for (const source of Array.from(this.held.keys())) {
      if (source.startsWith(prefix)) this.setHeld(source, '', false);
    }
    this.right = this.right.filter((stick: GamepadStick) => stick.device !== device);
  }

  releaseAll(): void {
    for (const source of Array.from(this.held.keys())) this.setHeld(source, '', false);
    this.right = [];
    this.lastTick = 0;
  }

  private filteredStick(x: number, y: number): number[] {
    const magnitude: number = Math.sqrt(x * x + y * y);
    const dead: number = this.config.deadzone / 100;
    if (magnitude <= dead || magnitude === 0) return [0, 0];
    const scaled: number = Math.min(1, (magnitude - dead) / (1 - dead));
    return [x / magnitude * scaled, y / magnitude * scaled];
  }

  private directions(device: number, axis: string, x: number, y: number, keys: string[], buttons: boolean): void {
    const values: number[] = [-x, x, -y, y];
    for (let index: number = 0; index < 4; index++) {
      const source: string = `${device}:${axis}:${keys[index]}`;
      const down: boolean = values[index] >= (this.held.has(source) ? 0.25 : 0.35);
      if (buttons) this.button(device, Number(keys[index]), down, axis);
      else this.setHeld(source, keys[index], down);
    }
  }

  private setHeld(source: string, target: string, down: boolean): void {
    const previous: string | undefined = this.held.get(source);
    if (previous !== undefined && (!down || previous !== target)) {
      this.held.delete(source);
      const left: number = (this.counts.get(previous) ?? 1) - 1;
      if (left <= 0) { this.counts.delete(previous); this.output(previous, false); }
      else this.counts.set(previous, left);
    }
    if (!down || target === 'none' || target.length === 0 || this.held.has(source)) return;
    const count: number = this.counts.get(target) ?? 0;
    this.held.set(source, target);
    this.counts.set(target, count + 1);
    if (count === 0) this.output(target, true);
  }
}
