'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r\n/g, '\n');
const context = { exports: {} };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/RemoteControlMenu.ets')), context);
const { compactControlMenuMetrics: metrics, placeCompactControlMenu: place,
  remoteControlMenuWidthLabels: labels, estimateControlMenuTextWidth: estimate } = context.exports;
const catalog = { exports: {} };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/utils/I18nCatalog.ets')), catalog);
const translate = (label, language) => language === 'en' ? catalog.exports.ENGLISH[label] ?? label :
  language === 'zh-Hant' ? catalog.exports.TRADITIONAL[label] ?? label : label;
const items = {
  view: ['edgePan','pan','zoomIn','zoomOut','fullscreen','pip','orientation'],
  more: ['chat','upload','uploadFolder','download','recording','recordings','privacy'],
};
let cases = 0;
for (const [width,height] of [[120,80],[240,160],[280,640],[320,740],[396,780],[600,820],[720,720],
  [780,520],[840,600],[1040,700],[600,960],[800,1280],[1024,768],[1280,800],[1920,1080]]) {
  for (const scale of [1,1.3,1.8,2,2.8,3.2]) for (const language of ['zh-Hans','zh-Hant','en']) {
    for (const handheld of [true,false]) for (const category of ['view','more']) {
      const desktop = category === 'view' && !handheld;
      const longest = Math.max(...labels(category,items[category],desktop).map(label => estimate(translate(label,language),scale)));
      const m = metrics(category,width,height,scale,3,9,handheld,desktop,true,longest);
      const baseline = metrics(category,width,height,scale,3,9,handheld,desktop,true);
      assert(m.width >= baseline.width && m.width <= Math.min(width,380));
      assert.equal(m.rowHeight,baseline.rowHeight,'width tuning must not shrink click targets');
      assert.equal(m.height,baseline.height,'width tuning must not change scroll height');
      assert.equal(m.actionPadding,8);
      const required = Math.max((handheld?44:38)+18,longest+38,desktop?224+(scale-1)*64:0);
      assert.equal(m.width,Math.max(1,Math.min(Math.ceil(required),380,width-Math.min(8,width/4)*2)));
      for (const [x,y] of [[8,8],[width-48,8],[8,height-48],[width-48,height-48]]) {
        for(const beside of [false,true]) {
          const pos = place(m,{category,x,y,width:48,height:48},beside);
          assert(pos.x>=0 && pos.y>=0 && pos.x+m.width<=width+0.001 && pos.y+m.height<=height+0.001);
        }
      }
      cases++;
    }
  }
}
assert.equal(metrics('view',396,780,1,3,7,true,false,false,65).width,103);
assert.equal(metrics('more',396,780,1,3,9,true,false,false,78).width,116);
assert.equal(metrics('view',396,780,1,3,7,true,false,false,30).width,68,
  'short labels do not inherit an arbitrary 168/176 vp floor');
assert.equal(metrics('more',396,780,1,3,9,true,false,false,130).width,168);
assert.equal(metrics('more',396,780,1,3,9,true,false,false,65).width,103,
  'smaller measured labels shrink the menu again');
assert.equal(metrics('view',1040,700,1,3,7,false,true,true,65).width,224,
  'PC view slider has an explicit reserve independent of short labels');
for(const category of ['input','screens']) {
  const before=metrics(category,396,780,1,3,4,true,false,false);
  assert.equal(before.actionPadding,12);
  assert.equal(metrics(category,396,780,1,3,4,true,false,false,10000).width,before.width,
    'label-based expansion is scoped to view/more');
}
for(const invalid of [NaN,Infinity,-1,0]) {
  assert.equal(metrics('more',396,780,1,3,9,true,false,false,invalid).width,62,
    'invalid width hints retain only the minimum click area; production supplies estimated translated labels');
  assert(Number.isFinite(estimate('边缘跟随',invalid)));
}
assert.deepEqual(Array.from(labels('input',items.more,false)),[]);
assert(!labels('view',['fullscreen'],false).includes('边缘跟随开'),'hidden items do not reserve width');
for(const label of ['全屏','退出全屏','切换中…']) assert(labels('view',['fullscreen'],false).includes(label));
for(const label of ['发送文件夹','隐私屏处理中','连接信息','工具栏排序']) assert(labels('more',items.more,false).includes(label));

const source=read('entry/src/main/ets/pages/RemotePage.ets');
const method=name=>{const start=source.indexOf('\n  '+name+'(');assert(start>=0,name);return source.slice(start,source.indexOf('\n  }',start)+4);};
const native = { density:3, fail:false, bad:false, calls:0 };
const pageContext={ exports:{}, remoteControlMenuWidthLabels:labels, estimateControlMenuTextWidth:estimate, translate };
vm.runInNewContext(ts.transpile('class Page {'+method('getControlMenuLabelWidth')+'} exports.Page=Page;'),pageContext);
const page=Object.assign(new pageContext.exports.Page(), {
  controlMenu:'more',uiLanguage:'zh-Hans',uiFontScale:1,pageWidth:396,pageHeight:780,
  controlMenuLabelMeasureKey:'',controlMenuLabelMeasuredWidth:0,
  isPcDevice:()=>false,getVisibleControlMenuItems:()=>items.more,chatToolbarLabel:()=> '聊天 12',
  getUIContext:()=> ({
    vp2px:value=>value*native.density,px2vp:value=>value/native.density,
    getMeasureUtils:()=>({measureText:options=>{
      native.calls++;assert.equal(options.fontSize,'13fp');assert.equal(options.fontWeight,600);
      if(native.fail) throw Error('window unavailable');
      if(native.bad) return NaN;
      return estimate(options.textContent,page.uiFontScale)*native.density;
    }}),
  }),
});
const measured=page.getControlMenuLabelWidth(), firstCalls=native.calls;
assert(measured>0 && firstCalls>0);
assert.equal(page.getControlMenuLabelWidth(),measured);assert.equal(native.calls,firstCalls,'cache prevents repeat frame measurements');
for(const change of [()=>page.uiLanguage='en',()=>page.uiFontScale=2,()=>page.pageWidth=840,
  ()=>page.pageHeight=600,()=>native.density=2,()=>page.chatToolbarLabel=()=> '聊天 123456789']) {
  const before=native.calls;change();assert(page.getControlMenuLabelWidth()>0);assert(native.calls>before);
}
native.fail=true;page.pageWidth++;assert(page.getControlMenuLabelWidth()>0,'measurement exceptions use conservative translated width');
native.fail=false;native.bad=true;page.pageWidth++;assert(page.getControlMenuLabelWidth()>0,'non-finite native result uses fallback');
const before=native.calls;page.controlMenu='input';assert.equal(page.getControlMenuLabelWidth(),0);assert.equal(native.calls,before);
assert(method('getControlMenuMetrics').includes('this.getControlMenuLabelWidth()'));
assert(!/\bRustDeskNapi\b|\banimateTo\b|\bsetControlMenu\(/.test(method('getControlMenuLabelWidth')),
  'measurement must not mutate menu state or remote input');
console.log(`PASS adaptive menu widths: ${cases} window/font/language/device layouts, unchanged touch targets, PC slider reserve and measurement cache/fallback`);
