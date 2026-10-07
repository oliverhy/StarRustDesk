import { decodeRemotePeerOptions, remotePeerPreferenceKey, validRemotePeerOption } from '../model/RemotePeerOptions';
import { RustDeskNapi } from './RustDeskNapi';

// One local document per server + peer. These are UI/input preferences only;
// the allowlist excludes passwords, clipboard data and live pressed-key state.
export class RemotePeerPreferences {
  private key: string;
  private values: Map<string, string> = new Map<string, string>();
  private timer: number = -1;
  private dirty: boolean = false;
  private disposed: boolean = false;

  constructor(server: string, peer: string) {
    this.key = remotePeerPreferenceKey(server, peer);
    try {
      if (this.key) this.values = decodeRemotePeerOptions(RustDeskNapi.getOption(this.key));
      this.log(`restored scoped=${this.key.length > 0} overrides=${this.values.size}`);
    } catch (_error) {
      this.log('restore_failed fallback=legacy_defaults');
    }
  }

  has(name: string): boolean {
    return this.values.has(name);
  }

  get(name: string, legacyKey: string = ''): string {
    const saved: string | undefined = this.values.get(name);
    if (saved !== undefined) return saved;
    if (!legacyKey) return '';
    try { return RustDeskNapi.getOption(legacyKey); } catch (_error) { return ''; }
  }

  set(name: string, value: string): boolean {
    if (this.disposed || !this.key || !validRemotePeerOption(name, value)) return false;
    if (this.values.get(name) === value) return true;
    this.values.set(name, value);
    this.dirty = true;
    if (this.timer !== -1) clearTimeout(this.timer);
    // Sliders/gesture updates coalesce into one write, never one write/frame.
    this.timer = setTimeout(() => { this.timer = -1; this.flush(); }, 180);
    return true;
  }

  flush(): boolean {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (!this.dirty || !this.key) return true;
    try {
      const record: Record<string, string> = {};
      this.values.forEach((value: string, name: string) => { record[name] = value; });
      const result: number = RustDeskNapi.setOption(this.key, JSON.stringify(record));
      if (result === 0) this.dirty = false;
      this.log(`save_complete result=${result} overrides=${this.values.size}`);
      return result === 0;
    } catch (_error) {
      this.log('save_failed active_preferences_preserved=1');
      return false;
    }
  }

  dispose(): void {
    this.flush();
    this.disposed = true;
  }

  private log(message: string): void {
    try { RustDeskNapi.appendDiagnosticLog('peer-settings', message); } catch (_error) {}
  }
}
