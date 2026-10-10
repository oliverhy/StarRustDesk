export interface KeyboardRemapRule {
  source: number;
  target: number;
  modifiers: number;
  enabled: boolean;
}

export interface KeyboardRemapConfig {
  version: number;
  enabled: boolean;
  rules: KeyboardRemapRule[];
}

export const KEYBOARD_REMAP_KEYS: number[] = [17, 163, 91, 92, 18, 165, 16, 161,
  112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123,
  27, 9, 13, 8, 46, 45, 36, 35, 33, 34, 37, 38, 39, 40];

export function keyboardModifierBit(code: number): number {
  if (code === 17 || code === 163) return 1;
  if (code === 16 || code === 161) return 2;
  if (code === 18 || code === 165) return 4;
  if (code === 91 || code === 92) return 8;
  return 0;
}

export function validKeyboardRemap(config: KeyboardRemapConfig): boolean {
  if (!config || typeof config !== 'object' || Array.isArray(config) || config.version !== 1 ||
    typeof config.enabled !== 'boolean' || !Array.isArray(config.rules) || config.rules.length > 24 ||
    Object.keys(config).some((key: string) => !['version', 'enabled', 'rules'].includes(key))) return false;
  const sources: number[] = [];
  for (const rule of config.rules) {
    if (!rule || typeof rule !== 'object' || Array.isArray(rule) ||
      Object.keys(rule).some((key: string) => !['source', 'target', 'modifiers', 'enabled'].includes(key)) ||
      !KEYBOARD_REMAP_KEYS.includes(rule.source) || !KEYBOARD_REMAP_KEYS.includes(rule.target) ||
      !Number.isInteger(rule.modifiers) || rule.modifiers < 0 || rule.modifiers > 15 ||
      typeof rule.enabled !== 'boolean' || sources.includes(rule.source)) return false;
    // Modifier remapping must remain a held modifier, never a character/macro.
    // Plain keys cannot acquire a latched modifier through a one-key mapping.
    if ((keyboardModifierBit(rule.source) !== 0) !== (keyboardModifierBit(rule.target) !== 0) ||
      (keyboardModifierBit(rule.source) !== 0 && rule.modifiers !== 0)) return false;
    sources.push(rule.source);
  }
  return true;
}

export function decodeKeyboardRemap(value: string): KeyboardRemapConfig {
  const fallback: KeyboardRemapConfig = { version: 1, enabled: false, rules: [] };
  if (!value || value.length > 2048) return fallback;
  try {
    const config: KeyboardRemapConfig = JSON.parse(value) as KeyboardRemapConfig;
    if (!validKeyboardRemap(config)) return fallback;
    return { version: 1, enabled: config.enabled, rules: config.rules.map((rule: KeyboardRemapRule): KeyboardRemapRule =>
      ({ source: rule.source, target: rule.target, modifiers: rule.modifiers, enabled: rule.enabled })) };
  } catch (_error) { return fallback; }
}

export function validKeyboardRemapValue(value: string): boolean {
  if (!value || value.length > 2048) return false;
  try { return validKeyboardRemap(JSON.parse(value) as KeyboardRemapConfig); } catch (_error) { return false; }
}

export function keyboardRemapRule(config: KeyboardRemapConfig, source: number): KeyboardRemapRule | undefined {
  return config.enabled ? config.rules.find((rule: KeyboardRemapRule) => rule.enabled && rule.source === source) : undefined;
}

export function keyboardRemapPreset(name: string, enabled: boolean): KeyboardRemapConfig {
  let rules: KeyboardRemapRule[] = [];
  if (name === 'macCtrl' || name === 'macSwap') {
    rules = [{ source: 17, target: 91, modifiers: 0, enabled: true },
      { source: 163, target: 92, modifiers: 0, enabled: true }];
    if (name === 'macSwap') rules.push({ source: 91, target: 17, modifiers: 0, enabled: true },
      { source: 92, target: 163, modifiers: 0, enabled: true });
  } else if (name === 'macMission') {
    rules = [{ source: 114, target: 38, modifiers: 1, enabled: true }];
  }
  return { version: 1, enabled, rules };
}

export function keyboardRemapKeyLabel(code: number): string {
  if (code >= 112 && code <= 123) return `F${code - 111}`;
  switch (code) {
    case 17: return 'L Ctrl'; case 163: return 'R Ctrl';
    case 91: return 'L Win/Cmd'; case 92: return 'R Win/Cmd';
    case 18: return 'L Alt/Option'; case 165: return 'R Alt/Option';
    case 16: return 'L Shift'; case 161: return 'R Shift';
    case 27: return 'Esc'; case 9: return 'Tab'; case 13: return 'Enter';
    case 8: return 'Backspace'; case 46: return 'Delete'; case 45: return 'Insert';
    case 36: return 'Home'; case 35: return 'End'; case 33: return 'PageUp'; case 34: return 'PageDown';
    case 37: return '←'; case 38: return '↑'; case 39: return '→'; case 40: return '↓';
    default: return '?';
  }
}

export function keyboardRemapTargetLabel(rule: KeyboardRemapRule): string {
  let prefix: string = '';
  if ((rule.modifiers & 1) !== 0) prefix += 'Ctrl+';
  if ((rule.modifiers & 2) !== 0) prefix += 'Shift+';
  if ((rule.modifiers & 4) !== 0) prefix += 'Alt/Option+';
  if ((rule.modifiers & 8) !== 0) prefix += 'Win/Cmd+';
  return prefix + keyboardRemapKeyLabel(rule.target);
}

export function keyboardRemapHarmonyCode(code: number): number {
  if (code >= 2090 && code <= 2101) return 112 + code - 2090;
  const native: number[] = [2072, 2073, 2076, 2077, 2045, 2046, 2047, 2048,
    2070, 2049, 2054, 2055, 2071, 2083, 2081, 2082, 2068, 2069, 2014, 2012, 2015, 2013];
  const keys: number[] = [17, 163, 91, 92, 18, 165, 16, 161,
    27, 9, 13, 8, 46, 45, 36, 35, 33, 34, 37, 38, 39, 40];
  const index: number = native.indexOf(code);
  return index >= 0 ? keys[index] : 0;
}
