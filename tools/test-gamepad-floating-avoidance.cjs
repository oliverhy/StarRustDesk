'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r/g, '');
const ctx = { exports: {}, Math, Number, JSON, Array, Object };
for (const file of ['GamepadMapping', 'GameScreenControls', 'VirtualGamepadGeometry', 'GameScreenAvoidance',
  'FloatingControlAvoidance', 'RemoteToolbarPlacement']) {
  vm.runInNewContext(ts.transpile(read(`entry/src/main/ets/model/${file}.ets`).replace(/^import .*\n/gm, '')), ctx);
  Object.assign(ctx, ctx.exports);
}
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
Object.assign(ctx, { ConnectionStatus: { CONNECTED: 2 } });
const names = ['getRemoteToolbarX', 'getRemoteToolbarY', 'gamepadFloatingControlsPlan',
  'getRemoteToolbarBaseX', 'getRemoteToolbarBaseY', 'clampRemoteToolbarOffsetX', 'clampRemoteToolbarOffsetY',
  'getKeyboardLauncherBase', 'getKeyboardUsablePageHeight', 'clampKeyboardLauncherOffset',
  'beginRemoteToolbarDrag', 'updateRemoteToolbarDrag', 'finishRemoteToolbarDrag'];
vm.runInNewContext(ts.transpile('class Page {' + names.map(method).join('\n') + '} exports.Page=Page;'), ctx);
const intersects = (a, b) => a.x < b.x + b.width + 3.99 && b.x < a.x + a.width + 3.99 &&
  a.y < b.y + b.height + 3.99 && b.y < a.y + a.height + 3.99;
const boxes = (w, h) => ctx.virtualGamepadRects(w, h).map(r => ({ x:r.x, y:r.y, width:r.size, height:r.size }));
let tested = 0;
for (const [w, h] of [[360, 720], [720, 720], [800, 360], [1024, 600], [1024, 768], [1600, 850]]) {
  for (const collapsed of [false, true]) for (const screenOn of [false, true]) {
    const keys = ctx.defaultScreenGameKeys(w, h);
    const layout = ctx.avoidVirtualGamepad(keys, w, h);
    if (screenOn && !layout.fits) continue;
    const obstacles = boxes(w, h);
    if (screenOn) obstacles.push(...layout.placements.map(k => ({ x:k.x, y:k.y, width:k.size, height:k.size })));
    const tw = collapsed ? 56 : Math.min(350, w - 16), th = collapsed ? 54 : 62;
    const toolbar = { x:collapsed ? w - tw - 8 : (w - tw) / 2, y:h - th - 18, width:tw, height:th };
    const keyboard = { x:w - 64, y:h - 118, width:52, height:46 };
    const before = JSON.stringify({ toolbar, keyboard, obstacles });
    const plan = ctx.avoidGamepadFloatingControls(w, h, toolbar, keyboard, true, obstacles);
    assert(plan.fits, `${w}x${h} collapsed=${collapsed} screen=${screenOn} should accommodate both floating controls`);
    assert.equal(JSON.stringify({ toolbar, keyboard, obstacles }), before, 'source preferences and hitboxes are never mutated');
    for (const rect of [plan.toolbar, plan.keyboard]) {
      assert(rect.x >= 8 && rect.y >= 8 && rect.x + rect.width <= w - 8 + 0.01 && rect.y + rect.height <= h - 8 + 0.01);
      for (const obstacle of obstacles) assert(!intersects(rect, obstacle), `${w}x${h}: floating control covers a game button`);
    }
    assert(!intersects(plan.toolbar, plan.keyboard), `${w}x${h}: floating controls overlap each other`);
    assert.equal(JSON.stringify(ctx.avoidGamepadFloatingControls(w, h, toolbar, keyboard, true, obstacles)), JSON.stringify(plan));
    tested++;
  }
}
const blocked = ctx.avoidGamepadFloatingControls(240, 160,
  {x:8,y:90,width:224,height:62}, {x:170,y:40,width:52,height:46}, true,
  [{x:0,y:0,width:240,height:160}]);
assert.equal(blocked.fits, false, 'no unsafe overlay is returned when nothing fits');

const preferences = new Map(), writes = [];
const page = Object.assign(new ctx.exports.Page(), {
  pageWidth:1024, pageHeight:600, qualityViewportWidth:1024, qualityViewportHeight:600,
  remoteToolbarCollapsed:false, remoteToolbarPositionX:-1, remoteToolbarPositionY:-1,
  remoteToolbarOffsetX:0, remoteToolbarOffsetY:0, remoteToolbarDragging:false,
  keyboardLauncherOffsetX:0, keyboardLauncherOffsetY:0, virtualGamepadEnabled:false,
  gameScreenCoexistFits:true, gameScreenEditing:false, gameModeEnabled:true, gameScreenEnabled:true,
  fileOnly:false, pipSurfaceOwned:false, showKeyboardPanel:false, connectionStatus:2,
  gamepadFloatingPlanKey:'', gamepadFloatingPlanCache:undefined,
  isPcDevice:() => false, isHandheldDevice:() => true, isHandheldLandscape:() => true,
  getRemoteToolbarCurrentWidth:() => 350, getRemoteToolbarCurrentHeight:() => 62, getRemoteToolbarHeight:() => 62,
  cancelPcToolbarAutoCollapse() {}, schedulePcToolbarAutoCollapse() {},
  peerPreferences:{ set(key, value) { preferences.set(key, value); writes.push(key); }, flush() {} },
  getRemoteToolbarDisplayX() { return this.gamepadFloatingControlsPlan().toolbar.x; },
  getRemoteToolbarDisplayY() { return this.gamepadFloatingControlsPlan().toolbar.y; }
});
const screen = ctx.avoidVirtualGamepad(ctx.defaultScreenGameKeys(1024, 600), 1024, 600);
page.gameScreenKeys = screen.placements.map(k => ({ id:k.id, renderX:k.x, renderY:k.y, renderSize:k.size,
  x:0, y:0, size:k.size }));
const original = page.gamepadFloatingControlsPlan();
const originalFields = [page.remoteToolbarPositionX, page.remoteToolbarPositionY,
  page.remoteToolbarOffsetX, page.remoteToolbarOffsetY, page.keyboardLauncherOffsetX, page.keyboardLauncherOffsetY];
page.virtualGamepadEnabled = true;
const plan = page.gamepadFloatingControlsPlan();
assert(plan.fits);
assert(plan.toolbar.x !== original.toolbar.x || plan.toolbar.y !== original.toolbar.y, 'control bar is moved out of the way');
assert(plan.keyboard.x !== original.keyboard.x || plan.keyboard.y !== original.keyboard.y, 'keyboard launcher is moved out of the way');
assert.deepEqual([page.remoteToolbarPositionX, page.remoteToolbarPositionY, page.remoteToolbarOffsetX,
  page.remoteToolbarOffsetY, page.keyboardLauncherOffsetX, page.keyboardLauncherOffsetY], originalFields);
assert.equal(writes.length, 0, 'automatic avoidance never saves a position');
const obstacles = boxes(1024, 600).concat(screen.placements.map(k => ({x:k.x,y:k.y,width:k.size,height:k.size})));
for (const obstacle of obstacles) {
  assert(!intersects(plan.toolbar, obstacle)); assert(!intersects(plan.keyboard, obstacle));
}
assert(!intersects(plan.toolbar, plan.keyboard));
page.virtualGamepadEnabled = false;
assert.equal(JSON.stringify(page.gamepadFloatingControlsPlan()), JSON.stringify(original), 'disabling restores both positions');
page.virtualGamepadEnabled = true;
const display = page.gamepadFloatingControlsPlan().toolbar;
page.beginRemoteToolbarDrag(); page.updateRemoteToolbarDrag(0, 0);
assert(Math.abs(page.gamepadFloatingControlsPlan().toolbar.x - display.x) < 0.01);
assert(Math.abs(page.gamepadFloatingControlsPlan().toolbar.y - display.y) < 0.01, 'drag starts at the actual visible position');
assert.equal(writes.length, 0, 'no per-frame writes');
page.updateRemoteToolbarDrag(20, -20); page.finishRemoteToolbarDrag();
assert.equal(writes.length, 1, 'an explicit drag persists exactly once');
page.virtualGamepadEnabled = false;
assert.notEqual(page.remoteToolbarPositionX, -1, 'an explicit manual drag keeps its chosen position');
assert(method('buildFloatingToolbar').includes('this.getRemoteToolbarDisplayX()'));
assert(method('buildKeyboardLauncher').includes('this.getKeyboardLauncherDisplayX()'));
assert(method('buildKeyboardLauncher').includes('this.getKeyboardLauncherDisplayY() - this.getKeyboardLauncherBase(false)'));
assert(method('getControlMenuAnchor').includes('this.getRemoteToolbarDisplayX()'));
assert(source.includes('!this.gamepadFloatingControlsPlan().fits'));
console.log(`PASS floating controls: ${tested} collision-free layouts, preserved settings, safe fallback and drag continuity`);
