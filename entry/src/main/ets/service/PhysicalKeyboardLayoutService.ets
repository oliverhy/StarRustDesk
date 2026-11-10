import inputDevice from '@ohos.multimodalInput.inputDevice';
import { RustDeskNapi } from './RustDeskNapi';
import { KeyboardLayoutBinding, KeyboardLayoutRecord, KeyboardLayoutSnapshot, PhysicalKeyboardDescriptor,
  decodeKeyboardLayoutRecords, physicalKeyboardFingerprint, validKeyboardLayoutMode } from '../model/PhysicalKeyboardLayout';

const CALIBRATION_OPTION: string = 'physical-keyboard-layout-v1';

export class PhysicalKeyboardLayoutService {
  private active: boolean = false;
  private epoch: number = 0;
  private subscribed: boolean = false;
  private mode: string = 'auto';
  private devices: PhysicalKeyboardDescriptor[] = [];
  private records: KeyboardLayoutRecord[] = [];
  private sessionRecords: KeyboardLayoutBinding[] = [];
  private ready: boolean = false;
  private listener: (event: inputDevice.DeviceListener) => void = () => { this.refresh(); };
  private onChange: (state: KeyboardLayoutSnapshot) => void;
  private apply: (swap: boolean, bindings: KeyboardLayoutBinding[]) => void;

  constructor(onChange: (state: KeyboardLayoutSnapshot) => void,
    apply: (swap: boolean, bindings: KeyboardLayoutBinding[]) => void) {
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
    this.devices = []; this.sessionRecords = [];
    if (this.subscribed) {
      try { inputDevice.off('change', this.listener); } catch (_error) {}
      this.subscribed = false;
    }
    try { this.apply(false, []); } catch (_error) { this.log('state_apply_failed'); }
  }

  setMode(mode: string): void {
    if (!validKeyboardLayoutMode(mode)) return;
    this.mode = mode;
    if (this.active) this.publish();
  }

  snapshot(): KeyboardLayoutSnapshot {
    const device: PhysicalKeyboardDescriptor | undefined = this.ready && this.devices.length === 1 ? this.devices[0] : undefined;
    const fingerprint: string = device ? this.uniqueFingerprint(device) : '';
    const record: KeyboardLayoutBinding | undefined = device ? this.binding(device) : undefined;
    return { revision: this.epoch, ready: this.ready, count: this.devices.length,
      deviceId: device?.id ?? -1, deviceName: device?.name ?? '', fingerprint,
      calibrated: record?.calibrated ?? false, swap: record?.swap ?? false };
  }

  calibrationDeviceIds(): number[] {
    return this.active && this.ready ? this.devices.map((device: PhysicalKeyboardDescriptor) => device.id) : [];
  }

  private uniqueFingerprint(device: PhysicalKeyboardDescriptor): string {
    const fingerprint: string = physicalKeyboardFingerprint(device);
    if (!fingerprint) return '';
    return this.devices.filter((item: PhysicalKeyboardDescriptor) =>
      physicalKeyboardFingerprint(item) === fingerprint).length === 1 ? fingerprint : '';
  }

  private binding(device: PhysicalKeyboardDescriptor): KeyboardLayoutBinding {
    const session = this.sessionRecords.find((item: KeyboardLayoutBinding) => item.deviceId === device.id);
    const fingerprint: string = this.uniqueFingerprint(device);
    const record: KeyboardLayoutRecord | undefined = fingerprint ?
      this.records.find((item: KeyboardLayoutRecord) => item.fingerprint === fingerprint) : undefined;
    return { deviceId: device.id, swap: session?.swap ?? record?.swap ?? false,
      calibrated: session !== undefined || record !== undefined };
  }

  saveCalibration(captured: KeyboardLayoutSnapshot, swap: boolean): boolean {
    const current: KeyboardLayoutSnapshot = this.snapshot();
    if (!this.active || !current.ready || current.count !== 1 || current.deviceId < 0 ||
      captured.revision !== current.revision || captured.deviceId !== current.deviceId ||
      captured.fingerprint !== current.fingerprint) {
      this.log('calibration_rejected stale_or_ambiguous=1'); return false;
    }
    return this.saveCalibrationForDevices(captured.revision, [captured.deviceId], swap);
  }

  saveCalibrationForDevices(revision: number, deviceIds: number[], swap: boolean): boolean {
    const unique: number[] = Array.from(new Set(deviceIds));
    if (!this.active || !this.ready || this.mode !== 'apple' || revision !== this.epoch || typeof swap !== 'boolean' ||
      unique.length < 1 || unique.length > 2 || unique.length !== deviceIds.length ||
      unique.some((id: number) => !Number.isSafeInteger(id) || id < 0 ||
        !this.devices.some((device: PhysicalKeyboardDescriptor) => device.id === id))) {
      this.log('calibration_rejected stale_or_ambiguous=1'); return false;
    }
    const fingerprints: string[] = unique.map((id: number) => {
      const device = this.devices.find((item: PhysicalKeyboardDescriptor) => item.id === id);
      return device ? this.uniqueFingerprint(device) : '';
    });
    const persistent: string[] = fingerprints.filter((fingerprint: string) => fingerprint.length > 0);
    if (persistent.length > 0) {
      const next: KeyboardLayoutRecord[] = this.records.filter((item: KeyboardLayoutRecord) =>
        !persistent.includes(item.fingerprint));
      persistent.forEach((fingerprint: string) => { next.push({ fingerprint, swap }); });
      const bounded: KeyboardLayoutRecord[] = next.slice(-24);
      try {
        const value: string = JSON.stringify(bounded);
        if (RustDeskNapi.setOption(CALIBRATION_OPTION, value) !== 0 ||
          RustDeskNapi.getOption(CALIBRATION_OPTION) !== value) {
          this.log('calibration_save_failed'); return false;
        }
      } catch (_error) { this.log('calibration_save_failed'); return false; }
      this.records = bounded;
    }
    // Unidentified or ambiguous fingerprints are tied only to these device IDs
    // for this inventory revision; never restore them onto another keyboard.
    this.sessionRecords = this.sessionRecords.filter((item: KeyboardLayoutBinding) => !unique.includes(item.deviceId));
    unique.forEach((id: number, index: number) => {
      if (!fingerprints[index]) this.sessionRecords.push({ deviceId: id, swap, calibrated: true });
    });
    this.publish();
    this.log(`calibration_saved devices=${unique.length} persistent=${persistent.length} session_only=${unique.length - persistent.length}`);
    return true;
  }

  async refresh(): Promise<void> {
    if (!this.active) return;
    const epoch: number = ++this.epoch;
    this.ready = false; this.devices = []; this.sessionRecords = [];
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
          // Some composite keyboards report the modifier interface as UNKNOWN.
          // Such devices cannot acquire a mapping without explicit calibration.
          if (type !== inputDevice.KeyboardType.ALPHABETIC_KEYBOARD && type !== inputDevice.KeyboardType.UNKNOWN) return undefined;
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
      const calibrated: number = devices.filter((device: PhysicalKeyboardDescriptor) => this.binding(device).calibrated).length;
      this.log(`devices_ready count=${devices.length} calibrated=${calibrated}`);
    } catch (_error) {
      if (!this.active || epoch !== this.epoch) return;
      // An incomplete list must not look like one safely identified keyboard.
      this.devices = []; this.ready = false; this.publish(); this.log('device_query_failed fallback=system');
    } finally { if (timeout !== -1) clearTimeout(timeout); }
  }

  private publish(): void {
    if (!this.active) return;
    const state: KeyboardLayoutSnapshot = this.snapshot();
    // Per-device bindings require confirmed calibration. Unknown IDs and
    // ambiguous fingerprints never inherit another keyboard's calibration.
    const bindings: KeyboardLayoutBinding[] = state.ready && this.mode !== 'system' ?
      this.devices.map((device: PhysicalKeyboardDescriptor) => this.binding(device)) : [];
    try { this.apply(this.mode !== 'system' && state.ready && state.count === 1 && state.calibrated && state.swap, bindings); }
    catch (_error) { this.log('state_apply_failed'); }
    try { this.onChange(state); } catch (_error) { this.log('state_publish_failed'); }
  }

  private log(message: string): void {
    try { RustDeskNapi.appendDiagnosticLog('input-layout', message); } catch (_error) {}
  }
}
