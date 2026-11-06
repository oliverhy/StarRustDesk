'use strict';
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const sec = fs.readFileSync('entry/src/main/ets/pages/ExtendedDisplayPage.ets', 'utf8');
const main = fs.readFileSync('entry/src/main/ets/pages/RemotePage.ets', 'utf8');
const cpp = fs.readFileSync('entry/src/main/cpp/napi_init.cpp', 'utf8');
const service = fs.readFileSync('entry/src/main/ets/service/ConnectionService.ets', 'utf8');
assert(!service.includes('InputTrace letter char='), 'typed characters must not be logged');
assert(cpp.includes('token == g_secondaryToken.load() && g_secondaryKeyboardFocused') &&
  cpp.includes('EndSecondaryKeyboardInternal();'), 'native bridge is focus and session-token guarded');
const extract = (text, pattern) => { const start = text.indexOf(pattern); assert(start >= 0, pattern);
  return text.slice(start, text.indexOf('\n  }', start) + 4); };
const events = [];
const c = { exports: {}, KeySource:{ JOYSTICK:4 }, KeyType:{Down:0,Up:1},
  ConnectionStatus:{CONNECTED:2}, isNavigationControlKey: code => code >= 33 && code <= 40,
  RustDeskNapi:{ queueSecondaryKey:(...args) => {events.push(['queue',...args]); return 0;}, appendDiagnosticLog:()=>{} },
  ConnectionService:{ releaseModifiers:()=>events.push(['release']), syncCapsLockState:()=>{},
    sendHardwareControlKey:(...args)=>events.push(['control',...args]),
    syncNativeModifierState:(...args)=>events.push(['sync',...args]), sendLetterKeyEvent:(...args)=>events.push(['letter',...args]),
    sendPhysicalKeyEvent:(...args)=>events.push(['physical',...args]) } };
const keyboard = extract(sec, '  private keyboard(event: KeyEvent)');
vm.runInNewContext(ts.transpile('class Secondary {'+keyboard+'} globalThis.Secondary=Secondary;'),c);
const s = Object.assign(new c.Secondary(), {keyboardFocused:true, frameReady:true, token:7});
const e = { keySource:1, type:0, keyCode:2017, isCapsLockOn:false,
  getModifierKeyState: names => names[0] === 'Ctrl' };
assert.equal(s.keyboard(e), true); assert.deepEqual(events.pop(), ['queue',7,2017,0,1,true,0]);
s.keyboardFocused = false; assert.equal(s.keyboard(e), false); assert.equal(events.length,0);
const handler = extract(main, '  handleNativeKeyInput(event: NativeKeyInputEvent)');
const release = extract(main, '  releaseSecondaryKeyboardKeys(): void');
vm.runInNewContext(ts.transpile('class Main {'+handler+release+'} globalThis.Main=Main;'),c);
const m = Object.assign(new c.Main(), { desktopWindowActive:false, controlMenu:'screens',
  connectionStatus:2, secondaryHeldKeys:[], mapControlKeyCode:()=>0, mapHarmonyKeyCodeToUsbHidCode:()=>4,
  mapHarmonyKeyCodeToLetter:()=> 'a', releaseRemoteNavigationKeys:()=>events.push(['release-navigation']) });
m.handleNativeKeyInput({source:1001, action:0, keyCode:2017, modifierValid:false, capsLockValid:false});
assert.deepEqual(events.pop(), ['letter','a',4,0,undefined]);
m.handleNativeKeyInput({source:1001,action:-1});
assert.deepEqual(events.splice(0), [['letter','a',4,1],['sync',0]],
  'focus loss balances secondary keys without globally releasing other owners');
m.handleNativeKeyInput({source:1,action:0,keyCode:2017}); assert.equal(events.length,0);
console.log('PASS secondary keyboard: focus/token gate, existing mapper and ordered release');
