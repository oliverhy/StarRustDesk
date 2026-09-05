// Exercise the actual ArkTS ordering methods with deterministic storage mocks.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8');
const start = source.indexOf('  loadSavedConnectionSort():');
const end = source.indexOf('  groupNameForId(', start);
assert(start >= 0 && end > start);
let preference = '', storageFails = false;
const context = vm.createContext({
  RustDeskNapi: {
    getOption: () => { if (storageFails) throw Error('storage'); return preference; },
    setOption: (key, value) => { assert.equal(key, 'saved-connections-sort'); preference = value; }
  }, PEER_STATE_CHECKING: 0, PEER_STATE_ONLINE: 1, PEER_STATE_OFFLINE: 2
});
vm.runInContext(ts.transpileModule(`class Page { ${source.slice(start, end)} } globalThis.Page = Page;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
const item = (id, remoteId, name, groupId = '') => ({id, remoteId, name, groupId, password:'test-only'});
const page = Object.assign(new context.Page(), {
  savedConnectionSort:'id', savedConnectionsVersion:0, peerOnlineStates:{},
  connectionGroups:[{id:'g',name:'group'}], savedConnections:[
    item('c','300','Beta'), item('a','200','alpha'), item('b','100','Alpha'),
    item('d','2','', 'g'), item('e','10','', 'g'), item('f','400','Z', 'removed-group')
  ]
});
const ids = group => Array.from(page.connectionsForGroup(group), row => row.id);
let passed=0;
function test(name, fn) { fn(); passed++; console.log(`PASS ${name}`); }
test('default and invalid preferences fall back to ID', () => {
  for (preference of ['', 'invalid']) { page.loadSavedConnectionSort(); assert.equal(page.savedConnectionSort,'id'); }
  assert.deepEqual(ids(''), ['b','a','c','f']);
});
test('ID matches official string ordering, not numeric ordering', () => {
  assert.deepEqual(ids('g'), ['e','d']);
});
test('name is case insensitive with ID tie breaker', () => {
  page.setSavedConnectionSort('name'); assert.deepEqual(ids(''), ['b','a','c','f']);
});
test('Chinese device names use Chinese collation', () => {
  assert(page.compareSavedConnections(item('x','8','北京'), item('y','9','上海')) < 0);
});
test('online then offline then checking/unknown; same status uses name', () => {
  page.peerOnlineStates={'100':1,'200':1,'300':2,'400':3};
  page.setSavedConnectionSort('online'); assert.deepEqual(ids(''), ['b','a','c','f']);
});
test('online changes update ordering; name mode stays fixed', () => {
  page.peerOnlineStates={'300':1,'100':2,'200':2};
  assert.deepEqual(ids(''), ['c','b','a','f']);
  page.setSavedConnectionSort('name'); assert.deepEqual(ids(''), ['b','a','c','f']);
});
test('sorting does not mutate saved array, group membership or credentials', () => {
  const original = JSON.stringify(page.savedConnections);
  for (const mode of ['id','name','online']) { page.setSavedConnectionSort(mode); ids(''); ids('g'); }
  assert.equal(JSON.stringify(page.savedConnections), original);
});
test('preference survives new page instance and storage failure is safe', () => {
  page.setSavedConnectionSort('online');
  const next = new context.Page(); next.loadSavedConnectionSort(); assert.equal(next.savedConnectionSort,'online');
  storageFails=true; next.loadSavedConnectionSort(); assert.equal(next.savedConnectionSort,'id');
});
test('equal display name and remote ID have a deterministic final tie breaker', () => {
  page.savedConnectionSort='name';
  assert(page.compareSavedConnections(item('a','123','PC'), item('b','123','pc')) < 0);
  assert.equal(page.compareSavedConnections(item('a','123','PC'), item('a','123','PC')), 0);
});
console.log(`${passed} sorting checks passed`);
