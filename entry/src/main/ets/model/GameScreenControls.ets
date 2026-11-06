import { GAMEPAD_TARGETS, GamepadTarget } from './GamepadMapping';

export interface ScreenGameKey { id: number; target: string; x: number; y: number; size: number; opacity: number }
export interface ScreenGameProfile { name: string; keys: ScreenGameKey[] }
export interface ScreenGameConfig { version: number; active: number; profiles: ScreenGameProfile[] }

export function defaultScreenGameConfig(): ScreenGameConfig {
  return { version: 1, active: 0, profiles: [
    { name: '方案 1', keys: [] }, { name: '方案 2', keys: [] }, { name: '方案 3', keys: [] }
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
