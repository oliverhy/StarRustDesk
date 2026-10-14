import { display, window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { RustDeskNapi } from './RustDeskNapi';

export enum RemoteOrientationMode {
  SYSTEM = 'system',
  AUTO = 'auto',
  PORTRAIT = 'portrait',
  LANDSCAPE = 'landscape',
}

// Adapts the existing system-projected main window; does not initiate casting
// or create a second remote session/surface.
export class RemoteDisplayPolicy {
  private static main: window.Window | undefined;
  private static localDisplayId: number = -1;
  private static currentDisplayId: number = -1;
  private static original: window.Orientation = window.Orientation.AUTO_ROTATION_RESTRICTED;
  private static localMode: RemoteOrientationMode = RemoteOrientationMode.AUTO;
  private static followSystem: boolean = true;
  private static projectionMode: RemoteOrientationMode = RemoteOrientationMode.SYSTEM;
  private static active: boolean = false;
  private static pending: Promise<void> = Promise.resolve();
  private static changed = (id: number): void => {
    RemoteDisplayPolicy.currentDisplayId = id;
    RemoteDisplayPolicy.publishDisplayState();
    RemoteDisplayPolicy.apply();
  };

  static attach(main: window.Window): void {
    RemoteDisplayPolicy.detach();
    RemoteDisplayPolicy.main = main;
    RemoteDisplayPolicy.active = false;
    RemoteDisplayPolicy.projectionMode = RemoteOrientationMode.SYSTEM;
    RemoteDisplayPolicy.loadRotationPreferences();
    AppStorage.setOrCreate('remoteOrientationError', '');
    RemoteDisplayPolicy.original = window.Orientation.AUTO_ROTATION_RESTRICTED;
    try {
      RemoteDisplayPolicy.localDisplayId = display.getDefaultDisplaySync().id;
      const original = main.getPreferredOrientation();
      // Never restore the old sensor-only default after a session/projection.
      RemoteDisplayPolicy.original = original === window.Orientation.AUTO_ROTATION ?
        window.Orientation.AUTO_ROTATION_RESTRICTED : original;
      main.on('displayIdChange', RemoteDisplayPolicy.changed);
    } catch (_e) {
      RustDeskNapi.appendDiagnosticLog('projection', 'display_listener_unavailable');
    }
    RemoteDisplayPolicy.refresh();
  }

  static detach(): void {
    try { RemoteDisplayPolicy.main?.off('displayIdChange', RemoteDisplayPolicy.changed); } catch (_e) {}
    RemoteDisplayPolicy.main = undefined;
    RemoteDisplayPolicy.localDisplayId = -1;
    RemoteDisplayPolicy.currentDisplayId = -1;
    RemoteDisplayPolicy.publishDisplayState();
  }

  private static publishDisplayState(): void {
    const external: boolean = RemoteDisplayPolicy.localDisplayId >= 0 &&
      RemoteDisplayPolicy.currentDisplayId >= 0 &&
      RemoteDisplayPolicy.localDisplayId !== RemoteDisplayPolicy.currentDisplayId;
    AppStorage.setOrCreate('remoteExternalDisplay', external);
    AppStorage.setOrCreate('remoteProjectionDisplayId', RemoteDisplayPolicy.currentDisplayId);
    AppStorage.setOrCreate('remoteFollowSystemRotation', RemoteDisplayPolicy.followSystem);
    AppStorage.setOrCreate('remoteOrientationMode', !RemoteDisplayPolicy.active ? RemoteOrientationMode.SYSTEM :
      external ? RemoteDisplayPolicy.projectionMode : RemoteDisplayPolicy.followSystem ?
        RemoteOrientationMode.SYSTEM : RemoteDisplayPolicy.localMode);
    RemoteDisplayPolicy.publishHdrCapability();
  }

  private static publishHdrCapability(): void {
    let mask: number = 0;
    try {
      // Query the owning window's display, not the phone screen when projected.
      const target = RemoteDisplayPolicy.currentDisplayId >= 0 ?
        display.getDisplayByIdSync(RemoteDisplayPolicy.currentDisplayId) : display.getDefaultDisplaySync();
      for (const format of target.hdrFormats ?? []) {
        if (format === 1) mask |= 1; // VIDEO_HLG
        if (format === 2) mask |= 2; // VIDEO_HDR10
        if (format === 3) mask |= 4; // VIDEO_HDR_VIVID
      }
    } catch (_error) {
      // Older systems / disconnected external displays: never claim HDR output.
    }
    RustDeskNapi.setHdrDisplayFormats(mask);
  }

  static getMainWindow(): window.Window | undefined {
    return RemoteDisplayPolicy.main;
  }

  static getIndependentOrientationMode(): RemoteOrientationMode {
    return RemoteDisplayPolicy.localMode;
  }

  private static loadRotationPreferences(): void {
    try { RemoteDisplayPolicy.followSystem = RustDeskNapi.getOption('remote-follow-system-rotation') !== '0'; }
    catch (_error) {
      RemoteDisplayPolicy.followSystem = true;
      RustDeskNapi.appendDiagnosticLog('projection', 'rotation_preference_read_failed fallback=system');
    }
    try {
      const mode: string = RustDeskNapi.getOption('remote-independent-orientation');
      RemoteDisplayPolicy.localMode = mode === RemoteOrientationMode.PORTRAIT ? RemoteOrientationMode.PORTRAIT :
        mode === RemoteOrientationMode.LANDSCAPE ? RemoteOrientationMode.LANDSCAPE : RemoteOrientationMode.AUTO;
    } catch (_error) {
      RemoteDisplayPolicy.localMode = RemoteOrientationMode.AUTO;
      RustDeskNapi.appendDiagnosticLog('projection', 'independent_orientation_read_failed fallback=auto');
    }
  }

  private static targetIsCurrent(expectedDisplayId?: number): boolean {
    if (!RemoteDisplayPolicy.main || !RemoteDisplayPolicy.active ||
      (deviceInfo.deviceType !== 'phone' && deviceInfo.deviceType !== 'tablet') ||
      RemoteDisplayPolicy.localDisplayId < 0 || RemoteDisplayPolicy.currentDisplayId < 0) return false;
    try {
      const id = RemoteDisplayPolicy.main.getWindowProperties().displayId;
      return id === RemoteDisplayPolicy.currentDisplayId &&
        (expectedDisplayId === undefined || id === expectedDisplayId);
    } catch (_error) { return false; }
  }

  static setFollowSystemRotation(follow: boolean, expectedDisplayId?: number): boolean {
    if (typeof follow !== 'boolean' || !RemoteDisplayPolicy.targetIsCurrent(expectedDisplayId) ||
      RemoteDisplayPolicy.currentDisplayId !== RemoteDisplayPolicy.localDisplayId) return false;
    if (RemoteDisplayPolicy.followSystem === follow) { RemoteDisplayPolicy.apply(); return true; }
    const previous: boolean = RemoteDisplayPolicy.followSystem;
    try {
      const value: string = follow ? '1' : '0';
      if (RustDeskNapi.setOption('remote-follow-system-rotation', value) !== 0 ||
        RustDeskNapi.getOption('remote-follow-system-rotation') !== value) throw new Error('Preference write failed');
    } catch (_error) {
      try { RustDeskNapi.setOption('remote-follow-system-rotation', previous ? '1' : '0'); }
      catch (_rollbackError) { RustDeskNapi.appendDiagnosticLog('projection', 'rotation_preference_rollback_failed'); }
      RustDeskNapi.appendDiagnosticLog('projection', 'rotation_preference_save_failed');
      return false;
    }
    RemoteDisplayPolicy.followSystem = follow;
    RemoteDisplayPolicy.publishDisplayState();
    RustDeskNapi.appendDiagnosticLog('projection', 'follow_system_rotation_changed enabled=' + (follow ? '1' : '0'));
    RemoteDisplayPolicy.apply();
    return true;
  }

  static refresh(): void {
    const main = RemoteDisplayPolicy.main;
    if (!main) return;
    try {
      RemoteDisplayPolicy.currentDisplayId = main.getWindowProperties().displayId ?? -1;
    } catch (_e) {}
    RemoteDisplayPolicy.publishDisplayState();
    RemoteDisplayPolicy.apply();
  }

  static setActive(active: boolean): void {
    if (active && !RemoteDisplayPolicy.active) RemoteDisplayPolicy.loadRotationPreferences();
    RemoteDisplayPolicy.active = active;
    if (!active) {
      RemoteDisplayPolicy.projectionMode = RemoteOrientationMode.SYSTEM;
    }
    RemoteDisplayPolicy.publishDisplayState();
    RemoteDisplayPolicy.apply();
  }

  static setOrientationMode(mode: RemoteOrientationMode, expectedDisplayId?: number): boolean {
    if (!RemoteDisplayPolicy.targetIsCurrent(expectedDisplayId)) return false;
    const external = RemoteDisplayPolicy.localDisplayId >= 0 && RemoteDisplayPolicy.currentDisplayId >= 0 &&
      RemoteDisplayPolicy.localDisplayId !== RemoteDisplayPolicy.currentDisplayId;
    if (mode !== RemoteOrientationMode.PORTRAIT && mode !== RemoteOrientationMode.LANDSCAPE &&
      mode !== (external ? RemoteOrientationMode.SYSTEM : RemoteOrientationMode.AUTO)) return false;
    if (!external && RemoteDisplayPolicy.followSystem) return false;
    if (external) RemoteDisplayPolicy.projectionMode = mode;
    else {
      const previous: RemoteOrientationMode = RemoteDisplayPolicy.localMode;
      try {
        if (RustDeskNapi.setOption('remote-independent-orientation', mode) !== 0 ||
          RustDeskNapi.getOption('remote-independent-orientation') !== mode) throw new Error('Preference write failed');
      } catch (_error) {
        try { RustDeskNapi.setOption('remote-independent-orientation', previous); }
        catch (_rollbackError) { RustDeskNapi.appendDiagnosticLog('projection', 'independent_orientation_rollback_failed'); }
        RustDeskNapi.appendDiagnosticLog('projection', 'independent_orientation_save_failed');
        return false;
      }
      RemoteDisplayPolicy.localMode = mode;
      RustDeskNapi.appendDiagnosticLog('projection', `independent_orientation_saved mode=${mode}`);
    }
    AppStorage.setOrCreate('remoteOrientationMode', mode);
    RustDeskNapi.appendDiagnosticLog('projection', `orientation_selected external=${external} mode=${mode}`);
    RemoteDisplayPolicy.apply();
    return true;
  }

  private static apply(): void {
    const main = RemoteDisplayPolicy.main;
    if (!main || (deviceInfo.deviceType !== 'phone' && deviceInfo.deviceType !== 'tablet')) return;
    RemoteDisplayPolicy.pending = RemoteDisplayPolicy.pending.then(async () => {
      if (main !== RemoteDisplayPolicy.main) return;
      AppStorage.setOrCreate('remoteOrientationError', '');
      // A display migration can reach the window before its listener callback.
      // Never apply the phone's independent rotation policy to that new screen.
      const actualDisplayId = main.getWindowProperties().displayId;
      if (actualDisplayId !== undefined && actualDisplayId >= 0 && actualDisplayId !== RemoteDisplayPolicy.currentDisplayId) {
        RemoteDisplayPolicy.currentDisplayId = actualDisplayId;
        RemoteDisplayPolicy.publishDisplayState();
      }
      const external = RemoteDisplayPolicy.localDisplayId >= 0 && RemoteDisplayPolicy.currentDisplayId >= 0 &&
        RemoteDisplayPolicy.currentDisplayId !== RemoteDisplayPolicy.localDisplayId;
      let wide = false;
      if (external) {
        try {
          const target = display.getDisplayByIdSync(RemoteDisplayPolicy.currentDisplayId);
          wide = target.width > target.height;
        } catch (_e) {}
      }
      const mode = external ? RemoteDisplayPolicy.projectionMode : RemoteDisplayPolicy.localMode;
      let orientation = RemoteDisplayPolicy.original;
      if (RemoteDisplayPolicy.active) {
        if (!external && RemoteDisplayPolicy.followSystem) orientation = window.Orientation.AUTO_ROTATION_RESTRICTED;
        else if (mode === RemoteOrientationMode.PORTRAIT) orientation = window.Orientation.PORTRAIT;
        else if (mode === RemoteOrientationMode.LANDSCAPE || (external && wide)) {
          orientation = window.Orientation.LANDSCAPE;
        } else orientation = external ? window.Orientation.AUTO_ROTATION_RESTRICTED : window.Orientation.AUTO_ROTATION;
      }
      if (main.getPreferredOrientation() !== orientation) await main.setPreferredOrientation(orientation);
      RustDeskNapi.appendDiagnosticLog('projection',
        `window_policy active=${RemoteDisplayPolicy.active} external=${external} wide=${wide} mode=${mode} follow_system=${RemoteDisplayPolicy.followSystem} orientation=${orientation}`);
    }).catch(() => {
      if (main === RemoteDisplayPolicy.main && RemoteDisplayPolicy.active)
        AppStorage.setOrCreate('remoteOrientationError', '系统暂未允许切换屏幕方向，请稍后重试');
      RustDeskNapi.appendDiagnosticLog('projection', 'orientation_apply_failed');
    });
  }
}
