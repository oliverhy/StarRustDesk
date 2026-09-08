const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync('entry/src/main/ets/pages/RemotePage.ets', 'utf8');
const start = source.indexOf('\n  applyRemoteCursorPosition(');
const method = source.slice(start, source.indexOf('\n  }', start) + 4);
const ctx = vm.createContext({ LOCAL_CURSOR_ECHO_GUARD_MS: 360, RustDeskNapi: { appendDiagnosticLog() {} } });
vm.runInContext(ts.transpile('class Page {' + method + '} globalThis.Page = Page;'), ctx);
function page() {
  return Object.assign(new ctx.Page(), {
    lastRemoteCursorSequence: -1, remoteWidth: 1920, remoteHeight: 1080,
    lastLocalPointerInputAt: 1000, localPointerGestureActive: false,
    preferAuthoritativeCursor: false, leftButtonHeld: false, showCursor: true,
    updateCursorOverlayFromPosition(x,y) { this.showCursor=true; this.position=[x,y]; }
  });
}
const outside = {valid:true, x:2200,y:200,sequence:8};
let p=page();
p.applyRemoteCursorPosition(outside, 1010);
assert.equal(p.showCursor,true, 'old off-screen data must not hide a physical move');
assert.equal(p.lastRemoteCursorSequence,8);
p.applyRemoteCursorPosition(outside, 2000);
assert.equal(p.showCursor,true, 'consumed data must never replay after guard expires');
p.applyRemoteCursorPosition({...outside,sequence:9},2000);
assert.equal(p.showCursor,false, 'fresh remote departure must hide the cursor when idle');
p.applyRemoteCursorPosition({...outside,x:200,sequence:10},2010);
assert.equal(p.showCursor,true);
assert.deepEqual(p.position,[200,200]);
p=page();
p.applyRemoteCursorPosition({...outside,x:100},1010);
p.applyRemoteCursorPosition({...outside,x:100},2000);
assert.equal(p.position,undefined,'a suppressed in-bounds echo must not replay later');
p.applyRemoteCursorPosition({...outside,x:300,sequence:9},2010);
assert.deepEqual(p.position,[300,200]);
console.log('PASS old off-screen samples, local prediction, remote departure and fresh recovery');
