'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/service/RemoteNavigationBarPolicy.ets'),'utf8');
function fixture(){
 const ctx={exports:{},RustDeskNapi:{appendDiagnosticLog() {}}};
 vm.runInNewContext(ts.transpile(source.replace(/^import .*\r?\n/gm,'')),ctx);
 const Policy=ctx.exports.RemoteNavigationBarPolicy;
 const original={navigationBarColor:'#FFFFFF',navigationBarContentColor:'#333333',isNavigationBarLightIcon:false};
 const calls=[]; const target={
  getWindowSystemBarProperties:()=>({...original,statusBarColor:'#123456'}),
  async setWindowSystemBarProperties(props){calls.push(JSON.parse(JSON.stringify(props)));}
 };
 return {Policy,target,calls,original,flush:async()=>{await Policy.pending;}};
}
(async()=>{
 let f=fixture(),p=new f.Policy();p.enter(f.target);await f.flush();
 assert.equal(f.calls[0].navigationBarColor,'#090D14');assert.equal(f.calls[0].navigationBarContentColor,'#FFFFFF');
 assert(!('statusBarColor' in f.calls[0]));p.leave();await f.flush();assert.deepEqual(f.calls[1],f.original);
 f=fixture();p=new f.Policy();p.enter(f.target);p.leave();await f.flush();assert.equal(f.calls.length,0,'cancel before capture never mutates colors');
 f=fixture();p=new f.Policy();f.target.getWindowSystemBarProperties=()=>{throw Error('destroyed');};
 p.enter(f.target);await f.flush();p.leave();await f.flush();assert.equal(f.calls.length,0,'no mutation without restorable properties');
 f=fixture();p=new f.Policy();let resume;
 const apply=f.target.setWindowSystemBarProperties;
 f.target.setWindowSystemBarProperties=async props=>{await apply(props);if(props.navigationBarColor==='#090D14')await new Promise(r=>{resume=r;});};
 p.enter(f.target);for(let i=0;i<8;i++)await Promise.resolve();p.leave();resume();await f.flush();assert.deepEqual(f.calls[1],f.original,'late enter is followed by restore');
 f=fixture();const old=new f.Policy(),next=new f.Policy();old.enter(f.target);await f.flush();old.leave();next.enter(f.target);await f.flush();
 assert.equal(f.calls.at(-1).navigationBarColor,'#090D14','next owner applies after old restore');next.leave();await f.flush();assert.deepEqual(f.calls.at(-1),f.original);
 assert(!/setWindowSystemBarEnable|setWindowLayoutFullScreen/.test(source),'color policy never disables gestures or changes window mode');
 const page=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/RemotePage.ets'),'utf8');
 assert(page.includes('this.isHandheldDevice() && !this.remoteExternalDisplay'));
 assert(page.includes('this.navigationBarPolicy.leave()'));
 assert(page.includes('.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])'));
 assert(/Column\(\) \{\}[\s\S]{0,400}expandSafeArea[\s\S]{0,100}hitTestBehavior\(HitTestMode.None\)/.test(page),
  'only the non-interactive background extends behind gesture navigation, not the remote canvas or controls');
 console.log('PASS remote navigation colors: dark remote area, original restoration, cancellation, failed queries, serialized ownership, unchanged gestures and desktop/projection boundaries');
})().catch(e=>{console.error(e);process.exitCode=1;});
