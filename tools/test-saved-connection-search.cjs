#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

const page = fs.readFileSync(
  path.resolve(__dirname, '..', 'entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8').replace(/\r\n/g, '\n');

function method(name) {
  const start = page.indexOf('\n  ' + name + '(');
  const end = page.indexOf('\n  }', start);
  assert(start >= 0 && end > start, `method boundaries: ${name}`);
  return page.slice(start, end + 4);
}

assert.match(page, /placeholder: translate\('搜索名称或远端 ID', this\.uiLanguage\)/,
  'Saved connections need a clearly labelled search field');
assert.match(page, /savedConnectionSearchExpanded/,
  'Search must expand from the saved-connections action row');
const header = method('buildSavedConnections');
assert(header.indexOf('this.buildSavedConnectionSort()') < header.indexOf('this.buildSavedConnectionSearchToggle()'),
  'Sort remains on the left; search belongs immediately before group and backup on the right');
assert(header.indexOf('this.buildSavedConnectionSearchToggle()') < header.indexOf('this.buildSavedConnectionManagementActions()'));
assert.match(header, /if \(!this\.savedToolbarStacked\(\)\) \{\s*if \(!this\.savedConnectionSearchExpanded\) \{\s*this\.buildSavedConnectionSearchToggle\(\)\s*\}\s*this\.buildSavedConnectionManagementActions\(\)/);
assert.match(header, /if \(this\.savedToolbarStacked\(\)\) \{\s*Row\(\{ space: 8 \}\) \{\s*if \(!this\.savedConnectionSearchExpanded\) \{\s*this\.buildSavedConnectionSearchToggle\(\)\s*\}\s*this\.buildSavedConnectionManagementActions\(\)/,
  'Narrow windows keep Search, Group and Backup together rather than separating Search from Group');
const actions = method('buildSavedConnectionManagementActions');
assert(actions.indexOf("Button(translate('+ 分组'") < actions.indexOf("Button(translate('备份'"),
  'Rarely used backup belongs after group management');
assert.match(page, /placeholder: translate\('搜索名称或远端 ID', this\.uiLanguage\)[\s\S]*?\.layoutWeight\(1\)/,
  'Expanded search must use the free space to the left of fixed actions');
assert.match(actions, /Button\(translate\('备份', this\.uiLanguage\)\)\s*\.width\(this\.savedToolbarManagementButtonWidth\(48, '备份'\)\)/);
assert.match(actions, /Button\(translate\('\+ 分组', this\.uiLanguage\)\)\s*\.width\(this\.savedToolbarManagementButtonWidth\(56, '\+ 分组'\)\)/);
assert.doesNotMatch(page, /Search\(\{ value: this\.savedConnectionSearch[^}]+\}\)\s*\.width\('100%'\)/s,
  'Search must not consume a full standalone row');
assert.match(page, /matchesSavedConnectionSearch\(item\)/,
  'Saved connection rows must be filtered');
assert.match(page, /item\.name\.toLowerCase\(\)\.includes\(query\)/,
  'Search must match device names');
assert.match(page, /compactRemoteId\.includes\(compactQuery\)/,
  'Search must match remote IDs and ignore spaces');
assert.match(page, /Text\(translate\('未找到匹配的设备', this\.uiLanguage\)\)/,
  'Search needs an empty-result state');
assert.match(page, /shouldShowSavedConnectionGroup\(group\.id\)/,
  'Groups without matching devices must be hidden while searching');

const field = method('buildSavedConnectionSearchField');
assert.match(field, /\.height\(this\.savedToolbarButtonHeight\(\)\)/);
assert.match(field, /\.layoutWeight\(1\)/);
assert(!field.includes('FlexWrap.Wrap'), 'Search cannot auto-wrap away from fixed controls');
assert(field.includes(".textFont({ size: 14 })"));
assert(field.includes("translate('收起', this.uiLanguage)"), 'Collapse control stays inside the search field');
assert(field.includes('this.toggleSavedConnectionSearch()'));
assert(!header.includes("? '收起' : '搜索'"), 'No extra collapse pill below expanded search');
assert.match(header, /Row\(\{ space: 8 \}\)[\s\S]*?if \(!this\.savedToolbarStacked\(\)\)/);
assert(actions.includes("this.exportPlainBackup()") && actions.includes("this.openEncryptedExportDialog()") &&
  actions.includes("this.selectBackupForImport()"), 'All existing backup operations remain reachable');

const methods = ['savedToolbarLabelWidth', 'savedToolbarButtonWidth', 'savedToolbarButtonHeight',
  'savedToolbarContentWidth', 'savedToolbarManagementButtonWidth', 'savedToolbarManagementWidth', 'savedToolbarSearchButtonWidth',
  'savedToolbarSortWidth', 'savedToolbarStacked', 'savedCompactContentWidth', 'isWideDeviceLayout',
  'toggleSavedConnectionSearch', 'matchesSavedConnectionSearch', 'filteredSavedConnectionCount'];
const context = vm.createContext({
  deviceInfo: {deviceType: 'tablet'}, Curve: {EaseInOut: 'ease'},
  translate: (text, language) => language === 'en' ? ({ '搜索':'Search', '备份':'Backup', '+ 分组':'+ Group',
    '排序：ID':'Sort: ID', '排序：名称':'Sort: Name', '排序：在线':'Sort: Online' }[text] || text) : text,
});
const js = ts.transpileModule(`class Page { ${methods.map(method).join('\n')} } globalThis.Page = Page;`, {
  compilerOptions: {target: ts.ScriptTarget.ES2021}, reportDiagnostics: true
});
assert.equal(js.diagnostics.length, 0);
vm.runInContext(js.outputText, context);
const p = Object.assign(new context.Page(), {savedConnectionsContentWidth: 780,
  pageWidth: 840, pageFullHeight: 1280, uiFontScale: 1, uiLanguage:'zh-Hans',
  savedConnectionSort:'id', savedConnectionSearchExpanded:true, savedConnectionSearch:'Host',
  savedConnections: [{name:'Host-A', remoteId:'123456789'}, {name:'Other', remoteId:'987654321'}]});
assert.equal(p.savedToolbarButtonHeight(), 44, 'Search and actions grow from 30vp to a shared 44vp');
assert.equal(p.savedToolbarStacked(), false, 'Portrait tablet uses one coordinated row');
p.savedConnectionsContentWidth = 326;
assert.equal(p.savedToolbarStacked(), false, 'Normal phone also fits search and two actions');
p.savedConnectionsContentWidth = 250;
assert.equal(p.savedToolbarStacked(), true, 'Small widths use a deliberate two-row fallback');
let probes = 0;
for (const type of ['phone','tablet','2in1','pc','desktop']) {
  context.deviceInfo.deviceType = type;
  for (const [width,height] of [[320,760],[390,844],[700,500],[840,1280],[1200,760],[1440,900]]) {
    p.pageWidth=width; p.pageFullHeight=height; p.savedConnectionsContentWidth=width-60;
    for (const language of ['zh-Hans','zh-Hant','en']) {
      p.uiLanguage=language;
      for (const scale of [1,1.3,1.6,2,3]) {
        p.uiFontScale=scale;
        assert(p.savedToolbarButtonHeight() >= 44);
        const available=p.savedToolbarContentWidth();
        assert(p.savedToolbarManagementWidth() <= available, 'Management buttons must fit their actual toolbar');
        for (const expanded of [false,true]) {
          p.savedConnectionSearchExpanded=expanded;
          if (!p.savedToolbarStacked()) {
            const front=expanded ? 184+(scale-1)*120 : p.savedToolbarSearchButtonWidth()+p.savedToolbarSortWidth()+8;
            assert(front+p.savedToolbarManagementWidth()+8 <= available);
          } else if (!expanded) {
            assert(p.savedToolbarSearchButtonWidth()+p.savedToolbarManagementWidth()+8 <= available,
              'Stacked action row must fit Search then Group then Backup at large fonts');
          }
          probes++;
        }
      }
    }
  }
}
assert.equal(probes, 900);
p.savedConnectionSearch='HOST'; assert.equal(p.filteredSavedConnectionCount(),1);
p.savedConnectionSearch='123 456'; assert.equal(p.filteredSavedConnectionCount(),1);
p.savedConnectionSearch='not found'; assert.equal(p.filteredSavedConnectionCount(),0);
const original=JSON.stringify(p.savedConnections), animation=[];
p.savedConnectionSearchExpanded=true;
p.getUIContext=()=>({animateTo:(options,callback)=>{animation.push(options);callback();}});
p.toggleSavedConnectionSearch();
assert.equal(p.savedConnectionSearch,''); assert.equal(p.savedConnectionSearchExpanded,false);
assert.equal(p.filteredSavedConnectionCount(),2);
p.toggleSavedConnectionSearch();
assert.equal(p.savedConnectionSearchExpanded,true);
assert.equal(JSON.stringify(p.savedConnections),original, 'Search is presentation-only and must not rewrite saved data');
assert.equal(animation[0].duration,200);

console.log('PASS toolbar: sort-left, Search/Group/Backup together on right, aligned 44vp controls, inline collapse, 900 device/font/language layouts and preserved filtering/actions');
