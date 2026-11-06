// Exercise the actual ArkTS scope/expiry and persistence logic with fake platform services.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
let now = 1800000000000, raw = '', failFlush = false, pauseHash;
const db = {
  getSync: (_key, fallback) => raw || fallback,
  putSync: (_key, value) => { raw = value; },
  clearSync: () => { raw = ''; },
  flush: async () => { if (failFlush) { failFlush = false; throw new Error('test flush failure'); } },
};
const fakePrefs = { getPreferencesSync: () => db };
const fakeCrypto = { createMd: () => {
  const hash = crypto.createHash('sha256');
  return { update: async ({data}) => { if (pauseHash) await pauseHash; hash.update(Buffer.from(data)); },
    digest: async () => ({data: new Uint8Array(hash.digest())}) };
}};
const fakeUtil = { TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text, 'utf8')); } } };
function moduleFor(file, dependencies) {
  const js = ts.transpileModule(read(file), {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
  const module = {exports:{}};
  const sandbox = { module, exports:module.exports, require:name => {
    if (!(name in dependencies)) throw new Error(`unexpected import ${name}`);
    return dependencies[name];
  }, Date:class extends Date { static now(){ return now; } }, Uint8Array, Promise, console };
  vm.runInNewContext(js, sandbox, {filename:file});
  return module.exports;
}
const model = moduleFor('entry/src/main/ets/model/InsecureConsent.ets', {});
function loadStore() {
  return moduleFor('entry/src/main/ets/service/InsecureConsentStore.ets', {
    '@kit.ArkData':{preferences:fakePrefs}, '@kit.CryptoArchitectureKit':{cryptoFramework:fakeCrypto},
    '@kit.ArkTS':{util:fakeUtil}, '../model/InsecureConsent':model,
  }).InsecureConsentStore;
}
let Store=loadStore(), passed=0;
const ctx={}, scope={peer:'PRIVATE_PEER_ID',network:'PRIVATE_SERVER_AND_KEY',reason:2,generation:1};
async function test(name, fn){ await fn(); passed++; console.log(`PASS ${name}`); }
function pageSubject(mocks) {
  const source=read('entry/src/main/ets/pages/RemotePage.ets');
  const start=source.indexOf('  async checkInsecureFallback():'), end=source.indexOf('  async retrySession(',start);
  assert(start>=0 && end>start);
  const code=ts.transpileModule(`class Subject { ${source.slice(start,end)} } globalThis.Subject=Subject;`,
    {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText;
  const context=vm.createContext(mocks); vm.runInContext(code,context); return context.Subject;
}
(async()=>{
  await test('no opt-in means no persistent permission',async()=>{
    assert.equal(await Store.has(ctx,scope),false);
    assert.equal(await Store.remember(ctx,scope,()=>false),false);
    assert.equal(raw,'');
  });
  await test('one explicit permission persists without exposing scope values',async()=>{
    assert.equal(await Store.remember(ctx,scope,()=>true),true);
    assert.equal(await Store.has(ctx,scope),true);
    assert(!raw.includes(scope.peer)); assert(!raw.includes(scope.network));
    const records=JSON.parse(raw); assert.equal(records.length,1);
    assert.match(records[0].fingerprint,/^[0-9a-f]{64}$/);
    assert.equal(records[0].expiresAt-records[0].issuedAt,7*24*60*60*1000);
    Store=loadStore(); assert.equal(await Store.has(ctx,scope),true);
  });
  await test('peer, server/key and risk type cannot reuse another permission',async()=>{
    assert.equal(await Store.has(ctx,{...scope,peer:'different'}),false);
    assert.equal(await Store.has(ctx,{...scope,network:'different-server-or-key'}),false);
    assert.equal(await Store.has(ctx,{...scope,reason:1}),false);
    assert.equal(await Store.has(ctx,{...scope,reason:3}),false);
    assert.equal(await Store.has(ctx,{...scope,generation:99}),true);
  });
  await test('permission expires exactly after seven days and does not renew on use',async()=>{
    const issued=now; now=issued+7*24*60*60*1000-1;
    assert.equal(await Store.has(ctx,scope),true);
    now++; assert.equal(await Store.has(ctx,scope),false);
    now=issued-1; assert.equal(await Store.has(ctx,scope),false);
    now=issued;
  });
  await test('malformed, oversized or forged durations fail closed',async()=>{
    const previous=raw;
    for(const invalid of ['{broken',JSON.stringify([{fingerprint:'x',issuedAt:now,expiresAt:now+9}]),'x'.repeat(16001)]){
      raw=invalid; assert.equal(await Store.has(ctx,scope),false);
    }
    raw=previous;
  });
  await test('failed persistence cannot create an in-memory permission',async()=>{
    const other={...scope,peer:'other-private-peer'}; failFlush=true;
    assert.equal(await Store.remember(ctx,other,()=>true),false);
    assert.equal(await Store.has(ctx,other),false);
    assert.equal(await Store.has(ctx,scope),true);
  });
  await test('clear removes permissions and pending saves cannot undo it',async()=>{
    let release; pauseHash=new Promise(resolve=>{release=resolve;});
    const save=Store.remember(ctx,{...scope,peer:'pending'},()=>true);
    await Promise.resolve();
    const clear=Store.clear(ctx); release(); pauseHash=undefined;
    assert.equal(await save,false); assert.equal(await clear,true);
    assert.equal(await Store.has(ctx,scope),false);
    assert.equal(await Store.has(ctx,{...scope,peer:'pending'}),false);
  });
  await test('dialog starts unchecked and cancel cannot save a permission',async()=>{
    const widget=read('entry/src/main/ets/widget/InsecureConnectionDialog.ets');
    assert.match(widget,/@State remember: boolean = false/);
    assert.match(widget,/aboutToAppear\(\): void \{ this\.remember = false/);
    assert.match(widget,/7天内不再提醒/);
    assert.match(widget,/this\.controller\?\.close\(\); this\.onCancel\(\)/);
    assert.match(widget,/this\.onContinue\(selected\)/);
  });
  await test('remembered permission is consulted only after a failed secure attempt',async()=>{
    const page=read('entry/src/main/ets/pages/RemotePage.ets');
    const failed=page.slice(page.indexOf('} else if (status === ConnectionStatus.FAILED) {',page.indexOf('startPolling():')),
      page.indexOf('if (status === ConnectionStatus.CONNECTED && !this.fileOnly',page.indexOf('startPolling():')));
    assert.match(failed,/ConnectionService\.canRetryWithoutEncryption\(\)/);
    assert.match(failed,/this\.checkInsecureFallback\(\)/);
    const cpp=read('entry/src/main/cpp/napi_init.cpp');
    assert.match(cpp,/if \(!allowInsecureFallback \|\| insecureReason < 1 \|\| insecureReason > 3\) insecureReason = 0/);
    assert.match(cpp,/insecureReason, fileOnly \? 1 : 0/);
  });
  await test('auto retry uses only the captured reason and stale lookups cannot connect',async()=>{
    let current=true, trusted=true, retries=[], prompts=0;
    const connection={insecureConsentScope:()=>scope,isInsecureConsentScopeCurrent:()=>current,
      retryWithoutEncryption:(reason,remembered)=>{retries.push([reason,remembered]);return true;}};
    const Page=pageSubject({ConnectionService:connection,InsecureConsentStore:{has:async()=>trusted},
      RustDeskNapi:{appendDiagnosticLog:()=>{}},getContext:()=>ctx,ConnectionStatus:{CONNECTING:1,FAILED:3}});
    const page=Object.assign(new Page(),{remotePageVisible:true,isLeavingAfterDisconnect:false,
      insecureFallbackPromptShown:true,showInsecureFallbackPrompt:()=>{prompts++;}});
    await page.checkInsecureFallback(); assert.deepEqual(retries,[[2,true]]); assert.equal(prompts,0);
    retries=[]; trusted=false; await page.checkInsecureFallback(); assert.equal(prompts,1); assert.equal(retries.length,0);
    current=false; trusted=true; await page.checkInsecureFallback(); assert.equal(retries.length,0);
    assert.equal(page.insecureFallbackPromptShown,false);
  });
  await test('explicit cancel or unchecked continuation never stores a grant',async()=>{
    let saves=0, retries=0, current=true;
    const connection={isInsecureConsentScopeCurrent:()=>current,retryWithoutEncryption:()=>{retries++;return true;}};
    const Page=pageSubject({ConnectionService:connection,InsecureConsentStore:{remember:async()=>{saves++;return true;}},
      RustDeskNapi:{appendDiagnosticLog:()=>{}},getContext:()=>ctx,ConnectionStatus:{CONNECTING:1,FAILED:3}});
    const page=Object.assign(new Page(),{remotePageVisible:true,isLeavingAfterDisconnect:false,showFileToast:()=>{}});
    await page.acceptInsecureConnection(scope,false); assert.equal(saves,0); assert.equal(retries,1);
    current=false; await page.acceptInsecureConnection(scope,true); assert.equal(saves,0); assert.equal(retries,1);
  });
  console.log(`${passed} insecure consent checks passed`);
})().catch(error=>{console.error(error);process.exitCode=1;});
