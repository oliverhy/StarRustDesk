// Runs the actual ArkTS method bodies against deterministic platform mocks.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
function slice(file, start, end) {
  const source = read(file);
  const a = source.indexOf(start), b = source.indexOf(end, a);
  assert(a >= 0 && b > a, `method boundaries: ${start}`);
  return source.slice(a, b);
}
let passed = 0;
function test(name, fn) { fn(); passed++; console.log(`PASS ${name}`); }
function subject(methods, mocks) {
  const context = vm.createContext(mocks);
  vm.runInContext(ts.transpileModule(`class Subject { ${methods} } globalThis.Subject = Subject;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
  return context.Subject;
}
let now = 1000, raw = '', refresh = 0, fallback = 0, restart = 0, background = false;
const napi = { takePeerOnlineStates: () => { const result = raw; raw = ''; return result; },
  refreshVideo: () => { refresh++; return 0; }, fallbackVideoToVp9: () => { fallback++; return 0; },
  restartVideoDecoder: () => { restart++; return 0; },
  appendDiagnosticLog: () => {} };
const clock = { now: () => now };
const Online = subject(slice('entry/src/main/ets/pages/ConnectionPage.ets',
  '  pollPeerOnlineStates():', '  peerOnlineStateColor('), {
  Date: clock, RustDeskNapi: napi, PEER_STATE_QUERY_TIMEOUT_MS: 12000, PEER_STATE_REFRESH_MS: 30000,
  PEER_STATE_UNKNOWN: 3, PEER_STATE_ONLINE: 1, PEER_STATE_OFFLINE: 2,
});
const online = Object.assign(new Online(), { savedConnections: [{remoteId: 'a'}, {remoteId: 'b'}],
  peerOnlineQueryInFlight: true, peerOnlineQueryStartedAt: 1000, peerOnlineStatesVersion: 0,
  customServerHint: 'server', peerOnlineStates: {} });
test('timeout marks unknown without inventing offline', () => {
  now = 14000; online.pollPeerOnlineStates();
  assert.equal(online.peerOnlineQueryInFlight, false); assert.equal(online.peerOnlineStates.a, 3);
});
test('late successful response is consumed after UI timeout', () => {
  raw = JSON.stringify({server:'server', error:'', peers:[{id:'a',online:true},{id:'b',online:false}]});
  now = 19000; online.pollPeerOnlineStates();
  assert.equal(online.peerOnlineStates.a, 1); assert.equal(online.peerOnlineStates.b, 2);
});
test('old server response cannot override current states', () => {
  raw = JSON.stringify({server:'old-server', error:'', peers:[{id:'a',online:false}]});
  online.pollPeerOnlineStates(); assert.equal(online.peerOnlineStates.a, 1);
  assert.equal(online.nextPeerOnlineRefreshAt, 0);
});
test('malformed response remains unknown, not green', () => {
  raw = '{invalid'; online.pollPeerOnlineStates(); assert.equal(online.peerOnlineStates.a, 3);
});
const Video = subject(slice('entry/src/main/ets/pages/RemotePage.ets',
  '  checkFirstVideoHealth(', '  startRemoteCursorPolling('), {
  Date:clock, RustDeskNapi:napi, ConnectionStatus:{CONNECTED:2},
  ConnectionService:{retryDirectViaRelay:()=>false},
  RemoteSessionBackgroundTask:{isAppBackground:()=>background},
  hilog:{warn:()=>{},error:()=>{}}, LOG_DOMAIN:0,
});
const video = Object.assign(new Video(), {connectionStatus:2, hasVideo:false,
  firstVideoWaitStartedAt:0, firstVideoRecoveryStage:0, videoFallbackRequested:false,
  decoderHealthInitialized:false, decoderStallStartedAt:0, videoRecoveryRefreshRequested:false,
  videoCodecName:()=> 'H265'});
const empty = {hasFrame:false,totalFrames:0,decodedFrames:0,codec:0};
test('no first frame requests refresh then bounded VP9 recovery', () => {
  now=1000; video.checkFirstVideoHealth(empty);
  now=5100; video.checkFirstVideoHealth(empty); assert.equal(refresh,1);
  now=11100; video.checkFirstVideoHealth(empty); assert.equal(fallback,1);
  now=21100; video.checkFirstVideoHealth(empty); assert.match(video.videoWaitingHint,/未发送/);
  now=41100; video.checkFirstVideoHealth(empty); assert.equal(fallback,1); assert.equal(refresh,1);
});
test('background and already rendered video never trigger first-frame fallback', () => {
  video.firstVideoRecoveryStage=0; video.firstVideoWaitStartedAt=1000;
  background=true; video.checkFirstVideoHealth(empty); assert.equal(video.firstVideoWaitStartedAt,0);
  background=false; video.hasVideo=true; video.checkFirstVideoHealth(empty);
  assert.equal(video.firstVideoWaitStartedAt,0); assert.equal(refresh,1);
});
test('single encoded frame with zero decoded output triggers recovery', () => {
  video.hasVideo=false; video.videoFallbackRequested=false;
  const stalled={hasFrame:false,totalFrames:1,decodedFrames:0,codec:5};
  now=1000; video.checkDecoderHealth(stalled);
  now=2400; video.checkDecoderHealth(stalled); assert.equal(refresh,2);
  now=5000; video.checkDecoderHealth(stalled); assert.equal(restart,1); assert.equal(fallback,1);
  now=8200; video.checkDecoderHealth(stalled); assert.equal(fallback,2);
  now=15000; video.checkDecoderHealth(stalled); assert.equal(restart,1); assert.equal(fallback,2);
});
test('decoded but unpresented frames also trigger decoder recovery', () => {
  video.decoderHealthInitialized=false; video.videoFallbackRequested=false;
  video.videoDecoderRestartRequested=false; video.decoderStallStartedAt=0;
  const stalled={hasFrame:false,totalFrames:5,decodedFrames:5,renderedFrames:0,codec:2};
  now=20000; video.checkDecoderHealth(stalled);
  now=24000; video.checkDecoderHealth(stalled); assert.equal(restart,2);
  now=30000; video.checkDecoderHealth(stalled); assert.equal(restart,2); assert.equal(fallback,2);
});
let route=1, status=2, connections=0, disconnects=0;
const serviceNapi={getConnectionStatus:()=>status,getConnectionRoute:()=>route,
  disconnect:()=>{disconnects++;}, appendDiagnosticLog:()=>{},
  connectWithServer:(id,pw,rv,relay,forced)=>{assert.equal(forced,true);connections++;return 0;}};
const Service = subject(slice('entry/src/main/ets/service/ConnectionService.ets',
  '  static disconnect():', '  static sendKeyEvent(').replaceAll('ConnectionService','Subject'), {
  RustDeskNapi:serviceNapi,ConnectionStatus:{CONNECTING:1,CONNECTED:2,FAILED:3},
  RemoteSessionBackgroundTask:{stop:()=>{},syncForConnectionStatus:()=>{}},
});
Object.assign(Service,{retryPeer:'test',retryPassword:'test-only',relayRetryUsed:false,
  releaseModifiers:()=>{},recordNetworkSnapshot:()=>{},resetTransientInputState:()=>{}});
test('direct retry forces relay exactly once',()=>{
  assert.equal(Service.retryDirectViaRelay('test'),true);
  assert.equal(Service.retryDirectViaRelay('test'),false);
  assert.equal(connections,1); assert.equal(disconnects,1);
});
test('2FA and login failure never automatically retry',()=>{
  Service.relayRetryUsed=false;
  for(status of [3,4]) assert.equal(Service.retryDirectViaRelay('test'),false);
  assert.equal(connections,1);
});
test('explicit cancellation clears credentials and prevents delayed retry',()=>{
  status=2; Service.disconnect();
  assert.equal(Service.retryPassword,''); assert.equal(Service.retryDirectViaRelay('test'),false);
});
test('relay route never retries relay again',()=>{
  route=2; Service.retryPeer='test'; Service.relayRetryUsed=false;
  assert.equal(Service.retryDirectViaRelay('test'),false);
});

for (const endpoint of ['192.168.2.123', '192.168.2.123:21118', '[2001:db8::1]:21118', '::1']) {
  test(`IP direct connection never retries through ID relay: ${endpoint}`,()=>{
    route=1; status=2; Service.retryPeer=endpoint; Service.relayRetryUsed=false;
    assert.equal(Service.retryDirectViaRelay('test'),false);
  });
}
let polledFrame={generation:1,security:0,hasFrame:true,width:1280,height:720}, scheduled;
const Poller = subject(slice('entry/src/main/ets/pages/RemotePage.ets',
  '  startFramePolling():', '  onAppForegroundEpochChanged():') +
  slice('entry/src/main/ets/pages/RemotePage.ets',
  '  resetRemoteViewportForSession():', '  checkFirstVideoHealth('), {
  RustDeskNapi:{getVideoFrame:()=>polledFrame,appendDiagnosticLog:()=>{}},
  setTimeout:fn=>{scheduled=fn;return 1;},ConnectionStatus:{CONNECTED:2},
});
const poller=Object.assign(new Poller(),{framePollGeneration:0,videoSessionGeneration:-1,
  stopFramePolling(){this.framePollGeneration++;}, resetViewportTransform(){},
  checkFirstVideoHealth(){},checkDecoderHealth(){},updateStats(){},
  scheduleSurfaceRebindIfSizeChanged(){}});
test('new session resets old successful frame and statistics',()=>{
  poller.startFramePolling(); scheduled(); assert.equal(poller.hasVideo,true);
  poller.lastStatsFrames=9000; poller.lastStatsBytes=99000;
  polledFrame={generation:2,security:0,hasFrame:false,width:0,height:0,totalFrames:0};
  scheduled(); assert.equal(poller.hasVideo,false);
  assert.equal(poller.lastStatsFrames,0); assert.equal(poller.lastStatsBytes,0);
});
test('encoded input alone does not make UI display success',()=>{
  polledFrame={...polledFrame,totalFrames:1,decodedFrames:0,renderedFrames:0};
  scheduled(); assert.equal(poller.hasVideo,false);
});
const Stats = subject(slice('entry/src/main/ets/pages/RemotePage.ets',
  '  updateStats(frame:', '  videoCodecName('), {Date:clock});
test('FPS counts presented frames while speed counts received bytes',()=>{
  const stats=Object.assign(new Stats(),{lastStatsTime:0,smoothFps:0,smoothKbps:0,videoCodecStatus:()=>''});
  now=1000; stats.updateStats({totalFrames:100,renderedFrames:10,totalBytes:1024});
  now=2000; stats.updateStats({totalFrames:200,renderedFrames:20,totalBytes:2048});
  assert.equal(stats.fpsText,'10.0 fps'); assert.equal(stats.speedText,'1 KB/s');
});
const device = {sdkApiVersion:22};
const bg = {BackgroundTaskMode:{MODE_MULTI_DEVICE_CONNECTION:6,MODE_AV_PLAYBACK_AND_RECORD:12,
  MODE_AUDIO_PLAYBACK:2,MODE_DATA_TRANSFER:1}, BackgroundTaskSubmode:{
  SUBMODE_VIDEO_BROADCAST_NORMAL_NOTIFICATION:10,SUBMODE_NORMAL_NOTIFICATION:2,
  SUBMODE_AVSESSION_AUDIO_PLAYBACK:5,SUBMODE_LIVE_VIEW_NOTIFICATION:3},
  ContinuousTaskRequest:class { isModeSupported() {
    assert.equal(this.backgroundTaskModes.length,this.backgroundTaskSubmodes.length);
    if(this.backgroundTaskSubmodes.includes(10)) throw {code:9800005};
    return true;
  } }};
const Bg = subject(slice('entry/src/main/ets/service/RemoteSessionBackgroundTask.ets',
  '  private static createRequest(', '  private static scheduleReconcile(')
  .replaceAll('RemoteSessionBackgroundTask', 'Subject'), {backgroundTaskManager:bg, deviceInfo:device,RustDeskNapi:napi,
    RemoteTaskRequestError:class extends Error {constructor(error){super(error.message);this.code=error.code;}}});
for (const api of [21,22]) for (const audio of [false,true]) for (const transfer of [false,true]) {
  test(`background matching submodes api=${api} audio=${audio} transfer=${transfer}`, () => {
    device.sdkApiVersion=api; Bg.audioPlaybackActive=audio; Bg.dataTransferActive=transfer; Bg.taskId=7;
    const result=Bg.supportedRequest({},true);
    assert.equal(result.backgroundTaskSubmodes[0],2); assert.equal(result.continuousTaskId,7);
    assert.equal(result.backgroundTaskModes.length,1+Number(audio)+Number(transfer));
  });
}
test('background permission error is not bypassed by fallback', () => {
  bg.ContinuousTaskRequest.prototype.isModeSupported=function(){throw {code:201};};
  assert.throws(()=>Bg.supportedRequest({},false),error=>error.code===201);
});
console.log(`${passed} regression checks passed`);
