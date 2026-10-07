'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8').replace(/\r\n/g, '\n');
const context = { exports: {} };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/RemoteControlMenu.ets')), context);
const { compactControlMenuMetrics: menuMetrics, compactInputSelectorMetrics: selectorMetrics } = context.exports;
let cases = 0;
for (const width of [120,160,180,200,224,280,320,396,600,840,1040,1440]) {
  for (const scale of [1,1.3,1.8,2,2.4,2.8,3.2]) for (const height of [150,360,780]) {
    for (const handheld of [false,true]) {
      const m = menuMetrics('input',width,height,scale,3,4,handheld,false,false);
      const s = selectorMetrics(m.contentWidth,scale,m.rowHeight);
      assert.equal(s.stacked,m.inputSelectorStacked);
      assert.equal(s.segmentWidth,m.inputSegmentWidth);
      assert.equal(s.height,m.inputSelectorHeight);
      assert(s.segmentWidth > 0 && s.segmentWidth <= m.contentWidth);
      assert.equal(s.height,s.stacked?m.rowHeight*2+4:m.rowHeight);
      if(!s.stacked) assert.equal(s.segmentWidth*2+4,m.contentWidth);
      const expectedContent=s.height+3*m.rowHeight+3*m.gap;
      assert.equal(m.contentHeight,expectedContent,'mode selector height must be included before clipping/scrolling');
      assert(m.width<=width && m.height<=height);
      cases++;
    }
  }
}
assert.equal(selectorMetrics(206,1,44).stacked,false);
assert.equal(selectorMetrics(166,1,44).stacked,true);
assert.equal(selectorMetrics(347,3.2,96).stacked,true);
for (const invalid of [NaN,Infinity,-1,0]) {
  const s=selectorMetrics(invalid,invalid,invalid);
  assert(Number.isFinite(s.height) && Number.isFinite(s.segmentWidth) && s.segmentWidth>0);
}
const source=read('entry/src/main/ets/pages/RemotePage.ets');
const method=name=>{const start=source.indexOf('\n  '+name+'(');assert(start>=0,name);return source.slice(start,source.indexOf('\n  }',start)+4);};
const choiceContext={exports:{},INPUT_MODE_MOUSE:'mouse',INPUT_MODE_TOUCH:'touch'};
vm.runInNewContext(ts.transpile('class Page {'+method('selectInputModeChoice')+'} exports.Page=Page;'),choiceContext);
const calls=[];
const page=Object.assign(new choiceContext.exports.Page(),{inputMode:'mouse',setInputMode(mode){calls.push(mode);this.inputMode=mode;}});
page.selectInputModeChoice('mouse');assert.deepEqual(calls,[],'clicking selected mode is idempotent');
page.selectInputModeChoice('touch');assert.deepEqual(calls,['touch']);
page.selectInputModeChoice('touch');assert.deepEqual(calls,['touch']);
page.selectInputModeChoice('mouse');assert.deepEqual(calls,['touch','mouse']);
page.selectInputModeChoice('unknown');assert.deepEqual(calls,['touch','mouse']);
const choice=method('buildControlInputModeChoice'), selector=method('buildControlInputModeSelector');
for(const name of ['buildControlInputModeChoice','buildControlInputModeSelector','buildInputModeChoice']) {
  assert.equal([...source.matchAll(new RegExp('^  '+name+'\\(', 'gm'))].length,1,'builder declarations must not shadow gesture-help builders');
}
assert(choice.includes("app.media.remote_menu_input") && choice.includes("app.media.remote_input_touch"));
assert(choice.includes('.width(16).height(16)'));
assert(choice.includes('Row({ space: 6 })') && choice.includes('justifyContent(FlexAlign.Center)'));
assert(!choice.includes('layoutWeight(1)') && !choice.includes('buildInputModeIcon('));
assert(choice.includes('.fontSize(13).minFontSize(11).maxFontSize(13)') && choice.includes('.maxLines(1).flexShrink(1)'));
assert(choice.includes('this.inputMode === mode ? this.controlSelectedBackgroundColor()'));
assert(choice.includes('.border({ width: this.inputMode === mode ? 1 : 0, color: this.controlSelectedBorderColor() })'),
  'unselected choice has no boxed outline; selected keeps the shared pale-blue treatment');
assert(choice.includes('.height(this.getControlActionHeight())'),
  'smaller visual content must not shrink the touch target');
assert(choice.includes('.focusable(false)') && choice.includes('.hitTestBehavior(HitTestMode.None)'));
assert(choice.includes('this.selectInputModeChoice(mode)') && !choice.includes('toggleInputMode('));
assert(choice.includes("openToolbarOrderEditor('control', 'input')"));
assert(choice.includes('鼠标模式') && choice.includes('触摸模式') && choice.includes('已选中'));
assert(selector.includes('inputSelectorStacked') && selector.includes('Column({ space: 4 })') && selector.includes('Row({ space: 4 })'));
assert.equal((selector.match(/this\.buildControlInputModeChoice\(INPUT_MODE_MOUSE\)/g)||[]).length,2);
assert.equal((selector.match(/this\.buildControlInputModeChoice\(INPUT_MODE_TOUCH\)/g)||[]).length,2);
const old=method('setInputMode');
for(const guard of ['this.cancelActiveTouchGesture()','this.setRelativeMouse(false)',"this.peerPreferences?.set('input-mode', mode)",'this.updateSystemPointerVisibility()']) {
  assert(old.includes(guard),'existing input cleanup and persistence remain authoritative');
}
const svg=read('entry/src/main/resources/base/media/remote_input_touch.svg');
assert(svg.includes('Material Icons touch_app, Apache-2.0') && svg.includes('viewBox="0 0 24 24"'));
assert(!/<script|href=|url\(|<image/.test(svg));
assert(read('entry/src/main/resources/rawfile/licenses/material-icons-Apache-2.0.txt').includes('Apache License'));
console.log(`PASS input mode selector: ${cases} responsive cases, explicit/idempotent choices, centered icons/text and unchanged input pipeline`);
