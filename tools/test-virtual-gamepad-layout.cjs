'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const widget = fs.readFileSync(path.join(root, 'entry/src/main/ets/widget/VirtualGamepad.ets'), 'utf8');
const page = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemotePage.ets'), 'utf8');
const method = name => {
  const start = widget.indexOf(`  ${name}(): number {`);
  assert(start >= 0, name);
  const end = widget.indexOf(' }', start);
  assert(end > start, name);
  return widget.slice(start, end + 2);
};
const context = { exports: {}, Math };
vm.runInNewContext(ts.transpileModule('export class Layout {' +
  ['buttonSize', 'stickSize', 'padTop', 'faceLeft'].map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText, context);
for (const [w, h] of [[240,160], [280,180], [320,200], [360,720], [640,360], [800,400], [1024,768]]) {
  const view = Object.assign(new context.exports.Layout(), { viewportWidth: w, viewportHeight: h });
  const b = view.buttonSize(), s = view.stickSize(), p = view.padTop(), face = view.faceLeft();
  const boxes = [];
  const add = (name, x, y, size) => { boxes.push({ name, x, y, size }); };
  add('LT', 8, 8, b); add('LB', 12 + b, 8, b);
  add('Select', Math.max(0, w / 2 - b * 1.6), 8, b); add('Start', w / 2 + b * 0.6, 8, b);
  add('Home', Math.max(0, w / 2 - b / 2), 8, b);
  add('RB', w - 2 * b - 12, 8, b); add('RT', w - b - 8, 8, b);
  add('up', 8 + b, p, b); add('left', 8, p + b, b); add('right', 8 + 2 * b, p + b, b);
  add('down', 8 + b, p + 2 * b, b);
  add('Y', face + b, p, b); add('X', face, p + b, b); add('B', face + 2 * b, p + b, b);
  add('A', face + b, p + 2 * b, b);
  add('left stick', 12, h - s - 12, s); add('right stick', w - s - 12, h - s - 12, s);
  add('L3', s + 20, h - b - 12, b); add('R3', w - s - b - 20, h - b - 12, b);
  add('C', w / 2 - b / 2, h - b - 12, b);
  for (const box of boxes) {
    assert(box.x >= -0.01 && box.y >= -0.01 && box.x + box.size <= w + 0.01 && box.y + box.size <= h + 0.01,
      `${w}x${h}: ${box.name} outside viewport`);
  }
  for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
    const a = boxes[i], z = boxes[j];
    assert(!(a.x < z.x + z.size - 0.01 && z.x < a.x + a.size - 0.01 &&
      a.y < z.y + z.size - 0.01 && z.y < a.y + a.size - 0.01),
    `${w}x${h}: ${a.name} overlaps ${z.name}`);
  }
}
assert(widget.includes("height('100%').hitTestBehavior(HitTestMode.None)"), 'empty overlay is hit-test transparent');
assert.equal((widget.match(/\.hitTestBehavior\(HitTestMode\.Default\)/g) || []).length, 2,
  'buttons and sticks block hits on the remote viewport');
assert.equal((widget.match(/event\.stopPropagation\(\)/g) || []).length, 2);
assert.equal((widget.match(/TouchType\.Cancel/g) || []).length, 2);
assert(page.includes('this.qualityViewportWidth >= 240 && this.qualityViewportHeight >= 160'));
assert(page.includes('窗口过小，请放大窗口以使用虚拟手柄'));
console.log('PASS virtual controller layout bounds, non-overlap, touch routing contract and small-window fallback');
