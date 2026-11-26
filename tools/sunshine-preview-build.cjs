'use strict';
// Use an in-memory build profile: never rewrite signing settings, the normal
// page list, or the normal rawfile directory. No opt-in means no override.
function configureSunshineTest(ctx, env = process.env) {
  if (env.SESAME_STREAM_TEST_BUILD !== '1') return;
  if (ctx.getBuildMode() !== 'debug') throw new Error('Streaming test resources are debug-only');
  const p = ctx.getBuildProfileOpt();
  const t = p.targets.find(t => t.name === 'default');
  if (!t) throw new Error('Missing entry target');
  // Hvigor replaces, rather than extends, the implicit main resource list.
  const dirs = t.resource?.directories;
  t.resource = { ...t.resource, directories: [...(dirs?.length ? dirs : ['./src/main/resources']), './src/sunshineTest/resources'] };
  const native = p.buildOption.externalNativeOptions;
  const off = '-DSESAME_STREAM_TEST_BUILD:BOOL=OFF';
  if (!(native.arguments || '').split(/\s+/).includes(off)) throw new Error('Missing default-off native gate');
  native.arguments = native.arguments.replace(off, '-DSESAME_STREAM_TEST_BUILD:BOOL=ON');
  // CMake leaves .so files in the shared output directory when an optional
  // target is turned off. Only this opted-in debug package may collect it.
  const filters = p.buildOption.nativeLib.filter;
  const deny = '**/libsunshine_stream_exp.so';
  if (!filters.excludes.includes(deny)) throw new Error('Missing default-off packaging gate');
  filters.excludes = filters.excludes.filter(pattern => pattern !== deny);
  ctx.setBuildProfileOpt(p);
  const m = ctx.getModuleJsonOpt();
  if (m.module.pages !== '$profile:main_pages') throw new Error('Unexpected entry page list');
  m.module.pages = '$profile:sunshine_test_pages';
  ctx.setModuleJsonOpt(m);
}
module.exports = { configureSunshineTest };
