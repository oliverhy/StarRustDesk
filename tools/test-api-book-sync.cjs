const fs = require('node:fs'), vm = require('node:vm'), path = require('node:path'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const options = new Map(); let writes = 0, imports = 0;
const native = { getOption: k => options.get(k) || '', setOption: (k,v) => options.set(k,v), appendDiagnosticLog() {} };
const context = { exports: {}, AppStorage: { get:()=>0,setOrCreate(){} }, require: name => {
  if (name === './RustDeskApiService') {
    const module = { exports: {}, require: context.require };
    const service = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/service/RustDeskApiService.ets'), 'utf8');
    vm.runInNewContext(ts.transpileModule(service, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText, module);
    return module.exports;
  }
  if (name === '@kit.RemoteCommunicationKit') return { rcp: {} };
  if (name === '@kit.ArkTS') return { url: { URL }, util: {} };
  if (name === './ApiAccountStore') return { ApiAccountStore: {} };
  if (name === './RustDeskNapi') return { RustDeskNapi: native };
  if (name === './OperationDiagnostic') {
    const module = { exports: {}, require: context.require };
    const helper = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/service/OperationDiagnostic.ets'), 'utf8');
    vm.runInNewContext(ts.transpileModule(helper, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText, module);
    return module.exports;
  }
  if (name === './CloudSyncService') return { CloudSyncService:{markLocalChanged(){}} };
  if (name === './ApiAddressBookImport') return { ApiAddressBookImport: { importSelected(book,peers) {
    imports++; const rows = JSON.parse(native.getOption('saved-connections') || '[]');
    peers.forEach(p => { if (!rows.some(r=>r.remoteId===p.id)) rows.push({remoteId:p.id,name:p.name}); });
    native.setOption('saved-connections',JSON.stringify(rows));
  } } };
  throw Error(name);
} };
const source = fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/service/ApiBookSync.ets'),'utf8');
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,context);
const S=context.exports.ApiBookSync, p=(id,name=id,tags=[])=>({id,name,tags,platform:''});
const kinds=(b,l,r)=>Array.from(S.diff(b,l,r),v=>v.kind);
assert.deepEqual(kinds([], [p('1')], []),['upload']);
assert.deepEqual(kinds([], [], [p('1')]),['download']);
assert.deepEqual(kinds([p('1')], [], [p('1')]),['deleteRemote']);
assert.deepEqual(kinds([p('1')], [p('1')], []),['deleteLocal']);
assert.deepEqual(kinds([p('1')], [p('1','local')], [p('1','remote')]),['conflict']);
assert.deepEqual(kinds([], [p('1','same',['a','b'])], [p('1','same',['b','a'])]),[]);
let remote=[], revision=0;
const api={server:'https://example.test',username:'test',sessionRevision:()=>revision,
  peers:async()=>remote.map(v=>({...v,tags:[...v.tags]})),writePeer:async(book,peer)=>{writes++;remote=remote.filter(p=>p.id!==peer.id).concat(peer);},
  deletePeer:async(book,id)=>{writes++;remote=remote.filter(p=>p.id!==id);} };
const book={guid:'book',name:'book',legacy:false,writable:true};
(async()=>{
  native.setOption('saved-connections',JSON.stringify([{remoteId:'1',name:'first',credentialAlias:'local-secret',groupId:'keep'}]));
  let plan=await S.preview(api,book); assert.equal(writes,0,'preview never writes remote');
  await S.apply(api,book,plan,false); assert.equal(writes,1); assert.equal(remote[0].credentialAlias,undefined);
  remote=[p('1','renamed'),p('2')]; plan=await S.preview(api,book); await S.apply(api,book,plan,false);
  let rows=JSON.parse(native.getOption('saved-connections'));assert.equal(rows[0].name,'renamed');assert.equal(rows[0].credentialAlias,'local-secret');assert.equal(rows[0].groupId,'keep');
  remote=[p('2')]; plan=await S.preview(api,book);assert(plan.changes.some(c=>c.kind==='deleteLocal'));await S.apply(api,book,plan,false);
  assert.equal(JSON.parse(native.getOption('saved-connections')).length,1);
  plan=await S.preview(api,book);revision++;await assert.rejects(S.apply(api,book,plan,false),/变化/);
  plan=await S.preview(api,book);remote.push(p('3'));await assert.rejects(S.apply(api,book,plan,false),/服务器数据/);
  native.setOption('saved-connections',JSON.stringify([{remoteId:'4',name:'new'}])); plan=await S.preview(api,book);
  const before=writes;await assert.rejects(S.apply(api,{...book,writable:false},plan,true),/只读/);assert.equal(writes,before);
  const baseline = native.getOption(S.key(api, book));
  const broken = { ...api, writePeer: async () => {} };
  await assert.rejects(S.apply(broken, book, plan, true), /未完整保存|又有修改/);
  assert.equal(native.getOption(S.key(api, book)), baseline, 'a false success must never advance the sync baseline');
  console.log('PASS book sync: three-way diff, explicit preview, conflict, deletion, credential preservation, account/data race and read-only preflight');
})().catch(e=>{console.error(e);process.exitCode=1;});
