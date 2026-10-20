'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const app = JSON.parse(read('AppScope/app.json5')).app;
const notes = read('entry/src/main/ets/widget/ReleaseNotesDialog.ets');
const literal = name => notes.match(new RegExp(`export const ${name}: string = '([^']+)'`))[1];
assert.equal(literal('RELEASE_NOTES_VERSION'), app.versionName);
assert.equal(literal('RELEASE_NOTES_BUILD'), String(app.versionCode));
assert(notes.includes('`${RELEASE_NOTES_VERSION}-${RELEASE_NOTES_BUILD}`'),
  'first-launch marker must change with the released version/build');
const firstSection = notes.match(/this\.buildSection\('([^']+)'/)[1];
assert(firstSection.startsWith(`${app.versionName}（${app.versionCode}）`),
  'current release appears before historical notes');
assert(fs.existsSync(path.join(root, `docs/releases/${app.versionName}-${app.versionCode}.md`)));
const tsv = read('tools/i18n-en.tsv');
assert(tsv.includes(firstSection + '\t'), 'latest release heading has an English translation');
const catalog = read('entry/src/main/ets/utils/I18nCatalog.ets');
assert(catalog.includes(JSON.stringify(firstSection)), 'generated translation catalog includes current notes');
assert(catalog.includes('"展开": "Expand"'), 'keyboard expand accessibility label is translated');
console.log(`PASS release metadata, newest-first notes, first-launch marker and translations: ${app.versionName}/${app.versionCode}`);
