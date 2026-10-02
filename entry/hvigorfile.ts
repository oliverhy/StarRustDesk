import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { hvigor } from '@ohos/hvigor';

const { preserveAppIcon } = require('../tools/preserve-app-icon.cjs');
hvigor.afterNodeEvaluate(node => {
  // Preserve the approved opaque source after SDK validation/conversion and
  // before packaging (also covers cached resource tasks on incremental builds).
  // SDK >= 26 runs restool (icon conversion) in `CompileResource`; older SDKs
  // did it inside `ProcessResource`. Hook whichever of the two compiles resources.
  const resourceTask = node.getTaskByName('default@CompileResource')
    ?? node.getTaskByName('default@ProcessResource');
  resourceTask?.afterRun(() => preserveAppIcon(node.getNodePath()));
  node.getTaskByName('default@PackageHap')?.beforeRun(() => preserveAppIcon(node.getNodePath()));
});

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: []       /* Custom plugin to extend the functionality of Hvigor. */
}
