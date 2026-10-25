'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const read=p=>fs.readFileSync(path.join(__dirname,'..',p),'utf8').replace(/\r\n/g,'\n');
const context={exports:{}};
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/RemoteGlassMenu.ets')),context);
const {RemoteGlassMenuState:State,glassMenuMetrics:metrics,placeGlassMenu:place}=context.exports;
let checks=0;
const baseline={screens:252,input:224,keyboard:224,view:224,more:204,orientation:244};
for(const category of Object.keys(baseline)){
 const s=new State();s.category=category;s.displayCount=3;s.followSystem=false;
 s.items=category==='input'?['input','virtualMouse','clipboard','gestureHelp']:category==='view'?
 ['zoomIn','zoomOut','pan','edgePan','fullscreen','pip','orientation']:
 ['upload','uploadFolder','download','chat','recording','recordings','privacy'];
 const base=metrics(s,396,780,1);assert.equal(base.width,baseline[category]);
 for(const [w,h] of [[120,80],[240,160],[280,640],[360,780],[600,820],[840,400],[1024,768],[1440,900]]){
  for(const scale of [1,1.3,1.8,2.8,3.2])for(const [x,y] of [[8,8],[w-48,8],[8,h-48],[w-48,h-48]]){
   const m=metrics(s,w,h,scale),p=place(m,w,h,x,y,40,48);
   assert(m.width>0&&m.height>0&&m.width<=w&&m.height<=h);
   assert(p.x>=0&&p.y>=0&&p.x+m.width<=w+.001&&p.y+m.height<=h+.001);
   assert(m.rowHeight>=base.rowHeight);assert(m.bodyHeight>0);
   if(p.arrowVisible)assert(p.arrowX>=18&&p.arrowX<=m.width-18);
   checks++;
  }
 }
}
const widget=read('entry/src/main/ets/widget/RemoteGlassMenu.ets'),page=read('entry/src/main/ets/pages/RemotePage.ets');
const pc=new State();pc.category='view';pc.items=['zoomIn','zoomOut','fullscreen','pip'];
const handheld=metrics(pc,1024,768,1);pc.desktop=true;
for(const mode of ['adaptive','original','custom']){
 pc.desktopViewMode=mode;const m=metrics(pc,1024,768,1);
 assert.equal(m.width,248);assert.equal(m.contentHeight-handheld.contentHeight,
 m.segmentHeight+(mode==='custom'?5:4)*m.rowHeight+9,'PC reserves only the rows it actually renders');
}
const screen=new State();screen.category='screens';screen.displayCount=16;
assert.equal(metrics(screen,396,780,1).displayWidth,70);
assert(metrics(screen,396,780,3.2).displayWidth>=180,'large-font screen captions scroll rather than clip');
const direction=new State();direction.category='orientation';
for(const projection of [false,true])for(const followSystem of [false,true])for(const scale of [1,1.3,2.8]){
 direction.projection=projection;direction.followSystem=followSystem;
 const m=metrics(direction,396,780,scale,0,76);
 assert.equal(m.footerHeight,Math.max(Math.ceil(18*scale),76));
 const rows=(projection?0:m.rowHeight+10)+((!followSystem||projection)?
  (m.stacked?3*m.segmentHeight+4:m.segmentHeight):0);
 assert.equal(m.contentHeight,m.headerHeight+rows+10+m.footerHeight,'all direction rows, both margins and wrapped footer fit');
}
const method=(s,name)=>{const start=s.indexOf('\n  '+name+'(');assert(start>=0,name);return s.slice(start,s.indexOf('\n  }',start)+4);};
const ui={exports:{}};
vm.runInNewContext(ts.transpile('class Menu{'+['gridKeys','gridRows','rowKeys','shortcutKeys','extraKeys','keySelected','actionEnabled','segmentSelected']
 .map(n=>method(widget,n)).join('\n')+'}exports.Menu=Menu;'),ui);
const s=new State();s.keyboardItems=['Esc','Tab','Del','Home','End','PgUp','Left','Up','PgDn','Down','Right','Enter',
 'Ctrl+Alt+Del','Ctrl+Shift+Esc','Ins','Ctrl+Shift+Del','Alt+F4'];s.canSendCtrlAltDel=true;
const m=Object.assign(new ui.exports.Menu(),{state:s,metrics:{stacked:false}});
assert.equal(m.gridRows().length,4);assert.deepEqual(Array.from(m.rowKeys(0)),['Esc','Tab','Del']);
assert.deepEqual(Array.from(m.rowKeys(3)),['Down','Right','Enter']);
assert.deepEqual(Array.from(m.shortcutKeys()),['Ctrl+Alt+Del','Ctrl+Shift+Esc']);
assert.deepEqual(Array.from(m.extraKeys()),['Ins','Ctrl+Shift+Del','Alt+F4']);
s.canSendCtrlAltDel=false;assert(!m.shortcutKeys().includes('Ctrl+Alt+Del'));
for(const [key,mask] of [['Ctrl',1],['Alt',2],['Shift',4],['Win/Cmd',8]]){
 s.modifiers=mask;assert(m.keySelected(key));assert(!m.keySelected('Enter'));
}
s.transferBusy=true;for(const key of ['upload','download','uploadFolder'])assert(!m.actionEnabled(key));
for(const tab of ['modifiers','function','more']){
 s.keyboardTab=tab;assert(m.segmentSelected('tab-'+tab));
 for(const other of ['modifiers','function','more'].filter(x=>x!==tab))assert(!m.segmentSelected('tab-'+other));
}
const segment=widget.slice(widget.indexOf('\n  segment('),widget.indexOf('\n  @Builder',widget.indexOf('\n  segment(')));
assert(segment.includes('this.segmentSelected(key)'));
assert(!/selected \?/.test(segment),'Builder primitive snapshots must not drive live selection');
assert(segment.includes("!key.startsWith('mode-')"),'mouse and touch selection do not show a checkmark');
assert(segment.includes("!key.startsWith('orientation-')"),'orientation selection does not show a checkmark');
assert(widget.includes("this.state.category === 'orientation' && this.state.projection"),
 'only temporary projection orientation shows the session marker');
assert(widget.includes('.constraintSize({ minHeight: this.metrics.footerHeight })'));
assert(!widget.includes('.maxLines('), 'menu text can grow and scroll instead of being capped');
assert(method(page,'getGlassMenuMetrics').includes('measureTextSize'),'orientation footer height follows translated text and font scale');
const calls=[],pctx={exports:{},VIRTUAL_MODIFIER_CTRL:17,VIRTUAL_MODIFIER_ALT:18,VIRTUAL_MODIFIER_SHIFT:16,VIRTUAL_MODIFIER_META:91,
 MODIFIER_MASK_CTRL:2,MODIFIER_MASK_SHIFT:1,MODIFIER_MASK_ALT:4};
vm.runInNewContext(ts.transpile('class Page{'+method(page,'sendGlassMenuKey')+'}exports.Page=Page;'),pctx);
const p=Object.assign(new pctx.exports.Page(),{controlMenu:'keyboard',canSendCtrlAltDel:true,
 toggleVirtualModifier:code=>calls.push(['modifier',code]),sendVirtualControlKey:(...v)=>calls.push(['key',...v]),
 sendPresetShortcut:(...v)=>calls.push(['shortcut',...v]),sendCtrlAltDel:()=>calls.push(['secure'])});
for(const [key,code] of [['Esc',27],['Enter',13],['Home',36],['End',35],['Left',37],['Up',38],['Down',40],['Right',39],['F1',112],['F12',123]]){
 p.sendGlassMenuKey(key);assert.deepEqual(calls.at(-1),['key',code,key]);
}
p.sendGlassMenuKey('Ctrl+Shift+Esc');assert.deepEqual(calls.at(-1),['shortcut',27,3,'Ctrl+Shift+Esc']);
for(const [key,code] of [['Ctrl',17],['Alt',18],['Shift',16],['Win/Cmd',91]]){p.sendGlassMenuKey(key);assert.deepEqual(calls.at(-1),['modifier',code]);}
const count=calls.length;for(const key of ['F0','F13','password','not-a-key'])p.sendGlassMenuKey(key);assert.equal(calls.length,count);
p.canSendCtrlAltDel=false;p.sendGlassMenuKey('Ctrl+Alt+Del');assert.equal(calls.length,count);
p.controlMenu='view';p.sendGlassMenuKey('Enter');assert.equal(calls.length,count);
assert(widget.includes('.fontFamily(Style.FONT)'));assert(widget.includes('.selectedColor(Style.BLUE)'));
const scrollHint=method(widget,'scrollHint');
assert(scrollHint.includes("Image($r('app.media.glass_chevron'))")&&scrollHint.includes('up ? 270 : 90'),
 'overflowing secondary menus show direction-aware chevron hints');
assert(!/\bText\(/.test(scrollHint),'the scroll affordance has no visible text');
assert(scrollHint.includes('.backgroundColor(Color.Transparent)')&&!scrollHint.includes('.border('),
 'scroll chevrons have no visible background or border');
assert(widget.includes('this.keyboardScrollY > 0.5')&&widget.includes('!this.keyboardScrollAtEnd'),
 'the keyboard menu shows up/down arrows according to its scroll position');
assert(widget.includes('this.menuScrollY > 0.5')&&widget.includes('!this.menuScrollAtEnd'),
 'other secondary menus show up/down arrows according to their scroll position');
const keyboardMenu=method(widget,'keyboard');
assert(!keyboardMenu.includes('Stack({ alignContent: Alignment.Center })')&&
 keyboardMenu.includes('this.keyboardScrollHint(true)')&&keyboardMenu.includes('this.keyboardScrollHint(false)'),
 'scroll hints stay outside the keyboard scroll viewport and cannot intercept vertical swipes');
assert(method(widget,'keyboardScrollHint').includes("height(18)")&&
 method(widget,'menuScrollHint').includes("height(18)"),
 'scroll hints occupy only their transparent edge rows');
assert(widget.includes('this.metrics.contentHeight > this.metrics.bodyHeight + 1'),'the hint is limited to vertically overflowing menus');
const overflow=(new Function(method(widget,'hasVerticalOverflow').replace(/^\s*hasVerticalOverflow\(\): boolean\s*/, '')));
assert.equal(overflow.call({state:{category:'view',keyboardTab:'more'},metrics:{contentHeight:220,bodyHeight:180}}),true);
assert.equal(overflow.call({state:{category:'view',keyboardTab:'more'},metrics:{contentHeight:180,bodyHeight:180}}),false);
for(const keyboardTab of ['function','more'])assert.equal(overflow.call({state:{category:'keyboard',keyboardTab},metrics:{contentHeight:180,bodyHeight:180}}),true);
assert(!widget.includes('ButtonShapeModifier')&&!widget.includes('BarState.Auto'));
assert(method(page,'buildControlMenuOverlay').includes('backgroundColor(Color.Transparent)'));
assert(method(page,'buildControlMenuOverlay').includes('BlurStyle.COMPONENT_ULTRA_THIN'));
assert(method(page,'buildControlMenuOverlay').includes('AdaptiveColor.DEFAULT'));
assert(method(page,'buildControlMenuOverlay').includes('.enabled(!this.controlMenuClosing)'));
assert(!method(page,'showOrientationMenu').includes('showActionMenu'));
console.log(`PASS prototype glass menus: ${checks} geometry/font/window cases, exact baseline widths, 12 keycap layout, extra-key preservation, protocol actions and input isolation`);
