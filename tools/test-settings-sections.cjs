'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH ||
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const read = file => fs.readFileSync(path.join(__dirname, '../entry/src/main/ets', file), 'utf8').replace(/\r\n/g, '\n');
const source = read('pages/SettingsPage.ets');
const home = read('pages/HomePage.ets');
const controls = read('widget/SettingsControls.ets');
const catalog = read('utils/I18nCatalog.ets');
const functionSlice = (text, from, to) => {
  const start = text.indexOf(from), end = text.indexOf(to, start + 1);
  assert(start >= 0 && end > start, from);
  return text.slice(start, end);
};
const categoryBuilder = functionSlice(source, '  buildCategoryContent(', '  buildSunshineExperiment() {');
const expected = {
  home: ['buildCategoryGroup', 'buildCategoryGroup', 'buildSunshineExperiment', 'buildAboutCard'],
  personal: ['buildLanguageCard', 'buildButtonShapeCard', 'buildThemeToggle'],
  remote: ['buildDisplayCard', 'buildInputCard', 'buildAudioCard'],
  network: ['buildServerConfigCard', 'buildApiAccountEntry'],
  backup: ['buildCloudSyncCard'],
  diagnostics: ['buildDiagnosticsCard', 'buildRecordsCard'],
};
for (const [key, sections] of Object.entries(expected)) {
  const start = categoryBuilder.indexOf(`category === '${key}') {`);
  assert(start >= 0, key);
  const branch = categoryBuilder.slice(start).split('    }', 1)[0];
  assert.deepEqual([...branch.matchAll(/this\.(build\w+)\(/g)].map(m => m[1]), sections, key);
}
assert(categoryBuilder.includes("this.buildCategoryGroup('常用设置', ['personal', 'remote', 'network'])"));
assert(categoryBuilder.includes("this.buildCategoryGroup('数据与支持', ['backup', 'diagnostics'])"));
assert.match(source, /buildSunshineExperiment\(\) \{\s*if \(this\.sunshineAvailable\)/,
  'ordinary builds must not show the optional test row');
assert.doesNotMatch(categoryBuilder, /category === 'about'/, 'About is a visible card, not a separate settings page');
assert(!categoryBuilder.includes("translate('Account'"), 'no standalone device account card');
assert(source.includes('builder: ApiAccountDialog()'));
assert(source.includes('onAction: () => { this.apiAccountDialogController.open() }'));
const records = functionSlice(source, '  buildRecordsCard()', '  setDiagnosticLogEnabled(');
assert(records.includes('this.fileTransferHistoryDialogController.open()'));
assert(records.includes('this.recordingDialogController.open()'));
const about = functionSlice(source, '  buildAboutCard()', '  async openFilingWebsite(');
assert(about.includes("this.sectionTitle(translate('关于与反馈', this.uiLanguage), 'info')"));
assert(about.includes("Text('v' + RELEASE_NOTES_VERSION)"));
assert.equal(catalog.split('"关于与反馈":').length, 3, 'the inline section title remains translated');
assert.doesNotMatch(about, /fileTransferHistoryDialogController|recordingDialogController/);
assert(about.includes('this.releaseNotesDialogController.open()') && about.includes('this.openQQGroup()') &&
  about.includes('this.openFilingWebsite()'));

const categoryData = functionSlice(source, 'interface SettingsCategory {', '@Extend(Column)');
const navCode = functionSlice(source, '  private openCategory(', '  private categoryTransition(');
const backCode = functionSlice(home, '  onBackPress():', '  build() {');
const navigation = [];
const context = { curves: { cubicBezierCurve: (...args) => args }, SETTINGS_IN: 'in', Curve: { EaseOut: 'out', Linear: 'linear' },
  animate: (options, fn) => { navigation.push(options.duration); fn(); } };
vm.createContext(context);
vm.runInContext(ts.transpileModule(`${categoryData}
class Settings { ${navCode} }
class Home { ${backCode} }
globalThis.Subject = { Settings, Home, SETTINGS_CATEGORIES };`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, context);
const parent = Object.assign(new context.Subject.Home(), { settingsCategory: 'home', currentTabIndex: 1,
  getUIContext: () => ({ animateTo: context.animate }) });
const child = new context.Subject.Settings();
child.getUIContext = parent.getUIContext;
Object.defineProperty(child, 'settingsCategory', { get: () => parent.settingsCategory,
  set: category => { parent.settingsCategory = category; } });
assert.deepEqual(Array.from(context.Subject.SETTINGS_CATEGORIES, c => c.id), Object.keys(expected));
for (const { id, title, description } of context.Subject.SETTINGS_CATEGORIES) {
  assert.equal(catalog.split(JSON.stringify(title) + ':').length, 3, `both translations: ${title}`);
  assert.equal(catalog.split(JSON.stringify(description) + ':').length, 3, `both translations: ${description}`);
  if (id === 'home') continue;
  child.openCategory(id);
  assert.equal(parent.settingsCategory, id);
  assert.equal(parent.onBackPress(), true);
  assert.equal(parent.settingsCategory, 'home');
}
for (const category of ['about', 'invalid']) {
  child.openCategory(category);
  assert.equal(parent.settingsCategory, 'home');
}
assert.equal(parent.onBackPress(), false);
parent.currentTabIndex = 0; parent.settingsCategory = 'backup';
assert.equal(parent.onBackPress(), false, 'Back from Connections does not consume a Settings event');
assert(navigation.every(ms => ms === 287));
assert(home.includes('settingsCategory: $settingsCategory'));
assert(source.includes('.transition(this.categoryTransition(category))'));
assert.match(source, /\.height\('100%'\)\.align\(Alignment\.Top\)\.scrollBar\(/,
  'short category lists must sit directly under the header instead of being centered in the Scroll');
assert.match(controls, /Canvas\(this\.painter\)[\s\S]*?\.width\(this\.iconSize\)\.height\(this\.iconSize\)/);
assert.match(controls, /new Path2D\(path, LengthMetricsUnit\.PX\)/,
  'draw the approved viewBox once in canvas pixels at every device density');

for (const token of ['.bindPopup(this.expanded', 'placement: Placement.BottomRight', 'enableArrow: false',
  'mask: true', 'focusable: true', 'autoCancel: true', 'onStateChange:', 'this.expanded ? 180 : 0',
  "icon: 'check'", 'this.selected === item.key', 'WordBreak.BREAK_WORD']) assert(controls.includes(token), token);
const actions = functionSlice(controls, '  private activate(): void', '  private popupTransition(');
let selected = 0;
const action = { isEnabled: false, items: [], expanded: false, onAction: () => { selected++; } };
vm.runInNewContext(ts.transpileModule(`class Harness { ${actions} } globalThis.Harness = Harness;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, action);
const button = Object.assign(new action.Harness(), { isEnabled: false, items: [], expanded: false, onAction: action.onAction });
button.activate(); assert.equal(selected, 0);
button.isEnabled = true;
button.activate(); assert.equal(selected, 1);
button.items = [{ key: 'dark' }];
button.activate(); assert.equal(button.expanded, true);
button.activate(); assert.equal(button.expanded, false);
assert.equal(selected, 1);
console.log('PASS 5 Settings categories, inline About and Feedback, back navigation, translations and anchored controls');
