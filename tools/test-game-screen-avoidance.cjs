'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r/g, '');
const ctx = { exports: {}, Math, Number, JSON, Array, Object };
for (const file of ['GamepadMapping', 'GameScreenControls', 'VirtualGamepadGeometry', 'GameScreenAvoidance']) {
  vm.runInNewContext(ts.transpile(read(`entry/src/main/ets/model/${file}.ets`).replace(/^import .*\n/gm, '')), ctx);
  Object.assign(ctx, ctx.exports);
}
const intersects = (a, b) => a.x < b.x + b.size + 1.99 && b.x < a.x + a.size + 1.99 &&
  a.y < b.y + b.size + 1.99 && b.y < a.y + a.size + 1.99;
for (const [width, height] of [[320, 200], [360, 720], [640, 360], [800, 400], [1024, 768], [1600, 850]]) {
  const keys = ctx.defaultScreenGameKeys(width, height), before = JSON.stringify(keys);
  const layout = ctx.avoidVirtualGamepad(keys, width, height);
  assert.equal(JSON.stringify(keys), before, 'layout must never mutate saved keys');
  assert(layout.fits, `${width}x${height}: default keys should fit together with the virtual controller`);
  assert.equal(layout.placements.length, keys.length);
  assert(layout.moved > 0, `${width}x${height}: a collision should be adjusted`);
  for (const key of layout.placements) {
    assert(key.x >= 0 && key.y >= 0 && key.x + key.size <= width + 0.01 && key.y + key.size <= height + 0.01);
    for (const pad of ctx.virtualGamepadRects(width, height)) assert(!intersects(key, pad),
      `${width}x${height}: screen key ${key.id} overlaps ${pad.id}`);
  }
  for (let i = 0; i < layout.placements.length; i++) for (let j = i + 1; j < layout.placements.length; j++)
    assert(!intersects(layout.placements[i], layout.placements[j]), `${width}x${height}: reflowed keys overlap`);
  assert.equal(JSON.stringify(ctx.avoidVirtualGamepad(keys, width, height)), JSON.stringify(layout), 'placement is deterministic');
}
const custom = [{ id: 1, target: 'k:26', x: 0.5, y: 0.3, size: 52, opacity: 70 },
  { id: 2, target: 'k:4', x: 0.05, y: 0.95, size: 52, opacity: 70 }];
const customBefore = JSON.stringify(custom), plan = ctx.avoidVirtualGamepad(custom, 1024, 768);
assert(plan.fits);
assert.equal(plan.placements[0].x, custom[0].x * (1024 - 52), 'unobstructed custom positions stay unchanged');
assert.equal(plan.placements[0].y, custom[0].y * (768 - 52));
assert.equal(JSON.stringify(custom), customBefore, 'custom positions are never saved over by temporary reflow');
const groupedKeys = ctx.defaultScreenGameKeys(1024, 600);
const grouped = ctx.avoidVirtualGamepad(groupedKeys, 1024, 600);
for (const [a, b] of [[0, 1], [0, 2], [0, 3], [4, 5], [4, 6]]) {
  const initialX = groupedKeys[a].x * (1024 - groupedKeys[a].size) - groupedKeys[b].x * (1024 - groupedKeys[b].size);
  const initialY = groupedKeys[a].y * (600 - groupedKeys[a].size) - groupedKeys[b].y * (600 - groupedKeys[b].size);
  assert(Math.abs((grouped.placements[a].x - grouped.placements[b].x) - initialX) < 0.01,
    'nearby controls preserve their horizontal relationship when there is room');
  assert(Math.abs((grouped.placements[a].y - grouped.placements[b].y) - initialY) < 0.01,
    'nearby controls preserve their vertical relationship when there is room');
}
const crowded = Array.from({ length: 12 }, (_, i) => ({ id: i + 1, target: 'k:26', x: 0, y: 1, size: 100, opacity: 70 }));
const crowdedBefore = JSON.stringify(crowded), failure = ctx.avoidVirtualGamepad(crowded, 240, 160);
assert.equal(failure.fits, false, 'impossible layouts produce an explicit safe fallback');
assert.equal(JSON.stringify(crowded), crowdedBefore);
console.log('PASS collision-free screen/gamepad layout, saved-position preservation and small-window fallback');
