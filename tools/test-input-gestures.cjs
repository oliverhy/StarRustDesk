const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const method = n => { const a=source.indexOf('\n  '+n+'('); assert(a>=0,n); return source.slice(a,source.indexOf('\n  }',a)+4); };
let passed=0;
const test=(name,fn)=>{fn();passed++;console.log('PASS '+name);};
const calls=[];
const napi={appendDiagnosticLog(){},sendKeyEvent:(...args)=>{calls.push(['key',...args]);return 0;},
  sendPhysicalKeyEvent:(...args)=>calls.push(['scan',...args]),sendMouseEvent:(...args)=>calls.push(['mouse',...args])};
const serviceSource=read('entry/src/main/ets/service/ConnectionService.ets').replace(/^import .*$/gm,'').replace('export class','class');
const context=vm.createContext({RustDeskNapi:napi,hilog:{info(){}},Date});
vm.runInContext(ts.transpile(serviceSource+'\nglobalThis.Service=ConnectionService;'),context);
const S=context.Service;
test('Ctrl down is present on mouse packet',()=>{
  S.sendKeyEvent(17,0,2072);S.sendMouseEvent(10,10,1);assert.equal(calls.at(-1)[4],1);
});
test('native empty snapshot cannot erase ArkUI Ctrl',()=>{
  S.releaseModifiers();S.syncHeldModifierState(true,false,false);S.syncNativeModifierState(0);
  S.sendMouseEvent(10,10,1);assert.equal(calls.at(-1)[4],1);
});
test('left and right Shift release independently',()=>{
  S.releaseModifiers();S.sendKeyEvent(16,0,2047);S.sendKeyEvent(16,0,2048);
  S.sendKeyEvent(16,1,2047);S.sendMouseEvent(0,0,1);assert.equal(calls.at(-1)[4],2);
  S.sendKeyEvent(16,1,2048);S.sendMouseEvent(0,0,1);assert.equal(calls.at(-1)[4],0);
});
test('duplicate modifier callbacks are idempotent',()=>{
  S.releaseModifiers();calls.length=0;S.sendKeyEvent(17,0,2072);S.sendKeyEvent(17,0,2072);
  S.sendKeyEvent(17,1,2072);S.sendKeyEvent(17,1,2072);assert.equal(calls.length,2);
});
test('authoritative key-up clears stale snapshots',()=>{
  S.sendKeyEvent(17,0,2072);S.syncNativeModifierState(1);S.syncHardwareModifierState(true,false,false);
  S.syncHeldModifierState(true,false,false);S.sendKeyEvent(17,1,2072);
  S.sendMouseEvent(0,0,1);assert.equal(calls.at(-1)[4],0);
});
test('plain letters retain physical scan path for remote IME',()=>{
  S.releaseModifiers();S.sendLetterKeyEvent('a',30,0);assert.equal(calls.at(-1)[0],'scan');
});
test('Shift letter uses uppercase and matching release path',()=>{
  S.sendKeyEvent(16,0,2047);S.sendLetterKeyEvent('a',30,0);assert.equal(calls.at(-1)[1],65);
  S.sendKeyEvent(16,1,2047);S.sendLetterKeyEvent('a',30,1);assert.equal(calls.at(-1)[0],'key');
  assert.equal(calls.at(-1)[1],65);
});
test('queue reset balances held printable keys as well as modifiers',()=>{
  S.releaseModifiers();S.sendPhysicalKeyEvent(30,0);S.sendKeyEvent(13,0);calls.length=0;
  S.releaseModifiers();assert(calls.some(c=>c[0]==='scan'&&c[1]===30&&c[2]===1));
  assert(calls.some(c=>c[0]==='key'&&c[1]===13&&c[2]===1));
});
let now=1000, output=[];
const TouchType={Down:0,Move:1,Up:2,Cancel:3};
const gc=vm.createContext({Date:{now:()=>now},Math,TouchType,SourceType:{Mouse:99},
 SourceTool:{MOUSE:99,TOUCHPAD:98},INPUT_MODE_MOUSE:0,INPUT_MODE_TOUCH:1,
 PINCH_DISTANCE_THRESHOLD:10,MULTI_TOUCH_MOVE_THRESHOLD:8,THREE_FINGER_SWIPE_THRESHOLD:40,
 THREE_FINGER_HORIZONTAL_LIMIT:80,THREE_FINGER_MAX_DURATION:1200,RustDeskNapi:napi,
 ConnectionService:{sendMouseEvent:(x,y,a)=>output.push(a===3?'right_down':'right_up')}});
vm.runInContext(ts.transpile('class Gesture {'+['handleRemoteTouch','handleMultiTouch','finishMultiTouchGesture',
 'handleThreeFingerGesture','finishThreeFingerGesture'].map(method).join('\n')+'};globalThis.Gesture=Gesture;'),gc);
function make(full=false){
  now=1000;output=[];
  const p=Object.assign(new gc.Gesture(),{isFullScreen:full,inputMode:0,multiTouchActive:false,
    threeFingerGestureActive:false,zoomScale:1,lastAbsX:100,lastAbsY:100,lastPinchEndedAt:0,
    touchSequenceDraining:false,touchSequenceMaxFingers:0,threeFingerStartCenterY:0});
  for(const n of ['stopEdgeAutoPan','endLocalPointerGesture','clearLongPressTimer','flushPendingTap','sendLeftUp',
    'ensurePointerInitialized','clampViewportOffset','finishSingleTouch','handleTouchpadTouch','applyPinchTransform'])p[n]=()=>{};
  p.cancelActiveTouchGesture=()=>{p.multiTouchActive=false;p.threeFingerGestureActive=false;};
  p.openRemoteKeyboard=()=>output.push('keyboard');p.sendTouchScroll=()=>output.push('scroll');
  return p;
}
function send(p,type,n,y=20){now+=25;const touches=Array.from({length:n},(_,i)=>({id:i,x:20+i*30,y}));
  p.handleRemoteTouch({type,touches,changedTouches:touches.length?[touches.at(-1)]:[]});}
function lift(p,n,y=20){for(let i=n;i>0;i--)send(p,TouchType.Up,i,y);}
for(const count of [2,3])test(`${count}-finger scroll never adds a right-click on staggered lift`,()=>{
  const p=make();send(p,0,1);send(p,0,count);send(p,1,count,60);lift(p,count,60);
  assert.deepEqual(output,['scroll']);
});
test('two-finger tap emits exactly one right-click',()=>{
  const p=make();send(p,0,1);send(p,0,2);lift(p,2);assert.deepEqual(output,['right_down','right_up']);
});
test('three-finger tap cannot become two-finger tap',()=>{
  const p=make();send(p,0,1);send(p,0,3);lift(p,3);assert.deepEqual(output,[]);
});
test('cancel never clicks',()=>{
  const p=make();send(p,0,1);send(p,0,2);send(p,3,2);lift(p,2);assert.deepEqual(output,[]);
});
test('full-screen keyboard swipe does not restart with remaining fingers',()=>{
  const p=make(true);send(p,0,1);send(p,0,3,100);send(p,1,3,20);lift(p,3,20);
  assert.deepEqual(output,['keyboard']);
});
test('new two-finger tap works after completed scroll',()=>{
  const p=make();send(p,0,1);send(p,0,3);send(p,1,3,60);lift(p,3,60);
  send(p,0,1);send(p,0,2);lift(p,2);assert.deepEqual(output,['scroll','right_down','right_up']);
});
test('release event cannot initialize a multi-touch tap',()=>{
  const p=make();send(p,2,2);send(p,2,1);assert.deepEqual(output,[]);
});
const ordered=[];
const dc=vm.createContext({RustDeskNapi:{takeNativeInputEvents:()=>[
  {sequence:1,key:{keyCode:2072}},{sequence:2,mouse:{action:1}},{sequence:3,reset:true}]},
  ConnectionService:{releaseModifiers:()=>ordered.push('reset_keys')}});
vm.runInContext(ts.transpile('class Drain {'+method('drainNativeInputEvents')+'};globalThis.Drain=Drain;'),dc);
test('unified native drain preserves keyboard-before-click and resets overflow',()=>{
  const d=Object.assign(new dc.Drain(),{handleNativeKeyInput:()=>ordered.push('key'),
    handleNativeMouseInput:()=>ordered.push('mouse'),releaseHeldMouseButtons:()=>ordered.push('reset_mouse')});
  d.drainNativeInputEvents();assert.deepEqual(ordered,['key','mouse','reset_mouse','reset_keys']);
});
console.log(`${passed} input/gesture regression checks passed`);
