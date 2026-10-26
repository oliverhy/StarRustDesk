const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const source = read('entry/src/main/ets/service/CommunicationService.ets');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
let connected = 2, state = 0, received = [], capture = false, starts = 0, permission = 0, background = false;
let permissionResolver;
let delayedPermission = false;
let voiceDesired = false, voiceReady = false;
const audio = [];
const native = {
  getVoiceCallState: () => state,
  takeChatMessages: () => { const result = JSON.stringify(received); received = []; return result; },
  sendChatMessage: () => connected === 2 ? 0 : -2,
  requestVoiceCall: () => { state = 1; return 0; },
  endVoiceCall: () => { state = 4; capture = false; return 0; },
  startVoiceCapture: () => { assert.equal(state, 2); capture = true; starts++; return 0; },
  stopVoiceCapture: () => { capture = false; return 0; }
};
const context = {
  exports: {}, setInterval: () => 1, clearInterval: () => {}, Date,
  require: name => {
    if (name === 'libentry.so') return { default: native };
    if (name === '@kit.AbilityKit') return { abilityAccessCtrl: { createAtManager: () => ({
      requestPermissionsFromUser: () => delayedPermission ? new Promise(resolve => { permissionResolver = resolve; }) : Promise.resolve({ authResults: [permission] })
    }) } };
    if (name === './RustDeskNapi') return { RustDeskNapi: { getConnectionStatus: () => connected,
      setRemoteAudioEnabled: enabled => audio.push(enabled), getOption: () => '0', appendDiagnosticLog: () => {} } };
    if (name === './RemoteSessionBackgroundTask') return { RemoteSessionBackgroundTask: {
      isAppBackground: () => background, setVoiceCallActive: active => voiceDesired = active,
      canKeepVoiceCall: () => voiceDesired && voiceReady } };
    throw Error(name);
  }
};
vm.runInNewContext(js, context);
const service = context.exports.CommunicationService;
(async () => {
  service.start(() => {});
  service.poll();
  assert.equal(service.send('中文聊天'), true);
  received = ['remote reply']; service.poll();
  assert.equal(service.unread, 1);
  assert.equal(service.messages.length, 2);
  service.setPanelOpen(true); assert.equal(service.unread, 0);
  permission = -1; await service.call({}); assert.equal(starts, 0);
  permission = 0; await service.call({}); assert.equal(state, 1); assert.equal(capture, false);
  state = 2; service.poll(); assert.equal(capture, true);
  service.toggleMute(); assert.equal(capture, false); assert.equal(service.muted, true);
  service.toggleMute(); assert.equal(capture, true);
  service.onBackground(); assert.equal(capture, false); assert.equal(state, 4); assert.equal(audio.at(-1), false);
  await service.call({}); state = 2; service.poll(); voiceReady = true; background = true;
  service.onBackground(); assert.equal(capture, true, 'granted task keeps active call');
  voiceReady = false; service.poll(); assert.equal(capture, false, 'task revocation stops microphone');
  assert.equal(voiceDesired, false); background = false;
  await service.call({}); state = 3; service.poll(); assert.equal(capture, false); assert.equal(audio.at(-1), false);
  delayedPermission = true;
  const pending = service.call({});
  service.dispose(); permissionResolver({ authResults: [0] }); await pending;
  assert.equal(capture, false); assert.equal(state, 4);
  service.start(() => {}); service.poll(); service.send('session data');
  connected = 3; service.poll(); assert.equal(service.messages.length, 0); assert.equal(capture, false);
  const page = read('entry/src/main/ets/pages/RemotePage.ets');
  for (const method of ['handleNativeKeyInput', 'handleNativeMouseInput', 'syncHardwareKeyState', 'handleRemoteKey', 'requestRemoteInputFocus']) {
    const pos = page.indexOf(`  ${method}(`);
    // Inspect the method, not an arbitrary character window: another early
    // safety guard (for a screen transition) may precede chat isolation.
    const body = page.slice(pos, page.indexOf('\n  }', pos));
    assert(pos >= 0 && body.includes('if (this.showCommunicationPanel) return'), `${method} must not route chat input to remote`);
  }
  const rust = read('entry/src/main/rust/src/communication.rs');
  assert.match(rust, /MAX_VOICE_QUEUED: usize = 10/);
  assert.match(rust, /call.timestamp != response.req_timestamp/);
  assert.match(rust, /call.state != 2/);
  assert.match(rust, /MAX_CHAT_MESSAGES: usize = 100/);
  const panel = read('entry/src/main/ets/widget/CommunicationPanel.ets');
  assert.match(panel, /const VOICE_CALL_UI_ENABLED: boolean = true/);
  assert.match(page, /case 'chat': return '聊天与语音'/);
  assert.match(panel, /if \(VOICE_CALL_UI_ENABLED\) \{[\s\S]*?Button\(translate\('发起语音', this\.uiLanguage\)\)/);
  assert.match(panel, /VOICE_CALL_UI_ENABLED \? '聊天与通话' : '聊天'/);
  console.log('Communication lifecycle, privacy, backpressure and input isolation tests passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
