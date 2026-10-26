'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source=fs.readFileSync(path.resolve(__dirname,'../entry/src/main/ets/pages/RemotePage.ets'),'utf8');
const method=name=>{const m=new RegExp('\\n  (?:async )?'+name+'\\(').exec(source);assert(m,name);
 return source.slice(m.index,source.indexOf('\n  }',m.index)+4);};
const models=source.slice(source.indexOf('class DisplaySwitchImage {'),source.indexOf('\ninterface KeyboardInputAnchor'));
const paint=source.slice(source.indexOf('class DisplaySwitchPaintCallback '),source.indexOf('\ninterface UploadQueueItem'));
const methods=['clearDisplaySwitchTransition','canAnimateDisplaySwitch','traceDisplaySwitch','releaseDisplaySwitchImage',
 'captureDisplaySwitchImage','requestDisplaySwitch','waitDisplaySwitchFrame','startDisplaySwitchTransition',
 'validateDisplaySwitchRequest','setDisplaySwitchDeadline','fallbackDisplaySwitch','afterDisplaySwitchPaint',
 'matchesDisplaySwitchImage','onDisplaySwitchImageReady','onDisplaySwitchImageError','commitDisplaySwitchTransition','prepareIncomingDisplaySwitchImage'];
const flush=async()=>{for(let i=0;i<5;i++)await Promise.resolve();};
function harness() {
 let now=0,id=0,rendered=10,received=20,generation=1,nativeResult=true,background=false,captureResolve,captureReject;
 let animateFailure=false,postFailure=false,frameWidth=1920,frameHeight=1080;
 const timers=new Map(),calls=[],logs=[],systemLogs=[],animations=[],released=[],frames=[];
 let diagnostics=true;
 const c={Date:{now:()=>now},FrameCallback:function(){},ConnectionStatus:{CONNECTED:2},Curve:{EaseInOut:1},
  LOG_DOMAIN:0,hilog:{info:(_domain,_tag,_format,message)=>systemLogs.push(message)},
  setTimeout:(fn,ms)=>{timers.set(++id,{fn,at:now+ms});return id;},clearTimeout:id=>timers.delete(id),
  image:{createPixelMapFromSurface:()=>new Promise((r,j)=>{calls.push('capture');captureResolve=r;captureReject=j;})},
  RemoteSessionBackgroundTask:{isAppBackground:()=>background},
  RustDeskNapi:{appendDiagnosticLog:(tag,text)=>{if(diagnostics)logs.push(text);},getOption:()=>diagnostics?'1':'0',
   getVideoFrame:()=>({hasFrame:true,width:frameWidth,height:frameHeight,totalFrames:received,renderedFrames:rendered,generation})}};
 vm.runInNewContext(ts.transpile(paint+'\n'+models+'\nclass Page{'+methods.map(method).join('\n')+'}globalThis.Page=Page;'),c);
 const p=Object.assign(new c.Page(),{remotePageVisible:true,hasVideo:true,fileOnly:false,pipSurfaceOwned:false,
  connectionStatus:2,currentDisplay:0,displayCount:3,componentWidth:800,componentHeight:600,
  remoteWidth:1920,remoteHeight:1080,zoomScale:2,offsetX:53,offsetY:-29,surfaceRebindTimer:-1,
  displaySwitchAnimationEpoch:0,displaySwitchTimer:-1,displaySwitchCaptureBusy:false,displaySwitchActive:false,
  displaySwitchOutgoingX:0,displaySwitchIncomingX:0,displaySwitchImageReady:false,readCurrentSurfaceId:()=> '123',
  getDisplayWidth:()=>800,getDisplayHeight:()=>450,
  cancelActiveTouchGesture(){calls.push('cancel');},releaseVirtualMouseButtons(){calls.push('releaseMouse');},stopEdgeAutoPan(){},
  showFileToast:()=>calls.push('toast'),
  switchDisplay(display){calls.push('switch:'+display);p.touchSequenceDraining=false;p.ignoreTouchUntilNextDown=false;
   if(nativeResult)p.currentDisplay=display;return nativeResult;},
  getUIContext:()=>({
   postFrameCallback:cb=>{if(postFailure)throw Error('disposed');frames.push(cb);},
   animateTo:(options,change)=>{if(animateFailure)throw Error('disposed');animations.push(options);change();}})});
 async function tick(ms) {
  const end=now+ms;
  for(;;){let selected;
   for(const [id,t] of timers)if(t.at<=end&&(!selected||t.at<selected[1].at))selected=[id,t];
   if(!selected)break;now=selected[1].at;timers.delete(selected[0]);selected[1].fn();await flush();
  }now=end;await flush();
 }
 const pixel=label=>({release:()=>{released.push(label);return Promise.resolve();}});
 // Real video workloads may have no idle time at all. Vsync/frame callbacks
 // must be sufficient; always delivering onIdle masked an animation regression.
 function present(){const pending=frames.splice(0);for(const cb of pending){cb.onFrame(now*1000000);cb.onFrame(now*1000000);}}
 async function oldReady(target=1,direction='left') {
  const pending=p.requestDisplaySwitch(target,direction);captureResolve(pixel('old'));await pending;
  p.onDisplaySwitchImageReady(p.displaySwitchImage,true);present();present();await flush();
 }
 async function newReady() {
  received++;rendered++;await tick(40);
  captureResolve(pixel('new'));await flush();
  p.onDisplaySwitchImageReady(p.displaySwitchIncomingImage,false);present();present();await flush();
 }
 return {p,calls,logs,systemLogs,animations,released,tick,pixel,present,oldReady,newReady,frames,
  disableDiagnostics:()=>diagnostics=false,
  resolve:label=>captureResolve(pixel(label)),reject:()=>captureReject(Error('unsupported')),
  render:()=>rendered++,receive:()=>received++,generation:()=>generation++,fail:()=>nativeResult=false,background:()=>background=true,
  animateFailure:()=>animateFailure=true,postFailure:()=>postFailure=true,frameSize:(w,h)=>{frameWidth=w;frameHeight=h;}};
}
let checks=0;
async function test(name,fn){await fn();checks++;console.log('PASS '+name);}
(async()=>{
 await test('ArkUI-wrapped Image callbacks match by snapshot token, not JavaScript identity',async()=>{
  const h=harness(),pending=h.p.requestDisplaySwitch(1);h.resolve('old');await pending;
  const old=new Proxy(h.p.displaySwitchImage,{});
  assert.notEqual(old,h.p.displaySwitchImage);
  h.p.onDisplaySwitchImageReady(old,true);h.present();h.present();await flush();
  assert.equal(h.p.currentDisplay,1);
  h.receive();h.render();await h.tick(40);h.resolve('new');await flush();
  h.p.onDisplaySwitchImageReady(new Proxy(h.p.displaySwitchIncomingImage,{}),false);
  h.present();h.present();assert.equal(h.animations.length,1);
  h.animations[0].onFinish();h.present();h.present();assert(!h.p.displaySwitchActive);
  assert(!h.logs.some(x=>x.startsWith('skip ')));
 });
 await test('stale or wrong-role wrapped image callbacks cannot advance or cancel the next transition',async()=>{
  const h=harness();let pending=h.p.requestDisplaySwitch(1);h.resolve('stale');await pending;
  const stale=new Proxy(h.p.displaySwitchImage,{});h.p.clearDisplaySwitchTransition();
  pending=h.p.requestDisplaySwitch(1);h.resolve('current');await pending;
  const current=new Proxy(h.p.displaySwitchImage,{});
  h.p.onDisplaySwitchImageReady(stale,true);h.p.onDisplaySwitchImageError(stale,true);
  h.p.onDisplaySwitchImageReady(current,false);h.p.onDisplaySwitchImageError(current,false);
  assert.equal(h.p.displaySwitchRequest.phase,'load_old');assert(h.p.displaySwitchActive);
  h.p.onDisplaySwitchImageError(current,true);
  assert(!h.p.displaySwitchActive);assert.deepEqual(h.calls.filter(x=>x.startsWith('switch:')),['switch:1']);
 });
 await test('continuous video without ANY idle callback still starts and completes exactly one animation',async()=>{
  const h=harness();await h.oldReady();await h.newReady();
  assert.equal(h.animations.length,1);h.animations[0].onFinish();h.present();h.present();
  assert(!h.p.displaySwitchActive);assert(h.logs.some(x=>x==='end target=1'));
  assert(!h.logs.some(x=>x.startsWith('skip ')));
 });
 await test('transition diagnostics are inspectable live and honor the existing opt-in switch',async()=>{
  const h=harness();h.p.traceDisplaySwitch('test_stage');
  assert.deepEqual(h.logs,['test_stage']);assert.deepEqual(h.systemLogs,['test_stage']);
  h.disableDiagnostics();h.p.traceDisplaySwitch('disabled_stage');
  assert.deepEqual(h.logs,['test_stage']);assert.deepEqual(h.systemLogs,['test_stage']);
 });
 await test('slow Image decode keeps live canvas in place: no switch or offset until old cover is painted',async()=>{
  const h=harness(),pending=h.p.requestDisplaySwitch(1,'left');h.resolve('old');await pending;
  await h.tick(250);assert.equal(h.p.currentDisplay,0);assert.equal(h.p.displaySwitchIncomingX,0);
  assert(!h.p.displaySwitchImageReady);assert(!h.calls.includes('switch:1'));assert.equal(h.animations.length,0);
  h.p.onDisplaySwitchImageReady(h.p.displaySwitchImage,true);
  assert(h.p.displaySwitchImageReady);assert(!h.calls.includes('switch:1'));
  h.present();assert(!h.calls.includes('switch:1'));h.present();assert(h.calls.includes('switch:1'));
  assert.equal(h.p.displaySwitchIncomingX,0);assert.equal(h.p.displaySwitchOutgoingX,0);
  assert(h.p.touchSequenceDraining&&h.p.ignoreTouchUntilNextDown);
 });
 await test('both snapshots must decode and paint before simultaneous slide, then final handoff waits for paint',async()=>{
  const h=harness();await h.oldReady();h.receive();h.render();await h.tick(40);
  assert.equal(h.animations.length,0);assert.equal(h.p.displaySwitchOutgoingX,0);
  h.resolve('new');await flush();await h.tick(200);
  assert.equal(h.animations.length,0);assert.equal(h.p.displaySwitchIncomingX,0);
  assert.equal(h.p.displaySwitchRequest.phase,'load_new');
  h.p.onDisplaySwitchImageReady(h.p.displaySwitchIncomingImage,false);
  assert.equal(h.p.displaySwitchIncomingX,800);assert.equal(h.p.displaySwitchOutgoingX,0);
  h.present();assert.equal(h.animations.length,0);h.present();
  assert.equal(h.animations.length,1);assert.equal(h.p.displaySwitchOutgoingX,-800);assert.equal(h.p.displaySwitchIncomingX,0);
  assert.equal(h.animations[0].duration,300);h.animations[0].onFinish();
  assert(h.p.displaySwitchIncomingImage);h.present();assert(h.p.displaySwitchIncomingImage);h.present();
  assert(!h.p.displaySwitchActive);await h.tick(64);assert.deepEqual(h.released.sort(),['new','old']);
  assert.deepEqual([h.p.zoomScale,h.p.offsetX,h.p.offsetY],[2,53,-29]);
 });
 await test('first-to-last and last-to-first retain gesture direction; menu direction follows index',async()=>{
  for(const [from,to,direction,end] of [[2,0,'left',-800],[0,2,'right',800],[2,0,'',800],[0,2,'',-800]]){
   const h=harness();h.p.currentDisplay=from;await h.oldReady(to,direction);await h.newReady();
   assert.equal(h.p.displaySwitchOutgoingX,end);assert.equal(h.p.displaySwitchIncomingX,0);
  }
 });
 await test('receive progress and presentation progress are both required, without an arbitrary 120ms wait',async()=>{
  const h=harness();await h.oldReady();h.render();await h.tick(40);
  assert.equal(h.calls.filter(x=>x==='capture').length,1);
  h.receive();await h.tick(40);assert.equal(h.calls.filter(x=>x==='capture').length,2);
  assert(h.logs.includes('video_ready target=1 wait_ms=80'));
 });
 await test('different resolution/rebind waits for settled layout and a subsequent presented frame',async()=>{
  const h=harness();await h.oldReady();h.frameSize(1600,900);h.receive();h.render();await h.tick(40);
  assert.equal(h.calls.filter(x=>x==='capture').length,1);
  h.p.remoteWidth=1600;h.p.remoteHeight=900;h.p.surfaceRebindTimer=9;h.render();await h.tick(40);
  h.p.surfaceRebindTimer=-1;await h.tick(40);assert.equal(h.calls.filter(x=>x==='capture').length,1);
  h.render();await h.tick(40);assert.equal(h.calls.filter(x=>x==='capture').length,2);
 });
 await test('capture failure, timeout and oversized frames switch directly without a delayed animation',async()=>{
  for(const mode of ['reject','timeout','oversize']){
   const h=harness();if(mode==='oversize')h.p.remoteWidth=100000;
   const pending=h.p.requestDisplaySwitch(1);
   if(mode==='reject')h.reject();if(mode==='timeout')await h.tick(160);await pending;
   assert(h.calls.includes('switch:1'));assert(!h.p.displaySwitchActive);assert.equal(h.animations.length,0);
   if(mode==='timeout'){h.resolve('late');await flush();assert.deepEqual(h.released,['late']);}
  }
 });
 await test('old Image decode error or missing callback falls back once, never a late slide',async()=>{
  for(const mode of ['error','timeout','frame_timeout']){
   const h=harness(),pending=h.p.requestDisplaySwitch(1);h.resolve('old');await pending;
   const old=h.p.displaySwitchImage;
   if(mode==='error')h.p.onDisplaySwitchImageError(old,true);
   else {if(mode==='frame_timeout')h.p.onDisplaySwitchImageReady(old,true);await h.tick(600);}
   h.p.onDisplaySwitchImageReady(old,true);h.present();h.present();
   assert.deepEqual(h.calls.filter(x=>x.startsWith('switch:')),['switch:1']);
   assert(!h.p.displaySwitchActive);assert.equal(h.animations.length,0);
  }
 });
 await test('new capture or Image error cannot resend the display request or leave stale overlay',async()=>{
  for(const mode of ['capture','error','timeout']){
   const h=harness();await h.oldReady();h.receive();h.render();await h.tick(40);
   if(mode==='capture'){h.reject();await flush();}
   else {h.resolve('new');await flush();if(mode==='error')h.p.onDisplaySwitchImageError(h.p.displaySwitchIncomingImage,false);
    else await h.tick(600);}
   assert.deepEqual(h.calls.filter(x=>x.startsWith('switch:')),['switch:1']);
   assert(!h.p.displaySwitchActive);await h.tick(64);assert(h.released.includes('old'));
  }
 });
 await test('repeat requests and duplicate onComplete cannot enqueue switches or animations',async()=>{
  const h=harness();await h.oldReady();await h.p.requestDisplaySwitch(2);
  h.p.onDisplaySwitchImageReady(h.p.displaySwitchImage,true);h.present();h.present();
  await h.newReady();h.p.onDisplaySwitchImageReady(h.p.displaySwitchIncomingImage,false);h.present();h.present();
  assert.deepEqual(h.calls.filter(x=>x.startsWith('switch:')),['switch:1']);assert.equal(h.animations.length,1);
 });
 await test('late capture after leaving is released and never sends a switch',async()=>{
  for(const incoming of [false,true]){
   const h=harness();let pending;
   if(incoming){await h.oldReady();h.receive();h.render();await h.tick(40);}
   else pending=h.p.requestDisplaySwitch(1);
   h.p.clearDisplaySwitchTransition();h.p.remotePageVisible=false;h.resolve('late');await pending;await flush();
   assert(h.released.includes('late'));assert.equal(h.calls.filter(x=>x.startsWith('switch:')).length,incoming?1:0);
  }
 });
 await test('background, PiP, resize and session generation cancel while waiting',async()=>{
  for(const mode of ['background','pip','resize','generation']){
   const h=harness();await h.oldReady();
   if(mode==='background')h.background();if(mode==='pip')h.p.pipSurfaceOwned=true;
   if(mode==='resize')h.p.componentWidth=600;if(mode==='generation')h.generation();
   await h.tick(40);assert(!h.p.displaySwitchActive);assert.equal(h.p.displaySwitchIncomingX,0);
   await h.tick(64);assert.deepEqual(h.released,['old']);
  }
 });
 await test('slow peer has bounded fallback; old cover remains visible throughout waiting',async()=>{
  const h=harness();await h.oldReady();await h.tick(1160);
  assert(h.p.displaySwitchImageReady&&h.p.displaySwitchImage);assert.equal(h.p.displaySwitchOutgoingX,0);
  await h.tick(40);assert(!h.p.displaySwitchActive);assert.equal(h.animations.length,0);
  assert(h.logs.some(x=>x.includes('frame_wait_timeout')));
 });
 await test('native rejection preserves selection and releases only after detaching snapshot',async()=>{
  const h=harness();h.fail();await h.oldReady();assert.equal(h.p.currentDisplay,0);assert(h.calls.includes('toast'));
  assert(!h.p.displaySwitchActive);await h.tick(64);assert.deepEqual(h.released,['old']);
 });
 await test('stale frame-end and animation callbacks cannot clear the next request',async()=>{
  const h=harness();await h.oldReady();await h.newReady();const old=h.animations[0];
  h.p.clearDisplaySwitchTransition();const pending=h.p.requestDisplaySwitch(2);h.resolve('next');await pending;
  old.onFinish();h.present();h.present();assert(h.p.displaySwitchActive);assert.equal(h.p.displaySwitchRequest.target,2);
 });
 await test('missing completion, compositor failure and frame callback failure are bounded',async()=>{
  for(const mode of ['animate','missing','frame']){
   const h=harness();await h.oldReady();
   if(mode==='animate')h.animateFailure();if(mode==='frame')h.postFailure();
   await h.newReady();if(mode==='missing')await h.tick(500);
   assert(!h.p.displaySwitchActive);await h.tick(64);assert.deepEqual(h.released.sort(),['new','old']);
  }
 });
 await test('same display, invalid target, disconnected state and PiP never capture',async()=>{
  for(const patch of [{currentDisplay:1},{displayCount:1},{connectionStatus:0},{pipSurfaceOwned:true},{remotePageVisible:false}]){
   const h=harness();Object.assign(h.p,patch);await h.p.requestDisplaySwitch(1);assert.equal(h.calls.length,0);
  }
  const h=harness();for(const target of [-1,NaN,1.2,3])await h.p.requestDisplaySwitch(target);assert.equal(h.calls.length,0);
 });
 console.log(checks+' display-slide readiness/lifecycle scenario groups passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
