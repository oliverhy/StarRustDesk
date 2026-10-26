'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root=path.resolve(__dirname,'..'),read=p=>fs.readFileSync(path.join(root,p),'utf8');
const context={exports:{}};
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/RemoteDisplaySwipe.ets')),context);
const {RemoteDisplaySwipe:Swipe,adjacentRemoteDisplay:next}=context.exports;
let checks=0;const test=(name,fn)=>{fn();checks++;console.log('PASS '+name);};
const points=(x=0,y=0)=>Array.from({length:3},(_,id)=>({id,x:x+id*30,y}));
function result(x,y,end=200,start=points()) {const s=new Swipe();s.begin(start,0);s.update(points(x,y));return s.finish(end);}
test('three fingers from y=0 are valid; threshold and duration are deterministic',()=>{
 assert.equal(result(-70,0).action,'left');assert.equal(result(70,0).action,'right');
 assert.equal(result(0,-70).action,'up');assert.equal(result(69,0).action,'none');
 assert.equal(result(100,0,1501).reason,'expired');assert.equal(result(100,0,-1).reason,'expired');
 assert.equal(result(0,100).reason,'downward');assert.equal(result(100,100).action,'none');
});
test('stable contact ids survive array reordering, but replacements are rejected',()=>{
 const s=new Swipe();s.begin(points(),10);s.update(points(-100).reverse());assert.equal(s.finish(200).action,'left');
 s.begin(points(),10);const p=points(-100);p[0].id=4;s.update(p);assert.equal(s.finish(200).reason,'finger_replaced');
});
test('one moving finger cannot masquerade as a parallel swipe; sequential updates are allowed',()=>{
 const s=new Swipe();s.begin(points(),0);const p=points();p[0].x-=300;s.update(p);assert.equal(s.finish(100).reason,'not_parallel');
 s.begin(points(),0);for(let i=0;i<3;i++) {const q=points();for(let j=0;j<=i;j++)q[j].x-=100;s.update(q);}
 assert.equal(s.finish(100).action,'left');
});
test('locked vertical gesture cannot bend into a horizontal switch',()=>{
 const s=new Swipe();s.begin(points(),0);s.update(points(0,-30));s.update(points(100,-40));
 assert.equal(s.finish(200).action,'none');
});
test('vertical spreading while moving sideways is not a parallel display swipe',()=>{
 const s=new Swipe();s.begin(points(),0);const p=points(-100);p[0].y=-80;p[2].y=80;s.update(p);
 assert.equal(s.finish(200).reason,'not_parallel');
});
test('invalid points, fourth finger and reset never complete a swipe',()=>{
 for(const p of [[],points().slice(0,2),[...points(),{id:4,x:0,y:0}],
  [{id:0,x:NaN,y:0},...points().slice(1)],points().map(q=>({...q,id:0}))]){
  const s=new Swipe();s.begin(p,0);s.update(points(-100));assert.equal(s.finish(100).action,'none');
 }
 const s=new Swipe();s.begin(points(),0);s.update([...points(-100),{id:9,x:0,y:0}]);s.update(points(-100));
 assert.equal(s.finish(100).action,'none');s.begin(points(),0);s.update(points(-100));s.reset();assert.equal(s.finish(100).action,'none');
});
test('cycling rejects unavailable or invalid monitor indices',()=>{
 assert.equal(next(0,3,'left'),1);assert.equal(next(2,3,'left'),0);assert.equal(next(0,3,'right'),2);
 for(const [i,n,a] of [[0,1,'left'],[-1,3,'left'],[3,3,'left'],[NaN,3,'left'],[0,2.5,'left'],[0,3,'up']])assert.equal(next(i,n,a),-1);
});
const page=read('entry/src/main/ets/pages/RemotePage.ets');
const method=n=>{const i=page.indexOf('\n  '+n+'(');assert(i>=0,n);return page.slice(i,page.indexOf('\n  }',i)+4);};
test('pending taps are cancelled, not flushed when claiming a three-finger gesture',()=>{
 assert(method('handleThreeFingerGesture').includes('this.cancelActiveTouchGesture()'));
 assert(!method('handleThreeFingerGesture').includes('flushPendingTap'));
 assert(method('cancelActiveTouchGesture').includes('this.clearTapTimer()'));
 assert(method('cancelActiveTouchGesture').includes('this.displaySwipe.reset()'));
});
test('switch failure does not change selected display or report success',()=>{
 let response=-1,refreshed=0;const hints=[];
 const c={RustDeskNapi:{appendDiagnosticLog(){},switchDisplay:()=>response,getRemoteCursorPosition:()=>({sequence:8}),refreshVideo:()=>refreshed++},
   hilog:{error(){}},LOG_DOMAIN:0};
 vm.runInNewContext(ts.transpile('class Page{'+method('switchDisplay')+'}globalThis.Page=Page;'),c);
 const p=Object.assign(new c.Page(),{currentDisplay:0,displayCount:3,physicalMouseDeduplicator:{clear(){}},
   cancelActiveTouchGesture(){},stopEdgeAutoPan(){},clearKeyboardInputAnchor(){},bindSurfaceIfReady(){},
   showDisplaySwitchHint(display){hints.push(display);}});
 assert.equal(p.switchDisplay(1),false);assert.equal(p.currentDisplay,0);assert.equal(refreshed,0);
 assert.deepEqual(hints,[]);
 response=0;assert.equal(p.switchDisplay(1),true);assert.equal(p.currentDisplay,1);assert.equal(refreshed,1);
 assert.equal(p.switchDisplay(1),false);
 assert.deepEqual(hints,[1]);
});

test('only prepared image overlays slide; native viewport never leaves its stable position',()=>{
 const view=method('buildRemoteViewportWithQualityMonitor');
 assert.equal(view.split('this.buildRemoteViewport();').length-1,1);
 assert(!view.includes('.translate({ x: this.displaySwitchIncomingX })'));
 assert(view.indexOf('this.displaySwitchIncomingImage')<view.indexOf('if (this.displaySwitchImage)'));
 assert(view.includes('HitTestMode.Block'));
 const image=method('buildDisplaySwitchImage');
 assert(image.includes('event?.loadingStatus === 1'));
 assert(image.includes('.onError('));
 assert(image.includes('Color.Transparent'));
 assert(image.includes('outgoing ? this.displaySwitchOutgoingX : this.displaySwitchIncomingX'));
 for(const n of ['handleRemoteTouch','handleRemoteMouse','handleRemoteClickFallback','handleRemoteAxis','handleNativeMouseInput'])
  assert(method(n).includes('if (this.displaySwitchActive) return;'),n);
 assert(method('finishThreeFingerGesture').includes('this.requestDisplaySwitch(target, result.action)'));
 const animation=method('startDisplaySwitchTransition');
 for(const unsafe of ['zoomScale','offsetX','offsetY','surfaceEpoch','rebindSurface','switchDisplay(','sendMouse'])
  assert(!animation.includes(unsafe));
});

test('hint is non-interactive and its timer is cleared when leaving',()=>{
 const overlay=page.slice(page.indexOf('if (this.connectionStatus === ConnectionStatus.CONNECTED && this.displaySwitchHint.length'));
 assert(overlay.slice(0,800).includes('HitTestMode.None'));assert(overlay.slice(0,800).includes('TransitionEffect.OPACITY'));
 assert(method('aboutToDisappear').includes('this.clearDisplaySwitchHint()'));
});
test('screen menu toggle stays live and is included in responsive menu geometry',()=>{
 const widget=read('entry/src/main/ets/widget/RemoteGlassMenu.ets');
 assert(widget.includes("case 'displaySwipe': return this.state.displaySwipe"));
 assert(widget.includes("this.action('displaySwipe')"));
 assert(method('getGlassMenuState').includes('state.displaySwipe = this.displaySwipeEnabled'));
 assert(method('handleGlassMenuAction').includes('this.setDisplaySwipeEnabled(!this.displaySwipeEnabled)'));
 const c={exports:{}};vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/RemoteGlassMenu.ets')),c);
 for(const displays of [1,2,3,8])for(const [w,h] of [[240,160],[360,780],[1024,768],[1440,900]])for(const scale of [1,1.8,3.2]){
  const s=new c.exports.RemoteGlassMenuState();s.displayCount=displays;
  const m=c.exports.glassMenuMetrics(s,w,h,scale);
  assert(m.width<=w&&m.height<=h);assert.equal(m.contentHeight,m.headerHeight+m.screenHeight+8+m.rowHeight);
 }
});
console.log(`${checks} display-swipe scenario groups passed`);
