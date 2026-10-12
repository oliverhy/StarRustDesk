'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const read=p=>fs.readFileSync(path.resolve(__dirname,'..',p),'utf8');
const source=read('entry/src/main/ets/pages/ConnectionPage.ets');
const editor=read('entry/src/main/ets/widget/SavedConnectionEditorDialog.ets');
const slice=(start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
const ui=slice('  buildPasswordInput()','  @Builder\n  buildSavedConnections');
assert(ui.includes("Text(translate('密码已保存', this.uiLanguage))"));
assert(ui.includes('更多 → 修改连接'));assert(ui.includes('.showPasswordIcon(true)'));
assert(editor.includes("this.smallAction('更换'")&&editor.includes("this.smallAction('清除'"));
assert(editor.includes('保存后生效'));
assert(!source.includes('this.password = item.password'));
assert(!slice('  editSavedConnection(', '  closeConnectionEditor(').includes('item.password,'));
assert(editor.includes("password: string = ''"));
assert(editor.includes("osPassword: string = ''"));
assert(editor.includes("this.password = ''")&&editor.includes("this.osPassword = ''"));
assert.match(source,/SavedConnectionEditing\.endpoint\(item\.remoteId\) === SavedConnectionEditing\.endpoint\(peerId\)/);
assert.match(source,/SavedConnectionEditing\.sameNetwork\(item\.serverScope, this\.currentConnectionScope\(\)\)/);
assert.match(source,/password: includesPasswords \? item\.password : ''/);
assert.doesNotMatch(slice('  buildBackupPayload(', '  async saveBackupFile('), /osPassword|RemoteSecurityStore/);
assert(!slice('  async confirmConnectionPassword(', '  closeBackupDialogs(').includes('this.password = password'));
assert(editor.includes("this.passwordMode === 'replace' && this.password.trim().length === 0"));
assert(source.includes('Credential verification failed'));
assert(source.includes('OS credential verification failed'));
// Runtime keep/replace/clear, identity isolation, rollback, cancellation and pending-password
// cases run against production methods in test-saved-connection-editing.cjs.
console.log('PASS password privacy: no secret refill, endpoint/network matching, isolated editor, staged changes, verified writes and secret-free backups');
