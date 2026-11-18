const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync('entry/src/main/ets/pages/RemotePage.ets', 'utf8');
const tracker = fs.readFileSync('entry/src/main/ets/model/OrdinaryPointerDiagnostics.ets', 'utf8');
const start = source.indexOf('\n  applyRemoteCursorPosition(');
const method = source.slice(start, source.indexOf('\n  }', start) + 4);
const ctx = vm.createContext({ LOCAL_CURSOR_ECHO_GUARD_MS: 360, RustDeskNapi: { appendDiagnosticLog() {} } });
vm.runInContext(ts.transpile(tracker.replace('export class', 'class') + 'class Page {' + method +
  '} globalThis.Page = Page; globalThis.Tracker = OrdinaryPointerDiagnostics;'), ctx);
function page() {
  return Object.assign(new ctx.Page(), {
    pointerDelivery: new ctx.Tracker(),
    lastRemoteCursorSequence: -1, remoteWidth: 1920, remoteHeight: 1080,
    deferredRemoteCursorSequence: -1, deferredRemoteCursorInputRevision: 0,
    localPointerInputRevision: 0, pointerCursorDeferred: 0, pointerCursorDeferredStale: 0,
    lastLocalPointerInputAt: 1000, localPointerGestureActive: false,
    preferAuthoritativeCursor: false, leftButtonHeld: false, showCursor: true,
    virtualMouseDragActive: false,
    alignVirtualMouseToRemotePosition(x,y) { this.virtualMousePosition=[x,y]; },
    updateCursorOverlayFromPosition(x,y) { this.showCursor=true; this.position=[x,y]; }
  });
}
const outside = {valid:true, x:2200,y:200,sequence:8};
let p=page();
function feedback(page, now) { return page.pointerDelivery.summary(now, 0, 0, 1, 1); }
assert.match(feedback(p, 1000), /remote_cursor_feedback=none cursor_feedback_samples=0/);
p.applyRemoteCursorPosition(outside, 1010);
assert.match(feedback(p, 1010), /remote_cursor_feedback=outside_display cursor_feedback_samples=1/);
assert.equal(p.showCursor,true, 'old off-screen data must not hide a physical move');
assert.equal(p.lastRemoteCursorSequence,8);
p.applyRemoteCursorPosition(outside, 2000);
assert.match(feedback(p, 2000), /remote_cursor_feedback=outside_display cursor_feedback_samples=1/);
assert.equal(p.showCursor,true, 'consumed data must never replay after guard expires');
p.applyRemoteCursorPosition({...outside,sequence:9},2000);
assert.equal(p.showCursor,false, 'fresh remote departure must hide the cursor when idle');
p.applyRemoteCursorPosition({...outside,x:200,sequence:10},2010);
assert.equal(p.showCursor,true);
assert.deepEqual(p.position,[200,200]);
assert.deepEqual(p.virtualMousePosition,[200,200], 'fresh remote cursor must recalibrate the virtual mouse');
p=page();
p.applyRemoteCursorPosition({...outside,x:100},1010);
assert.match(feedback(p, 1030), /remote_cursor_feedback=local_guard cursor_feedback_samples=1 .*cursor_feedback_age_ms=20/);
p.applyRemoteCursorPosition({...outside,x:100},2000);
assert.equal(p.position,undefined,'a suppressed in-bounds echo must not replay later');
p.applyRemoteCursorPosition({...outside,x:300,sequence:9},2010);
assert.match(feedback(p, 2010),
  /remote_cursor_feedback=applied cursor_feedback_samples=2 cursor_feedback_applied=1 cursor_feedback_local_guard=1/);
assert.deepEqual(p.position,[300,200]);
console.log('PASS old off-screen samples, local prediction, remote departure and fresh recovery');
p=page();
p.relativeMouseEnabled=true;
p.localPointerGestureActive=true;
p.applyRemoteCursorPosition({...outside,x:350,sequence:20},1010);
assert.deepEqual(p.position,[350,200], 'Relative mode must accept real cursor feedback during local movement');
console.log('PASS relative mode does not suppress authoritative cursor feedback');
p=page();
p.remoteWidth=0; p.remoteHeight=0; p.lastLocalPointerInputAt=0;
const early={valid:true,x:417,y:906,sequence:21};
p.applyRemoteCursorPosition(early,1000);
p.applyRemoteCursorPosition(early,1033);
assert.match(feedback(p, 1033), /remote_cursor_feedback=deferred_geometry cursor_feedback_samples=1/);
assert.equal(p.lastRemoteCursorSequence,-1,'unknown dimensions must not consume the sample');
assert.equal(p.pointerCursorDeferred,1,'polling the same deferred sample must not spam diagnostics');
p.remoteWidth=1920; p.remoteHeight=1080;
p.applyRemoteCursorPosition(early,1100);
assert.deepEqual(p.position,[417,906],'same sample must become usable when dimensions arrive');
assert.equal(p.hasAuthoritativeRemoteCursor,true);
console.log('PASS early remote position is applied when geometry becomes ready');
p=page(); p.remoteWidth=0; p.remoteHeight=0; p.lastLocalPointerInputAt=0;
p.applyRemoteCursorPosition(early,1000);
p.localPointerInputRevision++;
p.remoteWidth=1920; p.remoteHeight=1080;
p.applyRemoteCursorPosition(early,2000);
assert.match(feedback(p, 2000), /remote_cursor_feedback=superseded cursor_feedback_samples=2/);
assert.equal(p.position,undefined,'a deferred sample must never override newer local input');
assert.equal(p.pointerCursorDeferredStale,1);
p.applyRemoteCursorPosition({...early,sequence:22,x:500},2100);
assert.deepEqual(p.position,[500,906]);
console.log('PASS local input invalidates a stale deferred sample');
p=page(); p.lastLocalPointerInputAt=0; p.virtualMouseDragActive=true;
p.applyRemoteCursorPosition({...early,sequence:23},2000);
assert.match(feedback(p, 2000), /remote_cursor_feedback=virtual_drag cursor_feedback_samples=1/);
assert.equal(p.position,undefined,'late peer positions must not overwrite an active virtual drag');
assert.equal(p.lastRemoteCursorSequence,23);
p.virtualMouseDragActive=false;
p.applyRemoteCursorPosition({...early,sequence:23},2100);
assert.equal(p.position,undefined,'a sample consumed during dragging must not replay on release');
p.applyRemoteCursorPosition({...early,sequence:24},2200);
assert.deepEqual(p.position,[417,906]);
console.log('PASS delayed peer samples cannot jump an active virtual drag');
