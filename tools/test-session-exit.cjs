'use strict';
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root=path.join(__dirname,'..'),source=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/RemotePage.ets'),'utf8').replace(/\r\n/g,'\n');
function method(name){const a=source.indexOf('\n  '+name+'(')>=0?source.indexOf('\n  '+name+'('):source.indexOf('\n  async '+name+'(');
 assert(a>=0,name);return source.slice(a,source.indexOf('\n  }',a)+4);}
const pageCode=ts.transpileModule('class Page{'+['requestDisconnect','retrySession','onBackPress'].map(method).join('\n')+'}exports.Page=Page;',
 {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText;
function fixture(){
 let reconnecting=false,dialog,shows=0,exits=0,failUI=false,request=async()=>true;
 const logs=[],events=[];
 const c=vm.createContext({exports:{},ConnectionStatus:{DISCONNECTED:0,CONNECTING:1,CONNECTED:2,FAILED:3},
  RustDeskNapi:{appendDiagnosticLog:(tag,text)=>logs.push([tag,text])},RustDeskTheme:{ERROR:'red'},translate:text=>text,
  ConnectionService:{isReconnecting:()=>reconnecting,retryCurrentSession:()=>request(),getLastConnectionError:()=> '连接超时'}});
 vm.runInContext(pageCode,c);
 const p=Object.assign(new c.exports.Page(),{connectionStatus:2,remotePageVisible:true,isLeavingAfterDisconnect:false,pipDisconnectPending:false,
  disconnectConfirmationVisible:false,disconnectConfirmationEpoch:0,retryRequestGeneration:0,transferActive:false,uploadStaging:false,recordingActive:false,
  controlMenu:'',connectionError:'',getUIContext:()=>({showAlertDialog:options=>{if(failUI)throw Error('unavailable');shows++;dialog=options;}}),
  disconnectSession:()=>{exits++;p.isLeavingAfterDisconnect=true;},
  releaseHeldMouseButtons:()=>events.push('mouse-release'),releaseRemoteNavigationKeys:()=>events.push('keys-release'),
  resetRemoteViewportForSession:()=>events.push('reset-viewport'),
  closeOrientationMenu:()=>events.push('orientation'),closeInputSettings:()=>events.push('input-settings'),setControlMenu:value=>{p.controlMenu=value;events.push('menu');},
  closeCommunication:()=>events.push('chat'),closeRemoteKeyboard:()=>events.push('keyboard'),closeRemoteFileBrowser:()=>events.push('files'),exitFullScreen:()=>events.push('fullscreen')});
 return {p,logs,events,dialog:()=>dialog,shows:()=>shows,exits:()=>exits,reconnecting:value=>{reconnecting=value;},failUI:()=>{failUI=true;},request:fn=>{request=fn;}};
}
let count=0;async function test(name,fn){await fn();count++;console.log('PASS '+name);}
(async()=>{
 await test('live session shows confirmation; cancel and backdrop keep the connection',()=>{
  for(const cancel of ['primaryButton','cancel']){const f=fixture();f.p.requestDisconnect();assert.equal(f.shows(),1);assert.equal(f.exits(),0);
   if(cancel==='cancel')f.dialog().cancel();else f.dialog().primaryButton.action();assert.equal(f.exits(),0);assert(!f.p.disconnectConfirmationVisible);}
 });
 await test('double click creates one dialog and confirmation disconnects exactly once',()=>{
  const f=fixture();f.p.requestDisconnect();f.p.requestDisconnect();assert.equal(f.shows(),1);const callback=f.dialog().secondaryButton.action;
  callback();callback();assert.equal(f.exits(),1);assert(f.logs.some(([,text])=>text==='disconnect_confirmation_accepted'));
 });
 await test('failed, disconnected and initial-connecting pages leave immediately without redundant confirmation',()=>{
  for(const status of [0,1,3]){const f=fixture();f.p.connectionStatus=status;f.p.requestDisconnect();assert.equal(f.shows(),0);assert.equal(f.exits(),1);}
 });
 await test('reconnecting sessions and active file transfers still require exit confirmation',()=>{
  const f=fixture();f.p.connectionStatus=1;f.reconnecting(true);f.p.requestDisconnect();assert.equal(f.shows(),1);
  for(const key of ['transferActive','uploadStaging','recordingActive']){const g=fixture();g.p.connectionStatus=3;g.p[key]=true;g.p.requestDisconnect();assert.equal(g.shows(),1);}
 });
 await test('stale dialog actions after page exit do not disconnect another session',()=>{
  const f=fixture();f.p.requestDisconnect();f.p.remotePageVisible=false;f.p.disconnectConfirmationEpoch++;f.dialog().secondaryButton.action();assert.equal(f.exits(),0);
 });
 await test('a failed dialog API never silently disconnects the live connection',()=>{
  const f=fixture();f.failUI();f.p.requestDisconnect();assert.equal(f.exits(),0);assert(!f.p.disconnectConfirmationVisible);
 });
 await test('Back first dismisses transient UI or full screen, not the remote session',()=>{
  for(const [key,event] of [['showOrientationDialog','orientation'],['showKeyboardSettings','input-settings'],['showCommunicationPanel','chat'],
    ['showKeyboardPanel','keyboard'],['showRemoteFileBrowser','files'],['isFullScreen','fullscreen']]){
   const f=fixture();f.p[key]=true;assert(f.p.onBackPress());assert(f.events.includes(event));assert.equal(f.shows(),0);assert.equal(f.exits(),0);
  }
  const f=fixture();assert(f.p.onBackPress());assert.equal(f.shows(),1);assert.equal(f.exits(),0);
 });
 await test('Retry reconnects inside the same page rather than navigating or disconnecting',async()=>{
  const f=fixture();f.p.connectionStatus=3;await f.p.retrySession();assert.equal(f.p.connectionStatus,1);assert.equal(f.exits(),0);
  assert(f.p.reconnecting);assert(f.events.includes('reset-viewport'));
 });
 await test('failed manual retry reports an error in place; async completion is ignored after leaving',async()=>{
  const f=fixture();f.request(async()=>false);await f.p.retrySession();assert.equal(f.p.connectionStatus,3);assert.equal(f.p.connectionError,'连接超时');assert.equal(f.exits(),0);
  const g=fixture();let resume;g.request(()=>new Promise(resolve=>{resume=resolve;}));const pending=g.p.retrySession();
  g.p.remotePageVisible=false;g.p.connectionStatus=0;g.p.retryRequestGeneration++;resume(false);await pending;assert.equal(g.p.connectionStatus,0);
 });
 const error=method('buildErrorView');assert.match(error,/Button\(translate\('Retry'[\s\S]*?this\.retrySession\(\)/);
 assert.equal((error.match(/this\.disconnectSession\(\)/g)||[]).length,1,'only Back exits the error page');
 for(const name of ['buildControlCategoryButton','buildControlToolbarItem','buildFileOnlySession','buildFileOnlyToolbar']){
  if(source.includes('\n  '+name+'('))assert(method(name).includes('this.requestDisconnect()'),name);
 }
 assert(method('buildConnectingView').includes("'user_cancelled_reconnect'"));
 assert(method('disconnectSession').includes('this.retryRequestGeneration++'));
 const rust=fs.readFileSync(path.join(root,'entry/src/main/rust/src/lib.rs'),'utf8');
 assert(rust.includes('message_kind != "misc_close_reason"'));
 assert(rust.includes('session_recovery::classify_peer_close_reason(&reason)'));
 assert(!rust.includes('peer close reason received value='),'do not log peer-provided close text');
 const cpp=fs.readFileSync(path.join(root,'entry/src/main/cpp/napi_init.cpp'),'utf8');
 assert(cpp.includes('"peer close reason class="'));
 assert(cpp.includes('reason == "manual" ? "远端已主动断开连接"'));
 assert(cpp.includes('reason == "rejected" ? "远端拒绝连接" : "远端已结束本次连接"'));
 console.log(`PASS ${count} exit/retry cases and native close-reason integration (real Windows-login acceptance pending)`);
})().catch(error=>{console.error(error);process.exitCode=1;});
