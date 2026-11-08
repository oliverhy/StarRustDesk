'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8').replace(/\r/g, '');
const c = { exports: {}, Math, Number, JSON, Map, Array, Object, TouchType: { Down: 0, Move: 1, Up: 2, Cancel: 3 } };
for (const file of ['GamepadMapping', 'GameScreenControls']) {
  const source = read(`entry/src/main/ets/model/${file}.ets`).replace(/^import .*\n/gm, '');
  vm.runInNewContext(ts.transpile(source), c); Object.assign(c, c.exports);
}
const config = c.defaultScreenGameConfig();
assert.equal(config.profiles.length, 3);
assert.equal(config.profiles[0].keys.length, 7, 'new peers see a usable preset');
assert(config.profiles.slice(1).every(profile => profile.keys.length === 0));
assert(c.validScreenGameConfig(config));
for (const [width, height] of [[240,160],[320,200],[360,720],[640,360],[1024,768]]) {
  const keys = c.defaultScreenGameKeys(width, height);
  const boxes = keys.map(key => ({ x: key.x * (width - key.size),
    y: key.y * (height - key.size), size: key.size }));
  assert(boxes[6].x + boxes[6].size <= boxes[5].x,
    `${width}x${height}: space stays clear of the right-edge keyboard launcher`);
  assert(boxes[1].x + 3 * (boxes[1].size + 6) >= boxes[3].x + boxes[3].size,
    `${width}x${height}: WASD should remain compact`);
  for (let i=0;i<boxes.length;i++) for (let j=i+1;j<boxes.length;j++) {
    const a=boxes[i],b=boxes[j];
    assert(!(a.x < b.x+b.size-0.01 && b.x < a.x+a.size-0.01 &&
      a.y < b.y+b.size-0.01 && b.y < a.y+a.size-0.01), `${width}x${height}: preset overlap`);
  }
}
const legacy = {version:1, active:0, profiles:[{name:'My empty layout',keys:[]},
  {name:'Second',keys:[]},{name:'Third',keys:[]}]};
assert.equal(c.decodeScreenGameConfig(JSON.stringify(legacy)).profiles[0].keys.length, 0,
  'an explicitly saved empty profile is not silently replaced');
config.profiles[0].keys = [];
config.profiles[0].keys.push({ id: 1, target: 'k:26', x: 0, y: 1, size: 52, opacity: 70 });
assert(c.validScreenGameConfig(config));
const invalid = JSON.parse(JSON.stringify(config)); invalid.profiles[0].keys[0].x = 1.01;
assert(!c.validScreenGameConfig(invalid), 'out of bounds positions rejected');
invalid.profiles[0].keys[0].x = 0; invalid.profiles[0].keys[0].target = 'arbitrary';
assert(!c.validScreenGameConfig(invalid), 'unrecognized actions rejected');
assert.equal(c.decodeScreenGameConfig('broken').profiles[0].keys.length, 7);
c.Observed = value => value;
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/GameScreenRenderKey.ets').replace(/^import .*\n/gm, '')), c);
Object.assign(c, c.exports);
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const syncStart = page.indexOf('\n  syncGameScreenKeys(');
const syncSource = page.slice(syncStart, page.indexOf('\n  }', syncStart) + 4);
vm.runInNewContext(ts.transpile('class Page {' + syncSource + '} exports.Page = Page;'), c);
const pageObj = Object.assign(new c.exports.Page(), { gameScreenConfig: config, gameScreenKeys: [], gameScreenKeysProfile: -1,
  refreshGameScreenAvoidance() {} });
pageObj.syncGameScreenKeys();
const original = pageObj.gameScreenKeys[0];
config.profiles[0].keys[0].target = 'mouse:left'; config.profiles[0].keys[0].size = 90;
config.profiles[0].keys[0].x = 0.6;
pageObj.syncGameScreenKeys();
assert.equal(pageObj.gameScreenKeys[0], original, 'keep control identity across updates and drag');
assert.equal(original.target, 'mouse:left'); assert.equal(original.size, 90); assert.equal(original.x, 0.6);
config.active = 1; pageObj.syncGameScreenKeys(); assert.equal(pageObj.gameScreenKeys.length, 0);
config.active = 0; pageObj.syncGameScreenKeys(); assert.notEqual(pageObj.gameScreenKeys[0], original);
config.profiles[0].keys[0].target = 'k:26';
const source = read('entry/src/main/ets/widget/GameScreenOverlay.ets');
const extract = name => { const start = source.indexOf(`\n  ${name}(`); assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4); };
vm.runInNewContext(ts.transpile('class Control {' + ['release', 'touch'].map(extract).join('\n') + '} exports.Control = Control;'), c);
const calls = [], moves = [];
const button = Object.assign(new c.exports.Control(), { item: config.profiles[0].keys[0], editing: false, finger: -1,
  onButton: (...args) => calls.push(args), onSelect: () => {}, onMove: (...args) => moves.push(args),
  viewportWidth: 400, viewportHeight: 300 });
const event = (type, point) => ({ type, changedTouches: point ? [point] : [], touches: point ? [point] : [], stopPropagation() {} });
button.touch(event(0, { id: 1, windowX: 10, windowY: 20 }));
button.touch(event(3));
assert.deepEqual(calls, [[1, 'k:26', true], [1, 'k:26', false]], 'cancel releases pressed key');
button.editing = true;
button.touch(event(0, { id: 2, windowX: 10, windowY: 20 }));
button.touch(event(1, { id: 2, windowX: 1000, windowY: -1000 }));
assert.equal(moves[0][1], 1); assert.equal(moves[0][2], 0);
button.touch(event(2, { id: 2, windowX: 1000, windowY: -1000 }));
assert.equal(calls.length, 2, 'editing must not send remote input');
console.log('PASS screen game profiles, bounds, input validation, editing and cancel release');
