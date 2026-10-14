'use strict';
const fs=require('node:fs'), vm=require('node:vm'), assert=require('node:assert/strict'), path=require('node:path');
const ts=require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const read=file=>fs.readFileSync(path.join(__dirname,'..',file),'utf8').replace(/\r\n/g,'\n');
const source=read('entry/src/main/ets/service/RemoteDisplayPolicy.ets');
assert.match(read('entry/src/main/module.json5'),/"orientation": "auto_rotation_restricted"/);
const storage=new Map(), options=new Map(), hdrMasks=[], logs=[], applied=[];
const O={AUTO_ROTATION:5,AUTO_ROTATION_RESTRICTED:8,LANDSCAPE:1,PORTRAIT:2};
let id=0, orientation=O.AUTO_ROTATION, listener, failNext=false, failWrite=false, silentWrite=false, failRead=false;
const main={
  on:(_,fn)=>{listener=fn;},off:()=>{listener=undefined;},
  getWindowProperties:()=>({displayId:id}),getPreferredOrientation:()=>orientation,
  setPreferredOrientation:async value=>{
    if(failNext){failNext=false;throw Error('window rejected');}
    orientation=value;applied.push(value);
  },
};
const deviceInfo={deviceType:'phone'};
const context=vm.createContext({
  display:{getDefaultDisplaySync:()=>({id:0,hdrFormats:[1,2,3]}),
    getDisplayByIdSync:id=>({width:id===2?1080:1920,height:id===2?1920:1080,hdrFormats:id===0?[2,3]:[]})},
  window:{Orientation:O},deviceInfo,
  RustDeskNapi:{appendDiagnosticLog:(category,message)=>logs.push([category,message]),
    setHdrDisplayFormats:mask=>hdrMasks.push(mask),
    getOption:key=>{if(failRead)throw Error('read');return options.get(key)||'';},
    setOption:(key,value)=>{if(failWrite)return -1;if(!silentWrite)options.set(key,value);return 0;}},
  AppStorage:{setOrCreate:(key,value)=>storage.set(key,value),get:key=>storage.get(key)},
});
vm.runInContext(ts.transpile(source.replace(/^import .*$/gm,'').replace(/^export /gm,'')+
  '\nglobalThis.Policy=RemoteDisplayPolicy;globalThis.Mode=RemoteOrientationMode;'),context);
const p=context.Policy,M=context.Mode,option='remote-follow-system-rotation',modeOption='remote-independent-orientation';
const select=async mode=>{const result=p.setOrientationMode(mode);await p.pending;return result;};
const follow=async value=>{const result=p.setFollowSystemRotation(value,0);await p.pending;return result;};
const project=async target=>{id=target;listener(target);await p.pending;};
const remote=read('entry/src/main/ets/pages/RemotePage.ets');
const method=(text,name)=>{const start=text.indexOf('  '+name+'(');assert(start>=0,name);return text.slice(start,text.indexOf('\n  }',start)+4);};
const choices=[],follows=[];
let page;
const ui=vm.createContext({
  AppStorage:{setOrCreate:(key,value)=>storage.set(key,value)},
  RemoteOrientationMode:M,ConnectionStatus:{CONNECTED:2},ConnectionService:{releaseModifiers(){}},
  RemoteDisplayPolicy:{setOrientationMode:(mode,display)=>{choices.push([mode,display]);return true;},
    setFollowSystemRotation:(value,display)=>{follows.push([value,display]);return true;}},
  RustDeskNapi:{appendDiagnosticLog(){},takeNativeInputEvents:()=>[]},
});
vm.runInContext(ts.transpile('class Page{'+['orientationModeLabel','showOrientationMenu','finishOrientationMenu',
  'closeOrientationMenu','syncOrientationMenuViewport','applyGlassOrientationAction']
  .map(name=>method(remote,name)).join('\n')+'}globalThis.Page=Page;'),ui);
page=Object.assign(new ui.Page(),{
  remotePageVisible:true,connectionStatus:2,remoteProjectionDisplayId:0,remoteExternalDisplay:false,
  remoteOrientationMode:M.SYSTEM,remoteFollowSystemRotation:true,peerPreferences:{},showOrientationDialog:false,
  isDarkMode:false,uiLanguage:'zh-Hans',pageWidth:396,pageHeight:780,controlMenu:'',
  releaseHeldMouseButtons(){},stopEdgeAutoPan(){},releaseRemoteNavigationKeys(){},releaseVirtualModifiers(){},
  setControlMenu(value){this.controlMenu=value;},showKeyboardPanel:false,
});
(async()=>{
  assert.equal(page.orientationModeLabel(),'跟随系统');page.showOrientationMenu();
  assert.equal(page.controlMenu,'orientation');assert.equal(page.showOrientationDialog,true);
  page.applyGlassOrientationAction('follow-system');assert.deepEqual(follows.at(-1),[false,0]);
  page.remoteFollowSystemRotation=false;
  page.applyGlassOrientationAction('orientation-landscape');assert.deepEqual(choices.at(-1),[M.LANDSCAPE,0]);
  const choiceCount=choices.length,followCount=follows.length,originalPeer=page.peerPreferences;
  page.peerPreferences={};page.applyGlassOrientationAction('follow-system');page.peerPreferences=originalPeer;
  page.remoteProjectionDisplayId=1;page.applyGlassOrientationAction('orientation-portrait');page.remoteProjectionDisplayId=0;
  page.connectionStatus=3;page.applyGlassOrientationAction('follow-system');page.connectionStatus=2;
  page.remotePageVisible=false;page.applyGlassOrientationAction('orientation-auto');page.remotePageVisible=true;
  assert.equal(choices.length,choiceCount);assert.equal(follows.length,followCount);
  page.closeOrientationMenu();assert.equal(page.showOrientationDialog,false);assert.equal(page.controlMenu,'');
  page.applyGlassOrientationAction('follow-system');assert.equal(follows.length,followCount);
  page.remoteExternalDisplay=true;page.remoteOrientationMode=M.SYSTEM;page.remoteFollowSystemRotation=true;
  assert.equal(page.orientationModeLabel(),'自动适配');page.showOrientationMenu();
  page.applyGlassOrientationAction('follow-system');assert.equal(follows.length,followCount,'projection has no phone switch');
  page.applyGlassOrientationAction('orientation-auto');assert.deepEqual(choices.at(-1),[M.SYSTEM,0]);
  page.applyGlassOrientationAction('orientation-portrait');assert.deepEqual(choices.at(-1),[M.PORTRAIT,0]);
  const projectionCount=choices.length;page.remoteProjectionDisplayId=1;page.applyGlassOrientationAction('orientation-landscape');
  assert.equal(choices.length,projectionCount);page.closeOrientationMenu();
  page.remoteExternalDisplay=false;page.remoteProjectionDisplayId=0;
  p.attach(main);p.setActive(true);await p.pending;
  assert.equal(storage.get('remoteFollowSystemRotation'),true,'first install defaults to follow system');
  assert.equal(storage.get('remoteOrientationMode'),M.SYSTEM);
  assert.equal(orientation,O.AUTO_ROTATION_RESTRICTED,'default respects system rotation lock');
  assert.equal(hdrMasks.at(-1),6);
  assert.equal(await select(M.PORTRAIT),false,'independent choices are inactive while following system');
  assert.equal(await follow(false),true);assert.equal(options.get(option),'0');
  assert.equal(orientation,O.AUTO_ROTATION,'explicit opt-out permits sensor rotation despite system lock');
  assert.equal(storage.get('remoteOrientationMode'),M.AUTO);
  assert(await select(M.PORTRAIT));assert.equal(orientation,O.PORTRAIT);
  assert.equal(options.get(modeOption),M.PORTRAIT);
  assert(await select(M.LANDSCAPE));assert.equal(orientation,O.LANDSCAPE);
  assert.equal(options.get(modeOption),M.LANDSCAPE);
  assert(await follow(true));assert.equal(orientation,O.AUTO_ROTATION_RESTRICTED);
  assert.equal(storage.get('remoteOrientationMode'),M.SYSTEM);
  assert(await follow(false));assert.equal(orientation,O.LANDSCAPE,'same session keeps the independent selection');
  assert(await select(M.AUTO));assert.equal(orientation,O.AUTO_ROTATION);
  assert.equal(options.get(modeOption),M.AUTO);
  assert.equal(await select(M.SYSTEM),false,'the system choice is the switch, not an independent mode');
  assert(await select(M.PORTRAIT));
  const localChoiceBeforeProjection=options.get(modeOption);
  await project(1);assert.equal(storage.get('remoteExternalDisplay'),true);
  assert.equal(storage.get('remoteOrientationMode'),M.SYSTEM);assert.equal(orientation,O.LANDSCAPE);
  assert.equal(hdrMasks.at(-1),0);assert.equal(p.setFollowSystemRotation(true,1),false,'projection cannot change the phone switch');
  assert.equal(await select(M.AUTO),false,'projection retains its existing auto-adaptation contract');
  assert(await select(M.PORTRAIT));assert.equal(orientation,O.PORTRAIT,'projected portrait overrides wide adaptation');
  assert(await select(M.LANDSCAPE));await project(0);
  assert.equal(options.get(modeOption),localChoiceBeforeProjection,'projection selection never overwrites saved phone orientation');
  assert.equal(storage.get('remoteOrientationMode'),M.PORTRAIT);assert.equal(orientation,O.PORTRAIT);
  assert.equal(hdrMasks.at(-1),6);assert(await select(M.AUTO));
  await project(1);assert.equal(storage.get('remoteOrientationMode'),M.LANDSCAPE);
  assert(await select(M.SYSTEM));await project(2);assert.equal(orientation,O.AUTO_ROTATION_RESTRICTED);
  assert(await select(M.LANDSCAPE));await project(0);assert.equal(orientation,O.AUTO_ROTATION);
  assert(await follow(true));assert.equal(orientation,O.AUTO_ROTATION_RESTRICTED);
  deviceInfo.deviceType='tablet';assert(await follow(false));assert(await select(M.PORTRAIT));
  assert.equal(orientation,O.PORTRAIT);assert(await select(M.LANDSCAPE));assert.equal(orientation,O.LANDSCAPE);
  assert(await select(M.AUTO));assert.equal(orientation,O.AUTO_ROTATION);
  for(const kind of ['failed','silent']){
    if(kind==='failed')failWrite=true;else silentWrite=true;
    assert.equal(await follow(true),false);assert.equal(storage.get('remoteFollowSystemRotation'),false);
    assert.equal(orientation,O.AUTO_ROTATION,'failed persistence must not change the applied preference');
    failWrite=silentWrite=false;
  }
  for(const kind of ['failed','silent']){
    if(kind==='failed')failWrite=true;else silentWrite=true;
    assert.equal(await select(M.LANDSCAPE),false);
    assert.equal(p.getIndependentOrientationMode(),M.AUTO);
    assert.equal(storage.get('remoteOrientationMode'),M.AUTO);
    assert.equal(options.get(modeOption),M.AUTO);
    assert.equal(orientation,O.AUTO_ROTATION,'failed direction persistence must not change the active direction');
    failWrite=silentWrite=false;
  }
  assert(logs.some(([,message])=>message==='independent_orientation_save_failed'));
  assert(await follow(true));failNext=true;assert(await follow(false));
  assert.equal(orientation,O.AUTO_ROTATION_RESTRICTED);assert(storage.get('remoteOrientationError').includes('系统暂未允许'));
  assert(logs.some(([,message])=>message==='orientation_apply_failed'));
  assert(await select(M.PORTRAIT));assert.equal(orientation,O.PORTRAIT);assert.equal(storage.get('remoteOrientationError'),'');
  assert.equal(p.setFollowSystemRotation('0',0),false);
  assert.equal(p.setFollowSystemRotation(true,99),false);assert.equal(await select('invalid'),false);
  p.setActive(false);await p.pending;assert.equal(orientation,O.AUTO_ROTATION_RESTRICTED);
  assert.equal(storage.get('remoteOrientationMode'),M.SYSTEM);assert.equal(options.get(option),'0');
  assert.equal(await follow(true),false,'inactive page cannot change the setting');
  p.setActive(true);await p.pending;assert.equal(storage.get('remoteOrientationMode'),M.PORTRAIT);
  assert.equal(orientation,O.PORTRAIT,'next session restores both opt-out and fixed portrait');
  p.setActive(false);await p.pending;p.detach();p.attach(main);p.setActive(true);await p.pending;
  assert.equal(storage.get('remoteFollowSystemRotation'),false,'recreated window restores the persisted switch');
  assert.equal(orientation,O.PORTRAIT,'recreated window restores the saved independent direction');
  for(const mode of [M.AUTO,M.PORTRAIT,M.LANDSCAPE]){
    assert(await select(mode));
    const restarted=vm.createContext({display:context.display,window:context.window,deviceInfo,
      RustDeskNapi:context.RustDeskNapi,AppStorage:context.AppStorage});
    vm.runInContext(ts.transpile(source.replace(/^import .*$/gm,'').replace(/^export /gm,'')+
      '\nglobalThis.Policy=RemoteDisplayPolicy;'),restarted);
    const next=restarted.Policy;
    // A restarted app creates a window with the manifest's system-follow default,
    // not the previous process's still-active independent orientation.
    orientation=O.AUTO_ROTATION_RESTRICTED;
    next.attach(main);next.setActive(true);await next.pending;
    assert.equal(next.getIndependentOrientationMode(),mode,'fresh process restores '+mode);
    assert.equal(orientation,mode===M.AUTO?O.AUTO_ROTATION:mode===M.PORTRAIT?O.PORTRAIT:O.LANDSCAPE);
    next.setActive(false);await next.pending;next.detach();p.attach(main);p.setActive(true);await p.pending;
  }
  assert(await select(M.AUTO));
  for(const raw of ['', 'invalid', 'system']){
    p.setActive(false);await p.pending;options.set(modeOption,raw);p.setActive(true);await p.pending;
    assert.equal(p.getIndependentOrientationMode(),M.AUTO,'unknown saved direction falls back to auto');
    assert.equal(orientation,O.AUTO_ROTATION);
  }
  assert(await follow(true));
  const writes=options.get(option);id=1;
  assert.equal(p.setFollowSystemRotation(false,0),false,'actual window target protects against delayed display notifications');
  assert.equal(options.get(option),writes);id=0;
  p.setFollowSystemRotation(false,0);id=1;await p.pending;
  assert.equal(orientation,O.LANDSCAPE,'queued local rotation discovers a display migration and adapts projection instead');
  assert.equal(storage.get('remoteExternalDisplay'),true);await project(0);assert.equal(orientation,O.AUTO_ROTATION);
  assert(await follow(true));p.setFollowSystemRotation(false,0);p.setActive(false);await p.pending;
  assert.equal(orientation,O.AUTO_ROTATION_RESTRICTED,'queued changes cannot override the final session-exit restoration');
  failRead=true;p.setActive(true);await p.pending;
  assert.equal(storage.get('remoteFollowSystemRotation'),true,'unreadable saved settings fail closed to system follow');
  failRead=false;p.setActive(false);await p.pending;
  for(const raw of ['', 'invalid', '1']){
    options.set(option,raw);p.setActive(true);await p.pending;
    assert.equal(storage.get('remoteFollowSystemRotation'),true);assert.equal(orientation,O.AUTO_ROTATION_RESTRICTED);
    p.setActive(false);await p.pending;
  }
  p.setActive(true);await p.pending;deviceInfo.deviceType='2in1';const count=applied.length;
  assert.equal(await select(M.LANDSCAPE),false);assert.equal(await follow(false),false);
  assert.equal(applied.length,count,'PC never receives handheld rotation requests or modifies the switch');
  p.detach();assert.equal(listener,undefined);assert.equal(storage.get('remoteProjectionDisplayId'),-1);

  for(const name of ['handleRemoteKey','handleRemoteTouch','handleRemoteMouse','handleNativeKeyInput','handleNativeMouseInput']){
    assert(method(remote,name).includes('showOrientationDialog'),'modal blocks '+name);
  }
  console.log('PASS rotation switch: default, persistence, independent auto/fixed, system lock, projection isolation, failure rollback, lifecycle, stale callbacks and anchored popup');
})().catch(error=>{console.error(error);process.exitCode=1;});
