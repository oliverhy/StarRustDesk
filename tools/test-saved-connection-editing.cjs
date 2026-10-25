'use strict';
const fs=require('node:fs'), path=require('node:path'), vm=require('node:vm'), assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root=path.resolve(__dirname,'..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8').replace(/\r/g,'');
const source=read('entry/src/main/ets/pages/ConnectionPage.ets');
const editor=read('entry/src/main/ets/widget/SavedConnectionEditorDialog.ets');
const model=read('entry/src/main/ets/model/SavedConnectionEditing.ets').replace(/export /g,'');
function method(s,name){const start=s.search(new RegExp(`\\n  (?:async )?${name}\\(`));assert(start>=0,name);return s.slice(start,s.indexOf('\n  }',start)+4);}
const names=['saveCurrentConnection','currentConnectionScope','findDuplicateConnection','showDuplicateConnection',
  'requestForCurrentForm','requestForSavedConnection','saveConnectionDraft','cloneSavedConnections','persistSavedConnections',
  'savedConnectionForPassword','hasSavedConnectionPassword','connectionPasswordForUse','connectSavedConnection',
  'clearConnectionForm','normalizeRemoteId','confirmConnectionPassword','closeConnectionPasswordDialog','saveEditedConnection','onRemoteIdChanged','closeConnectionEditor','openNewSavedConnection','connectionFormSignature','loadSavedConnections'];
function compile(s,ctx){const out=ts.transpileModule(s,{compilerOptions:{target:ts.ScriptTarget.ES2021},reportDiagnostics:true});assert.equal(out.diagnostics.length,0);vm.runInContext(out.outputText,ctx);}
const row=(id,remoteId,name='Office',password='old-secret')=>({id,remoteId,name,password,performancePreset:'smooth',groupId:'work'});
function fixture(rows=[]){
  const options=new Map(),secrets=new Map(),osSecrets=new Map(),security=new Map(),bindings=new Map(),logs=[];
  let dirty=0, dialog, failRows=false, failSecret=false, failOs=false, pause;
  for(const r of rows)if(r.password)secrets.set(r.id,r.password);
  const context=vm.createContext({
    RustDeskNapi:{getOption:k=>options.get(k)||'',setOption:(k,v)=>{if(k==='saved-connections'&&failRows)return -1;options.set(k,v);return 0;},appendDiagnosticLog:(...a)=>logs.push(a)},
    CredentialStore:{load:async id=>secrets.get(id)||'',save:async(id,p)=>{if(pause)await pause;if(failSecret){failSecret=false;secrets.delete(id);return;}if(p)secrets.set(id,p);else secrets.delete(id);}},
    RemoteSecurityStore:{options:id=>security.get(id)||{lockAfterDisconnect:false,privacyMode:false,autoUnlock:false},
      saveOptions:(id,o)=>security.set(id,o),loadOsPassword:async id=>osSecrets.get(id)||'',
      saveOsPassword:async(id,p)=>{if(failOs){failOs=false;osSecrets.delete(id);bindings.delete(id);throw Error('OS asset add failed');}if(p)osSecrets.set(id,p);else osSecrets.delete(id);bindings.set(id,'new-binding');},
      removeOsPassword:async id=>{osSecrets.delete(id);bindings.delete(id);},
      serverBinding:id=>bindings.get(id)||'',restoreServerBinding:(id,b)=>b?bindings.set(id,b):bindings.delete(id)},
    CloudSyncService:{markLocalChanged:()=>dirty++,getLastRestoreOperationId:()=>'',recordUi:()=>{}},PerformanceSettings:{normalize:v=>v},translate:v=>v,
    promptAction:{showToast:()=>{}},Date,Math
  });
  compile(model+`\nclass ConnectionSaveConflict extends Error {}\nclass Page {${names.map(n=>method(source,n)).join('\n')}} globalThis.Page=Page; globalThis.Editing=SavedConnectionEditing;`,context);
  const p=Object.assign(new context.Page(),{savedConnections:rows.map(r=>({...r})),savedConnectionsVersion:0,selectedConnectionId:'',
    remoteId:'',connectionName:'',password:'',passwordEditMode:'keep',selectedGroupId:'work',performancePreset:'smooth',
    lockAfterDisconnect:false,privacyMode:false,autoUnlock:false,osPasswordDraft:'',clearOsPassword:false,hasStoredOsPassword:false,
    editingConnectionGeneration:1,editingConnectionId:'',creatingSavedConnection:false,connectionGroups:[],lastSavedHomepageId:'',savePageActive:true,savingConnection:false,uiLanguage:'zh-Hans',savedConnectionsLoadGeneration:0,savedConnectionsCloudRevision:0});
  p.makeConnectionId=remoteId=>`${remoteId}-${Date.now()}-${p.savedConnectionsVersion}`;
  p.validGroupId=id=>['work','home'].includes(id)?id:'';
  p.refreshSavedConnectionOnlineStates=()=>{};
  p.getUIContext=()=>({showAlertDialog:d=>{dialog=d;}});
  p.onConnect=(fileOnly,request)=>{p.connectionRequest=request;p.requestFileOnly=fileOnly;};
  p.editSavedConnection=r=>{p.openedEditor=r.id;}; p.showSavedTip=()=>{};
  p.connectionEditorController={close:()=>{},open:()=>{p.editorOpened=true;}};
  p.persistSavedConnections(p.savedConnections,false);
  return {p,context,options,secrets,osSecrets,security,bindings,logs,get dirty(){return dirty;},get dialog(){return dialog;},
    failRows:()=>{failRows=true;},failSecret:()=>{failSecret=true;},failOs:()=>{failOs=true;},pause:()=>{let resolve;pause=new Promise(r=>{resolve=r;});return()=>{pause=undefined;resolve();};}};
}
const draft=(f,r)=>({...f.context.Editing.empty(),remoteId:r.remoteId,name:r.name,groupId:r.groupId,performancePreset:r.performancePreset});
let count=0;
async function test(name,fn){await fn();count++;console.log('PASS '+name);}
(async()=>{
 await test('new editor and homepage preserve uppercase and mixed-case IDs while removing spacing',()=>{
   const f=fixture();compile(`class Editor {${['identityChanged','changeRemoteId'].map(n=>method(editor,n)).join('\n')}} globalThis.Editor=Editor;`,f.context);
   const e=Object.assign(new f.context.Editor(),{initial:f.context.Editing.empty(),remoteId:'',createNew:true,busy:false});
   for(const [input,expected] of [['C','C'],[' AbCd\u200B123 ','AbCd123'],['MY-PC','MY-PC'],['001234','001234'],['[2001:DB8::ABCD]:21118','[2001:DB8::ABCD]:21118']]){
     e.changeRemoteId(input);assert.equal(e.remoteId,expected);f.p.onRemoteIdChanged(input);assert.equal(f.p.remoteId,expected);
   }
   Object.assign(e,{remoteId:'AbCd123',initial:{...f.context.Editing.empty(),remoteId:'AbCd123'},password:'typed-secret',osPassword:'typed-os',autoUnlock:true});
   e.changeRemoteId('abcd123');assert.equal(e.identityChanged(),true);assert.equal(e.password,'');assert.equal(e.osPassword,'');assert.equal(e.autoUnlock,false);
 });
 await test('mixed-case IDs survive both save flows, persisted reload and direct connection requests',async()=>{
   const f=fixture();f.p.openNewSavedConnection();const d=draft(f,row('a','AbCd123','Work Mac',''));
   d.passwordMode='replace';d.password='Mixed-Secret';assert.equal((await f.p.saveEditedConnection(d,'new')).success,true);f.p.closeConnectionEditor();
   f.p.onRemoteIdChanged('MY-PC');f.p.connectionName='Uppercase';assert.equal(await f.p.saveCurrentConnection(),true);
   const stored=JSON.parse(f.options.get('saved-connections'));assert.deepEqual(stored.map(r=>r.remoteId).sort(),['AbCd123','MY-PC']);
   assert.equal(f.p.cloneSavedConnections(stored).find(r=>r.remoteId==='AbCd123').name,'Work Mac');
   f.p.savedConnections=[];await f.p.loadSavedConnections();const saved=f.p.savedConnections.find(r=>r.remoteId==='AbCd123');f.p.connectSavedConnection(saved);
   assert.equal(f.p.connectionRequest.draft.remoteId,'AbCd123');assert.equal(f.p.connectionRequest.draft.password,'Mixed-Secret');assert.equal(f.secrets.get(saved.id),'Mixed-Secret');
 });
 await test('case-only ID changes cannot reuse passwords, overwrite old rows or inherit security options',async()=>{
   const a=row('a','AbCd123');const f=fixture([a]);Object.assign(f.p,{remoteId:'AbCd123',password:'typed-secret',osPasswordDraft:'typed-os',privacyMode:true});
   f.p.onRemoteIdChanged('abcd123');assert.equal(f.p.password,'');assert.equal(f.p.osPasswordDraft,'');assert.equal(f.p.privacyMode,false);
   assert.equal(f.p.connectionPasswordForUse(),'');assert.equal(f.p.savedConnectionForPassword(),undefined);
   assert.equal(await f.p.saveCurrentConnection(),true);assert.equal(f.p.savedConnections.length,2);assert.equal(f.secrets.get('a'),'old-secret');
   assert.equal(f.p.savedConnections.find(r=>r.remoteId==='abcd123').password,'');
   f.p.onRemoteIdChanged('AbCd123');assert.equal(f.p.connectionPasswordForUse(),'old-secret');assert.equal(await f.p.saveCurrentConnection(),false);
   const g=fixture([row('legacy','abcd123')]);g.p.onRemoteIdChanged('AbCd123');assert.equal(g.p.connectionPasswordForUse(),'');
   assert.equal(await g.p.saveCurrentConnection(),true);assert.equal(g.p.savedConnections.find(r=>r.id==='legacy').remoteId,'abcd123');
 });
 await test('IPv6 comparison ignores hex letter case without rewriting the saved address',async()=>{
   const address='[2001:DB8::ABCD]:21118';const f=fixture();f.p.onRemoteIdChanged(address);assert.equal(await f.p.saveCurrentConnection(),true);
   assert.equal(f.p.savedConnections[0].remoteId,address);assert.equal(JSON.parse(f.options.get('saved-connections'))[0].remoteId,address);
   f.p.onRemoteIdChanged(address.toLowerCase());assert.equal(await f.p.saveCurrentConnection(),false);assert.equal(f.p.savedConnections.length,1);
 });
 await test('save A then type B adds B without clicking New; legacy selected ID cannot overwrite A',async()=>{
   const f=fixture(),p=f.p;p.remoteId='111111';p.connectionName='A';p.password='secret-A';p.passwordEditMode='replace';
   assert.equal(await p.saveCurrentConnection(),true);const original=JSON.stringify(p.savedConnections[0]);const id=p.savedConnections[0].id;
   assert.equal(p.selectedConnectionId,'');assert.equal(p.password,'');
   p.lockAfterDisconnect=true;p.privacyMode=true;p.autoUnlock=true;p.osPasswordDraft='new-os-secret';
   p.onRemoteIdChanged('222222');assert.equal(p.connectionName,'');assert.equal(p.privacyMode,false);assert.equal(p.osPasswordDraft,'');
   p.selectedConnectionId=id;p.connectionName='B';
   assert.equal(await p.saveCurrentConnection(),true);assert.equal(p.savedConnections.length,2);
   assert.equal(JSON.stringify(p.savedConnections.find(r=>r.id===id)),original);assert.equal(f.secrets.get(id),'secret-A');
   assert.equal(p.savedConnections[0].password,'');assert.equal(f.dirty,2);
 });
 await test('duplicate save is blocked without replacing name, password, group or settings',async()=>{
   const r=row('a','123456');const f=fixture([r]);Object.assign(f.p,{remoteId:'123 456',connectionName:'Changed',password:'attack',passwordEditMode:'replace',selectedGroupId:'home'});
   const before=JSON.stringify(f.p.savedConnections);assert.equal(await f.p.saveCurrentConnection(),false);
   assert.equal(JSON.stringify(f.p.savedConnections),before);assert.equal(f.secrets.get('a'),'old-secret');assert.equal(f.dirty,0);
   assert.equal(f.dialog.title,'此连接已保存');assert.equal(f.dialog.buttons.length,3);
   f.dialog.buttons[0].action();assert.equal(f.p.connectionRequest.draft.password,'old-secret');
   f.dialog.buttons[1].action();assert.equal(f.p.openedEditor,'a');
 });
 await test('direct connection uses a private request and does not alter the homepage draft',()=>{
   const r=row('a','123456');const f=fixture([r]);Object.assign(f.p,{remoteId:'other-id',connectionName:'Unsaved',password:'typed',selectedGroupId:'home'});
   f.p.connectSavedConnection(r);assert.equal(f.p.remoteId,'other-id');assert.equal(f.p.connectionName,'Unsaved');assert.equal(f.p.password,'typed');
   assert.equal(f.p.connectionRequest.savedId,'a');assert.equal(f.p.connectionRequest.draft.password,'old-secret');assert.equal(f.dirty,0);
 });
 await test('explicit metadata edit preserves both passwords and immutable identity',async()=>{
   const r=row('a','123456');const f=fixture([r]);f.osSecrets.set('a','os-secret');f.bindings.set('a','original-binding');
   const d=draft(f,r);d.name='Renamed';d.groupId='home';await f.p.saveConnectionDraft(d,'a','update',{...r});
   assert.equal(f.p.savedConnections[0].id,'a');assert.equal(f.p.savedConnections[0].name,'Renamed');
   assert.equal(f.secrets.get('a'),'old-secret');assert.equal(f.osSecrets.get('a'),'os-secret');assert.equal(f.bindings.get('a'),'original-binding');
 });
 await test('changed ID defaults to copy; original credentials and connection remain untouched',async()=>{
   const r=row('a','123456');const f=fixture([r]);f.osSecrets.set('a','os-secret');const d=draft(f,r);d.remoteId='654321';
   await assert.rejects(f.p.saveConnectionDraft(d,'a','update',{...r}),/远端 ID 已改变/);
   await f.p.saveConnectionDraft(d,'a','copy',{...r});assert.equal(f.p.savedConnections.length,2);
   assert.equal(f.p.savedConnections[0].password,'');assert.equal(f.secrets.get('a'),'old-secret');assert.equal(f.osSecrets.get('a'),'os-secret');
   assert.equal(f.osSecrets.has(f.p.savedConnections[0].id),false);
 });
 await test('replace requires an explicit action and clears old-device credentials',async()=>{
   const r=row('a','123456');const f=fixture([r]);f.osSecrets.set('a','os-secret');const d=draft(f,r);d.remoteId='654321';
   await f.p.saveConnectionDraft(d,'a','replace',{...r});assert.equal(f.p.savedConnections.length,1);
   assert.equal(f.p.savedConnections[0].remoteId,'654321');assert.equal(f.secrets.has('a'),false);assert.equal(f.osSecrets.has('a'),false);
 });
 await test('duplicate destination during edit cannot overwrite either row',async()=>{
   const a=row('a','123456'),b=row('b','654321','Home','other-secret');const f=fixture([a,b]);const d=draft(f,a);d.remoteId=b.remoteId;
   for(const action of ['copy','replace'])await assert.rejects(f.p.saveConnectionDraft(d,'a',action,{...a}),/已保存/);
   assert.equal(f.p.savedConnections.length,2);assert.equal(f.secrets.get('a'),'old-secret');assert.equal(f.secrets.get('b'),'other-secret');assert.equal(f.dirty,0);
 });
 await test('same ID on a different known network is not globally deduplicated; old rows remain conservative',async()=>{
   const f=fixture();const a=row('a','123456');a.serverScope=f.context.Editing.network('other.example:21116','');f.p.savedConnections=[a];f.p.persistSavedConnections([a],false);
   f.p.remoteId='123456';assert.equal(await f.p.saveCurrentConnection(),true);assert.equal(f.p.savedConnections.length,2);
   assert.notEqual(f.p.savedConnections[0].serverScope,a.serverScope);
   const legacy=fixture([row('legacy','123456')]);legacy.p.remoteId='123456';assert.equal(await legacy.p.saveCurrentConnection(),false);
 });
 await test('saved password replace, clear and empty replacement preserve staged behavior',async()=>{
   const r=row('a','123456');const f=fixture([r]);let d=draft(f,r);d.passwordMode='replace';
   await assert.rejects(f.p.saveConnectionDraft(d,'a','update',{...r}),/请输入新密码/);assert.equal(f.secrets.get('a'),'old-secret');
   d.password='new-secret';await f.p.saveConnectionDraft(d,'a','update',{...r});assert.equal(f.secrets.get('a'),'new-secret');
   const updated={...f.p.savedConnections[0]};d=draft(f,updated);d.passwordMode='clear';await f.p.saveConnectionDraft(d,'a','update',updated);
   assert.equal(f.secrets.has('a'),false);assert.equal(f.p.savedConnections[0].password,'');
 });
 await test('readback failure preserves rows and restores credentials without cloud success',async()=>{
   const r=row('a','123456');const f=fixture([r]);f.failRows();const d=draft(f,r);d.name='Changed';d.passwordMode='replace';d.password='new-secret';
   await assert.rejects(f.p.saveConnectionDraft(d,'a','update',{...r}),/readback/);assert.equal(f.p.savedConnections[0].name,'Office');
   assert.equal(f.secrets.get('a'),'old-secret');assert.equal(f.dirty,0);
 });
 await test('silent credential failure is detected and cannot report save success',async()=>{
   const r=row('a','123456');const f=fixture([r]);f.failSecret();const d=draft(f,r);d.passwordMode='replace';d.password='new-secret';
   await assert.rejects(f.p.saveConnectionDraft(d,'a','update',{...r}),/Credential/);assert.equal(f.p.savedConnections[0].password,'old-secret');assert.equal(f.dirty,0);
 });
 await test('stale editor, deletion, background cancellation and network switch cannot overwrite',async()=>{
   const r=row('a','123456');const f=fixture([r]);const d=draft(f,r);f.p.savedConnections[0].name='Changed elsewhere';
   await assert.rejects(f.p.saveConnectionDraft(d,'a','update',{...r}),/已改变/);
   const g=fixture([r]);const release=g.pause();d.passwordMode='replace';d.password='new-secret';const saving=g.p.saveConnectionDraft(d,'a','update',{...r});
   await new Promise(resolve=>setImmediate(resolve));g.p.editingConnectionGeneration++;release();await assert.rejects(saving,/已改变/);
   assert.equal(g.secrets.get('a'),'old-secret');assert.equal(g.p.savedConnections[0].name,'Office');assert.equal(g.dirty,0);
   const h=fixture([r]);const scope=h.p.currentConnectionScope();h.options.set('custom-rendezvous-server','changed.example');
   await assert.rejects(h.p.saveConnectionDraft(d,'a','update',{...r},scope),/已改变/);
 });
 await test('cancel leaves both the saved record and homepage draft untouched',()=>{
   const r=row('a','123456');const f=fixture([r]);const before=JSON.stringify(f.p.savedConnections);
   Object.assign(f.p,{remoteId:'home-draft',connectionName:'Unsaved',password:'typed',selectedGroupId:'home',editingConnectionId:'a'});
   f.p.closeConnectionEditor();assert.equal(JSON.stringify(f.p.savedConnections),before);assert.equal(f.p.editingConnectionId,'');
   assert.equal(f.p.remoteId,'home-draft');assert.equal(f.p.connectionName,'Unsaved');assert.equal(f.p.password,'typed');assert.equal(f.dirty,0);
 });
 await test('failed OS asset replacement restores the old secret and exact server binding',async()=>{
   const r=row('a','123456');const f=fixture([r]);f.osSecrets.set('a','old-os-secret');f.bindings.set('a','original-server-binding');f.failOs();
   const d=draft(f,r);d.osPassword='new-os-secret';await assert.rejects(f.p.saveConnectionDraft(d,'a','update',{...r}),/OS asset/);
   assert.equal(f.osSecrets.get('a'),'old-os-secret');assert.equal(f.bindings.get('a'),'original-server-binding');assert.equal(f.dirty,0);
 });
 await test('credentials changed outside the editor are not overwritten by its stale cache',async()=>{
   const r=row('a','123456');const f=fixture([r]);f.secrets.set('a','new-cloud-secret');const d=draft(f,r);
   await assert.rejects(f.p.saveConnectionDraft(d,'a','update',{...r}),/已改变/);assert.equal(f.secrets.get('a'),'new-cloud-secret');assert.equal(f.dirty,0);
 });
 await test('remember password updates only the pending peer, leaving form and other rows untouched',async()=>{
   const a=row('a','123456','Office',''),b=row('b','654321','Home','other-secret');const f=fixture([a,b]);
   Object.assign(f.p,{remoteId:b.remoteId,connectionName:'User draft',password:'form-secret',pendingConnectionRequest:f.p.requestForSavedConnection(a),
     connectionPasswordDraft:'entered-secret',rememberConnectionPassword:true,pendingFileOnly:false});
   await f.p.confirmConnectionPassword();assert.equal(f.secrets.get('a'),'entered-secret');assert.equal(f.secrets.get('b'),'other-secret');
   assert.equal(f.p.connectionName,'User draft');assert.equal(f.p.password,'form-secret');assert.equal(f.p.remoteId,b.remoteId);
   assert.equal(f.p.connectionRequest.draft.remoteId,a.remoteId);assert.equal(f.p.connectionRequest.draft.password,'entered-secret');
 });
 await test('save completion cannot erase a newer homepage draft typed while credential writes wait',async()=>{
   const f=fixture();Object.assign(f.p,{remoteId:'123456',connectionName:'Original draft',password:'typed-secret',passwordEditMode:'replace'});
   const release=f.pause();const saving=f.p.saveCurrentConnection();await new Promise(resolve=>setImmediate(resolve));
   f.p.connectionName='New unsaved name';f.p.osPasswordDraft='new-unsaved-os-secret';release();await saving;
   assert.equal(f.p.savedConnections[0].name,'Original draft');assert.equal(f.p.connectionName,'New unsaved name');
   assert.equal(f.p.osPasswordDraft,'new-unsaved-os-secret');assert.equal(f.p.password,'typed-secret');
 });
 await test('remember password rejects a pending record whose ID was replaced while dialog was open',async()=>{
   const a=row('a','123456','Office','');const f=fixture([a]);f.p.pendingConnectionRequest=f.p.requestForSavedConnection(a);
   Object.assign(f.p,{connectionPasswordDraft:'entered-secret',rememberConnectionPassword:true});f.p.savedConnections[0].remoteId='654321';
   await f.p.confirmConnectionPassword();assert.match(f.p.connectionPasswordError,/已改变/);assert.equal(f.secrets.has('a'),false);assert.equal(f.dirty,0);
 });
 await test('official-style editor keeps existing device IDs fixed; new device changes reset sensitive choices',()=>{
   const f=fixture();compile(`class Editor {${['identityChanged','changeRemoteId','cancelPasswordReplacement'].map(n=>method(editor,n)).join('\n')}} globalThis.Editor=Editor;`,f.context);
   const e=new f.context.Editor();Object.assign(e,{initial:{...f.context.Editing.empty(),remoteId:'123456',lockAfterDisconnect:true,privacyMode:true,autoUnlock:true},remoteId:'123456',
     password:'typed-secret',osPassword:'typed-os-secret',lockAfterDisconnect:true,privacyMode:true,autoUnlock:true});
   e.createNew=false;e.changeRemoteId('654321');assert.equal(e.remoteId,'123456');assert.equal(e.password,'typed-secret');
   e.createNew=true;e.changeRemoteId('654321');assert.equal(e.password,'');assert.equal(e.osPassword,'');assert.equal(e.autoUnlock,false);assert.equal(e.privacyMode,false);
   e.password='new-secret';e.osPassword='new-os';e.changeRemoteId('222222');assert.equal(e.password,'');assert.equal(e.osPassword,'');
   e.password='new-draft';e.passwordMode='replace';e.cancelPasswordReplacement();assert.equal(e.password,'');assert.equal(e.passwordMode,'keep');
   assert(!method(source,'editSavedConnection').includes('this.applySavedConnection'));
   assert(method(source,'editSavedConnection').includes("password: '', passwordMode: 'keep'"));
   assert(editor.includes("this.createNew ? 'new' : 'update'"));assert(!editor.includes('确认替换原连接'));assert(!editor.includes('替换原连接（需要确认）'));
   assert(editor.includes('.selected(this.presetIndex()).value(this.presetLabel())'),'collapsed connection-mode selector shows its current label');
 });
 await test('independent add dialog starts empty and never inherits homepage secrets/settings',()=>{
   const f=fixture();Object.assign(f.p,{remoteId:'123456',connectionName:'Quick draft',password:'quick-secret',osPasswordDraft:'quick-os',privacyMode:true});
   f.p.openNewSavedConnection();assert.equal(f.p.connectionEditorDraft.remoteId,'');assert.equal(f.p.connectionEditorDraft.password,'');assert.equal(f.p.connectionEditorDraft.privacyMode,false);
   assert.equal(f.p.creatingSavedConnection,true);assert.equal(f.p.editorOpened,true);assert.equal(f.p.remoteId,'123456');assert.equal(f.p.password,'quick-secret');
   f.p.openNewSavedConnection(true);assert.equal(f.p.connectionEditorDraft.remoteId,'123456');assert.equal(f.p.connectionEditorDraft.name,'');assert.equal(f.p.connectionEditorDraft.osPassword,'');
 });
 await test('new dialog adds A then B without editing A; duplicates do not overwrite A',async()=>{
   const f=fixture();f.p.remoteId='quick-draft';f.p.openNewSavedConnection();let d=draft(f,row('a','123456','A',''));
   assert.equal((await f.p.saveEditedConnection(d,'replace')).success,true);f.p.closeConnectionEditor();const a=JSON.stringify(f.p.savedConnections[0]);
   f.p.openNewSavedConnection();d=draft(f,row('b','654321','B',''));assert.equal((await f.p.saveEditedConnection(d,'update')).success,true);f.p.closeConnectionEditor();
   assert.equal(f.p.savedConnections.length,2);assert.equal(JSON.stringify(f.p.savedConnections.find(r=>r.remoteId==='123456')),a);assert.equal(f.p.remoteId,'quick-draft');
   f.p.openNewSavedConnection();d=draft(f,row('a','123456','Overwrite',''));const result=await f.p.saveEditedConnection(d,'new');assert.equal(result.success,false);assert.match(result.message,/已保存/);
   assert.equal(JSON.stringify(f.p.savedConnections.find(r=>r.remoteId==='123456')),a);
 });
 await test('edit callback rejects changing an existing ID regardless of requested copy/replace action',async()=>{
   const r=row('a','123456');const f=fixture([r]);Object.assign(f.p,{editingConnectionId:'a',editingConnectionOriginal:{...r},editingConnectionScope:f.p.currentConnectionScope()});
   const d=draft(f,r);d.remoteId='654321';for(const action of ['update','copy','replace','new']){
     const result=await f.p.saveEditedConnection(d,action);assert.equal(result.success,false);assert.match(result.message,/ID 不能修改/);
   }assert.equal(f.p.savedConnections[0].remoteId,'123456');assert.equal(f.secrets.get('a'),'old-secret');assert.equal(f.dirty,0);
 });
 await test('cancel new dialog during asynchronous save rolls back instead of saving a discarded dialog',async()=>{
   const f=fixture();f.p.openNewSavedConnection();const d=draft(f,row('a','123456','A',''));d.passwordMode='replace';d.password='new-secret';
   const release=f.pause();const saving=f.p.saveEditedConnection(d,'new');await new Promise(resolve=>setImmediate(resolve));f.p.closeConnectionEditor();release();
   assert.equal((await saving).success,false);assert.equal(f.p.savedConnections.length,0);assert.equal(f.secrets.size,0);assert.equal(f.dirty,0);
 });
 await test('scope survives clone, persistence, backup, import and cloud restore; data/logs contain no credentials',()=>{
   const a=row('a','123456');const f=fixture([a]);a.serverScope=f.p.currentConnectionScope();const clones=f.p.cloneSavedConnections([a]);f.p.persistSavedConnections(clones,false);
   const stored=JSON.parse(f.options.get('saved-connections'));assert.equal(stored[0].serverScope,a.serverScope);assert(!('password' in stored[0]));
   for(const name of ['buildBackupPayload','normalizeImportedData','loadSavedConnections'])assert(method(source,name).includes('serverScope'));
   const cloud=read('entry/src/main/ets/service/CloudSyncService.ets');assert(cloud.includes('serverScope: row.serverScope'));assert(cloud.includes('serverScope: item.serverScope'));
   assert(!JSON.stringify(f.logs).includes('secret'));assert(!a.serverScope.includes('example'));
 });
 console.log(`Saved connection editing: ${count} scenario groups passed`);
})().catch(e=>{console.error(e);process.exitCode=1;});
