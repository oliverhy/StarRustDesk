'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {configureSunshineTest} = require('./sunshine-preview-build.cjs');
const read = f => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
const baselist = JSON.parse(read('entry/src/main/resources/base/profile/main_pages.json')).src;
assert(baselist.includes('pages/RemotePage') && !baselist.includes('pages/SunshineStreamPage'));
assert.match(read('entry/src/main/module.json5'), /"pages": "\$profile:main_pages"/);
const gate=read('entry/src/main/ets/service/SunshineExperiment.ets');
assert.match(gate,/bundleName === SUNSHINE_DEBUG_BUNDLE && debug && packaged/);
assert.match(gate,/setOrCreate\('sunshineTestEnabled', false\)/);
const pending=read('entry/src/main/ets/pages/SunshineStreamPage.ets');
assert(pending.includes('!SunshineExperiment.mayOpen(info.name, info.debug)'));
const deny='**/libsunshine_stream_exp.so';
const p={targets:[{name:'default'}],buildOption:{externalNativeOptions:{arguments:'-DSESAME_STREAM_TEST_BUILD:BOOL=OFF'},
  nativeLib:{filter:{excludes:[deny,'**/libunrelated.so']}}}};
const m={module:{pages:'$profile:main_pages'}};
let writes=0;
const ctx={getBuildMode:()=>'debug',getBuildProfileOpt:()=>p,getModuleJsonOpt:()=>m,
  setBuildProfileOpt:()=>++writes,setModuleJsonOpt:()=>++writes};
configureSunshineTest(ctx,{});
assert.equal(writes,0);
assert(p.buildOption.nativeLib.filter.excludes.includes(deny));
assert.equal(read('entry/build-profile.json5').split(deny).length-1,2, 'normal and release reject stale native output');
assert.throws(()=>configureSunshineTest({...ctx,getBuildMode:()=>'release'}, {SESAME_STREAM_TEST_BUILD:'1'}),/debug-only/);
assert.equal(writes,0);
configureSunshineTest(ctx,{SESAME_STREAM_TEST_BUILD:'1'});
assert.equal(writes,2);
assert.deepEqual(p.targets[0].resource.directories,['./src/main/resources','./src/sunshineTest/resources']);
assert.equal(p.buildOption.externalNativeOptions.arguments,'-DSESAME_STREAM_TEST_BUILD:BOOL=ON');
assert.deepEqual(p.buildOption.nativeLib.filter.excludes,['**/libunrelated.so']);
assert.equal(m.module.pages,'$profile:sunshine_test_pages');
assert(read('entry/src/main/ets/pages/ConnectionPage.ets').includes('linkedDeviceId'),
  'do not replace the original secure saved-connection path with the test baseline');
console.log('PASS default and release isolation, opt-in profile and native route, preserved RustDesk entry');
