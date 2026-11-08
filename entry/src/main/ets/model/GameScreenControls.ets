import { GAMEPAD_TARGETS, GamepadTarget } from './GamepadMapping';

export interface ScreenGameKey { id: number; target: string; x: number; y: number; size: number; opacity: number }
export interface ScreenGameProfile { name: string; keys: ScreenGameKey[] }
export interface ScreenGameConfig { version: number; active: number; profiles: ScreenGameProfile[] }

// A usable starting point for a new peer. Existing saved profiles, including
// deliberately empty ones, remain untouched until the user chooses a preset.
export function defaultScreenGameKeys(viewportWidth: number = 360, viewportHeight: number = 720): ScreenGameKey[] {
  const width: number = Number.isFinite(viewportWidth) && viewportWidth > 0 ? viewportWidth : 360;
  const height: number = Number.isFinite(viewportHeight) && viewportHeight > 0 ? viewportHeight : 720;
  const size: number = Math.max(36, Math.min(52, Math.floor(width / 6.5), Math.floor(height / 4)));
  const gap: number = Math.max(4, Math.round(size * 0.1));
  const margin: number = Math.min(12, Math.max(0, width - size));
  const bottom: number = Math.max(8, Math.min(68, height * 0.16));
  const low: number = Math.max(0, height - bottom - size);
  const high: number = Math.max(0, low - size - gap);
  const right: number = Math.max(0, width - margin - size);
  const x: (value: number) => number = (value: number): number => Math.max(0, Math.min(1, value / Math.max(1, width - size)));
  const y: (value: number) => number = (value: number): number => Math.max(0, Math.min(1, value / Math.max(1, height - size)));
  return [
    { id: 1, target: 'k:26', x: x(margin + size + gap), y: y(high), size, opacity: 70 },
    { id: 2, target: 'k:4', x: x(margin), y: y(low), size, opacity: 70 },
    { id: 3, target: 'k:22', x: x(margin + size + gap), y: y(low), size, opacity: 70 },
    { id: 4, target: 'k:7', x: x(margin + 2 * (size + gap)), y: y(low), size, opacity: 70 },
    { id: 5, target: 'mouse:left', x: x(right - size - gap), y: y(high), size, opacity: 70 },
    { id: 6, target: 'mouse:right', x: x(right), y: y(high), size, opacity: 70 },
    // Keep the lower action away from the default keyboard launcher at the right edge.
    { id: 7, target: 'k:44', x: x(right - size - gap), y: y(low), size, opacity: 70 }
  ];
}

export function defaultScreenGameConfig(): ScreenGameConfig {
  return { version: 1, active: 0, profiles: [
    { name: '方案 1', keys: defaultScreenGameKeys() }, { name: '方案 2', keys: [] }, { name: '方案 3', keys: [] }
  ] };
}

export function validScreenGameConfig(config: ScreenGameConfig): boolean {
  if (!config || config.version !== 1 || !Number.isInteger(config.active) || config.active < 0 || config.active > 2 ||
    !Array.isArray(config.profiles) || config.profiles.length !== 3) return false;
  for (const profile of config.profiles) {
    if (!profile || typeof profile.name !== 'string' || profile.name.length < 1 || profile.name.length > 16 ||
      !Array.isArray(profile.keys) || profile.keys.length > 12) return false;
    const ids: number[] = [];
    for (const key of profile.keys) {
      if (!key || !Number.isInteger(key.id) || key.id < 1 || key.id > 9999 || ids.includes(key.id) ||
        !GAMEPAD_TARGETS.some((target: GamepadTarget) => target.value === key.target && target.value !== 'none') ||
        !Number.isFinite(key.x) || key.x < 0 || key.x > 1 || !Number.isFinite(key.y) || key.y < 0 || key.y > 1 ||
        !Number.isInteger(key.size) || key.size < 36 || key.size > 100 ||
        !Number.isInteger(key.opacity) || key.opacity < 20 || key.opacity > 100) return false;
      ids.push(key.id);
    }
  }
  return true;
}

export function decodeScreenGameConfig(value: string): ScreenGameConfig {
  if (!value || value.length > 4096) return defaultScreenGameConfig();
  try { const config: ScreenGameConfig = JSON.parse(value) as ScreenGameConfig;
    if (validScreenGameConfig(config)) return config;
  } catch (_error) {}
  return defaultScreenGameConfig();
}

export function validScreenGameConfigValue(value: string): boolean {
  if (!value || value.length > 4096) return false;
  try { return validScreenGameConfig(JSON.parse(value) as ScreenGameConfig); } catch (_error) { return false; }
}
