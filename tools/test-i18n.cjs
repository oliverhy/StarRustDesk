'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const state = new Map(), options = new Map(), resourceCalls = [], logs = [];
let systemLanguage = 'zh-CN', resourceThrows = false;
const modules = new Map();
const storage = { get: key => state.get(key), setOrCreate: (key, value) => state.set(key, value) };
const native = {
  getOption: key => options.get(key) || '', setOption: (key, value) => options.set(key, value),
  appendDiagnosticLog: (...args) => logs.push(args)
};
function load(file) {
  if (modules.has(file)) return modules.get(file);
  const exports = {};
  const context = {
    exports, AppStorage: storage, require: name => {
      if (name === '@kit.LocalizationKit') return { i18n: { System: {
        getSystemLanguage: () => systemLanguage,
        setAppPreferredLanguage: value => {
          if (resourceThrows) throw Error('older SDK');
          resourceCalls.push(value);
        }
      } } };
      if (name === '../service/RustDeskNapi') return { RustDeskNapi: native };
      if (name.startsWith('./')) return load(path.posix.join(path.posix.dirname(file), name + '.ets'));
      throw Error(name);
    }
  };
  vm.runInNewContext(ts.transpileModule(read(file), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, context, { filename: file });
  modules.set(file, exports);
  return exports;
}
const utils = 'entry/src/main/ets/utils/';
const { resolveLanguage, translate } = load(utils + 'I18n.ets');
const { ENGLISH, TRADITIONAL, DYNAMIC_KEYS } = load(utils + 'I18nCatalog.ets');
const { LanguageService, LANGUAGE_OPTION } = load(utils + 'LanguageService.ets');
for (const [locale, expected] of [
  ['zh_CN', 'zh-Hans'], ['zh-Hans-CN', 'zh-Hans'], ['zh-Hans-HK', 'zh-Hans'],
  ['zh-TW', 'zh-Hant'], ['zh-HK', 'zh-Hant'], ['zh_MO', 'zh-Hant'], ['zh-Hant', 'zh-Hant'],
  ['en-US', 'en'], ['en_GB', 'en'], ['fr-FR', 'en'], ['ja-JP', 'en'], ['', 'en']
]) assert.equal(resolveLanguage('system', locale), expected, locale);
assert.equal(resolveLanguage('zh-Hant', 'en-US'), 'zh-Hant');
assert.equal(resolveLanguage('en', 'zh-TW'), 'en');
LanguageService.initialize();
assert.equal(state.get('uiLanguagePreference'), 'system');
assert.equal(state.get('uiLanguage'), 'zh-Hans');
assert.equal(resourceCalls.at(-1), 'default');
systemLanguage = 'en-US'; LanguageService.refreshSystemLanguage();
assert.equal(state.get('uiLanguage'), 'en');
LanguageService.setPreference('zh-Hant');
assert.equal(options.get(LANGUAGE_OPTION), 'zh-Hant');
assert.equal(resourceCalls.at(-1), 'zh-Hant');
state.clear(); LanguageService.initialize();
assert.equal(state.get('uiLanguagePreference'), 'zh-Hant', 'manual preference survives restart');
assert.equal(state.get('uiLanguage'), 'zh-Hant');
systemLanguage = 'zh-CN'; LanguageService.refreshSystemLanguage();
assert.equal(state.get('uiLanguage'), 'zh-Hant', 'manual language ignores system changes');
LanguageService.setPreference('system');
assert.equal(state.get('uiLanguage'), 'zh-Hans');
options.set(LANGUAGE_OPTION, 'obsolete-invalid-value');
resourceThrows = true; LanguageService.initialize();
assert.equal(state.get('uiLanguagePreference'), 'system');
assert.equal(state.get('uiLanguage'), 'zh-Hans', 'resource API errors must not crash startup');
assert.deepEqual([...new Set(options.keys())], [LANGUAGE_OPTION], 'never changes server/network options');
assert(logs.every(entry => entry[0] === 'language' && /^preference_changed value=/.test(entry[1])));

assert.equal(translate('Connect', 'zh-Hans'), '连接');
assert.equal(translate('Connect', 'zh-Hant'), '連線');
assert.equal(translate('Connect', 'en'), 'Connect');
assert.equal(translate('连接超时', 'en'), 'Connection timed out');
assert.equal(translate('ID 服务器密钥不匹配', 'en'), 'ID server key mismatch');
assert.equal(translate('屏3', 'en'), 'Display 3');
assert.equal(translate('屏3', 'zh-Hant'), TRADITIONAL['屏{0}'].replace('{0}', '3'));
assert.equal(translate('VP9 · 软解', 'en'), 'VP9 · Software');
assert.equal(translate('排序：名称', 'en'), 'Sort: Name');
assert.equal(translate('上次同步 10-01 09:35', 'en'), 'Last synced 10-01 09:35');
assert.equal(translate('请输入远端设备 123456789 的连接密码', 'en'),
  'Enter the connection password for 123456789');
const name = '连接 {1} $& 测试.txt';
const deletion = translate(`确定永久删除“${name}”及其所有内容？此操作不能撤销。`, 'en');
assert(deletion.includes(name), 'filename and literal placeholder-looking content must stay intact');
assert.equal(translate('custom-folder/path/$&/{1}', 'en'), 'custom-folder/path/$&/{1}');
const fallbackKey = '文件传输';
const old = TRADITIONAL[fallbackKey]; delete TRADITIONAL[fallbackKey];
assert.equal(translate(fallbackKey, 'zh-Hant'), ENGLISH[fallbackKey]);
TRADITIONAL[fallbackKey] = old;
for (const [key, value] of Object.entries(ENGLISH)) {
  assert(value && TRADITIONAL[key], 'all keys have both translations: ' + key);
  const slots = s => (s.match(/\{\d+\}/g) || []).sort().join(',');
  assert.equal(slots(value), slots(key), 'English placeholders: ' + key);
  assert.equal(slots(TRADITIONAL[key]), slots(key), 'Traditional placeholders: ' + key);
  if (!['简体中文', '繁體中文', '浙ICP备2026058556号-2A'].includes(key)) {
    assert.doesNotMatch(value, /[\u4e00-\u9fff]/, 'English UI must not contain untranslated Chinese: ' + key);
  }
}
assert(DYNAMIC_KEYS.includes('连接失败（错误码：{0}）'));
for (const folder of ['base', 'en', 'zh_CN', 'zh_Hant']) {
  const strings = JSON.parse(read(`entry/src/main/resources/${folder}/element/string.json`)).string;
  const names = strings.map(item => item.name);
  const baseNames = JSON.parse(read('entry/src/main/resources/base/element/string.json')).string.map(item => item.name);
  assert.deepEqual(names, baseNames, 'system resource keys must match');
  assert(strings.every(item => item.value.length > 0));
  const reason = strings.find(item => item.name === 'permission_voice_call_reason').value;
  assert.equal(/[\u4e00-\u9fff]/.test(reason), folder === 'zh_CN' || folder === 'zh_Hant');
}
const remote = read('entry/src/main/ets/pages/RemotePage.ets');
assert(remote.includes("Button(/[\\u4e00-\\u9fff]/.test(label) ? translate(label, this.uiLanguage) : label)"),
  'physical Home key must not translate to the Home page label');
const chat = read('entry/src/main/ets/widget/CommunicationPanel.ets');
assert(chat.includes('Text(message.text)') && !chat.includes('translate(message.text'), 'chat content is not translated');
const connections = read('entry/src/main/ets/pages/ConnectionPage.ets');
assert(connections.includes('Text(item.name.length > 0 ? item.name : item.remoteId)'));
assert(connections.includes("Text(groupId.length === 0 ? translate('未分组', this.uiLanguage) : groupName)"));
const language = read(utils + 'LanguageService.ets');
assert.doesNotMatch(language, /disconnect|resetVideo|unbindSurface|router\.|loadContent/,
  'language changes must not recreate the remote session');
const settings = read('entry/src/main/ets/pages/SettingsPage.ets');
for (const option of ['system', 'zh-Hans', 'zh-Hant', 'en']) {
  assert(settings.includes(`languageMenuLabel('${option}'`));
  assert(settings.includes(`LanguageService.setPreference('${option}')`));
}
const cardStart = settings.indexOf('  buildLanguageCard()');
const cardEnd = settings.indexOf('  languagePreferenceLabel()', cardStart);
const languageCard = settings.slice(cardStart, cardEnd);
assert.equal((languageCard.match(/Button\(/g) || []).length, 1, 'one compact language selector, not four permanent buttons');
assert(languageCard.includes(".id('language-selector')") && languageCard.includes('.bindMenu(['));
assert(languageCard.includes('Text(this.languagePreferenceLabel())'));
assert(languageCard.includes('.minFontSize(11)') && languageCard.includes('.maxLines(2)'), 'selector accommodates larger fonts');
assert(!settings.includes('buildLanguageChoice('));
const labelEnd = settings.indexOf('  @Builder', cardEnd);
const labels = {};
vm.runInNewContext(ts.transpileModule(`class Page { ${settings.slice(cardEnd, labelEnd)} } globalThis.Page = Page;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, Object.assign(labels, { translate }));
const selector = new labels.Page();
for (const locale of ['zh-Hans', 'zh-Hant', 'en']) {
  selector.uiLanguage = locale;
  for (const [preference, label] of [['zh-Hans', '简体中文'], ['zh-Hant', '繁體中文'], ['en', 'English']]) {
    selector.uiLanguagePreference = preference;
    assert.equal(selector.languagePreferenceLabel(), label, 'current language uses recognizable self-name');
    assert.equal(selector.languageMenuLabel(preference, label), '✓ ' + label, 'current choice is marked in popup');
    selector.uiLanguagePreference = 'system';
    assert.equal(selector.languageMenuLabel(preference, label), label, 'other choices stay unmarked');
  }
  selector.uiLanguagePreference = 'system';
  assert.equal(selector.languagePreferenceLabel(), translate('跟随系统', locale));
  assert.equal(selector.languageMenuLabel('system', '跟随系统'), '✓ ' + translate('跟随系统', locale));
}
const home = read('entry/src/main/ets/pages/HomePage.ets');
assert(home.includes("this.buildTabItem(0, 'Connection')"), 'builders must receive stable source labels, not previous-locale text');
console.log(`PASS multilingual preferences, live system follow, persistence, fallback, ${Object.keys(ENGLISH).length} catalog entries, dynamic templates, user content, resources and connection/input boundaries`);
