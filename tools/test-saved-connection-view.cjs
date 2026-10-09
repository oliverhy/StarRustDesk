'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8').replace(/\r\n/g, '\n');
function method(name) {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const methods = ['loadSavedConnectionView', 'setSavedConnectionView', 'savedConnectionViewMenuLabel',
  'savedCompactContentWidth', 'savedCompactStackActions', 'savedCompactSingleLine',
  'savedCompactRowMinHeight', 'savedCompactActionHeight', 'savedCompactConnectWidth',
  'savedCompactIdWidth', 'isWideDeviceLayout', 'savedDeviceCardWidth'];
const js = ts.transpileModule('class Page {' + methods.map(method).join('\n') + '} globalThis.Page = Page;', {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(js.diagnostics.length, 0);
const catalog = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/utils/I18nCatalog.ets'), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, catalog);
function fixture(type = 'phone', width = 390, height = 844, scale = 1) {
  const options = new Map(), writes = [], tips = [], logs = [], animations = [];
  let failRead = false, failWrite = false;
  const context = vm.createContext({
    deviceInfo: { deviceType: type }, Curve: { EaseInOut: 'ease' },
    promptAction: { showToast: tip => tips.push(tip) },
    CloudSyncService: { markLocalChanged() { throw Error('View must not change cloud data'); } },
    translate: (key, locale) => locale === 'en' ? catalog.exports.ENGLISH[key] :
      locale === 'zh-Hant' ? catalog.exports.TRADITIONAL[key] : key,
    RustDeskNapi: {
      getOption(key) { if (failRead) throw Error('read'); return options.get(key) || ''; },
      setOption(key, value) { if (failWrite) throw Error('write'); options.set(key, value); writes.push([key, value]); },
      appendDiagnosticLog: (...args) => logs.push(args)
    }
  });
  vm.runInContext(js.outputText, context);
  const page = Object.assign(new context.Page(), {
    savedConnectionViewMode: 'normal', savedConnectionsContentWidth: 0,
    pageWidth: width, pageFullHeight: height, uiFontScale: scale, uiLanguage: 'zh-Hans',
    savedConnections: [{ id: 'a', remoteId: '123456789', name: 'Host', password: 'test-only', groupId: 'work' }],
    connectionGroups: [{ id: 'work', name: 'Work', expanded: false }],
    savedConnectionSort: 'online', savedConnectionSortAscending: false,
    savedConnectionSearch: 'host', savedConnectionsExpanded: false, selectedConnectionId: 'a',
    selectedGroupId: 'work', remoteId: '987654321', connectionName: 'Draft', password: 'draft-only',
    getUIContext: () => ({ animateTo(settings, action) { animations.push(settings); action(); } })
  });
  return { page, context, options, writes, tips, logs, animations,
    failRead: value => { failRead = value; }, failWrite: value => { failWrite = value; } };
}
let passed = 0;
function test(name, action) { action(); passed++; console.log('PASS ' + name); }
test('new installs, invalid stored values and read failures preserve the standard layout', () => {
  const f = fixture();
  for (const value of ['', 'invalid', 'normal']) {
    f.options.set('saved-connections-view', value); f.page.loadSavedConnectionView();
    assert.equal(f.page.savedConnectionViewMode, 'normal');
  }
  f.failRead(true); f.page.savedConnectionViewMode = 'compact'; f.page.loadSavedConnectionView();
  assert.equal(f.page.savedConnectionViewMode, 'normal'); assert.equal(f.writes.length, 0);
});
test('switching persists only a local appearance key and restores on a fresh page', () => {
  const f = fixture();
  assert.equal(f.page.setSavedConnectionView('compact'), true);
  assert.deepEqual(f.writes, [['saved-connections-view', 'compact']]);
  assert.equal(f.animations.length, 1); assert.equal(f.animations[0].duration, 180);
  f.page.savedConnectionViewMode = 'normal'; f.page.loadSavedConnectionView();
  assert.equal(f.page.savedConnectionViewMode, 'compact');
  assert.equal(f.page.setSavedConnectionView('normal'), true);
  assert.deepEqual(f.writes.at(-1), ['saved-connections-view', 'normal']);
});
test('same and invalid selections do not cause writes or animations', () => {
  const f = fixture();
  assert.equal(f.page.setSavedConnectionView('normal'), true);
  assert.equal(f.page.setSavedConnectionView('grid'), false);
  assert.equal(f.writes.length, 0); assert.equal(f.animations.length, 0);
});
test('storage failure preserves the active view and reports a safe error', () => {
  const f = fixture(); f.failWrite(true);
  assert.equal(f.page.setSavedConnectionView('compact'), false);
  assert.equal(f.page.savedConnectionViewMode, 'normal'); assert.equal(f.animations.length, 0);
  assert.equal(f.tips[0].message, '保存显示方式失败，请重试');
  assert.deepEqual(f.logs, [['saved-view', 'save_failed']]);
});
test('connections, credentials, editor draft, sorting, search and fold state remain untouched', () => {
  const f = fixture();
  const snapshot = () => JSON.stringify(Object.fromEntries(Object.entries(f.page)
    .filter(([key]) => key !== 'savedConnectionViewMode' && key !== 'getUIContext')));
  const before = snapshot(); f.page.setSavedConnectionView('compact'); f.page.setSavedConnectionView('normal');
  assert.equal(snapshot(), before);
  assert(!JSON.stringify(f.logs).includes('test-only') && !JSON.stringify(f.logs).includes('draft-only'));
});
test('phone and narrow tablet/PC use two text lines; wide tablet/PC align into one row', () => {
  for (const type of ['phone', 'tablet', '2in1', 'pc', 'desktop']) {
    const f = fixture(type, 390, 844); f.page.savedConnectionsContentWidth = 326;
    assert.equal(f.page.savedCompactSingleLine(), false); assert.equal(f.page.savedCompactStackActions(), false);
    f.page.pageWidth = 1200; f.page.pageFullHeight = 760; f.page.savedConnectionsContentWidth = 1100;
    assert.equal(f.page.savedCompactSingleLine(), type !== 'phone');
  }
  const portrait = fixture('tablet', 900, 1200); assert.equal(portrait.page.savedCompactSingleLine(), false);
});
test('actual card width, window resizing and fold/rotation re-evaluate the layout without changing preferences', () => {
  const f = fixture('pc', 1440, 900); f.page.savedConnectionsContentWidth = 520;
  assert.equal(f.page.savedCompactSingleLine(), false);
  f.page.savedConnectionsContentWidth = 1000; assert.equal(f.page.savedCompactSingleLine(), true);
  f.page.pageWidth = 760; f.page.savedConnectionsContentWidth = 696;
  assert.equal(f.page.savedCompactSingleLine(), false);
  f.page.savedConnectionsContentWidth = 260; assert.equal(f.page.savedCompactStackActions(), true);
  assert.equal(f.writes.length, 0);
});
test('large fonts grow rows and actions and place actions on a separate line', () => {
  const f = fixture('pc', 1200, 760);
  for (const scale of [1, 1.3, 1.6, 2, 3]) {
    f.page.uiFontScale = scale;
    assert(f.page.savedCompactActionHeight() >= 44);
    assert(f.page.savedCompactConnectWidth() >= 60);
    assert(f.page.savedCompactRowMinHeight() >= 44);
    assert.equal(f.page.savedCompactStackActions(), scale > 1.6);
    if (scale > 1.6) assert.equal(f.page.savedCompactSingleLine(), false);
  }
  assert.match(method('buildCompactSavedConnectionItem'), /constraintSize\(\{ minHeight: this\.savedCompactRowMinHeight\(\) \}\)/);
  assert.doesNotMatch(method('buildCompactSavedConnectionItem'), /\.height\(/, 'compact rows must be able to grow naturally');
});
test('standard grid dimensions remain unchanged', () => {
  const f = fixture('pc', 1440, 900); assert.equal(f.page.savedDeviceCardWidth(), '32%');
  f.page.pageWidth = 1200; assert.equal(f.page.savedDeviceCardWidth(), '49%');
  f.page.pageWidth = 760; assert.equal(f.page.savedDeviceCardWidth(), '100%');
});
test('selector translates both modes, marks the active mode and exposes accessible labels', () => {
  const f = fixture();
  for (const language of ['zh-Hans', 'zh-Hant', 'en']) {
    f.page.uiLanguage = language;
    assert(f.page.savedConnectionViewMenuLabel('normal').startsWith('✓ '));
    assert(!f.page.savedConnectionViewMenuLabel('compact').startsWith('✓ '));
    assert(!f.page.savedConnectionViewMenuLabel('compact').includes('undefined'));
  }
  f.page.uiLanguage = 'en'; assert.equal(f.page.savedConnectionViewMenuLabel('compact'), 'Compact list');
  assert.equal(f.page.savedCompactConnectWidth(), 76, 'English Connect keeps enough label space');
  f.page.uiFontScale = 3; assert.equal(f.page.savedCompactConnectWidth(), 160);
  assert.match(method('buildSavedConnectionViewSelector'), /accessibilityText\(translate\('连接显示方式'/);
  assert.match(source, /loadSavedConnectionSort\(\)\s+this\.loadSavedConnectionView\(\)/);
  const header = source.slice(source.indexOf('  buildSavedConnections()'), source.indexOf('  buildSavedConnectionViewSelector()'));
  assert.equal((header.match(/this\.buildSavedConnectionViewSelector\(\)/g) || []).length, 1);
  assert(header.indexOf('this.buildSavedConnectionViewSelector()') < header.indexOf('if (this.savedConnectionSearchExpanded)'),
    'view selector belongs to the title row, not an extra search/sort toolbar row');
});
test('both views reuse the exact connect and more actions; compact rows are full width with no large avatar', () => {
  const group = method('buildSavedConnectionGroup'), compact = method('buildCompactSavedConnectionItem');
  for (const helper of ['buildSavedConnectionConnectButton', 'buildSavedConnectionMoreButton']) {
    assert(group.includes(`this.${helper}(item, false)`)); assert(compact.includes(`this.${helper}(item, true)`));
  }
  assert(compact.includes(".width('100%')")); assert(!compact.includes('substring(0, 1)'));
  assert(group.includes('${this.savedConnectionViewMode}'));
  const f = fixture(), calls = [], item = f.page.savedConnections[0];
  for (const name of ['connectSavedConnection', 'applySavedConnection', 'onConnect',
    'openGroupPickerForConnection', 'openRenameConnectionDialog', 'editSavedConnection', 'deleteSavedConnection']) {
    f.page[name] = arg => calls.push([name, arg]);
  }
  f.context.item = item;
  const click = method('buildSavedConnectionConnectButton').match(/\.onClick\(\(\) => \{ ([^\n]+) \}\)/)[1];
  vm.runInContext(`(function(){${click}}).call(page);`, Object.assign(f.context, { page: f.page }));
  const menu = method('buildSavedConnectionMoreButton').match(/\.bindMenu\((\[[\s\S]*?\]), \{ placement:/)[1];
  vm.runInContext(`globalThis.menu = (function(){return ${menu}}).call(page);`, f.context);
  assert.equal(f.context.menu.length, 5);
  f.context.menu.forEach(entry => entry.action());
  assert.deepEqual(calls.map(([name]) => name), ['connectSavedConnection', 'applySavedConnection', 'onConnect',
    'openGroupPickerForConnection', 'openRenameConnectionDialog', 'editSavedConnection', 'deleteSavedConnection']);
  assert.equal(calls[2][1], true); assert.equal(calls[3][1], item.id);
});
test('online dot respects the existing query switch and view never reloads cloud state', () => {
  assert.match(method('buildCompactSavedConnectionStatus'), /if \(this\.peerOnlineQueryEnabled\)/);
  assert.match(method('buildCompactSavedConnectionStatus'), /peerOnlineStateColor\(item\.remoteId\)/);
  assert(!method('onCloudConnectionsChanged').includes('loadSavedConnectionView'));
  assert(!method('setSavedConnectionView').includes('markLocalChanged'));
});
console.log(`${passed} saved connection view checks passed (device layout acceptance pending)`);
