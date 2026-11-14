'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const page = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemotePage.ets'), 'utf8').replace(/\r\n/g, '\n');
function method(name) {
  const start = page.indexOf(`\n  ${name}(`);
  const asyncStart = page.indexOf(`\n  async ${name}(`);
  const pos = start >= 0 ? start : asyncStart;
  assert(pos >= 0, name);
  return page.slice(pos, page.indexOf('\n  }', pos) + 4);
}
const methods = ['sendKeyboardText', 'sendKeyboardTextSegment', 'getPrintableShortcutKeyCode',
  'resetKeyboardCaptureBuffer', 'handleRemoteKeyboardPaste', 'stagePendingKeyboardText',
  'showPendingKeyboardTextDialog', 'copyPendingKeyboardText', 'confirmDiscardPendingKeyboardText',
  'handleRemoteKeyboardSubmit', 'finishRemoteKeyboardSubmit', 'handleDirectKeyboardChange'];
let packets, logs, dialogs, copied, sendResult, clipboardResult;
const context = vm.createContext({
  ConnectionStatus: { CONNECTED: 2 }, KEYBOARD_CAPTURE_SENTINEL: '1'.repeat(64),
  ConnectionService: {
    sendText(value) { packets.push(['text', value]); return sendResult; },
    sendPrintableShortcutKey(code, mask) { packets.push(['shortcut', code, mask]); return sendResult; },
  },
  RustDeskNapi: {
    appendDiagnosticLog(category, value) { logs.push([category, value]); },
    async setClipboardTextAsync(value) { copied.push(value); return clipboardResult; },
  },
  RustDeskTheme: { ERROR: 'red' }, translate: value => value,
});
vm.runInContext(ts.transpileModule(`class Page { ${methods.map(method).join('\n')} } globalThis.Page=Page;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
function setup() {
  packets = []; logs = []; dialogs = []; copied = []; sendResult = 0; clipboardResult = 0;
  const p = Object.assign(new context.Page(), {
    remotePageVisible: true, showKeyboardPanel: true, connectionStatus: 2, keyboardHideOnSubmit: false,
    pendingKeyboardText: '', pendingKeyboardContextText: '', pendingKeyboardNeedsReview: false, pendingKeyboardReason: '',
    pendingKeyboardRevision: 0, pendingKeyboardDialogVisible: false, pendingKeyboardCopying: false,
    keyboardComposing: false, keyboardSubmitPending: false, uiLanguage: 'zh-Hans',
    allowWaylandText: () => true, getVirtualModifierMask: () => 0,
    getUIContext: () => ({ showAlertDialog(dialog) { dialogs.push(dialog); } }),
    sendControlKey(code) { packets.push(['control', code]); },
    showFileToast() {}, traceRemoteKeyboardState() {},
    closeRemoteKeyboard() { this.showKeyboardPanel = false; this.resetKeyboardCaptureBuffer(); },
  });
  p.resetKeyboardCaptureBuffer();
  return p;
}
function pasteEvent() { return { prevented: false, preventDefault() { this.prevented = true; } }; }
let passed = 0;
function test(name, run) { run(); passed++; console.log('PASS ' + name); }
async function asyncTest(name, run) { await run(); passed++; console.log('PASS ' + name); }

async function main() {
  test('multiline paste retains exact CRLF, blank lines and emoji without Enter or remote text', () => {
    const p = setup(), raw = '01甲\r\n\r\n02🙂\n03';
    const event = pasteEvent(); p.handleRemoteKeyboardPaste(raw, event);
    assert(event.prevented); assert.equal(p.pendingKeyboardText, raw); assert.equal(p.showKeyboardPanel, false);
    assert.deepEqual(packets, []); assert.equal(dialogs.length, 1);
    p.handleDirectKeyboardChange(raw, { value: '' }); p.handleRemoteKeyboardSubmit();
    assert.deepEqual(packets, []); assert.equal(p.pendingKeyboardText, raw);
    assert(!JSON.stringify(logs).includes(raw)); assert(!JSON.stringify(dialogs).includes(raw));
  });
  test('committed multiline delta is staged before any Backspace or Enter', () => {
    const p = setup(), base = p.keyboardInput;
    p.handleDirectKeyboardChange(base + '已输入', { value: '' });
    assert.deepEqual(packets, [['text', '已输入']]); packets.length = 0;
    p.handleDirectKeyboardChange(base + '已输入\n后续', { value: '' });
    assert.equal(p.pendingKeyboardText, '\n后续'); assert.deepEqual(packets, []);
  });
  test('multiline replacement retains new full value and requests manual review', () => {
    const p = setup(), base = p.keyboardInput;
    p.handleDirectKeyboardChange(base + '原内容', { value: '' }); packets.length = 0;
    p.handleDirectKeyboardChange(base + '新内容\n末行', { value: '' });
    assert.equal(p.pendingKeyboardText, '新内容\n末行'); assert.equal(p.pendingKeyboardNeedsReview, true);
    assert.deepEqual(packets, []); assert(dialogs[0].message.includes('远端可能已有部分内容'));
  });
  test('multiline paste during composition preserves local candidate and paste', () => {
    const p = setup(), base = p.keyboardInput;
    p.handleDirectKeyboardChange(base + '候选', { value: '候选' });
    const event = pasteEvent(); p.handleRemoteKeyboardPaste('第一行\n第二行', event);
    assert(event.prevented); assert.equal(p.pendingKeyboardText, '第一行\n第二行');
    assert.equal(p.pendingKeyboardContextText, '候选');
    assert(p.pendingKeyboardNeedsReview); assert.deepEqual(packets, []);
  });
  test('multiline input after submit during composition never emits deferred Enter', () => {
    const p = setup(), base = p.keyboardInput;
    p.handleDirectKeyboardChange(base + '拼音', { value: '拼音' });
    let kept = false; p.handleRemoteKeyboardSubmit({ keepEditableState() { kept = true; } });
    p.handleDirectKeyboardChange(base + '中文\n第二行', { value: '' });
    assert(kept); assert.equal(p.pendingKeyboardText, '中文\n第二行');
    assert.equal(p.keyboardSubmitPending, false); assert.deepEqual(packets, []);
  });
  test('multiline paste without a preventDefault callback is still staged', () => {
    const p = setup(); p.handleRemoteKeyboardPaste('甲\r\n乙', {});
    assert.equal(p.pendingKeyboardText, '甲\r\n乙'); assert.deepEqual(packets, []);
  });
  test('same committed long callback is sent once, but subsequent suffix is delivered', () => {
    const p = setup(), long = '汉🙂'.repeat(100);
    p.handleDirectKeyboardChange(long, { value: '' });
    p.handleDirectKeyboardChange(long, { value: '' });
    p.handleDirectKeyboardChange(long + '末', { value: '' });
    assert.deepEqual(packets, [['text', long], ['text', '末']]);
  });
  test('two explicit identical single-line pastes are both delivered', () => {
    const p = setup(), value = '相同🙂内容';
    const a = pasteEvent(), b = pasteEvent();
    p.handleRemoteKeyboardPaste(value, a); p.handleRemoteKeyboardPaste(value, b);
    assert(a.prevented && b.prevented); assert.deepEqual(packets, [['text', value], ['text', value]]);
  });
  test('whole-field replacement beginning with a digit preserves all digits without sentinel Backspaces', () => {
    const p = setup(); p.handleDirectKeyboardChange('123abc', { value: '' });
    assert.deepEqual(packets, [['text', '123abc']]);
  });
  test('ordinary Chinese IME composition and real manual Enter retain existing behavior', () => {
    const p = setup(), base = p.keyboardInput;
    p.handleDirectKeyboardChange(base + 'ni', { value: 'ni' });
    p.handleDirectKeyboardChange(base + '你', { value: '' });
    p.handleRemoteKeyboardSubmit({ keepEditableState() {} });
    assert.deepEqual(packets, [['text', '你'], ['control', 13]]); assert(p.showKeyboardPanel);
  });
  test('explicit soft-keyboard modifier shortcut remains a shortcut', () => {
    const p = setup(); p.getVirtualModifierMask = () => 1;
    p.handleDirectKeyboardChange(p.keyboardInput + 'q', { value: '' });
    assert.deepEqual(packets, [['shortcut', 81, 1]]);
  });
  test('a local queue failure preserves the unsent text rather than advancing the input shadow', () => {
    const p = setup(); sendResult = -1;
    p.handleDirectKeyboardChange(p.keyboardInput + '未发送', { value: '' });
    assert.equal(p.pendingKeyboardText, '未发送'); assert.equal(p.pendingKeyboardReason, 'queue_failed');
    assert.equal(p.showKeyboardPanel, false); assert.equal(dialogs.length, 1);
    assert(!JSON.stringify(logs).includes('未发送'));
  });
  test('replacement after a queue failure preserves the entire requested value for review', () => {
    const p = setup(), base = p.keyboardInput;
    p.handleDirectKeyboardChange(base + '旧内容', { value: '' }); packets.length = 0;
    sendResult = -1; p.handleDirectKeyboardChange(base + '新内容', { value: '' });
    assert.equal(p.pendingKeyboardText, '新内容'); assert(p.pendingKeyboardNeedsReview);
    assert.deepEqual(packets, [['control', 8], ['control', 8], ['control', 8], ['text', '新内容']]);
  });
  test('later and rejected discard keep the original pending text', () => {
    const p = setup(), value = '原文\n待处理'; p.handleRemoteKeyboardPaste(value, pasteEvent());
    dialogs[0].buttons[0].action(); assert.equal(p.pendingKeyboardText, value);
    p.showPendingKeyboardTextDialog(); dialogs[1].buttons[2].action();
    dialogs[2].primaryButton.action(); assert.equal(p.pendingKeyboardText, value);
  });
  await asyncTest('copy uses only local clipboard and clears pending only after success', async () => {
    const p = setup(), value = '保留\r\n原文🙂'; p.handleRemoteKeyboardPaste(value, pasteEvent());
    clipboardResult = -1; await p.copyPendingKeyboardText(p.pendingKeyboardRevision);
    assert.equal(p.pendingKeyboardText, value); assert.deepEqual(packets, []);
    clipboardResult = 0; await p.copyPendingKeyboardText(p.pendingKeyboardRevision);
    assert.equal(p.pendingKeyboardText, ''); assert.deepEqual(copied, [value, value]); assert.deepEqual(packets, []);
    assert(!JSON.stringify(logs).includes(value));
  });
  await asyncTest('composition context and original paste can be copied separately without losing either', async () => {
    const p = setup(), base = p.keyboardInput, raw = '粘贴\n原文';
    p.handleDirectKeyboardChange(base + '候选', { value: '候选' });
    p.handleRemoteKeyboardPaste(raw, pasteEvent());
    const revision = p.pendingKeyboardRevision;
    await p.copyPendingKeyboardText(revision, false);
    await p.copyPendingKeyboardText(revision, true);
    assert.deepEqual(copied, [raw, '候选']);
    assert.equal(p.pendingKeyboardText, raw); assert.equal(p.pendingKeyboardContextText, '候选');
    assert.deepEqual(packets, []); assert(!JSON.stringify(logs).includes(raw));
    p.confirmDiscardPendingKeyboardText(revision); dialogs[1].secondaryButton.action();
    assert.equal(p.pendingKeyboardText, ''); assert.equal(p.pendingKeyboardContextText, '');
  });
  test('discard is explicit and stale confirmation cannot discard a newer item', () => {
    const p = setup(); p.handleRemoteKeyboardPaste('一\n二', pasteEvent());
    const old = p.pendingKeyboardRevision; p.confirmDiscardPendingKeyboardText(old);
    p.pendingKeyboardRevision++; dialogs[1].secondaryButton.action();
    assert.equal(p.pendingKeyboardText, '一\n二');
    p.confirmDiscardPendingKeyboardText(p.pendingKeyboardRevision); dialogs[2].secondaryButton.action();
    assert.equal(p.pendingKeyboardText, ''); assert.deepEqual(packets, []);
  });
  assert.match(page, /\.onPaste\(\(value: string, event: PasteEvent\)/);
  assert.match(page, /if \(this\.pendingKeyboardText\.length > 0\) \{ this\.showPendingKeyboardTextDialog\(\); return; \}/);
  console.log(`PASS ${passed} remote multiline input scenarios`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
