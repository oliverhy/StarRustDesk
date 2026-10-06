'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8').replace(/\r\n/g,'\n');
const source=read('entry/src/main/ets/service/ThemePreference.ets');
const compiled=ts.transpile(source.replace(/^import .*\n/gm,''));
const wait=async()=>{for(let i=0;i<15;i++) await Promise.resolve();};
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
function fixture(initial,legacy={}) {
  const disk=new Map(initial===undefined?[]:[['mode',initial]]);
  const failures={open:false,read:false,write:false,flush:false,log:false};
  const writes=[],logs=[];let gate;
  function load(memory=legacy) {
    const storage=new Map(Object.entries(memory)),cache=new Map(disk);
    const store={
      getSync:(key,fallback)=>{if(failures.read) throw {code:15500000};return cache.has(key)?cache.get(key):fallback;},
      putSync:(key,value)=>{if(failures.write) throw {code:15500000};cache.set(key,value);writes.push(value);},
      flush:async()=>{
        if(gate) {const current=gate;gate=undefined;await current.promise;}
        if(failures.flush) throw {code:15500000};
        disk.clear();for(const [key,value] of cache) disk.set(key,value);
      },
    };
    const context={exports:{},preferences:{getPreferencesSync:(ability,options)=>{
      assert.deepEqual(JSON.parse(JSON.stringify(options)),{name:'starrustdesk_theme'});
      if(failures.open) throw {code:801};return store;
    }},AppStorage:{get:key=>storage.get(key),setOrCreate:(key,value)=>storage.set(key,value)},
      RustDeskNapi:{appendDiagnosticLog:(scope,message)=>{if(failures.log) throw Error('logger');logs.push([scope,message]);}},
    };
    vm.runInNewContext(compiled,context);
    return {theme:context.exports.ThemePreference,storage,cache};
  }
  return {disk,failures,writes,logs,load,block:()=>{gate=deferred();return gate;}};
}
let count=0;
async function test(name,run){await run();count++;console.log('PASS '+name);}
(async()=>{
  for(const dark of [false,true]) await test('fresh install follows system '+dark,async()=>{
    const f=fixture(),p=f.load();p.theme.initialize({},dark);
    assert.equal(p.storage.get('isDarkMode'),dark);assert.equal(p.storage.get('isDarkModeManual'),false);
    p.theme.updateSystem(!dark);assert.equal(p.storage.get('isDarkMode'),!dark);assert.equal(f.disk.size,0);
  });
  await test('manual dark survives a new process under a light system',async()=>{
    const f=fixture(),p=f.load();p.theme.initialize({},false);
    assert.equal(await p.theme.setMode('dark'),true);p.theme.updateSystem(false);
    const restarted=f.load({});restarted.theme.initialize({},false);
    assert.equal(restarted.storage.get('isDarkMode'),true);assert.equal(restarted.storage.get('isDarkModeManual'),true);
    assert.equal(f.disk.get('mode'),'dark');
  });
  await test('manual light survives a dark system, foreground and relaunch',async()=>{
    const f=fixture('dark'),p=f.load();p.theme.initialize({},true);
    assert.equal(await p.theme.setMode('light'),true);p.theme.updateSystem(true);
    assert.equal(p.storage.get('isDarkMode'),false);
    const restarted=f.load({});restarted.theme.initialize({},true);
    assert.equal(restarted.storage.get('isDarkMode'),false);assert.equal(restarted.storage.get('isDarkModeManual'),true);
  });
  await test('choice is acknowledged only after a durable flush',async()=>{
    const f=fixture(),p=f.load();p.theme.initialize({},false);const gate=f.block();
    const save=p.theme.setMode('dark');await wait();
    assert.equal(f.disk.size,0);assert.equal(p.storage.get('isDarkMode'),false);
    const before=f.load({});before.theme.initialize({},false);assert.equal(before.storage.get('isDarkMode'),false);
    gate.resolve();assert.equal(await save,true);assert.equal(p.storage.get('isDarkMode'),true);
    const after=f.load({});after.theme.initialize({},false);assert.equal(after.storage.get('isDarkMode'),true);
  });
  await test('system mode remains dynamic after resetting an explicit choice',async()=>{
    const f=fixture('light'),p=f.load();p.theme.initialize({},true);
    assert.equal(await p.theme.setMode('system'),true);assert.equal(p.storage.get('isDarkMode'),true);
    assert.equal(p.storage.get('isDarkModeManual'),false);p.theme.updateSystem(false);
    assert.equal(p.storage.get('isDarkMode'),false);
    const restarted=f.load({});restarted.theme.initialize({},true);assert.equal(restarted.storage.get('isDarkMode'),true);
  });
  for(const failure of ['write','flush']) await test('failed '+failure+' does not accept or remember the choice',async()=>{
    const f=fixture('light'),p=f.load();p.theme.initialize({},false);f.failures[failure]=true;
    assert.equal(await p.theme.setMode('dark'),false);assert.equal(p.storage.get('isDarkMode'),false);
    assert.equal(f.disk.get('mode'),'light');assert.equal(p.cache.get('mode'),'light');
    f.failures[failure]=false;assert.equal(await p.theme.setMode('dark'),true);
    const restarted=f.load({});restarted.theme.initialize({},false);assert.equal(restarted.storage.get('isDarkMode'),true);
  });
  await test('preference service unavailable at startup can be retried without a startup crash',async()=>{
    const f=fixture('dark');f.failures.open=true;const p=f.load();p.theme.initialize({},false);
    assert.equal(p.storage.get('isDarkMode'),false);assert.equal(await p.theme.setMode('dark'),false);
    f.failures.open=false;assert.equal(await p.theme.setMode('dark'),true);
  });
  await test('corrupt/unknown mode falls back safely and does not leak its contents',async()=>{
    const f=fixture('SECRET_UNKNOWN_VALUE'),p=f.load();p.theme.initialize({},true);
    assert.equal(p.storage.get('isDarkModeManual'),false);assert.equal(p.storage.get('isDarkMode'),true);
    assert(!JSON.stringify(f.logs).includes('SECRET_UNKNOWN_VALUE'));
    assert.equal(await p.theme.setMode('unknown'),false);assert.equal(f.disk.get('mode'),'SECRET_UNKNOWN_VALUE');
  });
  await test('rapid requests are serialized in the requested order',async()=>{
    const f=fixture('system'),p=f.load();p.theme.initialize({},false);const gate=f.block();
    const saves=[p.theme.setMode('dark'),p.theme.setMode('light'),p.theme.setMode('dark')];
    await wait();assert.deepEqual(f.writes,['dark']);gate.resolve();assert.deepEqual(await Promise.all(saves),[true,true,true]);
    assert.deepEqual(f.writes,['dark','light','dark']);assert.equal(f.disk.get('mode'),'dark');
  });
  await test('queued stale request cannot overwrite recreated Ability state',async()=>{
    const f=fixture('system'),p=f.load();p.theme.initialize({},false);
    const pending=p.theme.setMode('dark');p.theme.initialize({},true);
    assert.equal(await pending,false);assert.equal(f.disk.get('mode'),'system');assert.equal(p.storage.get('isDarkMode'),true);
  });
  await test('already-restored legacy memory choice is preserved and migrated',async()=>{
    const f=fixture(undefined,{isDarkModeManual:true,isDarkMode:true}),p=f.load();p.theme.initialize({},false);await wait();
    assert.equal(p.storage.get('isDarkMode'),true);assert.equal(f.disk.get('mode'),'dark');
    const restarted=f.load({});restarted.theme.initialize({},false);assert.equal(restarted.storage.get('isDarkMode'),true);
  });
  await test('diagnostic logger failure cannot break restore/save',async()=>{
    const f=fixture('dark');f.failures.log=true;const p=f.load();p.theme.initialize({},false);
    assert.equal(p.storage.get('isDarkMode'),true);assert.equal(await p.theme.setMode('light'),true);
  });
  const ability=read('entry/src/main/ets/entryability/EntryAbility.ets');
  assert(ability.indexOf('ThemePreference.initialize(')<ability.indexOf('windowStage.loadContent('),'restore occurs before first UI load');
  assert(!/PersistentStorage\.persistProp\('isDarkMode/.test(ability),'theme no longer relies on early UI persistence');
  const start=ability.indexOf('\n  private updateColorMode(');
  const colorMethod=ability.slice(start,ability.indexOf('\n  }',start)+4);
  const calls=[],ctx={exports:{},ConfigurationConstant:{ColorMode:{COLOR_MODE_NOT_SET:-1}},ThemePreference:{updateSystem:value=>calls.push(value)}};
  vm.runInNewContext(ts.transpile('class Ability { isDarkColorMode(v){return v===0;} '+colorMethod+'} exports.Ability=Ability;'),ctx);
  const a=new ctx.exports.Ability();a.updateColorMode(undefined);a.updateColorMode(-1);assert.deepEqual(calls,[]);
  a.updateColorMode(0);a.updateColorMode(1);assert.deepEqual(calls,[true,false]);
  const settings=read('entry/src/main/ets/pages/SettingsPage.ets');
  const method=name=>{const start=settings.indexOf('\n  async '+name+'(');return settings.slice(start,settings.indexOf('\n  }',start)+4);};
  const gates=[],toasts=[],uiContext={exports:{},translate:s=>s,promptAction:{showToast:arg=>toasts.push(arg)},
    ThemePreference:{setMode:mode=>{const d=deferred();gates.push([mode,d]);return d.promise;}}};
  vm.runInNewContext(ts.transpile('class Settings {'+method('setDarkMode')+'} exports.Settings=Settings;'),uiContext);
  const ui=Object.assign(new uiContext.exports.Settings(),{themePreferenceBusy:false,uiLanguage:'zh-Hans'});
  const save=ui.setDarkMode(true);assert.equal(ui.themePreferenceBusy,true);
  await ui.setDarkMode(false);assert.equal(gates.length,1,'busy switch ignores repeated events');
  gates[0][1].resolve(false);await save;assert.equal(ui.themePreferenceBusy,false);assert.equal(toasts.length,1);
  assert(settings.includes('.id(\'darkModeToggle\')') && settings.includes('.enabled(!this.themePreferenceBusy)'));
  assert(!source.includes('setOption(') && !/\bPersistentStorage\s*\./.test(source),'only the isolated theme preference file is written');
  console.log(`PASS theme preference: ${count} durable/cold-start/failure cases, startup ordering, partial configuration updates and controlled switch`);
})().catch(error=>{console.error(error);process.exitCode=1;});
