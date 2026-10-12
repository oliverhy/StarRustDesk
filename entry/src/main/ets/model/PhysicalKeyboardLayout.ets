import { keyboardRemapHarmonyCode } from './KeyboardRemapping';

export interface PhysicalKeyboardDescriptor {
  id: number;
  name: string;
  vendor: number;
  product: number;
  bus: number;
  uniq: string;
  phys: string;
}

export interface KeyboardLayoutRecord { fingerprint: string; swap: boolean; }
export interface KeyboardLayoutSnapshot {
  revision: number;
  ready: boolean;
  count: number;
  deviceId: number;
  deviceName: string;
  fingerprint: string;
  calibrated: boolean;
  swap: boolean;
}

export function validKeyboardLayoutMode(value: string): boolean {
  return value === 'auto' || value === 'system' || value === 'apple';
}

export function physicalKeyboardFingerprint(device: PhysicalKeyboardDescriptor): string {
  // A model name/VID/PID alone cannot distinguish two keyboards or their modes.
  // Persist only when the system supplies a physical/unique identity. Never save
  // that raw identity, device names, Bluetooth addresses, or ephemeral device IDs.
  const identity: string = (device.uniq || device.phys).trim();
  if (!identity || identity.length > 512 || !device.name.trim() || device.name.length > 256) return '';
  const raw: string = JSON.stringify([device.vendor, device.product, device.bus, device.name.trim(), identity]);
  let a: number = 2166136261;
  let b: number = 5381;
  for (let i = 0; i < raw.length; i++) {
    a = Math.imul(a ^ raw.charCodeAt(i), 16777619) >>> 0;
    b = (Math.imul(b, 33) ^ raw.charCodeAt(i)) >>> 0;
  }
  return `keyboard-v1-${a.toString(16).padStart(8, '0')}${b.toString(16).padStart(8, '0')}`;
}

export function decodeKeyboardLayoutRecords(raw: string): KeyboardLayoutRecord[] {
  if (!raw || raw.length > 8192) return [];
  try {
    const records = JSON.parse(raw) as KeyboardLayoutRecord[];
    if (!Array.isArray(records) || records.length > 24) return [];
    const seen: string[] = [];
    for (const record of records) {
      if (!record || typeof record !== 'object' || Array.isArray(record) ||
        Object.keys(record).some((key: string) => key !== 'fingerprint' && key !== 'swap') ||
        typeof record.fingerprint !== 'string' || !/^keyboard-v1-[0-9a-f]{16}$/.test(record.fingerprint) ||
        typeof record.swap !== 'boolean' || seen.includes(record.fingerprint)) return [];
      seen.push(record.fingerprint);
    }
    return records.map((record: KeyboardLayoutRecord): KeyboardLayoutRecord =>
      ({ fingerprint: record.fingerprint, swap: record.swap }));
  } catch (_error) { return []; }
}

export class KeyboardLayoutCapture {
  phase: string = 'idle';
  error: string = '';
  private held: number = 0;
  private command: number = 0;
  private option: number = 0;
  private deviceId: number;

  constructor(deviceId: number) { this.deviceId = deviceId; }

  begin(): void {
    this.phase = 'command'; this.error = ''; this.held = this.command = this.option = 0;
  }

  input(harmonyCode: number, action: number, deviceId: number): void {
    if (this.phase === 'idle' || this.phase === 'done') return;
    if (deviceId !== this.deviceId) { this.error = 'device'; return; }
    const code: number = keyboardRemapHarmonyCode(harmonyCode);
    if (action === 1) {
      if (code !== this.held || this.held === 0) return;
      this.held = 0;
      if (this.phase === 'command-release') this.phase = 'option';
      else if (this.phase === 'option-release') this.phase = 'done';
      return;
    }
    if (action !== 0 || this.held !== 0) return;
    if (code !== 18 && code !== 91) { this.error = 'modifier'; return; }
    this.error = '';
    if (this.phase === 'command') {
      this.command = code; this.held = code; this.phase = 'command-release';
    } else if (this.phase === 'option') {
      if (code === this.command) { this.error = 'same'; return; }
      this.option = code; this.held = code; this.phase = 'option-release';
    }
  }

  result(): boolean | undefined {
    if (this.phase !== 'done') return undefined;
    if (this.command === 91 && this.option === 18) return false;
    if (this.command === 18 && this.option === 91) return true;
    return undefined;
  }
}
