// Execute actual page methods: fast transfers, phase labels and stale replies.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/RemotePage.ets'), 'utf8');
function method(start, end) {
  const a = source.indexOf(`  ${start}(`), b = source.indexOf(`  ${end}(`, a);
  assert(a >= 0 && b > a, `method boundaries: ${start}`);
  return source.slice(a, b);
}
let raw = '', exportsCount = 0, cleanups = 0, finished = [], events = [], background = [];
const context = vm.createContext({ Date, JSON, Math,
  RustDeskNapi: { getFileTransferStatus: () => raw },
  RemoteSessionBackgroundTask: { setDataTransferActive: active => background.push(active) } });
vm.runInContext(ts.transpileModule(`class Subject {
  ${method('pollFileTransferStatus', 'updateTransferMetrics')}
  ${method('formatTransferSpeed', 'remoteEntryKey')}
  ${method('resetTransferTracking', 'beginFileTransferHistory')}
} globalThis.Subject = Subject;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
function page(direction = 'upload') {
  exportsCount = 0; cleanups = 0; finished = []; events = []; background = [];
  return Object.assign(new context.Subject(), {
    transferActive: true, transferDirection: direction, transferPhase: 'starting',
    transferTrace: { event: (step, fields) => events.push({ step, ...fields }) },
    transferIgnoredDirection: false, uploadQueue: [],
    updateTransferMetrics: () => {}, exportDownloadedItems: () => exportsCount++,
    finishFileTransferHistory: state => finished.push(state),
    cleanupPendingUploadFile: () => cleanups++, cleanupPendingDownloadFiles: () => cleanups++,
    clearUploadQueue: () => {}, showFileToast: () => {}, formatFileSize: n => `${n} B`,
  });
}
function reply(p, state, direction, transferred = 52510, total = 52510, error = '') {
  raw = JSON.stringify({ state, direction, transferred, total, error, completedItems: state === 'completed' ? 1 : 0 });
  p.pollFileTransferStatus();
}
let passed = 0;
function test(name, fn) { fn(); passed++; console.log(`PASS ${name}`); }
test('upload confirmation wait is visible and does not release the staged source', () => {
  const p = page(); reply(p, 'waiting_confirmation', 'upload');
  assert.equal(p.transferActive, true);
  assert.equal(p.formatTransferSpeed(12345), '等待远端确认');
  assert.equal(cleanups, 0); assert.equal(exportsCount, 0); assert.equal(finished.length, 0);
  assert.equal(events[0].step, 'waiting_confirmation'); assert.equal(events[0].upload, true);
  reply(p, 'waiting_confirmation', 'upload'); assert.equal(events.length, 1, 'no log per poll');
});
test('confirmed fast upload completes without becoming a download', () => {
  const p = page(); reply(p, 'completed', 'upload');
  assert.equal(p.transferActive, false); assert.equal(p.transferProgress, 100);
  assert.equal(p.transferDirection, 'upload'); assert.equal(cleanups, 1); assert.equal(exportsCount, 0);
  assert.deepEqual(finished, ['completed']); assert.deepEqual(background, [false]);
});
test('late opposite-direction status cannot export or change the operation', () => {
  const p = page(); reply(p, 'completed', 'download'); reply(p, 'transferring', 'download', 0, 0);
  assert.equal(p.transferActive, true); assert.equal(p.transferDirection, 'upload');
  assert.equal(cleanups, 0); assert.equal(exportsCount, 0); assert.equal(events.length, 1);
  assert.equal(events[0].step, 'stale');
});
test('download completion exports once and never performs upload cleanup', () => {
  const p = page('download'); reply(p, 'completed', 'download'); p.pollFileTransferStatus();
  assert.equal(exportsCount, 1); assert.equal(cleanups, 0); assert.equal(p.transferActive, false);
});
test('confirmation timeout is failure, not success, and stops background data task', () => {
  const p = page(); reply(p, 'waiting_confirmation', 'upload');
  reply(p, 'failed', 'upload', 52510, 52510, '等待远端确认超时');
  assert.equal(p.transferActive, false); assert.deepEqual(finished, ['failed']);
  assert.equal(exportsCount, 0); assert.deepEqual(background, [false]);
});
test('cancel remains upload and cleans only the local staging file', () => {
  const p = page(); reply(p, 'cancelled', 'upload', 10);
  assert.deepEqual(finished, ['cancelled']); assert.equal(cleanups, 1); assert.equal(exportsCount, 0);
});
test('new task resets phase and stale-direction guard', () => {
  const p = page(); p.transferPhase = 'waiting_confirmation'; p.transferIgnoredDirection = true;
  p.resetTransferTracking(3);
  assert.equal(p.transferPhase, 'starting'); assert.equal(p.transferIgnoredDirection, false);
  assert.equal(p.formatTransferSpeed(0), '正在准备传输');
  p.transferPhase = 'transferring'; assert.equal(p.formatTransferSpeed(0), '等待数据');
  assert.equal(p.formatTransferSpeed(512), '512 B/s');
});
test('invalid native JSON cannot complete or change a task', () => {
  const p = page(); raw = '{invalid'; p.pollFileTransferStatus();
  assert.equal(p.transferActive, true); assert.equal(exportsCount, 0);
});
console.log(`${passed} file transfer UI regressions passed`);
