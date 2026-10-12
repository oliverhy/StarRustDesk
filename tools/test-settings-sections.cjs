'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/SettingsPage.ets'), 'utf8');
const build = source.slice(source.indexOf('  build() {'), source.indexOf('  buildLanguageCard()'));
assert(!build.includes("translate('Account'"), 'remove the standalone device account card');
assert(!source.includes('buildSectionCard('), 'remove its unused builder');
assert(!source.includes('interface SettingItem'), 'remove its unused item type');
assert(!build.includes('getDeviceName()'), 'settings no longer fetch the device name for the removed card');
for (const section of ['buildLanguageCard', 'buildButtonShapeCard', 'buildDisplayCard', 'buildInputCard',
  'buildAudioCard', 'buildServerConfigCard', 'buildApiAccountEntry', 'buildCloudSyncCard',
  'buildDiagnosticsCard', 'buildThemeToggle', 'buildAboutCard']) {
  assert(build.includes(`this.${section}()`), `preserve ${section}`);
}
assert(source.includes('builder: ApiAccountDialog()'));
assert(source.includes('.onClick(() => { this.apiAccountDialogController.open() })'));
console.log('PASS settings removes the standalone account card and preserves server account, address book and other sections');
