'use strict';
const cp = require('node:child_process'), fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const vswhere = path.join(process.env['ProgramFiles(x86)'] || 'C:/Program Files (x86)', 'Microsoft Visual Studio/Installer/vswhere.exe');
const install = cp.execFileSync(vswhere, ['-latest', '-products', '*', '-requires',
  'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], {encoding:'utf8'}).trim();
if (!install) throw new Error('Visual C++ compiler unavailable');
const vars = path.join(install, 'VC/Auxiliary/Build/vcvars64.bat');
const env = {...process.env};
const result = cp.execFileSync(process.env.ComSpec || 'cmd.exe', ['/d','/s','/c', `""${vars}" >nul && set"`],
  {encoding:'utf8',windowsVerbatimArguments:true});
for (const line of result.split(/\r?\n/)) { const i=line.indexOf('='); if(i<=0) continue;
  const key=line.slice(0,i); for(const old of Object.keys(env)) if(old.toLowerCase()===key.toLowerCase()) delete env[old];
  env[key]=line.slice(i+1); }
const temp = fs.mkdtempSync(path.join(os.tmpdir(),'srd-frame-test-'));
const exe = path.join(temp,'bounds.exe');
cp.execFileSync('cl.exe',['/nologo','/EHsc','/std:c++17',`/Fe:${exe}`,path.resolve('tools/test-native-frame-bounds.cpp')],
  {cwd:temp,env,stdio:'pipe'});
cp.execFileSync(exe,[],{cwd:temp,env,stdio:'pipe'});
console.log('PASS native frame bounds: valid geometry, resized buffer, stride, short input and overflow');
