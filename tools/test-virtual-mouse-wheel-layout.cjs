'use strict';
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/RemotePage.ets'), 'utf8');
const overlayStart = source.indexOf('  buildVirtualMouseOverlay()');
const overlay = source.slice(overlayStart, source.indexOf('\n  @Builder', overlayStart));
const wheel = overlay.slice(overlay.indexOf('// Input surfaces'), overlay.indexOf('.zIndex(2)'));
assert(!overlay.includes('ReadableButtonModifier'), 'remote input controls must not inherit growable text-button geometry');
assert(!wheel.includes('.fontSize(') && !wheel.includes('minHeight'), 'wheel size must not depend on font metrics or intrinsic label height');
assert(!/Button\('[⌃⌄≡]'\)/.test(wheel), 'arrows and middle grip are vectors, not font glyphs');
const children = [...wheel.matchAll(/buildVirtualMouseWheelIcon\((-?\d)\)[\s\S]*?\.width\((\d+)\)\.height\((\d+)\)[\s\S]*?\.position\(\{ x: (\d+), y: (\d+) \}\)/g)]
  .map(m => ({ direction: +m[1], width: +m[2], height: +m[3], x: +m[4], y: +m[5] }));
assert.deepEqual(children, [
  { direction: -1, width: 22, height: 18, x: 0, y: 1 },
  { direction: 0, width: 22, height: 29, x: 0, y: 19 },
  { direction: 1, width: 22, height: 18, x: 0, y: 48 }
]);
for (const scale of [0.85, 1, 1.3, 1.8, 2, 2.8, 3.2]) {
  for (let i = 0; i < children.length; i++) {
    const b = children[i];
    assert(b.y >= 1 && b.y + b.height <= 66, `inside 67-vp wheel at font scale ${scale}`);
    assert(b.x === 0 && b.width === 22);
    if (i > 0) assert.equal(children[i - 1].y + children[i - 1].height, b.y, 'no overlap or dead gap');
    assert(12 <= b.width && 12 <= b.height, 'vector fits each hit region');
  }
}
assert(wheel.includes('.clip(true)') && wheel.includes('.height(67)'));
assert(wheel.includes('.accessibilityText(translate(\'向上滚动\''));
assert(wheel.includes('.accessibilityText(translate(\'向下滚动\''));
assert(wheel.includes('.accessibilityText(translate(\'中键\''));
assert(wheel.includes('sendVirtualMouseWheel(-VIRTUAL_MOUSE_WHEEL_BUTTON_STEP)'));
assert(wheel.includes('sendVirtualMouseWheel(VIRTUAL_MOUSE_WHEEL_BUTTON_STEP)'));
assert(wheel.includes('this.handleVirtualMouseWheelTouch(event)'));
assert(wheel.includes("this.clickVirtualMouseButtonFallback('middle')"));
const icon = source.slice(source.indexOf('  buildVirtualMouseWheelIcon('), overlayStart);
for (const name of ['up', 'down', 'grip']) {
  assert(icon.includes(`$r('app.media.virtual_mouse_wheel_${name}')`));
  const svg = fs.readFileSync(path.join(__dirname, `../entry/src/main/resources/base/media/virtual_mouse_wheel_${name}.svg`), 'utf8');
  assert(svg.includes('viewBox="0 0 12 12"') && svg.includes('fill="none"'));
  assert(!/text|font|href|script/.test(svg), 'SVG has no font dependence or external content');
  if(name === 'grip') assert(svg.includes('M3 3L9 3M3 6L9 6M3 9L9 9'), 'middle grip has clearly separated lines');
}
assert(icon.includes('.objectFit(ImageFit.Contain)'), 'density-independent SVG scaling');
assert(icon.includes('.hitTestBehavior(HitTestMode.None)'), 'vector must not intercept button or wheel touches');
assert(overlay.includes('.position({ x: 0, y: 69 })'), 'movement handle remains below all three wheel regions');
console.log('PASS virtual mouse: fixed non-overlapping wheel regions, vector glyphs, font-independent geometry, accessibility and preserved input handlers (device rendering verified separately)');
