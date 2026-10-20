'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root=path.resolve(__dirname,'..'),read=p=>fs.readFileSync(path.join(root,p),'utf8');
const source=read('entry/src/main/ets/pages/RemotePage.ets');
const ctx={exports:{},ConnectionStatus:{CONNECTED:2},RustDeskNapi:{appendDiagnosticLog(){}}};
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/RemoteDesktopView.ets')),ctx);
ctx.nextZoomPercent=ctx.exports.nextZoomPercent;
const next=ctx.nextZoomPercent;
function method(name){const start=source.indexOf('\n  '+name+'(');assert(start>=0,name);return source.slice(start,source.indexOf('\n  }',start)+4);}
vm.runInNewContext(ts.transpile('class Page{'+['adjustZoom','resetZoomTo100','handleGlassMenuAction'].map(method).join('\n')+'} exports.Page=Page;'),ctx);
function fixture(pc=false){const saved=[],calls=[];const p=Object.assign(new ctx.exports.Page(),{
 zoomScale:3.46,offsetX:87,offsetY:-102,pipSurfaceOwned:false,pinchStartScale:3.46,
 componentWidth:800,componentHeight:480,remotePageVisible:true,connectionStatus:2,
 controlMenu:'view',controlMenuClosing:false,isPcDevice:()=>pc,
 peerPreferences:{set:(...args)=>saved.push(args)},
 applyZoomAt(x,y,scale){calls.push(['zoom',x,y,scale]);this.zoomScale=scale;},
 cancelActiveTouchGesture(){calls.push(['cancel']);this.viewportPanActive=false;this.isPinching=false;},
 setPanMode(v){this.isPanMode=v;},syncVirtualMouseToCurrentPointer(){calls.push(['cursor']);},
 getDesktopDisplayedPercent:()=>121,setDesktopCustomPercent:v=>calls.push(['pc-percent',v]),
 selectDesktopViewMode:v=>calls.push(['pc-mode',v])});return {p,saved,calls};}
assert.equal(next(121,-1,50,500),100);assert.equal(next(96,1,50,500),100);
assert.equal(next(346,-1,50,500),325);assert.equal(next(346,1,50,500),350);
assert.equal(next(100,-1,50,500),75);assert.equal(next(100,1,50,500),125);
assert.equal(next(100.00000001,-1,50,500),75,'floating point noise cannot stick on a stop');
assert.equal(next(99.99999999,1,50,500),125);
assert.equal(next(NaN,-1,50,500),75);assert.equal(next(121,NaN,50,500),121);
for(const [min,max] of [[50,500],[25,300]])for(let n=min;n<=max;n+=0.71){
 const up=next(n,1,min,max),down=next(n,-1,min,max);
 assert(up>=n-1e-7&&up<=max);assert(down<=n+1e-7&&down>=min);
 assert.equal(up%25,0);assert.equal(down%25,0);
 let v=n;for(let i=0;i<25&&v>100;i++)v=next(v,-1,min,max);
 if(n>=100)assert.equal(v,100,'every arbitrary value above 100 reaches exactly 100');
 v=n;for(let i=0;i<25&&v<100;i++)v=next(v,1,min,max);
 if(n<=100)assert.equal(v,100,'every arbitrary value below 100 reaches exactly 100');
}
let h=fixture();h.p.handleGlassMenuAction('zoomOut');assert.equal(h.p.zoomScale,3.25);
h.p.zoomScale=1.21;h.p.handleGlassMenuAction('zoomOut');assert.equal(h.p.zoomScale,1);
assert.deepEqual(h.saved.at(-1),['handheld-zoom','1']);
h.p.zoomScale=.96;h.p.handleGlassMenuAction('zoomIn');assert.equal(h.p.zoomScale,1);
h.p.zoomScale=3.46;h.p.handleGlassMenuAction('zoomReset');
assert.equal(h.p.zoomScale,1);assert.equal(h.p.offsetX,0);assert.equal(h.p.offsetY,0);
assert.equal(h.p.rememberedHandheldZoomScale,1);assert.equal(h.p.pinchStartScale,1);
assert.equal(h.p.isPanMode,false);assert.equal(h.p.controlMenu,'view','reset does not close the menu');
assert(h.calls.some(c=>c[0]==='cancel'));assert(h.calls.some(c=>c[0]==='cursor'));
h.p.offsetX=90;h.p.handleGlassMenuAction('zoomReset');assert.equal(h.p.offsetX,0,'100% can still recenter');
h=fixture(true);h.p.adjustZoom(-.25);assert.deepEqual(h.calls.at(-1),['pc-percent',100]);
h.p.resetZoomTo100();assert.deepEqual(h.calls.at(-1),['pc-mode','original'],'PC reset retains physical-pixel semantics');
h=fixture();h.p.pipSurfaceOwned=true;h.p.resetZoomTo100();h.p.adjustZoom(.25);assert.equal(h.calls.length,0);assert.equal(h.saved.length,0);
for(const overrides of [{remotePageVisible:false},{connectionStatus:0},{controlMenuClosing:true},{controlMenu:''}]){
 h=fixture();Object.assign(h.p,overrides);h.p.handleGlassMenuAction('zoomReset');assert.equal(h.calls.length,0);
}
const widget=read('entry/src/main/ets/widget/RemoteGlassMenu.ets');
const zoom=widget.slice(widget.indexOf('  zoomControls()'),widget.indexOf('\n  @Builder\n  zoom()'));
assert(!zoom.includes('Path()'),'no unscaled pixel paths for zoom controls');
for(const name of ['plus','minus']){
 assert(zoom.includes(`app.media.glass_zoom_${name}`));
 const svg=read(`entry/src/main/resources/base/media/glass_zoom_${name}.svg`);
 assert(svg.includes('viewBox="0 0 16 16"')&&svg.includes('<path'));
}
assert(zoom.includes(".id('glass-zoom-reset')")&&zoom.includes("this.onAction('zoomReset')"));
assert(zoom.includes("translate('恢复 100% 并居中'"));
assert(source.includes('this.isPcDevice() ? this.getDesktopDisplayedPercent() : Math.round(this.zoomScale * 100)'));
console.log('PASS zoom controls: arbitrary pinch -> standard stops -> exact 100%, bounds, zero/invalid input, reset/recenter persistence, PC semantics, lifecycle/PiP guards, SVG and action wiring');
