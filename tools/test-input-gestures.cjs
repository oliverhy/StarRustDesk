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
const napi={getInputCapabilities:()=>0,appendDiagnosticLog(){},sendKeyEvent:(...args)=>{calls.push(['key',...args]);return 0;},
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
  S.releaseModifiers();calls.length=0;S.sendKeyEvent(16,0,2047);S.sendKeyEvent(161,0,2048);
  assert.deepEqual(calls.filter(c=>c[0]==='key').map(c=>c[1]),[16,161]);
  S.sendKeyEvent(16,1,2047);S.sendMouseEvent(0,0,1);assert.equal(calls.at(-1)[4],2);
  S.sendKeyEvent(161,1,2048);S.sendMouseEvent(0,0,1);assert.equal(calls.at(-1)[4],0);
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
  S.releaseModifiers();S.sendLetterKeyEvent('a',4,0);assert.equal(calls.at(-1)[0],'scan');
});
test('Shift letter uses uppercase and matching release path',()=>{
  S.sendKeyEvent(16,0,2047);S.sendLetterKeyEvent('a',4,0);assert.equal(calls.at(-1)[1],65);
  S.sendKeyEvent(16,1,2047);S.sendLetterKeyEvent('a',4,1);assert.equal(calls.at(-1)[0],'key');
  assert.equal(calls.at(-1)[1],65);
});
test('Ctrl+Shift letter stays on physical path for remote shortcuts',()=>{
  S.releaseModifiers();calls.length=0;S.sendKeyEvent(17,0,2072);S.sendKeyEvent(16,0,2047);
  S.sendLetterKeyEvent('c',6,0);assert.equal(calls.at(-1)[0],'scan');
});
test('right Alt is preserved for Linux AltGr and macOS Option',()=>{
  S.releaseModifiers();calls.length=0;S.sendKeyEvent(165,0,2046);S.sendPhysicalKeyEvent(20,0);
  assert(calls.some(c=>c[0]==='key'&&c[1]===165&&c[2]===0));
  assert.equal(calls.at(-1)[3]&4,4);
});
test('queue reset balances held printable keys as well as modifiers',()=>{
  S.releaseModifiers();S.sendPhysicalKeyEvent(4,0);S.sendKeyEvent(13,0);calls.length=0;
  S.releaseModifiers();assert(calls.some(c=>c[0]==='scan'&&c[1]===4&&c[2]===1));
  assert(calls.some(c=>c[0]==='key'&&c[1]===13&&c[2]===1));
});
let now=1000, output=[];
const TouchType={Down:0,Move:1,Up:2,Cancel:3};
const gc=vm.createContext({Date:{now:()=>now},Math,TouchType,SourceType:{Mouse:99},
 SourceTool:{MOUSE:99,TOUCHPAD:98},INPUT_MODE_MOUSE:0,INPUT_MODE_TOUCH:1,
 exports:{},ConnectionStatus:{CONNECTED:1},
 PINCH_DISTANCE_THRESHOLD:10,MULTI_TOUCH_MOVE_THRESHOLD:8,THREE_FINGER_SWIPE_THRESHOLD:40,
 THREE_FINGER_HORIZONTAL_LIMIT:80,THREE_FINGER_MAX_DURATION:1200,RustDeskNapi:napi,
 ConnectionService:{sendMouseEvent:(x,y,a)=>output.push(a===3?'right_down':'right_up')}});
vm.runInContext(ts.transpile(read('entry/src/main/ets/model/RemoteDisplaySwipe.ets')),gc);
Object.assign(gc,gc.exports);
vm.runInContext(ts.transpile('class Gesture {'+['touchGesturePoint','handleRemoteTouch','handleMultiTouch','finishMultiTouchGesture',
 'canSwipeRemoteDisplays','displaySwipePoints','handleThreeFingerGesture','finishThreeFingerGesture'].map(method).join('\n')+'};globalThis.Gesture=Gesture;'),gc);
function make(full=false){
  now=1000;output=[];
  const p=Object.assign(new gc.Gesture(),{isFullScreen:full,inputMode:0,multiTouchActive:false,
    threeFingerGestureActive:false,zoomScale:1,lastAbsX:100,lastAbsY:100,lastPinchEndedAt:0,
    touchSequenceDraining:false,touchSequenceMaxFingers:0,displaySwipe:new gc.RemoteDisplaySwipe(),
    displayCount:1,currentDisplay:0,displaySwipeEnabled:true,remotePageVisible:true,connectionStatus:1,lastDisplaySwipeAt:-1});
  for(const n of ['stopEdgeAutoPan','endLocalPointerGesture','clearLongPressTimer','flushPendingTap','sendLeftUp',
    'ensurePointerInitialized','clampViewportOffset','finishSingleTouch','handleTouchpadTouch','applyPinchTransform'])p[n]=()=>{};
  p.cancelActiveTouchGesture=()=>{p.multiTouchActive=false;p.multiTouchMoved=false;p.isPinching=false;
    p.threeFingerGestureActive=false;p.displaySwipe.reset();p.ignoreTouchUntilNextDown=false;};
  p.openRemoteKeyboard=()=>output.push('keyboard');p.sendTouchScroll=()=>output.push('scroll');
  p.switchDisplay=target=>{p.cancelActiveTouchGesture();p.currentDisplay=target;output.push(`display:${target}`);return true;};
  p.requestDisplaySwitch=target=>{if(!p.switchDisplay(target))p.showFileToast();};
  p.showDisplaySwitchHint=()=>{};p.showFileToast=()=>output.push('error');
  return p;
}
function send(p,type,n,y=20){now+=25;const touches=Array.from({length:n},(_,i)=>({id:i,x:20+i*30,y,windowX:20+i*30,windowY:y}));
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
function swipe(p,dx,dy=0,finish=true){
  send(p,0,1,200);send(p,0,3,200);
  const touches=Array.from({length:3},(_,id)=>({id,x:20+id*30+dx,y:200+dy,windowX:20+id*30+dx,windowY:200+dy}));
  now+=100;p.handleRemoteTouch({type:1,touches,changedTouches:touches});
  if(finish){now+=25;p.handleRemoteTouch({type:2,touches,changedTouches:[touches[2]]});
    p.handleRemoteTouch({type:2,touches:touches.slice(0,2),changedTouches:[touches[1]]});
    p.handleRemoteTouch({type:2,touches:touches.slice(0,1),changedTouches:[touches[0]]});}
}
test('left/right swipes cycle displays in both windowed and fullscreen views, once per lift',()=>{
 for(const full of [false,true]){
  const p=make(full);p.displayCount=3;swipe(p,-100);assert.equal(p.currentDisplay,1);
  now+=500;swipe(p,100);assert.equal(p.currentDisplay,0);
  now+=500;swipe(p,100);assert.equal(p.currentDisplay,2);
  now+=500;swipe(p,-100);assert.equal(p.currentDisplay,0);
  assert.deepEqual(output,['display:1','display:0','display:2','display:0']);
 }
});
test('keyboard swipe stays vertical and fullscreen-only with multiple displays',()=>{
 const p=make(true);p.displayCount=3;swipe(p,0,-100);assert.deepEqual(output,['keyboard']);
 const q=make(false);q.displayCount=3;swipe(q,0,-100);assert.deepEqual(output,[]);
});
test('disabled switch does not steal keyboard swipe; one display never switches',()=>{
 const p=make(true);p.displaySwipeEnabled=false;p.displayCount=3;swipe(p,-100);assert.deepEqual(output,[]);
 swipe(p,0,-100);assert.deepEqual(output,['keyboard']);
 const q=make(true);swipe(q,-100);assert.deepEqual(output,[]);
});
test('three-finger pinch, short motion and diagonal movement do not switch or click',()=>{
 for(const [x,y] of [[30,0],[-80,-80],[100,100]]){
  const p=make(true);p.displayCount=3;swipe(p,x,y);assert.deepEqual(output,[]);
 }
 const p=make(true);p.displayCount=3;send(p,0,1);send(p,0,3);
 const touches=[{id:0,x:-200,y:20,windowX:-200,windowY:20},
   {id:1,x:50,y:20,windowX:50,windowY:20},{id:2,x:300,y:20,windowX:300,windowY:20}];
 p.handleRemoteTouch({type:1,touches,changedTouches:touches});p.handleRemoteTouch({type:2,touches,changedTouches:[touches[2]]});
 assert.deepEqual(output,[]);
});
test('fourth finger and system cancel suppress all residual events',()=>{
 for(const extra of [true,false]){
  const p=make(true);p.displayCount=3;swipe(p,-100,0,false);
  send(p,extra?0:3,extra?4:3,200);lift(p,extra?4:3,200);assert.deepEqual(output,[]);
 }
});
test('adding a third finger to a running two-finger scroll does not switch',()=>{
 const p=make();p.displayCount=3;send(p,0,1);send(p,0,2);send(p,1,2,60);
 send(p,0,3,60);send(p,1,3,180);lift(p,3,180);assert.deepEqual(output,['scroll']);
});
test('first lift excluding the released finger still recognizes the final displacement',()=>{
 const p=make(true);p.displayCount=3;send(p,0,1,200);send(p,0,3,200);
 const touches=Array.from({length:3},(_,id)=>({id,x:-80+id*30,y:200,windowX:-80+id*30,windowY:200}));
 p.handleRemoteTouch({type:2,touches:touches.slice(0,2),changedTouches:[touches[2]]});
 assert.deepEqual(output,['display:1']);assert(p.touchSequenceDraining);
});
test('second rapid swipe is ignored; a later deliberate swipe works',()=>{
 const p=make(true);p.displayCount=3;swipe(p,-100);swipe(p,-100);
 assert.deepEqual(output,['display:1']);now+=500;swipe(p,-100);assert.deepEqual(output,['display:1','display:2']);
});
test('display topology change, background and disconnect cannot complete a switch',()=>{
 for(const change of [p=>p.displayCount=2,p=>p.currentDisplay=2,p=>p.remotePageVisible=false,
   p=>p.connectionStatus=0,p=>p.pipSurfaceOwned=true,p=>p.showRemoteFileBrowser=true]){
  const p=make(true);p.displayCount=3;swipe(p,-100,0,false);change(p);lift(p,3,200);
  assert.deepEqual(output,[]);
 }
});
test('physical mouse and touchpad compatibility events never enter display swipe recognition',()=>{
 for(const sourceTool of [99,98]){
  const p=make(true);p.displayCount=3;let forwarded=0;p.handlePointerCompatibilityTouch=()=>forwarded++;
  for(const type of [0,1,2])p.handleRemoteTouch({type,sourceTool,touches:[{id:0},{id:1},{id:2}],changedTouches:[]});
  assert.equal(forwarded,3);assert(!p.threeFingerGestureActive);assert.deepEqual(output,[]);
 }
});
test('switch request failure reports failure and still drains remaining fingers',()=>{
 const p=make(true);p.displayCount=3;p.switchDisplay=()=>false;swipe(p,-100);
 assert.deepEqual(output,['error']);assert.equal(p.currentDisplay,0);
});
const ordered=[];
const dc=vm.createContext({RustDeskNapi:{takeNativeInputEvents:()=>[
  {sequence:1,key:{keyCode:2072}},{sequence:2,mouse:{action:1}},{sequence:3,reset:true}]},
  ConnectionService:{releaseModifiers:()=>ordered.push('reset_keys')}});
vm.runInContext(ts.transpile('class Drain {'+method('drainNativeInputEvents')+'};globalThis.Drain=Drain;'),dc);
test('unified native drain preserves keyboard-before-click and resets overflow',()=>{
  const d=Object.assign(new dc.Drain(),{handleNativeKeyInput:()=>ordered.push('key'),
    handleNativeMouseInput:()=>ordered.push('mouse'),releaseHeldMouseButtons:()=>ordered.push('reset_mouse'),
    releaseRemoteNavigationKeys:reason=>ordered.push(`reset_navigation:${reason}`)});
  d.drainNativeInputEvents();assert.deepEqual(ordered,
    ['key','mouse','reset_mouse','reset_navigation:input_queue_reset','reset_keys']);
});
test('touchpad drag waits for confirmed movement before left-down',()=>{
  assert.match(source,/const TOUCHPAD_DRAG_START_THRESHOLD: number = 18;/);
  const handlerStart=source.indexOf('\n  handleTouchpadTouch(');
  const handlerEnd=source.indexOf('\n  handleDirectTouch(',handlerStart);
  const handler=source.slice(handlerStart,handlerEnd);
  const downStart=handler.indexOf('if (secondTap)');
  const moveStart=handler.indexOf('} else if (event.type === TouchType.Move)');
  assert(downStart>=0&&moveStart>downStart);
  assert.doesNotMatch(handler.slice(downStart,moveStart),/sendLeftDown/);
  assert.match(handler.slice(moveStart),/TOUCHPAD_DRAG_START_THRESHOLD[\s\S]*sendLeftDown/);
});
test('second touchpad tap without movement remains a double-click',()=>{
  const finish=method('finishTouchpadTouch');
  const candidate=finish.indexOf('wasDragCandidate && !cancelled');
  assert(candidate>=0);
  assert.equal((finish.slice(candidate).match(/sendLeftClick/g)||[]).length,2);
});
console.log(`${passed} input/gesture regression checks passed`);
