import inputDevice from '@ohos.multimodalInput.inputDevice';
import { RustDeskNapi } from './RustDeskNapi';
import { KeyboardLayoutRecord, KeyboardLayoutSnapshot, PhysicalKeyboardDescriptor,
  decodeKeyboardLayoutRecords, physicalKeyboardFingerprint, validKeyboardLayoutMode } from '../model/PhysicalKeyboardLayout';

const CALIBRATION_OPTION: string = 'physical-keyboard-layout-v1';

export class PhysicalKeyboardLayoutService {
  private active: boolean = false;
  private epoch: number = 0;
  private subscribed: boolean = false;
  private mode: string = 'auto';
  private devices: PhysicalKeyboardDescriptor[] = [];
  private records: KeyboardLayoutRecord[] = [];
  private sessionRecord: KeyboardLayoutRecord | undefined = undefined;
  private ready: boolean = false;
  private listener: (event: inputDevice.DeviceListener) => void = () => { this.refresh(); };
  private onChange: (state: KeyboardLayoutSnapshot) => void;
  private apply: (swap: boolean) => void;

  constructor(onChange: (state: KeyboardLayoutSnapshot) => void, apply: (swap: boolean) => void) {
    this.onChange = onChange; this.apply = apply;
  }

  start(mode: string): void {
    if (this.active) { this.setMode(mode); return; }
    this.active = true;
    this.mode = validKeyboardLayoutMode(mode) ? mode : 'auto';
    try { this.records = decodeKeyboardLayoutRecords(RustDeskNapi.getOption(CALIBRATION_OPTION)); }
    catch (_error) { this.records = []; this.log('calibration_load_failed'); }
    try { inputDevice.on('change', this.listener); this.subscribed = true; }
    catch (_error) { this.log('device_listener_unavailable'); }
    this.refresh();
  }

  stop(): void {
    this.active = false; this.epoch++; this.ready = false;
    this.devices = []; this.sessionRecord = undefined;
    if (this.subscribed) {
      try { inputDevice.off('change', this.listener); } catch (_error) {}
      this.subscribed = false;
    }
    try { this.apply(false); } catch (_error) { this.log('state_apply_failed'); }
  }

  setMode(mode: string): void {
    if (!validKeyboardLayoutMode(mode)) return;
    this.mode = mode;
    if (this.active) this.publish();
  }

  snapshot(): KeyboardLayoutSnapshot {
    const device: PhysicalKeyboardDescriptor | undefined = this.ready && this.devices.length === 1 ? this.devices[0] : undefined;
    const fingerprint: string = device ? physicalKeyboardFingerprint(device) : '';
    const record: KeyboardLayoutRecord | undefined = device ?
      (fingerprint ? this.records.find((item: KeyboardLayoutRecord) => item.fingerprint === fingerprint) : this.sessionRecord) : undefined;
    return { revision: this.epoch, ready: this.ready, count: this.devices.length,
      deviceId: device?.id ?? -1, deviceName: device?.name ?? '', fingerprint,
      calibrated: record !== undefined, swap: record?.swap ?? false };
  }

  saveCalibration(captured: KeyboardLayoutSnapshot, swap: boolean): boolean {
    const current: KeyboardLayoutSnapshot = this.snapshot();
    if (!this.active || !current.ready || current.count !== 1 || current.deviceId < 0 ||
      captured.revision !== current.revision || captured.deviceId !== current.deviceId ||
      captured.fingerprint !== current.fingerprint) {
      this.log('calibration_rejected stale_or_ambiguous=1'); return false;
    }
    const record: KeyboardLayoutRecord = { fingerprint: current.fingerprint, swap };
    if (current.fingerprint) {
      const next: KeyboardLayoutRecord[] = this.records.filter((item: KeyboardLayoutRecord) =>
        item.fingerprint !== current.fingerprint);
      next.push(record);
      const bounded: KeyboardLayoutRecord[] = next.slice(-24);
      try {
        const value: string = JSON.stringify(bounded);
        if (RustDeskNapi.setOption(CALIBRATION_OPTION, value) !== 0 ||
          RustDeskNapi.getOption(CALIBRATION_OPTION) !== value) {
          this.log('calibration_save_failed'); return false;
        }
      } catch (_error) { this.log('calibration_save_failed'); return false; }
      this.records = bounded;
    } else {
      // Unidentified keyboards are session-only; never restore onto another device.
      this.sessionRecord = record;
    }
    this.publish();
    this.log(`calibration_saved swap=${swap ? 1 : 0} persistent=${current.fingerprint ? 1 : 0}`);
    return true;
  }

  async refresh(): Promise<void> {
    if (!this.active) return;
    const epoch: number = ++this.epoch;
    this.ready = false; this.devices = []; this.sessionRecord = undefined;
    this.publish();
    let timeout: number = -1;
    try {
      const devices: PhysicalKeyboardDescriptor[] = [];
      const query = (async (): Promise<(PhysicalKeyboardDescriptor | undefined)[]> => {
        const ids: number[] = await inputDevice.getDeviceList();
        if (ids.length > 64) throw new Error('Device inventory too large');
        return Promise.all(Array.from(new Set(ids)).map(async (id: number): Promise<PhysicalKeyboardDescriptor | undefined> => {
          const info: inputDevice.InputDeviceData = await inputDevice.getDeviceInfo(id);
          if (!info.sources.includes('keyboard') || info.isVirtual === true) return undefined;
          const type: inputDevice.KeyboardType = await inputDevice.getKeyboardType(id);
          if (type !== inputDevice.KeyboardType.ALPHABETIC_KEYBOARD) return undefined;
          return { id, name: info.name.slice(0, 256), vendor: info.vendor, product: info.product,
            bus: info.bus, uniq: typeof info.uniq === 'string' ? info.uniq : '',
            phys: typeof info.phys === 'string' ? info.phys : '' };
        }));
      })();
      const deadline = new Promise<(PhysicalKeyboardDescriptor | undefined)[]>((_resolve, reject) => {
        timeout = setTimeout(() => { reject(new Error('Device query timeout')); }, 4000);
      });
      const discovered = await Promise.race([query, deadline]);
      if (!this.active || epoch !== this.epoch) return;
      discovered.forEach((device: PhysicalKeyboardDescriptor | undefined) => { if (device) devices.push(device); });
      this.devices = devices; this.ready = true; this.publish();
      this.log(`devices_ready count=${devices.length} calibrated=${this.snapshot().calibrated ? 1 : 0}`);
    } catch (_error) {
      if (!this.active || epoch !== this.epoch) return;
      // An incomplete list must not look like one safely identified keyboard.
      this.devices = []; this.ready = false; this.publish(); this.log('device_query_failed fallback=system');
    } finally { if (timeout !== -1) clearTimeout(timeout); }
  }

  private publish(): void {
    if (!this.active) return;
    const state: KeyboardLayoutSnapshot = this.snapshot();
    // Brand names never authorize an automatic swap. Multiple/unknown devices
    // fail closed because the native XComponent route has no keyboard device ID.
    try { this.apply(this.mode !== 'system' && state.ready && state.count === 1 && state.calibrated && state.swap); }
    catch (_error) { this.log('state_apply_failed'); }
    try { this.onChange(state); } catch (_error) { this.log('state_publish_failed'); }
  }

  private log(message: string): void {
    try { RustDeskNapi.appendDiagnosticLog('input-layout', message); } catch (_error) {}
  }
}
