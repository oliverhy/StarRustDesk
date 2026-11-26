'use strict';
// Exercise the actual ArkTS handlers and geometry without injecting OS input.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root=path.resolve(__dirname,'../../entry/src/main/ets');
const read=f=>fs.readFileSync(path.join(root,f+'.ets'),'utf8').replace(/\r\n/g,'\n');
const ctx=vm.createContext({exports:{},console,hilog:{info(){}}});
function run(s){vm.runInContext(ts.transpileModule(s,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,ctx)}
for(const f of ['model/SunshineControlMenu','model/RemoteGlassMenu','model/RemoteToolbarPlacement']){
  // The geometry model's only import is erased by TS or provided below.
  run(read(f).replace(/^import .*;$/gm,''));Object.assign(ctx,ctx.exports);
}
const src=read('widget/SunshineRemoteControls');
function method(name){
  const start=src.indexOf('\n  private '+name+'(');assert(start>=0,name);
  const first=src.indexOf('\n',start+1),one=src.slice(start+1,first);
  return one.trimEnd().endsWith('}')?one:src.slice(start+1,src.indexOf('\n  }',first)+4);
}
run('class Controls {'+['sharedAction','command','tapKey','cancelTouch','balance','mode','barW','barH','barX','barY',
  'dragStart','dragUpdate','dragEnd','cancelDrag','handleTap','recordAnchor','activeCategory','menuPlacement',
  'glassState','moveKey','submitIme'].map(method).join('\n')+'} exports.Controls=Controls;');
let tests=0;
function test(name,fn){fn();console.log('PASS '+name);tests++}
function controls(){
  const input=[],state={viewportW:390,viewportH:760,fontScale:1,edge:'',collapsed:true,xFraction:.6,yFraction:.4,
    originX:10,originY:20,anchors:[],inputState:2,modifiers:[],pressed:false,zoomPercent:100,menu:'keyboard',
    gridOrder:ctx.streamKeyGrid([]),closeOnSubmit:true,localPan:false,
    remember(){},getUIContext(){return {getPromptAction(){return {showToast(){}}}}},tr(s){return s},
    metrics(){return {width:240,height:200}},onInput(...args){input.push(args.slice(0,3));return true},
    onScale(z){this.zoomPercent=z},onOrientation(m){this.orientation=m},onFullscreen(){this.full=!this.full}};
  return Object.assign(new ctx.exports.Controls(),state,{input});
}
test('permission gate: no keyboard or release event in a read-only stream',()=>{
  const c=controls();c.inputState=0;c.sharedAction('key-Enter');c.sharedAction('release');
  assert.equal(c.menu,'input');assert.equal(c.input.length,0);
});
test('function keys and approved shortcuts have bounded Windows mappings',()=>{
  for(let k=1;k<=12;k++)assert.equal(ctx.streamKeyCode('F'+k),111+k);
  for(const key of ['F13','WA','Ctrl+Alt+Del','', 'key-Enter'])assert.equal(ctx.streamKeyCode(key),0);
  const c=controls();c.sharedAction('key-F12');assert.deepEqual(c.input,[[5,1,123],[5,0,123]]);
});
test('shortcut preserves a user-held Shift; failed key-up releases everything',()=>{
  const c=controls();c.modifiers=[16];c.sharedAction('key-Ctrl+Shift+Esc');
  assert.deepEqual(c.input,[[5,1,17],[5,1,27],[5,0,27],[5,0,17]]);
  c.input=[];c.onInput=(k,f,a)=>{c.input.push([k,f,a]);return !(k===5&&f===0)};
  c.sharedAction('key-Enter');assert.equal(c.input.at(-1)[0],7);assert.equal(c.modifiers.length,0);
});
test('view and orientation are local, restore exact 100 percent, no remote packets',()=>{
  const c=controls();for(let i=0;i<22;i++)c.sharedAction('zoomIn');assert.equal(c.zoomPercent,500);
  for(let i=0;i<22;i++)c.sharedAction('zoomOut');assert.equal(c.zoomPercent,50);
  c.sharedAction('zoomReset');c.sharedAction('orientation-landscape');c.sharedAction('fullscreen');
  assert.equal(c.zoomPercent,100);assert.equal(c.orientation,'landscape');assert(c.full);assert.equal(c.input.length,0);
});
test('pointer follows actual button, accounts for window origin, flips below at top',()=>{
  const c=controls();
  for(const pair of [[60,'keyboard'],[204,'view']]){
    c.recordAnchor(pair[1],{globalPosition:{x:pair[0]+10,y:620},width:42,height:44});
    c.menu=pair[1];const p=c.menuPlacement();assert.equal(p.x+p.arrowX,pair[0]+21);assert(p.arrowVisible&&!p.arrowAbove);
  }
  c.recordAnchor('view',{globalPosition:{x:214,y:24},width:42,height:44});
  const p=c.menuPlacement();assert(p.arrowVisible&&p.arrowAbove);assert(p.y>=48);
});
test('menu and tab stay within the new client area after rotation and large type',()=>{
  const c=controls();
  for(const [w,h] of [[320,680],[680,320],[220,270],[1024,720]]){
    for(const scale of [1,1.5,2]){
      c.viewportW=w;c.viewportH=h;c.fontScale=scale;c.menu='view';
      const s=new ctx.RemoteGlassMenuState();s.category='view';s.items=['zoomIn','zoomOut','fullscreen','orientation'];
      const metrics=ctx.glassMenuMetrics(s,w,h,scale);
      c.metrics=()=>metrics;
      for(const x of [8,Math.floor(w/2)-20,w-46]){
        c.recordAnchor('view',{globalPosition:{x:x+c.originX,y:h-72+c.originY},width:38,height:48});
        const at=c.menuPlacement();
        assert(at.x>=0&&at.x+metrics.width<=w&&at.y>=0&&at.y+metrics.height<=h);
        if(at.arrowVisible)assert(at.arrowX>=0&&at.arrowX<=metrics.width);
      }
      c.edge='right';assert(c.barW()<=16&&c.barX()+c.barW()<=w);
    }
  }
});
test('only collapsed drag docks, cancel restores; tapping undocks before expanding',()=>{
  const c=controls();c.inputState=0;c.dragStart();c.dragUpdate(1000,20);c.cancelDrag();assert.equal(c.xFraction,.6);assert.equal(c.edge,'');
  c.dragStart();c.dragUpdate(1000,20);c.dragEnd();assert.equal(c.edge,'right');assert.equal(c.barW(),16);assert.equal(c.barH(),62);
  c.ignoreHandleUntil=0;c.handleTap();assert.equal(c.edge,'');assert(c.collapsed);c.handleTap();assert(!c.collapsed);
  c.dragStart();c.dragUpdate(-1000,10);c.dragEnd();assert.equal(c.edge,'');assert.equal(c.input.length,0);
});
test('live display cards and a three-screen popup fit phone, tablet and notebook viewports',()=>{
  const c=controls(),requests=[];
  c.menu='screens';c.inputState=0;c.onChooseDisplay=slot=>requests.push(slot);
  c.displayCatalog=256;c.sharedAction('display-1');
  assert.equal(c.glassState().displayCount,1);assert.deepEqual(requests,[]);
  c.displayCatalog=(3<<8)|1;
  assert.equal(c.glassState().currentDisplay,1);
  for(const [w,h] of [[320,568],[760,360],[720,1024],[1024,720],[1366,768],[520,400]]){
    for(const scale of [1,1.5,2]){
      c.viewportW=w;c.viewportH=h;c.fontScale=scale;c.menu='screens';
      c.metrics=()=>ctx.glassMenuMetrics(c.glassState(),w,h,scale);
      c.recordAnchor('screens',{globalPosition:{x:c.originX+w/2,y:c.originY+h-62},width:42,height:48});
      const p=c.menuPlacement(),m=c.metrics();
      assert(p.x>=0&&p.x+m.width<=w&&p.y>=0&&p.y+m.height<=h);
    }
  }
  c.sharedAction('display-1');c.sharedAction('display-3');c.sharedAction('display-2');
  assert.deepEqual(requests,[2]);assert.equal(c.input.length,0);
});
test('switching input modes cannot complete a stale click or drag',()=>{
  const c=controls();c.lastTap=123;c.pressed=true;c.mode(true);
  assert.equal(c.lastTap,0);assert.equal(c.pressed,false);assert.deepEqual(c.input,[[3,0,1]]);assert(c.touchMode);
});
test('capability-filtered submenus track grants and do not advertise absent Windows features',()=>{
  const c=controls();for(const mode of [0,1,2,3,4]){
    c.inputState=mode;c.menu='input';const s=c.glassState();
    assert.equal(s.controlAccess,mode===2);assert.equal(s.disabledActions.includes('virtualMouse'),mode!==2);
    assert.equal(s.disabledActions.includes('controlAccess'),mode===1);
    assert.deepEqual(Array.from(s.inputTools),['gestureHelp','keyboardSettings','mouseSettings']);
  }
  c.menu='screens';assert.equal(c.glassState().displayCount,1);assert(!c.glassState().items.includes('displaySwipe'));
  c.menu='more';assert.deepEqual(Array.from(c.glassState().items),['monitor','sort']);
  const base=new ctx.RemoteGlassMenuState();assert.equal(base.explicitActions,false);
});
test('zoomed pan is local, resets at 100%, clamps both axes and letterboxing',()=>{
  const c=controls();c.inputState=0;c.sharedAction('pan');assert(!c.localPan);
  c.sharedAction('zoomIn');c.sharedAction('pan');assert(c.localPan);c.sharedAction('zoomReset');assert(!c.localPan);
  assert.equal(ctx.streamBoundPan(90,500,400),50);assert.equal(ctx.streamBoundPan(-70,500,400),-50);
  assert.equal(ctx.streamBoundPan(90,300,400),0);assert.equal(ctx.streamBoundPan(NaN,500,400),0);assert(!c.input.length);
});
test('only a transient decoder restart retains local UI; no initial, failed, disconnected or stale frame qualifies',()=>{
  for(const link of [4,5,11]) for(const phase of [1,2]){
    assert(ctx.streamRefreshingPicture(phase,link,true,150));assert(!ctx.streamRefreshingPicture(phase,link,false,0));
    assert(!ctx.streamRefreshingPicture(phase,link,true,6000));
  }
  for(const phase of [0,3,4,5,6])assert(!ctx.streamRefreshingPicture(phase,11,true,30));
  for(const link of [0,1,7])assert(!ctx.streamRefreshingPicture(2,link,true,30));
  const page=read('pages/SunshineStreamPage');
  assert(page.includes('this.hasPicture = active;') && page.includes('return this.hasPicture && this.requested && probe.inputSend'));
});
test('sort changes the rendered grid only, recovers old preferences without inventing keys',()=>{
  const c=controls();const initial=Array.from(c.gridOrder);c.moveKey(initial[0],-1);c.moveKey(initial[0],1);
  assert.equal(c.glassState().keyboardItems[1],initial[0]);c.moveKey(initial[0],-1);
  assert.deepEqual(Array.from(c.gridOrder),initial);assert(!c.input.length);
  const keys=Array.from(ctx.streamKeyGrid(['A','A','foreign','Ctrl+Alt+Del']));
  assert.equal(keys[0],'A');assert.equal(keys.length,initial.length);assert(!keys.includes('foreign'));
});
test('Done preserves composition and unsent edits, continuous input sends a single balanced Enter',()=>{
  const c=controls();let kept=0,closed=0;const e={keepEditableState(){++kept}};
  c.closeKeyboard=()=>closed++;c.soft=true;c.inputText='draft';c.committed='draft';c.composing=true;
  c.submitIme(e);c.composing=false;c.committed='';c.submitIme(e);assert.equal(c.input.length,0);
  c.committed='draft';c.closeOnSubmit=false;c.submitIme(e);assert.equal(kept,3);assert.equal(closed,0);
  assert.deepEqual(c.input,[[5,1,13],[5,0,13]]);c.closeOnSubmit=true;c.submitIme(e);assert.equal(closed,1);
});
const bridgePage=read('pages/SunshineStreamPage');
run(bridgePage.slice(bridgePage.indexOf('class StreamBridge {'),bridgePage.indexOf('function toNumber('))+
    '\nexports.Bridge=StreamBridge;');
test('covered Web is not the owner of telemetry; native reads real samples while open, Web receives the unchanged protocol',()=>{
  let reads=0,link=11,phase=3,rendered=100,index=1,kbps=4123,opens=0;
  ctx.probe={readUiLink:()=>link,secureSnapshot:(extended)=>{
    ++reads;assert.equal(extended,true);return [phase,rendered,kbps,5990,0,11,8000,8000,2,10900,0,11200,index].join(',');
  },runSecureClient:()=>{++opens;throw Error('no relaunch')}};
  const b=new ctx.exports.Bridge(), pictures=[];
  b.configure('','',()=>'',()=>{},()=>{},()=>{},(active)=>pictures.push(active));
  b.configureCompanion(true,()=>{});b.requested=true;b.playerStarted=true;
  assert.equal(b.snapshot().split(',').length,13);assert.equal(reads,1);assert(b.nativeOwnsReadout);
  const first=b.snapshot();assert.equal(reads,1);
  // No Web timer calls. A changed native measurement still reaches the HUD.
  kbps=3296;index=2;rendered=160;b.pollNativePlayback();assert.equal(b.receivedKbps,3296);
  assert.equal(b.sampleSequence,2);assert.notEqual(b.snapshot(),first);assert.equal(reads,2);
  rendered=161;b.pollNativePlayback();assert.equal(b.sampleSequence,2,'a render is not a new sample');
  phase=1;rendered=0;b.pollNativePlayback();assert(!b.hasPicture&&b.refreshingPicture);
  assert.equal(b.sampleSequence,0);assert(!b.openInput());
  phase=3;rendered=4;index=0;b.pollNativePlayback();assert(b.hasPicture);assert.equal(b.sampleSequence,0);
  link=8;phase=6;b.pollNativePlayback();assert(!b.nativeOwnsReadout&&!b.hasPicture);
  const ended=reads;b.pollNativePlayback();assert.equal(reads,ended);assert.equal(opens,0);
  assert.deepEqual(pictures,[true,true,true,false,true,false]);
});
test('info uses state directly in visible Text nodes, not snapshots or whole-panel opacity',()=>{
  const card=src.slice(src.indexOf('  monitorPanel()'),src.indexOf('  wheel('));
  for(const id of ['fps','rtt','received','gaps','sample'])assert(card.includes("id('sunshine-monitor-"+id+"')"));
  assert(card.includes('.backgroundColor(MONITOR_SCRIM)')&&src.includes("MONITOR_SCRIM: string = '#96000000'"));
  assert(!card.includes('this.note(')&&!card.includes('.opacity('));
  assert(bridgePage.includes('this.bridge.pollNativePlayback();')&&bridgePage.includes('clearInterval(this.readControlTimer)'));
});
console.log('sunshine_toolbar_regressions='+tests);
