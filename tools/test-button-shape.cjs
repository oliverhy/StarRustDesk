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
for (const file of ['pages/ConnectionPage.ets', 'pages/RemotePage.ets',
  'widget/ReleaseNotesDialog.ets', 'widget/FileTransferHistoryDialog.ets']) {
  const page = read(file);
  assert.match(page, /@StorageLink\('roundedRectButtons'\) roundedRectButtons: boolean = true/, file);
  assert.match(page, /\.attributeModifier\(new (?:ReadableButtonModifier|ButtonShapeModifier)\(this.roundedRectButtons,/, file);
}
const settings = read('pages/SettingsPage.ets');
assert.match(settings, /key: 'classic', label: '经典圆润'/);
assert.match(settings, /key: 'rectangle', label: '圆角长方形'/);
assert.match(settings, /RustDeskNapi\.setOption\('button-shape', rectangular \? 'rectangle' : 'classic'\)/);
const cardStart = settings.indexOf('  buildButtonShapeCard()');
const labelStart = settings.indexOf('  buttonShapeLabel()', cardStart);
const shapeCard = settings.slice(cardStart, labelStart);
assert.equal((shapeCard.match(/SettingsAction\(/g) || []).length, 1, 'one compact selector instead of two permanent buttons');
assert(shapeCard.includes("controlId: 'button-shape-selector'") && shapeCard.includes('items: BUTTON_OPTIONS'));
assert(shapeCard.includes('label: this.buttonShapeLabel()'));
assert(shapeCard.includes("selected: this.roundedRectButtons ? 'rectangle' : 'classic'"));
assert(shapeCard.includes("this.setButtonShape(value === 'rectangle')"));
const controls = read('widget/SettingsControls.ets');
assert(controls.includes("@StorageLink('roundedRectButtons')"));
assert(controls.includes("color: this.edge(), radius: this.radius()"),
  'set edge and radius in the same border operation so the edge does not reset the radius');
const action = controls.slice(controls.indexOf('export struct SettingsAction'));
const paint = action.slice(action.indexOf('  private fill()'), action.indexOf('  private radius()'));
const palette = read('theme/SettingsSkin.ets')
  .replace('export interface SettingsPalette', 'interface SettingsPalette')
  .replace('export function settingsPalette', 'function settingsPalette');
const paintContext = { Color: { Transparent: '#00000000' } };
vm.runInNewContext(ts.transpileModule(`${palette} class Action { ${paint} } globalThis.Action = Action;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, paintContext);
const renderer = Object.assign(new paintContext.Action(), { tone: 'neutral', dark: false, icon: '', grouped: false });
function stops() { return Array.from(renderer.actionGradient(), pair => pair[0]); }
assert.deepEqual(stops(), ['#FCFDFE', '#F0F5FC', '#F0F5FC'],
  'opaque pale stops avoid the gray band caused by transparent-black interpolation on a real phone');
renderer.dark = true;
assert.deepEqual(stops(), ['#2D384A', '#242F42', '#242F42']);
renderer.tone = 'quiet';
assert(stops().every(color => color === '#00000000'), 'quiet actions stay transparent');
assert(controls.includes('minHeight: 44') && controls.includes('WordBreak.BREAK_WORD') && !controls.includes('.maxLines('));
const server = read('widget/ServerConfigDialog.ets');
assert(server.includes('PasteButton({ text: PasteDescription.PASTE'));
assert(server.includes('buttonType: this.roundedRectButtons ?'));
const labelEnd = settings.indexOf('  async setThemeMode(', labelStart);
const radius = controls.slice(controls.indexOf('  private radius()'), controls.indexOf('  private labelWidth()'));
const writes = [];
const context = vm.createContext({
  RustDeskNapi: { setOption: (key, value) => writes.push([key, value]) },
  translate: (text, locale) => `${locale}:${text}`
});
vm.runInContext(ts.transpileModule(`class Page { ${settings.slice(labelStart, labelEnd)} ${radius} } globalThis.Page = Page;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
const selector = new context.Page();
for (const locale of ['zh-Hans', 'zh-Hant', 'en']) {
  selector.uiLanguage = locale;
  selector.setButtonShape(true);
  assert.equal(selector.roundedRectButtons, true);
  assert.equal(selector.buttonShapeLabel(), `${locale}:圆角长方形`);
  Object.assign(selector, { label: 'Appearance', grouped: false });
  assert.equal(selector.radius(), 12);
  selector.grouped = true; assert.equal(selector.radius(), 11);
  assert.deepEqual(writes.at(-1), ['button-shape', 'rectangle']);
  selector.setButtonShape(false);
  assert.equal(selector.roundedRectButtons, false);
  assert.equal(selector.buttonShapeLabel(), `${locale}:经典圆润`);
  assert.equal(selector.radius(), 23);
  selector.grouped = false; assert.equal(selector.radius(), 999);
  assert.deepEqual(writes.at(-1), ['button-shape', 'classic']);
}
assert(writes.every(([key]) => key === 'button-shape'), 'changing shape never mutates connection preferences');
const remote = read('pages/RemotePage.ets');
const viewportStart = remote.indexOf('  buildRemoteViewport() {');
const captureStart = remote.indexOf("Button('', { stateEffect: false })", viewportStart);
assert(viewportStart >= 0 && captureStart > viewportStart, 'capture belongs to the viewport builder, not a call site');
const surfaceStart = remote.indexOf('      if (this.showRemoteSurface)', captureStart);
assert(surfaceStart > captureStart, 'capture ends before the conditional render surface');
const capture = remote.slice(captureStart, surfaceStart);
assert.match(capture, /borderRadius\(0\)/);
assert.doesNotMatch(capture, /ButtonShapeModifier/);
console.log('PASS button appearance: default, classic restoration, persistence, reactive consumers and input surface exclusion');
