'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src/main/ets');
const read = file => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r\n/g, '\n');
const context = { exports: {} };
vm.runInNewContext(ts.transpile(read('theme/ReadableLayout.ets')), context);
const { readableInputHeight: inputHeight, readableLabelHeight: labelHeight } = context.exports;
let checks = 0;
for (const width of [120, 240, 280, 320, 396, 600, 720, 840, 1024, 1440, 1920]) {
  for (const scale of [1, 1.3, 1.8, 2, 2.8, 3.2]) {
    for (const size of [12, 14, 16, 18]) {
      const h = inputHeight(40, scale, size);
      assert(h >= 40 && h >= size * scale * 1.5 + 16 - 1, 'field reserves scaled line height and insets');
      for (const text of ['设置', '連線設定', 'Settings', 'View full connection details']) {
        const height = labelHeight(text, width, scale, size);
        assert(height >= 44 && Number.isFinite(height));
        assert(height >= labelHeight(text, width + 60, scale, size), 'narrower space must not reduce text height');
        assert(height >= labelHeight(text, width, 1, size), 'larger system fonts must not reduce height');
        checks++;
      }
    }
  }
}
for (const scale of [NaN, Infinity, 0, -1]) {
  assert.equal(inputHeight(40, scale), inputHeight(40, 1));
  assert.equal(labelHeight('Settings', NaN, scale), labelHeight('Settings', 120, 1));
}
const shape = read('theme/ButtonShapeModifier.ets'), readable = read('theme/ReadableButtonModifier.ets');
const types = { Normal: 'normal', Capsule: 'capsule' };
const c = { exports: {}, ButtonType: types, TextOverflow: { Clip: 'clip' },
  TextHeightAdaptivePolicy: { MAX_LINES_FIRST: 'lines' } };
vm.runInNewContext(ts.transpile(shape), c); c.ButtonShapeModifier = c.exports.ButtonShapeModifier;
vm.runInNewContext(ts.transpile(readable.replace(/^import .*\n/gm, '')), c);
for (const rectangular of [false, true]) {
  const calls = {};
  new c.exports.ReadableButtonModifier(rectangular).applyNormalAttribute({
    type: value => { calls.type = value; }, borderRadius: value => { calls.radius = value; },
    labelStyle: value => { calls.label = value; }
  });
  assert.equal(calls.type, rectangular ? 'normal' : 'capsule');
  assert.equal(calls.label.overflow, 'clip'); assert.equal(calls.label.maxLines, 100);
  assert.equal(calls.label.heightAdaptivePolicy, 'lines');
}
const method = (file, name) => {
  const s = read(file), start = s.indexOf('\n  ' + name + '('); assert(start >= 0, name);
  return s.slice(start, s.indexOf('\n  }', start) + 4);
};
const pctx = { exports: {}, translate: text => text };
vm.runInNewContext(ts.transpile('class Page {' + method('pages/ConnectionPage.ets', 'showSavedConnectionDetails') +
  '} exports.Page=Page;'), pctx);
const page = new pctx.exports.Page();
page.peerOnlineQueryEnabled = true; page.peerOnlineStateHint = () => '在线'; page.showFullText = text => { page.details = text; };
const item = { name: 'Very long MacBook name '.repeat(80), remoteId: 'MixedCase-AbCd123', password: 'must-not-be-shown' };
page.showSavedConnectionDetails(item);
assert(page.details.includes(item.name) && page.details.includes(item.remoteId));
assert(!page.details.includes(item.password), 'full text viewer never receives saved passwords');
const viewer = read('widget/FullTextDialog.ets');
assert(viewer.includes('Scroll()') && viewer.includes('.layoutWeight(1)') && viewer.includes('CopyOptions.LocalDevice'));
assert(!viewer.includes('.maxLines(') && !viewer.includes('TextOverflow.Ellipsis'));
for (const file of ['pages/ConnectionPage.ets', 'pages/RemotePage.ets']) {
  const s = read(file);
  assert(s.includes('FullTextDialog(') && s.includes('LongPressGesture().onAction('), file);
}
assert(read('widget/FileTransferHistoryDialog.ets').includes('showAlertDialog({ title:'));
const glass = read('widget/RemoteGlassMenu.ets');
assert(!glass.includes('.maxLines(') && !glass.includes('TextOverflow.Ellipsis'));
assert(glass.includes('.constraintSize({ minHeight: this.metrics.rowHeight })'));
assert(glass.includes('.constraintSize({ minHeight: this.metrics.footerHeight })'));
assert(glass.includes(".layoutWeight(1).scrollBar(BarState.Off)"), 'growing rows stay inside a scrollable bounded popup');
const menuContext = { exports: {}, translate: (text, language) => language === 'en' ? text.replace('屏幕', 'Screen') : text };
vm.runInNewContext(ts.transpile('class Menu {' + method('widget/RemoteGlassMenu.ets', 'screenCaptionWidth') +
  method('widget/RemoteGlassMenu.ets', 'verticalSegment') + '} exports.Menu=Menu;'), menuContext);
const menu = new menuContext.exports.Menu();
for (const scale of [1, 1.3, 2, 3.2]) for (const language of ['zh-Hans','zh-Hant','en']) for(const display of [0,11,999]) {
  Object.assign(menu, { uiFontScale:scale,language, metrics:{displayWidth:70, stacked:true} });
  assert(menu.screenCaptionWidth(display) >= 70);
  assert(menu.verticalSegment('mode-mouse') && menu.verticalSegment('orientation-auto'));
  assert(!menu.verticalSegment('tab-more') && !menu.verticalSegment('view-custom'));
}
assert(glass.includes(".width(this.screenCaptionWidth(display))"));
assert(glass.includes('this.zoomControls()') && !glass.includes('.width(58).height(30)'), 'zoom values can grow at large font sizes');
for (const file of ['pages/SettingsPage.ets', 'widget/CompactConnectionModeMenu.ets', 'widget/KeyboardLayoutCalibrationDialog.ets',
  'widget/SavedConnectionEditorDialog.ets']) assert(!read(file).includes('TextOverflow.Ellipsis'), file);
const remote = read('pages/RemotePage.ets');
assert(remote.includes('this.openRemoteDirectory(this.joinRemotePath(entry.name))'));
assert(remote.includes('this.toggleRemoteDownloadEntry(entry)'));
const captureStart = remote.indexOf("Button('', { stateEffect: false })");
const capture = remote.slice(captureStart, remote.indexOf('\n  }', captureStart));
assert(!capture.includes('ReadableButtonModifier') && !capture.includes('readableInputHeight'), 'remote coordinate capture geometry stays untouched');
assert(read('pages/HomePage.ets').includes('readableLabelHeight('));
console.log(`PASS readable text: ${checks} width/font/language layout checks, shared label/shape policy, full safe names, scrolling and unchanged remote input actions (not a device render test)`);
