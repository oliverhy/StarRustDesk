const SUNSHINE_DEBUG_BUNDLE = 'com.yinhe.starrustdesk';

/** The opt-in resets on app start; no RustDesk preference or backup uses it. */
export class SunshineExperiment {
  static initialize(bundleName: string, debug: boolean, packaged: boolean, ticket: string): void {
    const available = bundleName === SUNSHINE_DEBUG_BUNDLE && debug && packaged;
    AppStorage.setOrCreate('sunshineTestAvailable', available);
    AppStorage.setOrCreate('sunshineTestEnabled', false);
    AppStorage.setOrCreate('sunshineTestEpoch', 0);
    AppStorage.setOrCreate('sunshineUiNonce', available && /^[0-9a-f]{24}$/.test(ticket) ? ticket : '');
  }

  static mayOpen(bundleName: string, debug: boolean): boolean {
    return debug && bundleName === SUNSHINE_DEBUG_BUNDLE &&
      AppStorage.get<boolean>('sunshineTestAvailable') === true &&
      AppStorage.get<boolean>('sunshineTestEnabled') === true;
  }

  static leaveForeground(): void {
    if (AppStorage.get<boolean>('sunshineTestAvailable') !== true) return;
    const epoch = AppStorage.get<number>('sunshineTestEpoch') ?? 0;
    AppStorage.setOrCreate('sunshineTestEpoch', epoch + 1);
  }
}
