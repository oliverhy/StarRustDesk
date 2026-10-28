'use strict';
// Mechanical export of the user-supplied SVG. Foreground paths/colors are kept
// unchanged; only the document margins and launcher background are normalized.
// Build-only dependency: sharp (available via NODE_PATH); never ships in the app.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const sharp = require('sharp');
const root = path.resolve(__dirname, '..');
const assets = path.join(root, 'design/branding-zhima');

async function main() {
  const sourceFile = process.argv[2] ? path.resolve(process.argv[2]) : path.join(assets, 'source.svg');
  const original = fs.readFileSync(sourceFile);
  fs.mkdirSync(assets, { recursive: true });
  let svg = original.toString('utf8').replace(/<!DOCTYPE[^>]*>/g, '');
  assert.match(svg, /viewBox="0 0 3508 2481"/, 'unexpected source artboard');
  const background = svg.match(/<g transform="matrix\(0\.775259[^]*?<\/g>/)?.[0];
  assert(background, 'approved background layer must exist');
  const x = 1599.255 * 0.775259 - 389.936447;
  const y = 818.322 * 0.775259 - 298.290751;
  const side = (3931.473 - 1599.255) * 0.775259;
  svg = svg.replace('width="100%" height="100%"', 'width="1024" height="1024"')
    .replace('viewBox="0 0 3508 2481"', `viewBox="${x} ${y} ${side} ${side}"`);
  // Extend the original gray/white gradient to all four corners. Huawei masks
  // the single-layer icon itself; pre-rounded transparent corners are not used.
  const squareBackground = background.replace(/<path[^]*?\/>/,
    '<rect x="1599.255" y="818.322" width="2332.218" height="2332.218" style="fill:url(#_Radial1);"/>');
  const square = svg.replace(background, squareBackground);
  const foreground = svg.replace(background, '');
  const backgroundOnly = square.replace(/<g[^]*?<\/g>/g, (layer) => layer === squareBackground ? layer : '');
  const render = (source, size, opaque) => {
    let renderer = sharp(Buffer.from(source)).resize(size, size);
    if (opaque) renderer = renderer.removeAlpha();
    return renderer.png().toBuffer();
  };
  const icon = await render(square, 1024, true);
  const bg = await render(backgroundOnly, 1024, true);
  const fg = await render(foreground, 1024, false);
  // Check opacity BEFORE dropping alpha, to catch accidental gaps at corners.
  const { data } = await sharp(Buffer.from(square)).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  for (let i = 3; i < data.length; i += 4) assert.equal(data[i], 255, 'single-layer source must be fully opaque');
  // Do not overwrite an approved source/artifact until conversion succeeds.
  if (sourceFile !== path.join(assets, 'source.svg')) fs.copyFileSync(sourceFile, path.join(assets, 'source.svg'));
  fs.writeFileSync(path.join(assets, 'app-icon.svg'), square);
  fs.writeFileSync(path.join(assets, 'app-icon-1024.png'), icon);
  fs.writeFileSync(path.join(assets, 'preview-256.png'), await render(square, 256, true));
  for (const dir of ['AppScope/resources/base/media', 'entry/src/main/resources/base/media']) {
    for (const file of ['starrustdesk_app_icon.png', 'starrustdesk_app_icon_1024.png'])
      fs.writeFileSync(path.join(root, dir, file), icon);
    fs.writeFileSync(path.join(root, dir, 'background.png'), bg);
    fs.writeFileSync(path.join(root, dir, 'foreground.png'), fg);
  }
  fs.writeFileSync(path.join(root, 'entry/src/main/resources/base/media/starrustdesk_start_icon.png'), icon);
  fs.writeFileSync(path.join(root, 'entry/src/main/resources/base/media/startIcon.png'), await render(square, 144, true));
  console.log('Exported approved SVG: 1024px opaque square app/start icons, 144px legacy start icon, matching layered assets.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
