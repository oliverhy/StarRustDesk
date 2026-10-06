'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8').replace(/\r\n/g, '\n');
const context = { exports: {} };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/RemoteControlMenu.ets')), context);
const { compactControlMenuMetrics: metrics, placeCompactControlMenu: place, remoteControlCategoryItems } = context.exports;
// Synthetic logical-vp viewports, not claimed measurements of specific product models.
const sizes = [[280,640],[320,740],[360,720],[396,780],[480,840],[600,820],[720,720],
  [780,520],[840,600],[1040,700],[600,960],[800,1280],[1024,768],[1280,800],
  [1440,900],[1920,1080],[300,240],[240,160],[360,180],[840,150],[120,80],[16,16]];
let cases = 0;
for (const [width, height] of sizes) for (const scale of [1,1.3,1.8,2,2.8,3.2]) {
  for (const handheld of [true,false]) for (const category of ['screens','input','view','more']) {
    for (const displays of [1,3,16]) {
      const m = metrics(category, width, height, scale, displays, 9, handheld, category === 'view' && !handheld, true);
      assert(m.width > 0 && m.height > 0 && m.width <= width && m.height <= height);
      assert(m.rowHeight >= (handheld ? 44 : 38));
      assert(m.width <= 380, 'wide displays must not produce a huge popup');
      if (category === 'screens') assert.equal(m.contentHeight, m.rowHeight, 'one horizontal row; no unused scrollbar strip');
      assert.equal(m.frameInset, 18, 'padding plus the two border edges');
      assert.equal(m.contentWidth, Math.max(1,m.width-m.frameInset));
      assert.equal(m.bodyHeight, Math.max(1,m.height-m.frameInset));
      for (const [x,y] of [[8,8],[width-56,8],[8,height-56],[width-56,height-56]]) {
        for (const side of [false,true]) {
          const pos = place(m, {category,x,y,width:48,height:48}, side);
          assert(pos.x >= 0 && pos.y >= 0 && pos.x + m.width <= width + 0.001 && pos.y + m.height <= height + 0.001);
          cases++;
        }
      }
    }
  }
}
const phone = metrics('screens',396,780,1,3,1,true,false,false);
assert.equal(phone.width,198); assert.equal(phone.height,62);
assert.equal(phone.contentWidth,180); assert.equal(phone.bodyHeight,44);
const input = metrics('input',396,780,1,3,4,true,false,false);
assert.equal(input.width,224); assert.equal(input.height,200);
assert.equal(input.contentWidth,206); assert.equal(input.bodyHeight,182);
assert.equal(input.contentHeight,input.bodyHeight,'last selected row fits completely inside the scroll viewport');
const more = metrics('more',396,780,1,3,9,true,false,false,78);
assert.equal(more.width,116); assert(more.height <= 420); assert.equal(more.actionPadding,8);
assert.equal(metrics('view',396,780,1,3,7,true,false,false,65).width,103);
assert.equal(metrics('view',1040,700,1,3,7,false,true,true).width,224,'PC slider and scale rows retain space');
const large = metrics('more',396,780,2.8,3,9,true,false,false,78*2.8);
assert(large.rowHeight > more.rowHeight && large.width > more.width);
assert(large.contentHeight > large.bodyHeight, 'large menus must scroll instead of compressing all rows');
for (const invalid of [NaN,Infinity,-1,0]) {
  const m = metrics('screens',invalid,invalid,invalid,invalid,invalid,true,false,false);
  assert(Number.isFinite(m.width) && Number.isFinite(m.height) && m.width > 0 && m.height > 0);
}
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => { const start=source.indexOf('\n  '+name+'('); assert(start>=0,name); return source.slice(start,source.indexOf('\n  }',start)+4); };
const methods = ['getControlMenuMetrics','getVisibleControlMenuItems','getControlMenuViewportHeight','getControlMenuAnchor',
  'getControlMenuX','getControlMenuY','getControlMenuWidth','getControlMenuHeight','isControlMenuBesideToolbar',
  'recordControlMenuAnchor','getControlMenuRowWidth','getControlActionWidth','getControlActionHeight','getControlActionPadding'];
const pageContext = { exports: {}, compactControlMenuMetrics:metrics, placeCompactControlMenu:place, remoteControlCategoryItems };
vm.runInNewContext(ts.transpile('class Page {'+methods.map(method).join('\n')+'} exports.Page=Page;'),pageContext);
const p = Object.assign(new pageContext.exports.Page(), {
  pageWidth:396,pageHeight:780,controlMenu:'screens',displayCount:3,uiFontScale:1,
  controlToolbarOrder:['displays','input','virtualMouse','mobileActions','gestureHelp','clipboard','edgePan','pan','zoomIn','zoomOut','fullscreen','pip','privacy','orientation'],
  isPcDevice:()=>false,isHandheldDevice:()=>true,isHandheldLandscape:()=>false,isLargeLayout:()=>false,
  canPanViewport:()=>false,isPeerAndroid:false,desktopViewMode:'adaptive',isFullScreen:false,immersiveWindow:false,
  controlMenuAnchors:[],controlMenuPageOriginX:0,controlMenuPageOriginY:24,
  getRemoteToolbarX:()=>8,getRemoteToolbarY:()=>694,getSideToolbarHeight:()=>338,
  showKeyboardPanel:false,controlMenuKeyboardInset:0,keyboardLayoutHeight:0,
  adaptiveToolbarButtonWidth:n=>n,getRemoteToolbarButtonHeight:()=>40,
  getControlMenuLabelWidth:()=>0,
});
p.recordControlMenuAnchor('screens',{globalPosition:{x:92,y:730},width:48,height:48});
const anchors=p.controlMenuAnchors;
p.recordControlMenuAnchor('screens',{globalPosition:{x:92,y:730},width:48,height:48});
assert.equal(p.controlMenuAnchors,anchors,'same area must not cause a relayout/state loop');
assert.equal(p.getControlMenuX(),92); assert.equal(p.getControlMenuY(),636);
p.pageWidth=320;p.controlMenuPageOriginX=80;
assert.equal(p.getControlMenuX(),12,'anchor uses window-relative coordinates after moving/resizing');
p.controlMenu='input';
assert.equal(p.getControlActionPadding(),12,'input retains its existing padding');
assert.deepEqual(Array.from(p.getVisibleControlMenuItems()),['input','virtualMouse','gestureHelp','clipboard']);
p.controlMenu='view';
assert.deepEqual(Array.from(p.getVisibleControlMenuItems()),['zoomIn','zoomOut','fullscreen','pip','orientation']);
assert.equal(p.getControlMenuMetrics().contentHeight,5*44+4*2,
  'unzoomed menu height includes exactly five rendered actions');
p.canPanViewport=()=>true;
assert.deepEqual(Array.from(p.getVisibleControlMenuItems()),['edgePan','pan','zoomIn','zoomOut','fullscreen','pip','orientation']);
assert.equal(p.getControlMenuMetrics().contentHeight,7*44+6*2);
p.canPanViewport=()=>false;p.controlMenu='input';
p.isHandheldDevice=()=>false;p.isPeerAndroid=true;
assert.deepEqual(Array.from(p.getVisibleControlMenuItems()),['input','mobileActions','gestureHelp','clipboard']);
p.showKeyboardPanel=true;p.keyboardLayoutHeight=780;p.controlMenuKeyboardInset=300;
assert.equal(p.getControlMenuViewportHeight(),480);
p.pageHeight=480;assert.equal(p.getControlMenuViewportHeight(),480,'do not subtract IME twice after root resize');
p.pageHeight=150;assert.equal(p.getControlMenuViewportHeight(),150);
p.showKeyboardPanel=false;assert.equal(p.getControlMenuViewportHeight(),150);
p.controlMenu='more';assert.equal(p.getControlActionPadding(),8);
p.controlMenu='view';assert.equal(p.getControlActionPadding(),8);
p.controlMenu='';assert.equal(p.getControlActionPadding(),2,'fixed toolbar spacing is unchanged');
const overlay=method('buildControlMenuOverlay');
assert(overlay.includes('this.buildCompactDisplayMenu()'));
assert(overlay.includes('this.getVisibleControlMenuItems()'));
assert(!overlay.includes('FlexWrap.Wrap') && !overlay.includes('当前屏幕') && !overlay.includes('Divider()'));
assert(overlay.includes('.onClick(() => { this.setControlMenu(\'\'); })'),'dismiss tap remains local');
assert(overlay.includes('.height(this.getControlMenuMetrics().bodyHeight).scrollBar(BarState.Off)'));
assert(!overlay.includes('BarState.Auto'));
assert(overlay.includes('.align(Alignment.TopStart)') && overlay.includes('.justifyContent(FlexAlign.Start)'),
  'spare viewport space is not split above and below the content');
const display=method('buildCompactDisplayMenu');
assert(display.includes('ScrollDirection.Horizontal') && display.includes('this.switchDisplay(display)'));
assert(display.includes('.height(this.getControlMenuMetrics().bodyHeight)') && display.includes('BarState.Off'));
assert(!display.includes('BarState.Auto') && !display.includes('padding({ bottom: 6 })'));
assert(display.includes('this.controlSelectedBackgroundColor()') && display.includes('openToolbarOrderEditor'));
for(const name of ['buildToolbarButton','buildFullscreenButton','buildEdgeAutoPanButton']) {
  assert(method(name).includes('this.getControlActionWidth(buttonWidth)'));
  assert(method(name).includes('this.getControlActionHeight()'));
  assert(method(name).includes('TextAlign.Start'));
  assert(method(name).includes('.padding({ left: this.getControlActionPadding(), right: this.getControlActionPadding() })'));
}
assert(method('buildInputModeButton').includes('this.buildControlInputModeSelector()'));
assert(method('buildControlInputModeChoice').includes('.height(this.getControlActionHeight())'));
assert(method('handleRemoteKeyboardHeightChange').includes('this.getUIContext().px2vp(height)'));
assert(method('stopRemoteKeyboardTracking').includes('this.controlMenuKeyboardInset = 0'));
console.log(`PASS compact control menus: ${cases} geometry/anchor combinations, fold/window/IME/font variants and production integration`);
