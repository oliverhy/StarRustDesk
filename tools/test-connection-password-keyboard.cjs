const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8');
const home = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/HomePage.ets'), 'utf8');
const start = source.indexOf('  connectionPasswordDialogHeight():');
const end = source.indexOf('  @Builder', start);
assert(start >= 0 && end > start);
const compiled = ts.transpileModule(`class Subject { ${source.slice(start, end)} } globalThis.Subject=Subject;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
const sandbox = vm.createContext({});
vm.runInContext(compiled, sandbox);
const page = new sandbox.Subject();

for (const [viewport, scale] of [[720, 1], [280, 1], [240, 1.5], [180, 2], [720, 2]]) {
  page.pageVisibleHeight = viewport;
  page.uiFontScale = scale;
  const height = page.connectionPasswordDialogHeight();
  assert(height > 0 && height <= viewport - 16, `dialog exceeds visible area: ${viewport}/${scale}`);
}
page.pageVisibleHeight = 0;
page.uiFontScale = 1;
assert.equal(page.connectionPasswordDialogHeight(), 280);
page.uiFontScale = Number.NaN;
assert.equal(page.connectionPasswordDialogHeight(), 280);

const builder = source.slice(end, source.indexOf('  @Builder\n  buildBackupPasswordDialog()', end));
assert.match(builder, /Scroll\(\)\s*\{[\s\S]*TextInput\(\{ placeholder: translate\('连接密码'/);
assert.match(builder, /\.layoutWeight\(1\)[\s\S]*Row\(\{ space: 10 \}\)\s*\{\s*Button\(translate\('取消'/);
assert.match(builder, /Button\(translate\('连接'[\s\S]*this\.confirmConnectionPassword\(\)/);
assert.match(builder, /\.height\(this\.connectionPasswordDialogHeight\(\)\)/);
assert.match(source, /this\.pageVisibleHeight = nextHeight/);
assert.match(source, /Math\.max\(this\.pageFullHeight, nextHeight\)/);
assert.match(source, /@Link showConnectionPasswordDialog: boolean/);
assert.match(home, /showConnectionPasswordDialog: \$showConnectionPasswordDialog/);
assert.match(home, /if \(!this\.showConnectionPasswordDialog\) this\.buildFloatingTabBar\(\)/);
const avoidanceStart = source.indexOf('  applyPasswordDialogKeyboardAvoidMode():');
const avoidanceEnd = source.indexOf('  closeConnectionPasswordDialog():', avoidanceStart);
assert(avoidanceStart >= 0 && avoidanceEnd > avoidanceStart);
const avoidanceCompiled = ts.transpileModule(`class Avoidance { ${source.slice(avoidanceStart, avoidanceEnd)} } globalThis.Avoidance=Avoidance;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
const avoidanceSandbox = vm.createContext({ KeyboardAvoidMode: { RESIZE: 1 }, RustDeskNapi: { appendDiagnosticLog() {} } });
vm.runInContext(avoidanceCompiled, avoidanceSandbox);
let mode = 0;
const modes = [];
const avoidance = Object.assign(new avoidanceSandbox.Avoidance(), {
  passwordDialogAvoidModeChanged: false,
  getUIContext: () => ({ getKeyboardAvoidMode: () => mode, setKeyboardAvoidMode: value => { mode = value; modes.push(value); } }),
});
avoidance.applyPasswordDialogKeyboardAvoidMode();
avoidance.applyPasswordDialogKeyboardAvoidMode();
assert.deepEqual(modes, [1]);
avoidance.restorePasswordDialogKeyboardAvoidMode();
avoidance.restorePasswordDialogKeyboardAvoidMode();
assert.deepEqual(modes, [1, 0]);
assert.match(source.slice(source.indexOf('  openConnectionPasswordDialog():'), avoidanceStart),
  /this\.applyPasswordDialogKeyboardAvoidMode\(\)/);
assert.match(source.slice(avoidanceEnd, source.indexOf('  async confirmConnectionPassword()', avoidanceEnd)),
  /this\.restorePasswordDialogKeyboardAvoidMode\(\)/);
console.log('PASS password dialog fits the live viewport and keeps actions outside the scroll area');
