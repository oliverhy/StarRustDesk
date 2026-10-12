'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8').replace(/\r/g, '');
const model = fs.readFileSync(path.join(root, 'entry/src/main/ets/model/PerformanceSettings.ets'), 'utf8').replace(/export /g, '');
function method(name) {
  const start = source.indexOf('\n  ' + name + '('); assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const names = ['loadConnectionFormState', 'setConnectionFormExpanded', 'setTabletEditorVisible',
  'connectionModeOptions', 'connectionModeIndex', 'selectConnectionMode', 'connectionEditButtonHeight'];
const writes = [], animations = [];
const context = vm.createContext({ Curve: { EaseInOut: 'ease' }, Number,
  translate: (label, language) => language === 'en' ? `en:${label}` : label,
  RustDeskNapi: { getOption: () => '1', setOption: (...args) => writes.push(args) }
});
const output = ts.transpileModule(model + `\nclass Page {${names.map(method).join('\n')}} globalThis.Page = Page;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(output.diagnostics.length, 0); vm.runInContext(output.outputText, context);
const page = Object.assign(new context.Page(), { connectionFormExpanded: true, tabletEditorVisible: true,
  performancePreset: 'custom:600:72', uiLanguage: 'zh-Hans', uiFontScale: 1,
  getUIContext: () => ({ animateTo: (options, callback) => { animations.push(options); callback(); } })
});
page.loadConnectionFormState(); assert.equal(page.connectionFormExpanded, false); assert.equal(page.tabletEditorVisible, false);
assert.equal(page.performancePreset, 'custom:600:72');
page.setConnectionFormExpanded(true); assert.equal(page.connectionFormExpanded, true); assert.equal(writes.length, 0);
page.loadConnectionFormState(); assert.equal(page.connectionFormExpanded, false);
page.setTabletEditorVisible(true); assert.equal(page.connectionFormExpanded, true); assert.equal(page.tabletEditorVisible, true);
assert.equal(page.connectionModeOptions().length, 6);
for (const [index, preset] of ['stable', 'high_fps', 'smooth', 'silky', 'best'].entries()) {
  page.selectConnectionMode(index); assert.equal(page.performancePreset, preset); assert.equal(page.connectionModeIndex(), index);
}
page.selectConnectionMode(5); assert.equal(page.performancePreset, 'custom:100:30'); assert.equal(page.connectionModeIndex(), 5);
page.performancePreset = 'custom:600:72'; page.selectConnectionMode(5); assert.equal(page.performancePreset, 'custom:600:72');
for (const invalid of [-1, 6, NaN, 1.5, Infinity]) page.selectConnectionMode(invalid);
assert.equal(page.performancePreset, 'custom:600:72');
page.performancePreset = 'invalid'; assert.equal(page.connectionModeIndex(), 2);
page.uiLanguage = 'en'; assert(page.connectionModeOptions().every(option => option.value.startsWith('en:')));
for (const builder of ['buildConnectionForm', 'buildWideQuickConnect']) {
  const body = method(builder); assert(body.indexOf('this.buildRemoteIdInput()') < body.indexOf('if (this.connectionFormExpanded)'));
  assert(body.includes('this.buildQuickConnectionToggle()'));
  assert(body.indexOf('this.buildRemoteIdInput()') < body.indexOf('this.buildQuickConnectionToggle()'));
}
const selector = method('buildPerformancePresetSelector');
const remoteInput = method('buildRemoteIdInput');
assert(remoteInput.includes('.fontSize(18)'));
assert(remoteInput.includes('.height(this.connectionEditButtonHeight() + 8)'));
assert.equal((remoteInput.match(/\.height\(this\.connectionEditButtonHeight\(\)\)/g) || []).length, 3);
assert(remoteInput.includes('.width(this.connectionEditButtonHeight())'));
assert(remoteInput.includes('width: 44, height: 44'));
assert(remoteInput.includes('width: this.connectionEditButtonHeight() + 4'));
assert(remoteInput.includes('.onSubmit(() => { this.onConnect() })'));
assert(remoteInput.includes("this.onRemoteIdChanged('')"));
for (const scale of [1, 1.3, 1.6, 2, 3]) {
  page.uiFontScale = scale;
  const size = page.connectionEditButtonHeight();
  assert(size + 4 >= 44, 'compact arrow retains a usable touch target');
  assert(size >= 18 * scale + 4, 'large system fonts have vertical space');
}
page.uiFontScale = 1; assert.equal(page.connectionEditButtonHeight() + 8, 48);
assert.equal((selector.match(/\bSelect\(/g) || []).length, 1); assert(!selector.includes('buildPresetButton'));
assert(selector.includes('if (PerformanceSettings.isCustom(this.performancePreset))'));
assert(selector.includes('min: 10, max: 2000')); assert(selector.includes('min: 5, max: 120'));
assert(!source.includes("setOption('connection-advanced-expanded'"));
assert.equal(writes.length, 0);
assert(selector.includes('.menuItemContentModifier(new CompactConnectionModeMenu(this.isDarkMode, this.uiFontScale))'));
assert(selector.includes('.optionWidth(OptionWidthMode.FIT_TRIGGER)'));
const menu = fs.readFileSync(path.join(root, 'entry/src/main/ets/widget/CompactConnectionModeMenu.ets'), 'utf8');
assert(menu.includes('Math.ceil(36 + Math.max(0, this.fontScale - 1) * 18)'));
assert(menu.includes('.fontSize(14)')); assert(menu.includes('CONTROL_SELECTED_BG_DARK'));
assert(menu.includes('configuration.triggerSelect(configuration.index, configuration.value as string)'));
assert(menu.includes('.enabled(configuration.enabled)'));
assert(menu.indexOf('Text(configuration.value)') < menu.indexOf("Text('✓')"), 'mode selection mark follows the label');
const menuClass = menu.slice(menu.indexOf('export class '), menu.indexOf('\n@Builder')).replace('export class ', 'class ');
vm.runInContext(ts.transpileModule(menuClass + '\nglobalThis.ModeMenu = CompactConnectionModeMenu;', {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, context);
for (const [scale, expected] of [[1, 36], [1.3, 42], [1.6, 47], [2, 54], [3, 72]]) {
  assert.equal(new context.ModeMenu(false, scale).rowHeight(), expected);
}
const clickBody = menu.match(/\.onClick\(\(\) => \{([^}]+)\}\)/)[1].replace(' as string', '');
const selectItem = new Function('configuration', clickBody);
for (let index = 0; index < 6; index++) {
  let called; const value = page.connectionModeOptions()[index].value;
  selectItem({ index, value, triggerSelect: (...args) => { called = args; } });
  assert.deepEqual(called, [index, value]);
}
console.log('PASS persistent ID input, collapsed options beneath, compact native dropdown and preserved custom settings');
