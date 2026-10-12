'use strict';
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname,
  '../entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8');
const deviceInfo = { deviceType: 'tablet' };
const body = source.match(/isWideDeviceLayout\(\): boolean \{([\s\S]*?)\n  \}/)[1];
const isWide = new Function('deviceInfo', `return function() {${body}}`)(deviceInfo);
assert.equal(isWide.call({ pageWidth: 1200, pageFullHeight: 760 }), true);
assert.equal(isWide.call({ pageWidth: 900, pageFullHeight: 1200 }), false);
assert.equal(isWide.call({ pageWidth: 700, pageFullHeight: 500 }), false);
deviceInfo.deviceType = 'phone';
assert.equal(isWide.call({ pageWidth: 1200, pageFullHeight: 760 }), false);
deviceInfo.deviceType = '2in1';
assert.equal(isWide.call({ pageWidth: 1200, pageFullHeight: 760 }), true);
assert.equal(isWide.call({ pageWidth: 900, pageFullHeight: 1200 }), true, 'PC tall window still uses wide workspace');
assert.equal(isWide.call({ pageWidth: 819, pageFullHeight: 600 }), false);
for (const type of ['pc', 'desktop']) {
  deviceInfo.deviceType = type;
  assert.equal(isWide.call({ pageWidth: 1200, pageFullHeight: 760 }), true);
}
const cardBody = source.match(/savedDeviceCardWidth\(\): string \{([\s\S]*?)\n  \}/)[1];
const cardWidth = new Function(cardBody.replace(/: string/g, ''));
assert.equal(cardWidth.call({ pageWidth: 1440, isWideDeviceLayout: () => true }), '32%');
assert.equal(cardWidth.call({ pageWidth: 1200, isWideDeviceLayout: () => true }), '49%');
assert.equal(cardWidth.call({ pageWidth: 700, isWideDeviceLayout: () => false }), '100%');
assert.match(source, /Math\.max\(this\.pageFullHeight, nextHeight\)/,
  'keyboard resize must retain the full window height');
assert.match(source, /if \(this\.isWideDeviceLayout\(\)\) \{\s*Column[\s\S]*?buildWideQuickConnect\(\)[\s\S]*?Scroll\(\)[\s\S]*?buildSavedConnections\(\)/);
assert.match(source, /FlexWrap\.Wrap, justifyContent: FlexAlign\.SpaceBetween/);
assert.match(source, /\.width\(this\.savedDeviceCardWidth\(\)\)/);
assert.match(source, /editSavedConnection\(item:[\s\S]*?this\.connectionEditorController\.open\(\)/);
const editor = fs.readFileSync(require('node:path').join(__dirname,
  '../entry/src/main/ets/widget/SavedConnectionEditorDialog.ets'), 'utf8');
assert(editor.includes(".width('92%').height(this.showAdvanced ? '78%' : '52%').constraintSize({ maxWidth: 560 })"));
assert.match(source, /await this\.saveCurrentConnection\(\)[\s\S]*?if \(this\.tabletEditorVisible\) this\.setTabletEditorVisible\(false\)/);
assert.match(source, /\.zIndex\(8\)[\s\S]*?duration: 240/);
console.log('PASS tablet/PC layout: device/size scope, IME stability, quick connect, adaptive grid and editor');
