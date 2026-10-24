'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/RemotePage.ets'),'utf8');
function method(name){const i=source.indexOf('\n  '+name+'(');assert(i>=0);return source.slice(i,source.indexOf('\n  }',i)+4);}
const timers=[],logs=[],focus=[],menus=[],sent=[];
const ctx={ConnectionStatus:{CONNECTED:2,WAITING_2FA:4},KeyType:{Down:0,Up:1},
 RustDeskNapi:{appendDiagnosticLog:(c,m)=>logs.push([c,m])},ConnectionService:{send2FA:()=>{sent.push(true);return 0;}},
 setTimeout:fn=>{timers.push(fn);return timers.length;}};
vm.createContext(ctx);vm.runInContext(ts.transpile('class Page {'+['handleRemoteKey','requestRemoteInputFocus',
 'prepareTwoFactorInput','isTwoFactorCodeReady','submitTwoFactor'].map(method).join('\n')+'} globalThis.Page=Page;'),ctx);
const p=Object.assign(new ctx.Page(),{connectionStatus:4,controlMenu:'view',remotePageVisible:true,twoFaCode:'012345',
 setControlMenu:v=>menus.push(v),closeRemoteKeyboard(){},getUIContext:()=>({getFocusController:()=>({requestFocus:id=>{focus.push(id);return true;}})}),
 drainNativeInputEvents(){throw Error('local form must not drain or forward remote keys');}});
for(const keyCode of [2000,2001,2055,2101]) for(const type of [0,1])
 assert.equal(p.handleRemoteKey({keyCode,type}),false,'local form always receives keyboard events');
p.requestRemoteInputFocus();assert.equal(focus.length,0);
p.prepareTwoFactorInput();assert.deepEqual(menus,['']);timers.shift()();assert.deepEqual(focus,['remoteTwoFactorInput']);
p.prepareTwoFactorInput();p.remotePageVisible=false;timers.shift()();assert.equal(focus.length,1,'stale focus request ignored');
p.remotePageVisible=true;p.submitTwoFactor();assert.equal(sent.length,1);assert.equal(p.twoFaCode,'');
assert(!JSON.stringify(logs).includes('012345'),'no OTP contents in diagnostics');
assert(source.includes(".id('remoteTwoFactorInput')")&&source.includes('.onSubmit(() => { if (this.isTwoFactorCodeReady())'));
const account=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/widget/ApiAccountDialog.ets'),'utf8');
assert(account.includes(".id('apiAccountTwoFactorInput').defaultFocus(true).enterKeyType(EnterKeyType.Done)"));
console.log('PASS local 2FA keyboard priority, stale menus, focus ownership, enter submission and diagnostic privacy');
