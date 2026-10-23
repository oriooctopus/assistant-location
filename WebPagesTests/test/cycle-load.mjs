// Loads CycleApp/web/cycle-core.js the way the browser does (classic script,
// global CycleCore); see gripes-load.mjs for why require() cannot be used.
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const file = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/cycle-core.js');
vm.runInThisContext(fs.readFileSync(file, 'utf8'), { filename: file });
if (!globalThis.CycleCore) throw new Error('cycle-core.js did not define CycleCore');
export default globalThis.CycleCore;
