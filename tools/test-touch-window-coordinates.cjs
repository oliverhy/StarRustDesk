// Read-only, extracted production code; models ArkUI's inverse-transformed
// component coordinates as the canvas changes between physical touch samples.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const base = fs.readFileSync(path.join(__dirname, 'test-touch-center-follow.cjs'), 'utf8');
const harness = base.slice(0, base.indexOf("test('first movement"));
const { make, method, context, near, setNow } = new Function('require', '__dirname', harness +
  '\nreturn {make, method, context, near, setNow: value => {now=value;}};')(require, __dirname);
Object.assign(context, { VIEWPORT_PAN_SPEED: 1.5, TOUCH_MOVE_THRESHOLD: 8,
  PINCH_DISTANCE_THRESHOLD: 10, MULTI_TOUCH_MOVE_THRESHOLD: 8, INPUT_MODE_TOUCH: 1,
  SourceType: { Mouse: 99 }, SourceTool: { MOUSE: 99, TOUCHPAD: 98 } });
const methods = ['handleViewportPan', 'handleDirectTouch', 'handleMultiTouch', 'handleRemoteTouch',
  'applyPinchTransform', 'clampHorizontalOffset', 'clampVerticalOffset', 'clampOffsetToLimit'];
vm.runInContext(ts.transpile('class Extra {' + methods.map(method).join('\n') +
  '} globalThis.Extra=Extra;'), context);
function page(overrides={}) {
  const p = make(overrides);
  for (const name of methods) p[name] = context.Extra.prototype[name];
  Object.assign(p, { clearTapTimer(){}, discardViewportPanFrame(){}, updateSystemPointerVisibility(){},
    keepRemoteKeyboardForPointer(){},
    finishViewportPan(){this.viewportPanActive=false;},
    queueViewportPanFrame(x,y){this.offsetX=this.clampHorizontalOffset(this.offsetX+x,this.zoomScale);
      this.offsetY=this.clampVerticalOffset(this.offsetY+y,this.zoomScale);},
    syncVirtualMouseToCurrentPointer(){}, sendTouchScroll(x,y){this.scroll=[x,y];} });
  return p;
}
function point(p, wx, wy=200, id=0) {
  return {id,windowX:wx,windowY:wy,
    x:200+(wx-200-p.offsetX)/p.zoomScale-(p.inputMode===1?p.getDisplayLeft():0),
    y:200+(wy-200-p.offsetY)/p.zoomScale-(p.inputMode===1?p.getDisplayTop():0)};
}
function send(p, handler, type, coords, time=1000) {
  setNow(time);
  const touches=coords.map(([x,y],i)=>point(p,x,y,i));
  p[handler]({type,touches,changedTouches:touches});
}
let passed=0;
function test(name,fn){fn();passed++;console.log('PASS '+name);}
test('same physical stroke gives same center-follow distance at 1.5x/2x/4x/5x',()=>{
  for(const zoomScale of [1.5,2,4,5]){
    const p=page({zoomScale});
    send(p,'handleTouchpadTouch',0,[[200,200]]);
    for(let i=1;i<=4;i++) send(p,'handleTouchpadTouch',1,[[200+i*10,200]],1000+i*20);
    near(p.offsetX,-50);
    near(p.remotePointToVisual(p.lastAbsX,p.lastAbsY).x,200);
    const before=p.offsetX;
    send(p,'handleTouchpadTouch',1,[[240,200]],1120);
    near(p.offsetX,before,'stationary finger cannot feed canvas motion back into input');
  }
});
test('manual canvas pan retains 1.5 gain regardless of zoom and previous translation',()=>{
  for(const zoomScale of [1.5,2,4,5]){
    const p=page({zoomScale,offsetX:-30,isPanMode:true});
    send(p,'handleViewportPan',0,[[200,200]]);
    for(let i=1;i<=4;i++) send(p,'handleViewportPan',1,[[200+i*10,200]],1000+i*20);
    near(p.offsetX,30);
    send(p,'handleViewportPan',1,[[240,200]],1120);near(p.offsetX,30);
    send(p,'handleViewportPan',1,[[220,200]],1140);near(p.offsetX,0);
  }
});
test('touchpad drag threshold stays 18 window vp after repeated enlargement',()=>{
  for(const zoomScale of [1.5,2,4,5]){
    const p=page({zoomScale});p.isSecondTapNear=()=>true;
    send(p,'handleTouchpadTouch',0,[[200,200]]);
    send(p,'handleTouchpadTouch',1,[[217,200]],1020);assert(!p.leftButtonHeld);
    send(p,'handleTouchpadTouch',1,[[218,200]],1040);assert(p.leftButtonHeld);
  }
});
test('non-follow and relative pointer mapping applies zoom exactly once',()=>{
  for(const relativeMouseEnabled of [false,true]){
    const p=page({zoomScale:4,edgeAutoPanEnabled:false,relativeMouseEnabled});
    p.updatePointerFromDelta=(x,y)=>{near(x,10);near(y,0);return{x:500,y:500};};
    send(p,'handleTouchpadTouch',0,[[200,200]]);
    send(p,'handleTouchpadTouch',1,[[240,200]],1020);
  }
});
test('direct touch retains component hit coordinates but uses fixed window drag threshold',()=>{
  const p=page({zoomScale:4,inputMode:1});let hit;
  p.updatePointerFromLocal=(x,y)=>{hit={x,y};return{x:500,y:500};};
  send(p,'handleDirectTouch',0,[[200,200]]);
  send(p,'handleDirectTouch',1,[[209,200]],1020);
  assert(p.touchMoved);assert(p.leftButtonHeld);near(hit.x,202.25);
});
test('continuous pinch reaches 2x then 4x without oscillation; translated centroid stays anchored',()=>{
  const p=page({zoomScale:1,touchSequenceMaxFingers:2});
  send(p,'handleMultiTouch',0,[[150,200],[250,200]]);
  send(p,'handleMultiTouch',1,[[100,200],[300,200]],1020);near(p.zoomScale,2);
  send(p,'handleMultiTouch',1,[[60,200],[360,200]],1040);near(p.zoomScale,3);near(p.offsetX,10);
  send(p,'handleMultiTouch',1,[[10,200],[410,200]],1060);near(p.zoomScale,4);near(p.offsetX,10);
  p.multiTouchActive=false;
  send(p,'handleMultiTouch',0,[[160,200],[260,200]],1100);
  send(p,'handleMultiTouch',1,[[150,200],[275,200]],1120);near(p.zoomScale,5);near(p.offsetX,12.5);
});
test('scroll distance is independent of zoom and never switches to pinch from canvas movement',()=>{
  for(const zoomScale of [1,2,4,5]){
    const p=page({zoomScale,touchSequenceMaxFingers:2});
    send(p,'handleMultiTouch',0,[[150,200],[250,200]]);
    send(p,'handleMultiTouch',1,[[150,230],[250,230]],1020);
    assert.equal(p.multiTouchGesture,1);near(p.scroll[1],30);
  }
});
test('new Down immediately after pinch is delivered, residual fingers remain suppressed',()=>{
  const p=page({isPanMode:true,lastPinchEndedAt:1000,ignoreTouchUntilNextDown:true,touchSequenceDraining:true,
    touchSequenceMaxFingers:2,multiTouchActive:false,threeFingerGestureActive:false});
  send(p,'handleRemoteTouch',1,[[200,200]],1001);assert(!p.viewportPanActive);
  send(p,'handleRemoteTouch',0,[[200,200]],1002);assert(p.viewportPanActive);
  send(p,'handleRemoteTouch',1,[[220,200]],1003);near(p.offsetX,30);
});
test('fallback reconstructs viewport distances when window fields are absent',()=>{
  const p=page({zoomScale:4,offsetX:70,offsetY:-20});
  const t=point(p,240,180);delete t.windowX;delete t.windowY;
  const result=p.touchGesturePoint(t);near(result.x,240);near(result.y,180);
});
test('IME translation is included exactly once in fallback window coordinates',()=>{
  const p=page({zoomScale:4,offsetX:70,offsetY:-20,showKeyboardPanel:true});
  p.getKeyboardCanvasShiftY=()=>-150;
  const t=point(p,240,330);delete t.windowX;delete t.windowY;
  const result=p.touchGesturePoint(t);near(result.x,240);near(result.y,180);
  t.windowX=240;t.windowY=180;
  near(p.touchGesturePoint(t).y,180);
});
console.log(`touch-window coordinates: ${passed} scenario groups passed`);
