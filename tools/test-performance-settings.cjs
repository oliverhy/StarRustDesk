const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const context = { exports: {} };
vm.runInNewContext(ts.transpileModule(read('entry/src/main/ets/model/PerformanceSettings.ets'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText, context);
const p = context.exports.PerformanceSettings;
for (const preset of ['stable', 'high_fps', 'smooth', 'silky', 'best', 'custom:100:30', 'custom:2000:120']) {
  assert.equal(p.normalize(preset), preset);
  // The existing saved/backup/cloud schema stores this field verbatim.
  const saved = JSON.parse(JSON.stringify({ performancePreset: preset }));
  assert.equal(p.normalize(saved.performancePreset), preset);
}
for (const invalid of ['', 'custom', 'custom:NaN:60', 'custom:-1:30', 'custom:100:60:1', 'custom:999999:30', 'custom::30']) {
  assert.equal(p.normalize(invalid), 'smooth');
}
assert.equal(p.normalize('custom:0:0'), 'custom:10:5');
assert.equal(p.normalize('custom:9999:999'), 'custom:2000:120');
assert.equal(p.custom(NaN, Infinity), 'custom:100:30');
assert.equal(p.bitrate('custom:500:60'), 500);
assert.equal(p.fps('custom:500:60'), 60);
assert.equal(p.isCustom('best'), false);
assert.equal(p.isCustom('custom:100:30'), true);
const page = read('entry/src/main/ets/pages/ConnectionPage.ets');
assert.match(page, /Select\(this\.connectionModeOptions\(\)\)/);
assert.match(page, /\['稳定', '高帧率', '高流畅', '高丝滑', '高清优先', '自定义'\]/);
assert.match(page, /\['stable', 'high_fps', 'smooth', 'silky', 'best'\]\[index\]/);
assert.match(page, /index === 5 \? PerformanceSettings.custom/);
assert.match(page, /return PerformanceSettings.normalize\(value\)/);
assert.match(page, /performancePreset: PerformanceSettings.normalize\(row\['performancePreset'\]/);
assert.match(page, /this.performancePreset = PerformanceSettings.normalize\(item.performancePreset\)/);
for (const file of ['ConnectionBackupService.ets', 'CloudSyncService.ets']) {
  assert.match(read('entry/src/main/ets/service/' + file), /performancePreset: string/);
}
const rust = read('entry/src/main/rust/src/lib.rs');
assert.equal((rust.match(/custom_image_quality: performance.wire_quality\(\)/g) || []).length, 4);
assert.match(rust, /custom_bitrate_percent=\{\}/);
console.log('Performance settings validation, persistence and all four protocol paths passed');
