'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, 'entry/src/main/ets', file + '.ets'), 'utf8').replace(/\r\n/g, '\n');
function harness(capabilities = 8) {
  const calls = [], logs = [], disk = new Map();
  let failWrite = false;
  const context = vm.createContext({ exports: {}, hilog: { info() {} }, setTimeout() { return 1; }, clearTimeout() {},
    RustDeskNapi: new Proxy({}, { get(_, name) {
      if (name === 'getInputCapabilities') return () => capabilities;
      if (name === 'appendDiagnosticLog') return (...args) => logs.push(args);
      if (name === 'getOption') return key => disk.get(key) || '';
      if (name === 'setOption') return (key, value) => { if (failWrite) throw Error('storage'); disk.set(key, value); return 0; };
      return (...args) => { calls.push([name, ...args]); return 0; };
    } })
  });
  for (const file of ['model/KeyboardRemapping', 'model/RemoteToolbarPlacement', 'model/RemotePeerOptions',
    'service/RemotePeerPreferences', 'service/ConnectionService']) {
    const code = read(file).replace(/^import .*\n/gm, '');
    const compiled = ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2021,
      module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
    assert.equal(compiled.diagnostics.length, 0, file);
    vm.runInContext(compiled.outputText, context, { filename: file });
    Object.assign(context, context.exports);
  }
  const S = context.ConnectionService;
  return { S, context, calls, logs, disk,
    failWrite: value => { failWrite = value; },
    configure: rules => S.configureKeyboardRemapping(JSON.stringify({ version: 1, enabled: true, rules })),
    preset: name => S.configureKeyboardRemapping(JSON.stringify(context.keyboardRemapPreset(name, true))),
    keys: () => calls.filter(c => c[0] === 'sendKeyEvent').map(c => c.slice(1)),
    clear() { calls.length = logs.length = 0; } };
}
const rule = (source, target, modifiers = 0, enabled = true) => ({ source, target, modifiers, enabled });
let passed = 0;
function test(name, run) { run(); passed++; console.log('PASS ' + name); }
test('default, corrupted and unsupported versions remain disabled', () => {
  const h = harness();
  for (const raw of ['', '{', 'null', '[]', '{"version":2,"enabled":true,"rules":[]}', 'x'.repeat(2049)]) {
    const config = h.context.decodeKeyboardRemap(raw); assert.equal(config.enabled, false); assert.equal(config.rules.length, 0);
    h.S.configureKeyboardRemapping(raw); h.clear();
    h.S.sendHardwareControlKey(114, 0, 2092); h.S.sendHardwareControlKey(114, 1, 2092);
    assert.deepEqual(h.keys().map(k => k.slice(0, 2)), [[114,0],[114,1]]);
  }
});
test('schema rejects text, caps lock, modifier macros, duplicates, invalid bits and unknown fields', () => {
  const h = harness(), valid = h.context.validKeyboardRemap;
  for (const rules of [[rule(65,112)], [rule(20,17)], [rule(17,114)], [rule(114,17)],
    [rule(17,91,1)], [rule(114,38,16)], [rule(114,38,-1)], [rule(114,38,1.5)],
    [rule(114,115),rule(114,116)], [Object.assign(rule(114,115), { text:'not-allowed' })]]) {
    assert.equal(valid({ version:1, enabled:true, rules }), false);
  }
  assert.equal(valid({ version:1, enabled:true, rules:[], password:'test-only' }), false);
  assert.equal(valid({ version:1, enabled:true, rules:[rule(17,91),rule(91,17)] }), true, 'swap is a single-pass mapping');
});
test('presets preserve opt-in and left/right identity', () => {
  const h = harness();
  for (const name of ['macCtrl','macSwap','macMission']) {
    assert.equal(h.context.keyboardRemapPreset(name, false).enabled, false);
    assert(h.context.validKeyboardRemap(h.context.keyboardRemapPreset(name, true)));
  }
  assert.deepEqual(Array.from(h.context.keyboardRemapPreset('macSwap', true).rules, r => [r.source,r.target]),
    [[17,91],[163,92],[91,17],[92,163]]);
});
test('Ctrl maps to Command across direct, hardware, native and pointer evidence and mouse packets', () => {
  const h = harness(); h.preset('macCtrl'); h.clear();
  h.S.syncHardwareModifierState(true,false,false); h.S.sendHardwareControlKey(17,0,2072);
  h.S.syncNativeModifierState(1); h.S.syncHeldModifierState(true,false,false);
  h.S.sendLetterKeyEvent('c',6,0,1); h.S.sendLetterKeyEvent('c',6,1,1); h.S.sendMouseEvent(10,20,1);
  assert.deepEqual(h.keys().map(k => k.slice(0,2)), [[91,0]]);
  assert(h.calls.filter(c => c[0] === 'sendPhysicalKeyEvent').every(c => c[3] === 8));
  assert.equal(h.calls.at(-1)[4],8);
  h.S.sendHardwareControlKey(17,1,2072); h.S.syncHardwareModifierState(false,false,false);
  assert.deepEqual(h.keys().map(k => k.slice(0,2)), [[91,0],[91,1]]);
});
test('Ctrl/Command swap is not applied twice to letters or event masks', () => {
  for (const capability of [0,8]) {
    const h = harness(capability); h.preset('macSwap'); h.clear();
    h.S.syncNativeModifierState(1); h.S.sendLetterKeyEvent('q',20,0,1); h.S.sendLetterKeyEvent('q',20,1,1);
    assert(h.calls.filter(c => c[0] === 'sendPhysicalKeyEvent').every(c => c[3] === 8));
    h.S.releaseModifiers(); h.clear(); h.S.syncNativeModifierState(8);
    h.S.sendLetterKeyEvent('q',20,0,8);
    assert.equal(h.calls.filter(c => c[0] === 'sendPhysicalKeyEvent').at(-1)[3],1);
  }
});
test('left/right mapped modifiers and virtual buttons retain independent owners', () => {
  const h = harness(); h.preset('macCtrl'); h.clear();
  h.S.sendHardwareControlKey(17,0,2072); h.S.sendHardwareControlKey(163,0,2073);
  h.S.sendKeyEvent(91,0,10091); h.S.syncHeldModifierState(true,false,false);
  h.S.sendHardwareControlKey(17,1,2072); h.S.sendHardwareControlKey(163,1,2073);
  h.S.sendMouseEvent(1,1,1); assert.equal(h.calls.at(-1)[4],8);
  assert(!h.keys().some(k => k[0]===91 && k[1]===1));
  assert(h.keys().some(k => k[0]===92 && k[1]===1));
  h.S.sendKeyEvent(91,1,10091); assert(h.keys().some(k => k[0]===91 && k[1]===1));
});
test('virtual Ctrl remains Ctrl while physical Ctrl becomes Command', () => {
  const h = harness(); h.preset('macCtrl'); h.clear();
  h.S.syncHardwareModifierState(true,false,false); h.S.sendHardwareControlKey(17,0,2072);
  h.S.sendKeyEvent(17,0,10017); h.S.sendMouseEvent(0,0,1); assert.equal(h.calls.at(-1)[4],9);
  h.S.sendKeyEvent(17,1,10017); h.S.sendMouseEvent(0,0,1); assert.equal(h.calls.at(-1)[4],8);
  h.S.sendHardwareControlKey(17,1,2072); h.S.sendMouseEvent(0,0,1); assert.equal(h.calls.at(-1)[4],0);
});
test('snapshot-only modifier fallback maps without direct events and releases correctly', () => {
  const h = harness(); h.preset('macCtrl'); h.clear();
  h.S.syncHeldModifierState(true,false,false); h.S.sendMouseWheel(0,1);
  assert.deepEqual(h.keys().map(k => k.slice(0,2)),[[91,0]]); assert.equal(h.calls.at(-1)[3],8);
  h.S.syncHeldModifierState(false,false,false); assert.deepEqual(h.keys().map(k => k.slice(0,2)),[[91,0],[91,1]]);
});
test('side-specific remapping uses identified physical side rather than a phantom snapshot side', () => {
  const h = harness(); h.configure([rule(163,92)]); h.clear();
  h.S.syncNativeModifierState(1); h.S.sendHardwareControlKey(163,0,2073); h.S.sendMouseEvent(1,1,1);
  assert.equal(h.calls.at(-1)[4],8); h.S.sendHardwareControlKey(163,1,2073);
  assert(h.keys().some(k => k[0]===92 && k[1]===1));
});
test('single-key mapping preserves press/release and suppresses mirrored route repeats', () => {
  const h = harness(); h.configure([rule(114,121)]); h.clear();
  h.S.sendHardwareControlKey(114,0,2092,'native'); h.S.sendHardwareControlKey(114,0,2092,'ark');
  h.S.sendHardwareControlKey(114,0,2092,'native'); h.S.sendHardwareControlKey(114,1,2092,'ark');
  assert.deepEqual(h.keys().map(k => k.slice(0,2)),[[121,0],[121,0],[121,1]]);
});
test('two sources mapped to the same target cannot prematurely release it', () => {
  const h = harness(); h.configure([rule(114,121)]); h.clear();
  h.S.sendHardwareControlKey(114,0,2092); h.S.sendHardwareControlKey(121,0,2099);
  h.S.sendHardwareControlKey(114,1,2092); assert.deepEqual(h.keys().map(k => k.slice(0,2)),[[121,0]]);
  h.S.sendHardwareControlKey(121,1,2099); assert.deepEqual(h.keys().map(k => k.slice(0,2)),[[121,0],[121,1]]);
});
test('a complete shortcut fires once per press and never latches synthetic modifiers', () => {
  const h = harness(); h.preset('macMission'); h.clear();
  h.S.sendHardwareControlKey(114,0,2092,'native'); h.S.sendHardwareControlKey(114,0,2092,'ark');
  h.S.sendHardwareControlKey(114,0,2092,'native'); h.S.sendHardwareControlKey(114,2,2092,'native');
  h.S.sendHardwareControlKey(114,1,2092); h.S.sendMouseEvent(0,0,1);
  assert.deepEqual(h.keys(),[[38,2,1]]); assert.equal(h.calls.at(-1)[4],0);
  h.S.sendHardwareControlKey(114,0,2092); assert.equal(h.keys().length,2);
});
test('navigation repeats use mapped targets and a single matching release', () => {
  const h = harness(); h.configure([rule(38,40)]); h.clear();
  h.S.sendHardwareControlKey(38,0,38,'ark'); h.S.sendHardwareControlKey(38,2,38,'ark');
  h.S.sendHardwareControlKey(38,1,38,'native'); assert.deepEqual(h.keys().map(k=>k.slice(0,2)),[[40,0],[40,2],[40,1]]);
});
test('changing/disabling mappings releases old targets before installing new rules', () => {
  const h = harness(); h.configure([rule(114,121),rule(17,91)]); h.clear();
  h.S.sendHardwareControlKey(114,0,2092); h.S.sendHardwareControlKey(17,0,2072);
  h.S.configureKeyboardRemapping('');
  assert(h.keys().some(k=>k[0]===121 && k[1]===1)); assert(h.keys().some(k=>k[0]===91 && k[1]===1));
  h.clear(); h.S.sendHardwareControlKey(114,0,2092); assert.equal(h.keys()[0][0],114);
});
test('focus loss balances mapped keys and restores the same mapping on the next press', () => {
  const h = harness(); h.configure([rule(114,121)]); h.clear();
  h.S.sendHardwareControlKey(114,0,2092); h.S.releaseModifiers(); h.S.sendHardwareControlKey(114,0,2092);
  assert.deepEqual(h.keys().map(k=>k.slice(0,2)),[[121,0],[121,1],[121,0]]);
});
test('Chinese/IME text, paste, virtual keys and preset shortcuts bypass mapping', () => {
  const h = harness(); h.configure([rule(114,121),rule(17,91)]); h.clear();
  h.S.sendText('中文输入与粘贴'); h.S.sendKeyEvent(114,2); h.S.sendShortcutKey(114,1);
  h.S.sendPrintableShortcutKey(67,1);
  assert.deepEqual(h.calls[0],['sendText','中文输入与粘贴']);
  assert.deepEqual(h.keys().map(k=>k.slice(0,2)),[[114,2],[114,2]]);
  assert(h.calls.some(c=>c[0]==='sendPrintableShortcutKey' && c[1]===67 && c[2]===1));
  assert(!JSON.stringify(h.logs).includes('中文'));
});
test('rules restore only for the exact server/peer and never overwrite passwords or global defaults', () => {
  const h = harness(), a = new h.context.RemotePeerPreferences('[2001:db8::1]:21116','123');
  const raw=JSON.stringify(h.context.keyboardRemapPreset('macCtrl',false));
  assert(a.set('keyboard-remap-v1',raw)); assert(a.flush());
  const restored=new h.context.RemotePeerPreferences('[2001:db8::1]:21116','123');
  assert.equal(restored.get('keyboard-remap-v1'),raw);
  assert.equal(new h.context.RemotePeerPreferences('other','123').get('keyboard-remap-v1'),'');
  assert.equal(new h.context.RemotePeerPreferences('[2001:db8::1]:21116','456').get('keyboard-remap-v1'),'');
  assert.equal(a.set('keyboard-remap-v1','{"version":1,"enabled":true,"rules":[],"password":"test"}'),false);
  assert.equal(h.disk.size,1);
});
test('editor defaults disabled, saving is explicit, capture is local and rule labels contain no typed text', () => {
  const widget=read('widget/KeyboardMappingDialog'), page=read('pages/RemotePage');
  assert(widget.includes('@State mappingEnabled: boolean = false'));
  assert(widget.includes('keyboardRemapPreset(name, this.mappingEnabled)'));
  assert(widget.includes('this.onSave(value)'));
  assert(widget.includes('keyboardRemapHarmonyCode(event.keyCode)'));
  assert(!widget.includes('keyText') && !widget.includes('sendText'));
  assert(page.includes('this.peerPreferences !== preferences'));
  for(const name of ['handleNativeKeyInput','handleRemoteKey','handleNativeMouseInput','syncHardwareKeyState']) {
    const body=page.slice(page.indexOf('\n  '+name+'(')); assert(body.slice(0,300).includes('showKeyboardMappingDialog'));
  }
  assert(page.includes("for (const code of held) ConnectionService.sendHardwareControlKey(code, 1, code)"));
});
function extracted(file, name) {
  const source=read(file), start=source.indexOf('\n  '+name+'(');
  assert(start>=0,name); return source.slice(start,source.indexOf('\n  }',start)+4);
}
test('editing, preset selection, replacement and cancel affect only the draft; save failure keeps the editor open', () => {
  const h=harness(), ctx=h.context, closed=[];
  vm.runInContext(ts.transpileModule('class Editor {'+['aboutToAppear','selectSource','targetKeys','applyPreset',
    'addRule','save','close'].map(name=>extracted('widget/KeyboardMappingDialog',name)).join('\n')+
    '} globalThis.Editor=Editor;', {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,ctx);
  const saves=[], editor=Object.assign(new ctx.Editor(), { initial:'', mappingEnabled:false, rules:[],
    sourceKey:114,targetKey:38,modifiers:0,error:'',recording:false,
    controller:{close:()=>closed.push(true)},onClose:()=>{},onSave:value=>{saves.push(value);return false;} });
  editor.aboutToAppear(); editor.applyPreset('macCtrl'); assert.equal(editor.mappingEnabled,false);
  assert.equal(saves.length,0); editor.close(); assert.equal(saves.length,0);
  editor.selectSource(114); editor.targetKey=121; editor.addRule(); editor.targetKey=120;editor.addRule();
  assert.equal(editor.rules.filter(r=>r.source===114).length,1);
  assert.equal(editor.rules.find(r=>r.source===114).target,120);
  editor.selectSource(17); assert.equal(editor.targetKey,91);assert.equal(editor.modifiers,0);
  assert(Array.from(editor.targetKeys()).every(key=>ctx.keyboardModifierBit(key)!==0));
  const before=closed.length;editor.save();assert.equal(closed.length,before);assert.equal(editor.error,'保存键盘映射失败，请重试');
  assert.equal(saves.length,1);
});
test('page saves the captured peer only, rolls back failed storage and blocks stale session callbacks', () => {
  const h=harness(),ctx=h.context, previous=JSON.stringify(ctx.keyboardRemapPreset('macCtrl',true));
  const p=new ctx.RemotePeerPreferences('srv','A');assert(p.set('keyboard-remap-v1',previous));assert(p.flush());
  h.S.configureKeyboardRemapping(previous);
  const overlays=[];ctx.KeyboardMappingDialog=options=>{overlays.push(options);return options;};
  ctx.ConnectionStatus={CONNECTED:2};ctx.CustomDialogController=class {constructor(options){this.options=options;}open(){}close(){}};
  vm.runInContext(ts.transpileModule('class Page {'+extracted('pages/RemotePage','openKeyboardMappingDialog')+
    '} globalThis.EditorPage=Page;',{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,ctx);
  const page=Object.assign(new ctx.EditorPage(),{peerPreferences:p,connectionStatus:2,remotePageVisible:true,
    showKeyboardPanel:false,showKeyboardMappingDialog:false,releaseHeldMouseButtons(){},stopEdgeAutoPan(){},
    releaseRemoteNavigationKeys(){},releaseVirtualModifiers(){},setControlMenu(){},showFileToast(){} });
  page.openKeyboardMappingDialog();assert.equal(page.showKeyboardMappingDialog,true);
  page.openKeyboardMappingDialog();assert.equal(overlays.length,1,'repeated opening does not create another editor');
  const next=JSON.stringify(ctx.keyboardRemapPreset('macSwap',true));h.failWrite(true);
  assert.equal(overlays[0].onSave(next),false);assert.equal(p.get('keyboard-remap-v1'),previous);
  h.clear();h.S.sendHardwareControlKey(91,0,2076);assert.equal(h.keys()[0][0],91,'failed change retains old mapping');
  h.S.releaseModifiers();h.failWrite(false);
  page.peerPreferences=new ctx.RemotePeerPreferences('srv','B');assert.equal(overlays[0].onSave(next),false);
  assert.equal(page.peerPreferences.get('keyboard-remap-v1'),'');
  page.peerPreferences=p;page.remotePageVisible=false;assert.equal(overlays[0].onSave(next),false);
  page.remotePageVisible=true;assert.equal(overlays[0].onSave(next),true);assert.equal(p.get('keyboard-remap-v1'),next);
  h.clear();h.S.sendHardwareControlKey(91,0,2076);assert.equal(h.keys()[0][0],17,'successful save activates the new mapping');
  overlays[0].onClose();assert.equal(page.showKeyboardMappingDialog,false);
  ctx.CustomDialogController=class {constructor(){throw Error('window unavailable');}};
  page.openKeyboardMappingDialog();assert.equal(page.showKeyboardMappingDialog,false,'open failure cannot lock remote input');
  assert(h.logs.some(entry=>entry[1]==='editor_open_failed'));
});
console.log(`TOTAL=${passed} FAILED=0 (production keyboard remapping; real-device acceptance pending)`);
