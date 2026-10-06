'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/RemotePage.ets'),'utf8').replace(/\r\n/g,'\n');
const method=name=>{const start=source.indexOf('\n  '+name+'(');assert(start>=0,name);return source.slice(start,source.indexOf('\n  }',start)+4);};
function harness() {
  const frames=[],animations=[],logs=[];
  const sdk={failFrame:false,failAnimation:false};
  const context={exports:{},Curve:{EaseInOut:'symmetric'},
    ViewportFrameCallback:class { constructor(apply){this.apply=apply;} },
    RustDeskNapi:{appendDiagnosticLog:(...args)=>logs.push(args)},
  };
  vm.runInNewContext(ts.transpile('class Page {'+['setControlMenu','animateControlMenu','resetControlMenuAnimation','toggleControlMenu'].map(method).join('\n')+'} exports.Page=Page;'),context);
  const page=Object.assign(new context.exports.Page(), {
    controlMenu:'',controlMenuProgress:0,controlMenuClosing:false,controlMenuAnimationEpoch:0,
    remotePageVisible:true,isLeavingAfterDisconnect:false,
    cancelPcToolbarAutoCollapse(){},handleNonRemoteHover(){},releaseVirtualMouseButtons(){},cancelActiveTouchGesture(){},
    getUIContext:()=>({
      postFrameCallback:callback=>{if(sdk.failFrame) throw Error('frame unavailable');frames.push(callback);},
      animateTo:(options,apply)=>{if(sdk.failAnimation) throw Error('animation unavailable');apply();animations.push(options);},
    }),
  });
  const frame=()=>{assert(frames.length>0);frames.shift().apply();};
  const finish=index=>animations[index].onFinish();
  return {page,frames,animations,sdk,frame,finish,logs};
}
let cases=0;
{
  const h=harness(),p=h.page;
  p.setControlMenu('view');assert.equal(p.controlMenu,'view');assert.equal(p.controlMenuProgress,0);
  h.frame();assert.equal(p.controlMenuProgress,1);assert.equal(h.animations[0].duration,160);
  p.setControlMenu('');assert.equal(p.controlMenu,'view','exit keeps category/scrim mounted');
  assert.equal(p.controlMenuProgress,0);assert.equal(p.controlMenuClosing,true);
  assert.equal(h.animations[1].duration,h.animations[0].duration);
  assert.equal(h.animations[1].curve,h.animations[0].curve);
  const epoch=p.controlMenuAnimationEpoch;p.setControlMenu('');assert.equal(p.controlMenuAnimationEpoch,epoch,'repeat close does not cancel its finish');
  h.finish(1);assert.equal(p.controlMenu,'');assert.equal(p.controlMenuClosing,false);
  cases++;
}
{
  const h=harness(),p=h.page;
  p.setControlMenu('view');p.setControlMenu('');h.frame();
  assert.equal(p.controlMenu,'');assert.equal(p.controlMenuProgress,0);assert.equal(h.animations.length,0,'cancel before first frame cannot reopen');
  cases++;
}
{
  const h=harness(),p=h.page;
  p.setControlMenu('view');h.frame();p.setControlMenu('');p.setControlMenu('more');
  h.finish(1);assert.equal(p.controlMenu,'more','stale exit cannot remove the reopened/switched menu');
  assert.equal(p.controlMenuProgress,1);assert.equal(p.controlMenuClosing,false);
  h.finish(0);h.finish(2);assert.equal(p.controlMenu,'more');cases++;
}
for(const atFrame of [false,true]) {
  const h=harness(),p=h.page;p.setControlMenu('input');
  if(atFrame) {h.frame();p.setControlMenu('');}
  p.remotePageVisible=false;p.resetControlMenuAnimation();
  while(h.frames.length) h.frame();for(let index=0;index<h.animations.length;index++) h.finish(index);
  p.setControlMenu('more');assert.equal(p.controlMenu,'');assert.equal(p.controlMenuProgress,0);cases++;
}
for(const fail of ['failFrame','failAnimation']) {
  const h=harness(),p=h.page;h.sdk[fail]=true;p.setControlMenu('more');
  if(h.frames.length) h.frame();assert.equal(p.controlMenuProgress,1,'SDK error must not leave an invisible modal blocker');
  p.setControlMenu('');
  if(fail==='failFrame') {
    assert.equal(p.controlMenuClosing,true,'frame fallback can still animate its exit');
    h.finish(h.animations.length-1);
  }
  assert.equal(p.controlMenu,'');assert.equal(p.controlMenuClosing,false);cases++;
}
{
  const h=harness();h.page.isLeavingAfterDisconnect=true;h.page.setControlMenu('view');assert.equal(h.frames.length,0);cases++;
}
const overlay=method('buildControlMenuOverlay');
assert.equal((overlay.match(/\.opacity\(this\.controlMenuProgress\)/g)||[]).length,2,'scrim/card share animation progress');
assert(overlay.includes('0.97 + 0.03 * this.controlMenuProgress'));
assert(overlay.includes('.enabled(!this.controlMenuClosing)'),'fading actions cannot be executed twice');
assert(!overlay.includes('.transition('),'no second/default transition competes with explicit animation');
assert(method('aboutToDisappear').includes('this.resetControlMenuAnimation()'));
assert(method('disconnectSession').includes('this.resetControlMenuAnimation()'));
for(const name of ['handleRemoteMouse','handleNativeMouseInput','handleRemoteTouch','handleRemoteKey']) {
  assert(method(name).includes('this.controlMenu'),'remote input remains blocked during exit');
}
console.log(`PASS control-menu animation: ${cases} lifecycle/race/fallback cases, symmetric timing, retained scrim and local-input isolation`);
