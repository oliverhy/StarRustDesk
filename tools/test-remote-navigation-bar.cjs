'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/service/RemoteNavigationBarPolicy.ets'),'utf8');
const theme=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/service/SystemBarTheme.ets'),'utf8');
function fixture(){
 const ctx={exports:{},RustDeskNapi:{appendDiagnosticLog() {}}};
 vm.createContext(ctx);
 vm.runInContext(ts.transpile(theme.replace(/^import .*\r?\n/gm,'')+'\nglobalThis.SystemBarTheme=SystemBarTheme;'),ctx);
 vm.runInContext(ts.transpile(source.replace(/^import .*\r?\n/gm,'')),ctx);
 const Policy=ctx.exports.RemoteNavigationBarPolicy;
 const original={navigationBarColor:'#FFFFFF',navigationBarContentColor:'#333333',isNavigationBarLightIcon:false};
 const calls=[]; const target={
  getWindowSystemBarProperties:()=>({...original,statusBarColor:'#123456'}),
  async setWindowSystemBarProperties(props){calls.push(JSON.parse(JSON.stringify(props)));}
 };
 ctx.SystemBarTheme.attach(target);
 return {Policy,target,calls,original,theme:ctx.SystemBarTheme,flush:async()=>{await ctx.SystemBarTheme.pending;}};
}
(async()=>{
 let f=fixture(),p=new f.Policy();p.enter(f.target);await f.flush();
 assert.equal(f.calls[0].navigationBarColor,'#090D14');assert.equal(f.calls[0].navigationBarContentColor,'#FFFFFF');
 assert.equal(f.calls[0].statusBarColor,'#090D14');p.leave();await f.flush();assert.equal(f.calls[1].navigationBarColor,'#F7F9FC');
 f=fixture();p=new f.Policy();p.enter(f.target);p.leave();await f.flush();assert.equal(f.calls.at(-1).navigationBarColor,'#F7F9FC');
 f=fixture();p=new f.Policy();f.theme.setDark(true);await f.flush();
 assert.equal(f.calls.at(-1).statusBarColor,'#111827');p.enter(f.target);await f.flush();
 f.theme.setDark(false);await f.flush();assert.equal(f.calls.at(-1).navigationBarColor,'#090D14');
 p.leave();await f.flush();assert.equal(f.calls.at(-1).navigationBarColor,'#F7F9FC','restore the current theme');
 f=fixture();p=new f.Policy();let resume;
 const apply=f.target.setWindowSystemBarProperties;
 f.target.setWindowSystemBarProperties=async props=>{await apply(props);if(props.navigationBarColor==='#090D14')await new Promise(r=>{resume=r;});};
 p.enter(f.target);for(let i=0;i<8;i++)await Promise.resolve();p.leave();resume();await f.flush();assert.equal(f.calls[1].navigationBarColor,'#F7F9FC','late enter is followed by current theme');
 f=fixture();const old=new f.Policy(),next=new f.Policy();old.enter(f.target);await f.flush();old.leave();next.enter(f.target);await f.flush();
 assert.equal(f.calls.at(-1).navigationBarColor,'#090D14','next owner applies after old restore');next.leave();await f.flush();assert.equal(f.calls.at(-1).navigationBarColor,'#F7F9FC');
 f=fixture();p=new f.Policy();p.enter(f.target);f.theme.detach();await f.flush();assert.equal(f.calls.length,0,'destroyed window invalidates pending work');
 f=fixture();const working=f.target.setWindowSystemBarProperties;
 f.target.setWindowSystemBarProperties=async()=>{throw {code:1300002};};f.theme.setDark(true);await f.flush();
 f.target.setWindowSystemBarProperties=working;f.theme.refresh();await f.flush();
 assert.equal(f.calls.at(-1).statusBarColor,'#111827','a failed platform call does not poison later theme updates');
 assert(!/setWindowSystemBarEnable|setWindowLayoutFullScreen/.test(source),'color policy never disables gestures or changes window mode');
 const page=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/RemotePage.ets'),'utf8');
 assert(page.includes('this.isHandheldDevice() && !this.remoteExternalDisplay'));
 assert(page.includes('this.navigationBarPolicy.leave()'));
 assert(page.includes('.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])'));
 assert(/Column\(\) \{\}[\s\S]{0,400}expandSafeArea[\s\S]{0,100}hitTestBehavior\(HitTestMode.None\)/.test(page),
  'only the non-interactive background extends behind gesture navigation, not the remote canvas or controls');
 console.log('PASS remote navigation colors: dark remote area, original restoration, cancellation, failed queries, serialized ownership, unchanged gestures and desktop/projection boundaries');
})().catch(e=>{console.error(e);process.exitCode=1;});
