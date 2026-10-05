'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH ||
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8');
function slice(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a);
  assert(a >= 0 && b > a, `production methods found: ${start}`);
  return source.slice(a, b);
}
const methods = slice('  openRenameConnectionDialog(', '  openNewGroupDialog(') +
  slice('  persistSavedConnections(', '  refreshSavedConnectionOnlineStates(') +
  source.slice(source.indexOf('  cloneSavedConnections('), source.lastIndexOf('\n}'));
const result = ts.transpileModule(`class Page { ${methods} } globalThis.Page = Page;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal((result.diagnostics || []).length, 0);
const row = (id, name) => ({ id, name, remoteId: id === 'a' ? '123456789' : '987654321',
  password: `test-secret-${id}`, performancePreset: 'balanced', groupId: 'work' });
function fixture() {
  const writes = [], logs = [];
  let dirty = 0, tips = 0, failSave = false;
  const context = vm.createContext({
    RustDeskNapi: {
      setOption: (key, value) => {
        if (failSave) throw Error('storage unavailable');
        writes.push([key, value]); return 0;
      },
      appendDiagnosticLog: (scope, message) => logs.push([scope, message])
    },
    CloudSyncService: { markLocalChanged: () => dirty++ }
    // No CredentialStore or connection methods: renaming must never call them.
  });
  vm.runInContext(result.outputText, context);
  const page = Object.assign(new context.Page(), {
    savedConnections: [row('a', 'Office'), row('b', 'Home')], savedConnectionsVersion: 0,
    savingConnection: false, showRenameConnectionDialog: false, renamingConnectionId: '',
    connectionNameDraft: '', connectionNameError: '', selectedConnectionId: 'a', connectionName: 'Office',
    remoteId: 'editor-id', password: 'editor-password', passwordEditMode: 'replace', selectedGroupId: 'draft-group',
    peerOnlineStates: { '123456789': 1 }, nextPeerOnlineRefreshAt: 12345
  });
  page.closeAllDialogs = () => page.closeRenameConnectionDialog();
  page.showSavedTip = () => tips++;
  return { page, writes, logs, get dirty() { return dirty; }, get tips() { return tips; },
    fail: () => { failSave = true; }, recover: () => { failSave = false; } };
}
let count = 0;
function test(name, fn) { fn(); count++; console.log('PASS ' + name); }
test('opens a name-only dialog populated from the chosen connection', () => {
  const f = fixture(), p = f.page;
  p.openRenameConnectionDialog('a');
  assert.equal(p.showRenameConnectionDialog, true);
  assert.equal(p.renamingConnectionId, 'a');
  assert.equal(p.connectionNameDraft, 'Office');
  assert.equal(p.connectionNameError, '');
  assert.equal(p.remoteId, 'editor-id');
  assert.equal(p.password, 'editor-password');
  assert.equal(p.selectedGroupId, 'draft-group');
  assert.equal(f.writes.length, 0);
});
test('rename changes only the selected name and updates persistence/cloud revision', () => {
  const f = fixture(), p = f.page;
  const original = JSON.stringify(p.savedConnections), rows = p.savedConnections;
  const next = JSON.parse(original); next[0].name = 'New Office';
  p.openRenameConnectionDialog('a'); p.connectionNameDraft = '  New Office  '; p.saveConnectionName();
  assert.equal(JSON.stringify(p.savedConnections), JSON.stringify(next));
  assert.equal(JSON.stringify(rows), original, 'previous rows are not mutated');
  assert.equal(p.connectionName, 'New Office');
  assert.equal(p.savedConnectionsVersion, 1);
  assert.equal(p.showRenameConnectionDialog, false);
  assert.equal(p.renamingConnectionId, '');
  assert.equal(f.dirty, 1); assert.equal(f.tips, 1);
  assert.equal(f.writes[0][0], 'saved-connections');
  const stored = JSON.parse(f.writes[0][1]);
  assert.equal(stored[0].name, 'New Office');
  assert.equal(stored[0].credentialAlias, 'a');
  assert(!stored.some(item => 'password' in item), 'secrets stay out of serialized rows');
  assert.equal(p.peerOnlineStates['123456789'], 1);
  assert.equal(p.nextPeerOnlineRefreshAt, 12345, 'rename does not start another network query');
  assert(!JSON.stringify(f.logs).includes('Office'), 'diagnostics do not record names');
});
test('cancel or backdrop close does not change anything', () => {
  const f = fixture(), p = f.page, original = JSON.stringify(p.savedConnections);
  p.openRenameConnectionDialog('a'); p.connectionNameDraft = 'Changed'; p.closeRenameConnectionDialog();
  p.saveConnectionName();
  assert.equal(JSON.stringify(p.savedConnections), original);
  assert.equal(f.writes.length, 0); assert.equal(f.dirty, 0);
  assert.equal(p.connectionNameDraft, ''); assert.equal(p.connectionNameError, '');
});
test('empty and whitespace-only names are rejected without closing', () => {
  for (const value of ['', ' \t\n ']) {
    const f = fixture(), p = f.page;
    p.openRenameConnectionDialog('a'); p.connectionNameDraft = value; p.saveConnectionName();
    assert.equal(p.connectionNameError, '连接名称不能为空');
    assert.equal(p.showRenameConnectionDialog, true); assert.equal(f.writes.length, 0);
  }
});
test('unchanged name is a no-op without a write or cloud upload', () => {
  const f = fixture(), p = f.page;
  p.openRenameConnectionDialog('a'); p.connectionNameDraft = ' Office '; p.saveConnectionName();
  assert.equal(p.showRenameConnectionDialog, false);
  assert.equal(f.writes.length, 0); assert.equal(f.dirty, 0); assert.equal(f.tips, 0);
});
test('names may be equal; updates target the immutable local ID', () => {
  const f = fixture(), p = f.page;
  p.openRenameConnectionDialog('b'); p.connectionNameDraft = 'Office'; p.saveConnectionName();
  assert.equal(p.savedConnections[0].name, 'Office'); assert.equal(p.savedConnections[1].name, 'Office');
  assert.equal(p.savedConnections[1].remoteId, '987654321');
  assert.equal(p.connectionName, 'Office', 'another selected editor is unchanged');
});
test('an unsaved editor name is not overwritten', () => {
  const f = fixture(), p = f.page;
  p.connectionName = 'Unsaved editor draft';
  p.openRenameConnectionDialog('a'); p.connectionNameDraft = 'Saved name'; p.saveConnectionName();
  assert.equal(p.connectionName, 'Unsaved editor draft');
  assert.equal(p.passwordEditMode, 'replace'); assert.equal(p.password, 'editor-password');
});
test('uses latest rows when group or credentials change while dialog is open', () => {
  const f = fixture(), p = f.page;
  p.openRenameConnectionDialog('a'); p.connectionNameDraft = 'Renamed';
  p.savedConnections[0].groupId = 'new-group';
  p.savedConnections[0].password = 'new-test-secret';
  p.savedConnections.push(row('c', 'Third'));
  p.saveConnectionName();
  assert.equal(p.savedConnections.length, 3);
  assert.equal(p.savedConnections[0].groupId, 'new-group');
  assert.equal(p.savedConnections[0].password, 'new-test-secret');
});
test('deleted connections cannot be recreated accidentally', () => {
  const f = fixture(), p = f.page;
  p.openRenameConnectionDialog('missing'); assert.equal(p.showRenameConnectionDialog, false);
  p.openRenameConnectionDialog('a'); p.connectionNameDraft = 'Changed';
  p.savedConnections = p.savedConnections.filter(item => item.id !== 'a'); p.saveConnectionName();
  assert.equal(p.connectionNameError, '此连接已不存在，请关闭后重试');
  assert.equal(p.savedConnections.length, 1); assert.equal(f.writes.length, 0);
});
test('failed persistence keeps original rows and dialog for retry', () => {
  const f = fixture(), p = f.page, original = JSON.stringify(p.savedConnections);
  p.openRenameConnectionDialog('a'); p.connectionNameDraft = 'Retry name'; f.fail(); p.saveConnectionName();
  assert.equal(JSON.stringify(p.savedConnections), original);
  assert.equal(p.connectionName, 'Office'); assert.equal(p.savedConnectionsVersion, 0);
  assert.equal(p.showRenameConnectionDialog, true); assert.equal(p.connectionNameError, '保存失败，请重试');
  assert.equal(f.dirty, 0); assert.equal(f.tips, 0);
  f.recover(); p.saveConnectionName(); assert.equal(p.savedConnections[0].name, 'Retry name');
});
test('full save in progress blocks rename to avoid stale overwrite', () => {
  const f = fixture(), p = f.page;
  p.savingConnection = true; p.openRenameConnectionDialog('a');
  assert.equal(p.showRenameConnectionDialog, false);
  p.savingConnection = false; p.openRenameConnectionDialog('a');
  p.savingConnection = true; p.connectionNameDraft = 'Blocked'; p.saveConnectionName();
  assert.equal(p.savedConnections[0].name, 'Office'); assert.equal(f.writes.length, 0);
});
test('more menu and dialog dismiss/validation use the existing UI style', () => {
  assert.match(source, /value: translate\('重命名', this\.uiLanguage\)[\s\S]*?openRenameConnectionDialog\(item\.id\)/);
  assert.match(source, /if \(this\.showRenameConnectionDialog\) \{\s*this\.buildRenameConnectionDialog\(\)/);
  assert.match(source, /closeAllDialogs\(\): void \{\s*this\.closeRenameConnectionDialog\(\)/);
  const dialog = slice('  buildRenameConnectionDialog()', '  @Builder\n  buildGroupNameDialog()');
  assert(dialog.includes("text: this.connectionNameDraft"));
  assert(dialog.includes('this.connectionNameError'));
  assert(dialog.includes('this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD'));
  assert.equal((dialog.match(/new ButtonShapeModifier/g) || []).length, 2);
});
console.log(`Saved connection rename: ${count} checks passed.`);
