'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.join(__dirname, '../entry/src/main/ets');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const source = read('theme/ButtonShapeModifier.ets');
const body = source.match(/applyNormalAttribute\(instance: ButtonAttribute\): void \{([\s\S]*?)\n  \}/)[1];
const ButtonType = { Normal: 'normal', Capsule: 'capsule' };
const apply = new Function('ButtonType', `return function(instance) {${body}}`)(ButtonType);
const values = {};
const instance = { type: v => { values.type = v; }, borderRadius: v => { values.radius = v; } };
apply.call({ rectangular: true, legacyRadius: 21, legacyType: ButtonType.Capsule }, instance);
assert.deepEqual(values, { type: 'normal', radius: 12 });
apply.call({ rectangular: false, legacyRadius: 21, legacyType: ButtonType.Capsule }, instance);
assert.deepEqual(values, { type: 'capsule', radius: 21 });
assert.match(read('entryability/EntryAbility.ets'), /AppStorage\.setOrCreate\('roundedRectButtons', RustDeskNapi\.getOption\('button-shape'\) !== 'classic'\)/);
for (const file of ['pages/ConnectionPage.ets', 'pages/SettingsPage.ets', 'pages/RemotePage.ets',
  'widget/ServerConfigDialog.ets', 'widget/ReleaseNotesDialog.ets', 'widget/FileTransferHistoryDialog.ets']) {
  const page = read(file);
  assert.match(page, /@StorageLink\('roundedRectButtons'\) roundedRectButtons: boolean = true/, file);
  assert.match(page, /\.attributeModifier\(new ButtonShapeModifier\(this.roundedRectButtons,/, file);
}
const settings = read('pages/SettingsPage.ets');
assert.match(settings, /value: this\.buttonShapeMenuLabel\(true\), action: \(\) => \{ this\.setButtonShape\(true\) \}/);
assert.match(settings, /value: this\.buttonShapeMenuLabel\(false\), action: \(\) => \{ this\.setButtonShape\(false\) \}/);
assert.match(settings, /RustDeskNapi\.setOption\('button-shape', rectangular \? 'rectangle' : 'classic'\)/);
const cardStart = settings.indexOf('  buildButtonShapeCard()');
const labelStart = settings.indexOf('  buttonShapeLabel()', cardStart);
const shapeCard = settings.slice(cardStart, labelStart);
assert.equal((shapeCard.match(/Button\(/g) || []).length, 1, 'one compact selector instead of two permanent buttons');
assert(shapeCard.includes(".id('button-shape-selector')") && shapeCard.includes('.bindMenu(['));
assert(shapeCard.includes('Text(this.buttonShapeLabel())'));
assert(shapeCard.includes('.constraintSize({ minHeight: this.buttonShapeOptionHeight() })'));
assert(shapeCard.includes('.minFontSize(11)') && shapeCard.includes('.maxLines(2)'), 'larger fonts can adapt and wrap');
assert(shapeCard.includes('new ButtonShapeModifier(this.roundedRectButtons'), 'selector follows the selected style too');
const labelEnd = settings.indexOf('  @Builder', labelStart);
const writes = [];
const context = vm.createContext({
  RustDeskNapi: { setOption: (key, value) => writes.push([key, value]) },
  translate: (text, locale) => `${locale}:${text}`
});
vm.runInContext(ts.transpileModule(`class Page { ${settings.slice(labelStart, labelEnd)} } globalThis.Page = Page;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
const selector = new context.Page();
for (const locale of ['zh-Hans', 'zh-Hant', 'en']) {
  selector.uiLanguage = locale;
  selector.setButtonShape(true);
  assert.equal(selector.roundedRectButtons, true);
  assert.equal(selector.buttonShapeLabel(), `${locale}:圆角长方形`);
  assert.equal(selector.buttonShapeMenuLabel(true), `✓ ${locale}:圆角长方形`);
  assert.equal(selector.buttonShapeMenuLabel(false), `${locale}:经典圆润`);
  assert.deepEqual(writes.at(-1), ['button-shape', 'rectangle']);
  selector.setButtonShape(false);
  assert.equal(selector.roundedRectButtons, false);
  assert.equal(selector.buttonShapeLabel(), `${locale}:经典圆润`);
  assert.equal(selector.buttonShapeMenuLabel(false), `✓ ${locale}:经典圆润`);
  assert.equal(selector.buttonShapeMenuLabel(true), `${locale}:圆角长方形`);
  assert.deepEqual(writes.at(-1), ['button-shape', 'classic']);
}
for (const scale of [1, 1.5, 2, 3]) {
  selector.uiFontScale = scale;
  assert(selector.buttonShapeOptionHeight() >= 44);
  assert.equal(selector.buttonShapeOptionHeight(), Math.ceil(44 + (scale - 1) * 18));
}
assert(writes.every(([key]) => key === 'button-shape'), 'changing shape never mutates connection preferences');
const remote = read('pages/RemotePage.ets');
const capture = remote.slice(remote.indexOf("Button('', { stateEffect: false })"), remote.indexOf('buildRemoteViewport()') + 4400);
assert.match(capture, /borderRadius\(0\)/);
assert.doesNotMatch(capture.slice(0, capture.indexOf('\n      XComponent')), /ButtonShapeModifier/);
console.log('PASS button appearance: default, classic restoration, persistence, reactive consumers and input surface exclusion');
