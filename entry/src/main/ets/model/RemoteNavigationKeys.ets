// Protocol actions: down=0, up=1, press=2. Negative values do not send a packet.
export const NAVIGATION_LOCAL: number = -1;
export const NAVIGATION_HANDLED: number = -2;

export function isNavigationControlKey(code: number): boolean {
  return (code >= 33 && code <= 40) || code === 45;
}

export function navigationKeyName(code: number): string {
  switch (code) {
    case 33: return 'PageUp';
    case 34: return 'PageDown';
    case 35: return 'End';
    case 36: return 'Home';
    case 37: return 'Left';
    case 38: return 'Up';
    case 39: return 'Right';
    case 40: return 'Down';
    case 45: return 'Insert';
    default: return 'Unknown';
  }
}

export class RemoteNavigationKeys {
  private remoteKeys: Map<number, string> = new Map<number, string>();
  private localKeys: Set<number> = new Set<number>();

  route(code: number, down: boolean, source: string, composing: boolean): number {
    if (!down) {
      // Balance a remote key-down even if IME composition started in between.
      if (this.remoteKeys.has(code)) {
        this.remoteKeys.delete(code);
        this.localKeys.delete(code);
        return 1;
      }
      if (this.localKeys.delete(code)) return NAVIGATION_LOCAL;
      // Pre-IME and normal dispatch may both see a locally owned key-up.
      // An unmatched release sends nothing and remains available to the IME.
      return NAVIGATION_LOCAL;
    }
    if (composing || this.localKeys.has(code)) {
      // A candidate-selection press stays local through its matching release,
      // including when committing the candidate ends composition mid-press.
      this.localKeys.add(code);
      return NAVIGATION_LOCAL;
    }
    const owner: string | undefined = this.remoteKeys.get(code);
    if (owner !== undefined) {
      // ArkUI and XComponent can both report one physical press. Only the
      // original route supplies repeats; either route may supply the release.
      return owner === source ? 2 : NAVIGATION_HANDLED;
    }
    this.remoteKeys.set(code, source);
    return 0;
  }

  reset(): number[] {
    const held: number[] = [];
    this.remoteKeys.forEach((_source: string, code: number) => { held.push(code); });
    this.remoteKeys.clear();
    this.localKeys.clear();
    return held;
  }
}
