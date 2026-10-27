'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const overlay = page.slice(page.indexOf('  buildGestureHelpOverlay('), page.indexOf('  buildGestureGuideMode('));
const mode = page.slice(page.indexOf('  buildGestureGuideMode('), page.indexOf('  buildGestureGuideCard('));
const card = page.slice(page.indexOf('  buildGestureGuideCard('), page.indexOf('  buildVirtualMouseGuide('));
const virtual = page.slice(page.indexOf('  buildVirtualMouseGuide()'), page.indexOf('  buildGestureHelpSection('));
const details = page.slice(page.indexOf('  buildGestureHelpSection('), page.indexOf('  sendMobileAction('));
assert(overlay.includes("if (mouseSettings)"));
assert(overlay.includes("this.buildInputModeChoice(INPUT_MODE_MOUSE") && overlay.includes("this.buildInputModeChoice(INPUT_MODE_TOUCH"));
assert(mode.includes('this.gestureHelpView = mode') && !mode.includes('setInputMode') && !mode.includes('this.inputMode ='));
assert(overlay.includes('this.gestureHelpView = this.inputMode'));
assert(overlay.includes('仅切换说明预览，不改变当前输入模式'));
for (const text of ['轻点一次，再按住移动', '按住目标后立即移动', '单指双击', '单指长按',
  '双指轻点', '双指平行滑动', '双指捏合', '三指左右滑动', '全屏三指上滑', '三指切屏', '拖拽与框选']) {
  assert(overlay.includes(text), 'missing gesture: ' + text);
}
assert(overlay.includes('系统可能接管') && overlay.includes('触控板三指事件未开放给应用'));
for (const [title, icon] of [
  ['虚拟鼠标与画面跟随', 'guide_follow'], ['移动放大画面', 'guide_pan'],
  ['三指切屏', 'guide_three_finger'], ['手机 / 平板单独投屏', 'guide_projection'],
  ['拖拽与框选', 'guide_drag'], ['组合键与本地键盘', 'guide_shortcuts'],
  ['连续输入与键盘悬浮按钮', 'keyboard_launcher'], ['自定义实体键盘映射', 'guide_keymap'],
  ['实体键盘布局与校准', 'guide_calibration'], ['悬浮功能栏与移动画面', 'guide_toolbar']
]) assert(overlay.includes(`this.buildGestureHelpSection('${title}', $r('app.media.${icon}')`), title);
for (const text of ['按钮变为淡蓝色', '停手即停，抬手再滑无需等待', '是否提供该入口取决于设备',
  '默认关闭，按服务器和远端分别保存', '无法稳定识别时仅用于本次会话', '远端输入框没有可靠的焦点通知']) {
  assert(overlay.includes(text), 'missing condition: ' + text);
}
assert(details.includes("translate(details, this.uiLanguage).split('\\n')"));
assert(details.includes('Image(icon)') && details.includes('Text(paragraph)') && details.includes('this.isDarkMode'));
assert(details.includes('layoutWeight(1)') && !details.includes('.maxLines(') && !details.includes('.lineHeight('));
for (const label of ['左键', '右键', '向上滚动', '中键', '向下滚动', '按住底部移动区：移动鼠标']) assert(virtual.includes(label));
assert(card.includes('layoutWeight(1)') && card.includes('this.isDarkMode') && card.includes('accessibilityText'));
assert(!card.includes('.maxLines(') && !card.includes('.textOverflow('));
assert(overlay.includes('.layoutWeight(1)') && overlay.includes('.scrollBar('));
const icons = [...overlay.matchAll(/\$r\('app\.media\.(guide_[a-z_]+)'\)/g)].map(x => x[1]);
assert(new Set(icons).size >= 9);
for (const icon of new Set(icons)) {
  const svg = read(`entry/src/main/resources/base/media/${icon}.svg`);
  assert(svg.includes('<svg ') && svg.includes('viewBox="0 0 64 64"') && svg.includes('</svg>'), icon);
  assert(!/https?:\/\/(?!www\.w3\.org\/2000\/svg)/.test(svg), icon + ': no remote resources');
}
const ctx = { exports: {} };
vm.runInNewContext(ts.transpileModule(read('entry/src/main/ets/utils/I18nCatalog.ets'), { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, ctx);
for (const text of ['手势操作指南', '仅切换说明预览，不改变当前输入模式', '轻点一次，再按住移动',
  '按住目标后立即移动', '三指左右滑动', '切换远端屏幕', '按住底部移动区：移动鼠标']) {
  assert(ctx.exports.ENGLISH[text] && ctx.exports.TRADITIONAL[text], 'missing translation: ' + text);
}
const sections = [...overlay.matchAll(/this\.buildGestureHelpSection\('([^']+)',\s*\$r\('app\.media\.[^']+'\),\s*'((?:\\.|[^'])*)'\)/g)];
assert.equal(sections.length, 10, 'all detailed help sections must be illustrated');
for (const [, title, raw] of sections) {
  const key = raw.replace(/\\n/g, '\n');
  for (const locale of ['ENGLISH', 'TRADITIONAL']) {
    const translated = ctx.exports[locale][key];
    assert(translated, `${locale} translation missing for ${title}`);
    assert.equal(translated.split('\n').length, key.split('\n').length,
      `${locale} paragraph count must be preserved for ${title}`);
  }
}
console.log(`PASS gesture guide: read-only mode previews, accurate gestures, virtual mouse, adaptive cards, accessibility and ${new Set(icons).size} local SVGs`);
