const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const read = name => fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/widget', name), 'utf8');
const dialog = read('ApiAccountDialog.ets');
const action = read('ApiAccountAction.ets');
// Builder value parameters captured the initial busy=true state on-device.
// Every stateful button must instead receive reactive component props.
assert(!dialog.includes('this.action('));
for (const prop of ['label: string', 'selected: boolean', 'isEnabled: boolean']) {
  assert(action.includes('@Prop ' + prop), prop);
}
assert(action.includes('.enabled(this.isEnabled)'));
assert(action.includes('Button(translate(this.label, this.uiLanguage))'));
assert(action.includes('if (this.isEnabled) this.onAction()'));
assert.equal((dialog.match(/ApiAccountAction\(\{/g) || []).length, 17);
assert(dialog.includes("label: this.busy ? '取消请求' : '关闭'"));
assert(dialog.includes("label: '登录', selected: true, isEnabled: !this.busy"));
assert(dialog.includes('isEnabled: !this.busy && this.selected.length > 0'));
// ArkUI can emit onChange when select() changes programmatically. Replaying
// that notification must not invert the selection again or trigger a loop.
const checkbox = dialog.match(/Checkbox\(\{ name: peer\.id \}\)[\s\S]*?\.onChange\(\(value: boolean\) => \{([\s\S]*?)\}\)/);
assert(checkbox, 'address-book checkbox handler must be covered');
const makeHandler = vm.runInNewContext(`(function(peer) { return function(value) { ${checkbox[1]} }; })`);
const state = { selected: [], changes: 0, toggle(id) {
  this.changes++;
  this.selected = this.selected.includes(id) ? this.selected.filter(v => v !== id) : this.selected.concat(id);
} };
const notify = makeHandler({ id: 'device' }).bind(state);
state.selected = ['device']; notify(true); assert.equal(state.changes, 0, 'select-all does not toggle back');
notify(false); assert.equal(state.changes, 1); assert.deepEqual(state.selected, []);
notify(false); assert.equal(state.changes, 1, 'state-driven uncheck is idempotent');
notify(true); assert.equal(state.changes, 2); assert.deepEqual(state.selected, ['device']);
console.log('PASS account buttons: reactive labels, selected state, enablement and click guard on all 17 actions');
