'use strict';
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/service/ConnectionService.ets'),'utf8');
const code=ts.transpileModule(source.replace(/^import .*\r?\n/gm,''),
 {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
function fixture(){
 let now=1000,status=3,revision=1,background=false,id=0,prepared=0,prepare=async()=>{};
 const timers=new Map(),calls=[],logs=[],options={'custom-rendezvous-server':'server','relay-server':'relay',key:'secret-key'};
 const connect=(peer,password,server,relay,forceRelay,insecure,fileOnly,security,osPassword)=>{
  calls.push({peer,password,server,relay,forceRelay,insecure,fileOnly,security,osPassword});status=1;return 0;
 };
 const c=vm.createContext({exports:{},Date:{now:()=>now},ConnectionStatus:{DISCONNECTED:0,CONNECTING:1,CONNECTED:2,FAILED:3,WAITING_2FA:4},
  RustDeskNapi:{getConnectionStatus:()=>status,getConnectionRoute:()=>2,getLastConnectionError:()=> '远端传输中断',getOption:k=>options[k]||'',
   appendDiagnosticLog:(tag,text)=>logs.push([tag,text]),setPerformancePreset(){},connectWithServer:connect,
   connect:(peer,pw,insecure,fileOnly,security,os)=>connect(peer,pw,'','',false,insecure,fileOnly,security,os),disconnect:()=>{status=0;}},
  RemoteSessionBackgroundTask:{isAppBackground:()=>background,syncForConnectionStatus(){},stop(){}},
  AccountSession:{getApi:()=>({sessionRevision:()=>revision,prepareConnection:async()=>{prepared++;await prepare();}})},
  setTimeout:(fn,ms)=>{timers.set(++id,{fn,ms,due:now+ms});return id;},clearTimeout:key=>timers.delete(key)});
 vm.runInContext(code,c);const S=c.exports.ConnectionService;S.releaseModifiers=()=>{};S.resetTransientInputState=()=>{};
 return {S,timers,calls,logs,options,begin:async(peer='peer',fileOnly=false)=>{await S.connect(peer,'secret-password','smooth',fileOnly,
   {autoUnlock:true,privacyMode:false,lockAfterDisconnect:false},'secret-os-password');},
  authenticated(){status=2;S.observeSession(2);},fail(){status=3;},background:v=>{background=v;},revision:v=>{revision=v;},time:v=>{now=v;},
  prepared:()=>prepared,prepare:fn=>{prepare=fn;},delay:()=>[...timers.values()][0]?.ms,
  async tick(){const [key,timer]=[...timers.entries()].sort((a,b)=>a[1].due-b[1].due)[0]||[];assert(timer);timers.delete(key);now=timer.due;await timer.fn();}};
}
let count=0;
async function test(name,fn){await fn();count++;console.log('PASS '+name);}
(async()=>{
 await test('offline or transport errors before authentication do not automatically retry',async()=>{
  const f=fixture();await f.begin();f.fail();for(const error of ['远端设备已离线','远端传输中断','连接超时'])assert(!f.S.recoverInterruptedSession(error));
 });
 await test('authenticated EOF, interrupted transport, login-switch offline and temporary route failures retry securely',async()=>{
  for(const error of ['远端传输中断','Peer transport interrupted','远端连接已断开','Peer connection closed','Reset by the peer','远端设备已离线',
   'Remote desktop is offline','ID 服务器未响应','中继连接失败','连接超时','远端登录超时']){
   const f=fixture();await f.begin();f.authenticated();f.fail();assert(f.S.recoverInterruptedSession(error),error);assert.equal(f.delay(),1000);
   await f.tick();assert.equal(f.calls.length,2);assert.equal(f.calls[1].insecure,false);
  }
 });
 await test('manual close, unknown close text, password, key, permission and 2FA errors are terminal',async()=>{
  const f=fixture();await f.begin();f.authenticated();f.fail();
  for(const error of ['远端已主动断开连接','远端已结束本次连接','Wrong Password','远端密码错误','远端拒绝连接','Permission denied',
   '需要两步验证','服务器密钥无效','ID 服务器密钥不匹配','与远端安全握手失败','Remote desktop is offline password=secret'])assert(!f.S.recoverInterruptedSession(error),error);
  assert.equal(f.timers.size,0);
 });
 await test('30-second window backs off at 1/2/4/8 seconds and starts no attempt at the deadline',async()=>{
  const f=fixture();await f.begin();f.authenticated();f.fail();
  for(const ms of [1000,2000,4000,8000]){assert(f.S.recoverInterruptedSession('远端传输中断'));assert.equal(f.delay(),ms);await f.tick();f.fail();}
  assert(f.S.recoverInterruptedSession('远端设备已离线'));assert.equal(f.delay(),15000);await f.tick();
  assert.equal(f.calls.length,5);assert(!f.S.isReconnecting());assert(!f.S.recoverInterruptedSession('远端传输中断'));assert.equal(f.timers.size,0);
 });
 await test('successful recovery resets the budget for a later interruption',async()=>{
  const f=fixture();await f.begin();f.authenticated();f.fail();f.S.recoverInterruptedSession('远端传输中断');await f.tick();f.authenticated();
  assert.equal(f.S.getRecoveryAttempt(),0);assert(!f.S.isReconnecting());f.time(120000);f.fail();assert(f.S.recoverInterruptedSession('远端设备已离线'));assert.equal(f.delay(),1000);
 });
 await test('duplicate polling schedules one timer, and late success cancels it',async()=>{
  const f=fixture();await f.begin();f.authenticated();f.fail();for(let i=0;i<20;i++)assert(f.S.recoverInterruptedSession('远端传输中断'));
  assert.equal(f.timers.size,1);assert.equal(f.S.getRecoveryAttempt(),1);f.authenticated();assert.equal(f.timers.size,0);
 });
 await test('foreground/account/network/encryption gates remain enforced',async()=>{
  for(const change of [f=>f.background(true),f=>f.revision(2),f=>{f.options.key='changed';},f=>{f.S.insecureRetryUsed=true;},f=>{f.S.fileOnly=true;}]){
   const f=fixture();await f.begin();f.authenticated();f.fail();change(f);assert(!f.S.recoverInterruptedSession('远端传输中断'));
  }
 });
 await test('cancel and scope changes invalidate already queued recovery callbacks',async()=>{
  for(const change of [f=>f.S.disconnect(),f=>f.revision(2),f=>{f.options.key='changed';},f=>f.background(true)]){
   const f=fixture();await f.begin();f.authenticated();f.fail();f.S.recoverInterruptedSession('远端传输中断');const callback=[...f.timers.values()][0].fn;
   change(f);await callback();assert.equal(f.calls.length,1);
  }
 });
 await test('authentication rejection and 2FA cancel a scheduled reconnect',async()=>{
  const f=fixture();await f.begin();f.authenticated();f.fail();f.S.recoverInterruptedSession('远端传输中断');
  assert(!f.S.recoverInterruptedSession('远端拒绝连接'));assert.equal(f.timers.size,0);f.S.recoverInterruptedSession('远端传输中断');f.S.observeSession(4);
  assert.equal(f.timers.size,0);assert(!f.S.isReconnecting());
 });
 await test('manual retry retains peer/security context and starts one encrypted attempt',async()=>{
  const f=fixture();await f.begin();f.authenticated();f.fail();assert(await f.S.retryCurrentSession());assert.equal(f.calls.length,2);
  assert.equal(f.calls[1].password,'secret-password');assert.equal(f.calls[1].osPassword,'secret-os-password');assert.equal(f.calls[1].insecure,false);
  assert.equal(f.S.retryPeer,'peer');assert(!await f.S.retryCurrentSession(),'double click cannot start another reconnect');
 });
 await test('manual file-only retry preserves session mode but never prior insecure consent',async()=>{
  const f=fixture();await f.begin('peer',true);f.fail();f.S.insecureRetryUsed=true;assert(await f.S.retryCurrentSession());
  assert.equal(f.calls[1].fileOnly,true);assert.equal(f.calls[1].insecure,false);
 });
 await test('manual IPv6 retry skips account preparation and preserves the direct target',async()=>{
  const f=fixture();await f.begin('[2001:db8::5]:21118');f.fail();const before=f.prepared();assert(await f.S.retryCurrentSession());
  assert.equal(f.prepared(),before);assert.equal(f.calls[1].peer,'[2001:db8::5]:21118');
 });
 await test('changed account/server refuses stale manual retry credentials',async()=>{
  for(const change of [f=>{f.options.key='changed';},f=>f.revision(2)]){const f=fixture();await f.begin();f.fail();change(f);
   assert(!await f.S.retryCurrentSession());assert.equal(f.calls.length,1);assert.match(f.S.getLastConnectionError(),/账号已改变/);}
 });
 await test('cancel while async account preparation is pending cannot resurrect a closed session',async()=>{
  const f=fixture();await f.begin();f.fail();let resume;f.prepare(()=>new Promise(resolve=>{resume=resolve;}));const promise=f.S.retryCurrentSession();
  assert(f.S.isManualRetryPending());f.S.disconnect();resume();assert(!await promise);assert.equal(f.calls.length,1);assert.equal(f.S.retryPassword,'');assert(!f.S.isReconnecting());
 });
 await test('stale async completion cannot clear the new retry state',async()=>{
  const f=fixture();await f.begin();f.authenticated();f.fail();let resume;f.prepare(()=>new Promise(resolve=>{resume=resolve;}));f.S.recoverInterruptedSession('远端传输中断');
  const callback=[...f.timers.values()][0].fn;f.timers.clear();const old=callback();f.S.cancelPendingConnection();f.prepare(async()=>{});f.fail();
  assert(await f.S.retryCurrentSession());resume();await old;assert(f.S.isReconnecting());assert.equal(f.calls.length,2);
 });
 await test('slow/failed preparation is bounded, and diagnostic output never includes credentials',async()=>{
  const f=fixture();await f.begin();f.authenticated();f.fail();f.prepare(async()=>{f.time(32000);});f.S.recoverInterruptedSession('远端传输中断');await f.tick();assert.equal(f.calls.length,1);
  const g=fixture();await g.begin();g.fail();g.prepare(async()=>{throw Error('secret-token');});assert(!await g.S.retryCurrentSession());assert.match(g.S.getLastConnectionError(),/检查服务器账号/);
  for(const secret of ['secret-password','secret-os-password','secret-key','secret-token'])assert(!JSON.stringify([...f.logs,...g.logs]).includes(secret));
 });
 console.log(`PASS ${count} production session recovery cases (Windows login/remote-runtime acceptance pending)`);
})().catch(error=>{console.error(error);process.exitCode=1;});
