'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.resolve(__dirname,
  '../entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8').replace(/\r\n/g, '\n');
function method(name) {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const compiled = ts.transpileModule('class Page {' + [
  'requestDeleteConnectionGroup', 'deleteConnectionGroup', 'persistConnectionGroups',
  'cloneConnectionGroups', 'persistSavedConnections', 'cloneSavedConnections'
].map(method).join('\n') + '} globalThis.Page = Page;', {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(compiled.diagnostics.length, 0);
const makeRow = (id, groupId) => ({ id, groupId, name: 'Host-' + id,
  remoteId: '12345' + id, password: 'test-secret-' + id, performancePreset: 'balanced' });
function fixture() {
  const disk = new Map(), writes = [], logs = [], tips = [], snapshots = [];
  let failKey = '', dialog, closed = 0;
  const context = vm.createContext({
    RustDeskNapi: {
      setOption(key, value) {
        if (key === failKey) throw Error('storage unavailable');
        disk.set(key, value); writes.push([key, value]); return 0;
      }, appendDiagnosticLog: (...args) => logs.push(args)
    }, CloudSyncService: { markLocalChanged() {
      snapshots.push({ groups: disk.get('saved-connection-groups'), rows: disk.get('saved-connections') });
    } }, promptAction: { showToast: ({message}) => tips.push(message) },
    translate: value => value, RustDeskTheme: { ERROR: 'red' }
    // No credential or remote-security store: deleting a group must never call them.
  });
  vm.runInContext(compiled.outputText, context);
  const page = Object.assign(new context.Page(), {
    connectionGroups: [{id:'work',name:'Work',expanded:false}, {id:'home',name:'Home',expanded:true}],
    savedConnections: [makeRow('a','work'),makeRow('b','home'),makeRow('c','work'),makeRow('d','')],
    selectedGroupId:'work', selectedConnectionId:'a', savedConnectionsVersion:0,
    savedConnectionSearch:'Host-a', ungroupedExpanded:false, savingConnection:false,
    connectionName:'user draft', remoteId:'draft-id', password:'draft-password',
    osPasswordDraft:'draft-os-password', uiLanguage:'zh-Hans',
    savedConnectionSort:'name', savedConnectionSortAscending:false,
    getUIContext: () => ({showAlertDialog: options => {dialog=options;}}),
    closeAllDialogs: () => {closed++;}
  });
  // Initialize native storage using the production serialization paths.
  page.persistSavedConnections(page.savedConnections,false); page.persistConnectionGroups(page.connectionGroups,false);
  writes.length=0;
  return {page,disk,writes,logs,tips,snapshots,get dialog(){return dialog;},get closed(){return closed;},
    fail: key => {failKey=key;}};
}
let checks=0;
function test(name, fn){fn();checks++;console.log('PASS '+name);}
test('group menu exposes a delete confirmation rather than immediate deletion', () => {
  const group = source.slice(source.indexOf('  buildSavedConnectionGroup('),source.indexOf('\n  buildGroupNameDialog('));
  assert(group.includes("value: translate('删除分组', this.uiLanguage)"));
  assert(group.includes('this.requestDeleteConnectionGroup(groupId)'));
  const f=fixture(), before=JSON.stringify(f.page.savedConnections);
  f.page.requestDeleteConnectionGroup('work');
  assert.equal(f.dialog.title,'删除分组'); assert(f.dialog.message.includes('Work'));
  assert(f.dialog.message.includes('密码不会删除')); assert.equal(f.closed,1);
  assert.equal(f.writes.length,0); f.dialog.primaryButton.action();
  assert.equal(JSON.stringify(f.page.savedConnections),before); assert.equal(f.snapshots.length,0);
});
test('confirmation moves all members, including search-hidden rows, and preserves secrets and editor drafts', () => {
  const f=fixture(), p=f.page, before=JSON.parse(JSON.stringify(p.savedConnections));
  p.requestDeleteConnectionGroup('work'); f.dialog.secondaryButton.action();
  before[0].groupId=''; before[2].groupId='';
  assert.deepEqual(JSON.parse(JSON.stringify(p.savedConnections)),before);
  assert.deepEqual(Array.from(p.connectionGroups,g=>g.id),['home']);
  assert.equal(p.selectedGroupId,''); assert.equal(p.selectedConnectionId,'a');
  assert.equal(p.ungroupedExpanded,true); assert.equal(p.savedConnectionsVersion,1);
  assert.equal(p.connectionName,'user draft'); assert.equal(p.password,'draft-password');
  assert.equal(p.osPasswordDraft,'draft-os-password'); assert.equal(p.remoteId,'draft-id');
  assert.equal(p.savedConnectionSort,'name'); assert.equal(p.savedConnectionSortAscending,false);
  assert.equal(f.snapshots.length,1);
  const stored=JSON.parse(f.disk.get('saved-connections'));
  assert.equal(stored[0].credentialAlias,'a'); assert.equal(stored[2].credentialAlias,'c');
  assert(stored.every(row=>!('password' in row)));
  assert(!JSON.stringify(f.logs).includes('test-secret') && !JSON.stringify(f.logs).includes('Work'));
});
test('empty and last named groups can be deleted without touching connection storage', () => {
  const f=fixture(), p=f.page;
  p.connectionGroups=[{id:'empty',name:'Empty',expanded:true}]; p.savedConnections=[]; p.selectedGroupId='empty';
  assert.equal(p.deleteConnectionGroup('empty'),true);
  assert.equal(p.connectionGroups.length,0); assert.equal(p.savedConnections.length,0); assert.equal(p.selectedGroupId,'');
  assert.equal(f.writes.some(([key])=>key==='saved-connections'),false);
});
test('built-in ungrouped, missing groups and repeated confirmation never delete data', () => {
  const f=fixture(), p=f.page;
  for(const id of ['', 'missing']) {p.requestDeleteConnectionGroup(id); assert.equal(p.deleteConnectionGroup(id),false);}
  assert.equal(f.dialog,undefined); assert.equal(f.writes.length,0);
  assert.equal(p.deleteConnectionGroup('work'),true); const count=f.writes.length;
  assert.equal(p.deleteConnectionGroup('work'),false); assert.equal(f.writes.length,count);
});
test('confirmation uses current rows, not the rows captured when the menu opened', () => {
  const f=fixture(), p=f.page; p.requestDeleteConnectionGroup('work');
  p.savedConnections[0].groupId='home'; p.savedConnections[2].password='updated-test-secret';
  p.savedConnections.push(makeRow('new','work'));
  f.dialog.secondaryButton.action();
  assert.equal(p.savedConnections[0].groupId,'home'); assert.equal(p.savedConnections[2].password,'updated-test-secret');
  assert.equal(p.savedConnections.at(-1).groupId,'');
});
test('persistence can be reloaded with no removed-group references and one coherent cloud snapshot', () => {
  const f=fixture(); f.page.deleteConnectionGroup('work');
  const groups=JSON.parse(f.disk.get('saved-connection-groups'));
  const rows=JSON.parse(f.disk.get('saved-connections'));
  assert(groups.every(g=>g.id!=='work')); assert(rows.every(r=>r.groupId!=='work'));
  assert.equal(f.writes[0][0],'saved-connections'); assert.equal(f.writes[1][0],'saved-connection-groups');
  assert.equal(f.snapshots.length,1);
  assert.equal(f.snapshots[0].groups,f.disk.get('saved-connection-groups'));
  assert.equal(f.snapshots[0].rows,f.disk.get('saved-connections'));
});
test('first save failure preserves groups, member assignments, editor selection and cloud state', () => {
  const f=fixture(), p=f.page, before=JSON.stringify([p.connectionGroups,p.savedConnections]);
  f.fail('saved-connections'); assert.equal(p.deleteConnectionGroup('work'),false);
  assert.equal(JSON.stringify([p.connectionGroups,p.savedConnections]),before);
  assert.equal(p.selectedGroupId,'work'); assert.equal(f.snapshots.length,0);
  assert.equal(f.tips.at(-1),'删除分组失败，请重试');
});
test('partial save keeps moved connections and the group, reports the failure and safely retries', () => {
  const f=fixture(), p=f.page;
  f.fail('saved-connection-groups'); assert.equal(p.deleteConnectionGroup('work'),false);
  assert(p.connectionGroups.some(g=>g.id==='work'));
  assert(p.savedConnections.every(r=>r.groupId!=='work')); assert.equal(p.selectedGroupId,'');
  assert.equal(f.tips.at(-1),'连接已移到未分组，但删除分组失败，请重试');
  assert.equal(f.snapshots.length,1); f.fail(''); assert.equal(p.deleteConnectionGroup('work'),true);
  assert.equal(p.savedConnections.length,4); assert(p.savedConnections.every(r=>r.password.startsWith('test-secret-')));
});
test('in-flight connection saving disables destructive group actions', () => {
  const f=fixture(); f.page.savingConnection=true;
  f.page.requestDeleteConnectionGroup('work'); assert.equal(f.dialog,undefined);
  assert.equal(f.page.deleteConnectionGroup('work'),false); assert.equal(f.writes.length,0);
});
console.log(`TOTAL=${checks} FAILED=0 (production group deletion, persistence and cloud marking; device UI acceptance pending)`);
