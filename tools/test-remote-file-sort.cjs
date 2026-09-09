const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/utils/RemoteFileSort.ets'), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const exportsObject = {};
new Function('exports', js)(exportsObject);
const sort = exportsObject.sortRemoteFiles;
const file = (name, size, modifiedTime, entryType = 1) => ({ name, size, modifiedTime, entryType });
const entries = [file('文件10.txt', 10, 30), file('z-folder', 999, 40, 0),
  file('文件2.txt', 20, 10), file('a.jpg', 30, 20)];
const original = JSON.stringify(entries);
const ascendingNames = sort(entries, 'name', false).map(x => x.name);
const descendingNames = sort(entries, 'name', true).map(x => x.name);
assert.equal(ascendingNames[0], 'z-folder');
assert.equal(descendingNames[0], 'z-folder');
assert(ascendingNames.indexOf('文件2.txt') < ascendingNames.indexOf('文件10.txt'));
assert.deepEqual(descendingNames.slice(1), ascendingNames.slice(1).reverse());
assert.deepEqual(sort(entries, 'size', false).map(x => x.size), [999, 10, 20, 30]);
assert.deepEqual(sort(entries, 'size', true).map(x => x.size), [999, 30, 20, 10]);
assert.deepEqual(sort(entries, 'modified', false).map(x => x.modifiedTime), [40, 10, 20, 30]);
assert.deepEqual(sort(entries, 'modified', true).map(x => x.modifiedTime), [40, 30, 20, 10]);
assert.equal(sort(entries, 'type', false)[1].name, 'a.jpg');
assert.equal(sort(entries, 'type', true).at(-1).name, 'a.jpg');
assert.equal(JSON.stringify(entries), original, 'Sorting must not mutate native entries or selected objects');
assert.equal(sort(entries, 'name', false)[0], entries[1]);
assert.deepEqual(sort([], 'name', false), []);
for (const kind of [0, 2, 3]) {
  assert.equal(sort([file('a', 0, 0), file('z', 0, 0, kind)], 'name', true)[0].entryType, kind);
}
assert.deepEqual(sort([file('.hidden', 0, 0), file('x.TXT', 0, 0), file('x.jpg', 0, 0)], 'type', false)
  .map(x => x.name), ['.hidden', 'x.jpg', 'x.TXT']);
console.log('PASS remote file sorting: four fields, both directions, folders first, natural names, non-mutation');
