'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8');
const methods = source.slice(source.indexOf('  clearSaveTip(): void'), source.indexOf('  async saveCurrentConnection():'))
  .replace(/: Promise<void>|: void|: number/g, '');
let nextId = 0;
const timers = new Map();
const failures = [];
const animations = [];
const page = new Function('setTimeout', 'clearTimeout', 'Curve', 'promptAction', 'translate', `class ConnectionSaveConflict extends Error {} return new class {${methods}}`)(
  (fn, ms) => { timers.set(++nextId, { fn, ms }); return nextId; },
  id => timers.delete(id), { EaseOut: 'easeOut' }, { showToast: x => failures.push(x.message) }, key => key);
Object.assign(page, { savePageActive: true, saveTipGeneration: 0, saveTipTimer: -1,
  saveTipRemoveTimer: -1, savingConnection: false, remoteId: '123456789', saveTipVisible: false });
page.normalizeRemoteId = x => x.trim();
page.getUIContext = () => ({ animateTo: (options, fn) => { animations.push(options); fn(); } });
const fire = id => { const timer = timers.get(id); timers.delete(id); timer.fn(); };
(async () => {
  let finish;
  let calls = 0;
  page.saveCurrentConnection = () => { calls++; return new Promise(resolve => { finish = resolve; }); };
  const saving = page.saveConnectionWithTip();
  assert.equal(page.saveTipVisible, false, 'no success tip before save completes');
  await page.saveConnectionWithTip();
  assert.equal(calls, 1, 'duplicate save clicks are guarded');
  finish(true); await saving;
  assert.equal(page.saveTipVisible, true);
  assert.equal(timers.get(page.saveTipTimer).ms, 1200);
  fire(page.saveTipTimer);
  assert.equal(page.saveTipOffsetY, -32);
  assert.equal(page.saveTipOpacity, 0);
  assert.equal(animations[0].duration, 420);
  const oldRemove = timers.get(page.saveTipRemoveTimer).fn;
  page.showSavedTip();
  oldRemove();
  assert.equal(page.saveTipVisible, true, 'previous dismissal cannot hide a new save tip');
  fire(page.saveTipTimer); fire(page.saveTipRemoveTimer);
  assert.equal(page.saveTipVisible, false);
  page.showSavedTip(); page.clearSaveTip();
  assert.equal(timers.size, 0, 'page cleanup clears both timers');
  page.saveCurrentConnection = async () => { throw new Error('save failed'); };
  await page.saveConnectionWithTip();
  assert.equal(page.saveTipVisible, false);
  assert.deepEqual(failures, ['保存失败，请重试']);
  page.remoteId = '';
  await page.saveConnectionWithTip();
  assert.equal(failures.length, 1, 'empty ID does not save');
  assert.match(source, /aboutToDisappear\(\): void \{\s*this\.savePageActive = false\s*this\.clearSaveTip\(\)/);
  assert.match(source, /Text\(translate\('已保存', this\.uiLanguage\)\)[\s\S]*?hitTestBehavior\(HitTestMode.None\)/);
  console.log('PASS save tip: completion, repeat clicks, upward fade, cleanup and failure');
})().catch(error => { console.error(error); process.exitCode = 1; });
