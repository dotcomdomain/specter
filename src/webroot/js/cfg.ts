import { exec as bridgeExec } from './bridge.js';
import { shellEscape } from './utils.js';

let DATA_DIR: string | null = null;
const cache: Record<string, string | undefined | null> = {};
const pendingWrites = new Map<string, Promise<boolean>>();
const failedWrites = new Set<string>();

/** Set the Specter data directory for config file access. */
export function setDataDir(path: string) { DATA_DIR = path; }

/** Pre-populate the config cache by reading all `.val` files from the config directory. */
export async function cfgInit() {
  const preloaded = (window as any).__preloadedCfg;
  if (preloaded && typeof preloaded === 'object' && Object.keys(preloaded).length > 0) {
    const entries = Object.entries(preloaded);
    for (const [key, val] of entries) {
      if (typeof val === 'string') cache[key] = val;
    }
  }
  try {
    if (typeof localStorage !== 'undefined') {
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k && k.startsWith('sp_cfg_')) {
          cache[k.slice(7)] = localStorage.getItem(k);
        }
      }
    }
  } catch {}
  if (!DATA_DIR) return;
  const cfgDir = shellEscape(DATA_DIR + '/config/val');
  const cmd = `for f in ${cfgDir}/*.val; do [ -f "\$f" ] || continue; k="\${f##*/}"; k="\${k%.val}"; v="\$(cat "\$f")"; printf 'CFG:%s\n' "\$k"; printf '%s\n' "\$v"; done`;
  const result = await bridgeExec(cmd);
  const stdout = (result.stdout || '').trim();
  if (!stdout) return;
  const lines = stdout.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line || !line.startsWith('CFG:')) continue;
    const key = line.slice(4);
    const next = lines[i + 1];
    const value = next || '';
    cache[key] = value;
    try { localStorage.setItem('sp_cfg_' + key, value); } catch {}
    i++;
  }
}

async function readConfig(key: string): Promise<string | null> {
  if (!DATA_DIR) return null;
  const result = await bridgeExec(
    `cat ${shellEscape(DATA_DIR + '/config/val/' + key + '.val')} 2>/dev/null || true`
  );
  return (result.stdout || '').trim() || null;
}

function writeConfig(key: string, val: string | undefined | null): Promise<boolean> {
  // Serialize writes to each key so a slow older save cannot overwrite a newer
  // selection. Callers may ignore the promise; cfgFlush still observes errors.
  const previous = pendingWrites.get(key) || Promise.resolve(true);
  const dir = DATA_DIR;
  const pending = previous.then(async () => {
    if (!dir) throw new Error('Cannot save configuration: data directory unavailable');
    const cmd =
      `mkdir -p ${shellEscape(dir + '/config/val')} && printf '%s' ${shellEscape(val || '')} > ${shellEscape(dir + '/config/val/' + key + '.val')}`;
    const result = await bridgeExec(cmd);
    if (result.code !== 0) throw new Error(result.stderr || `Config write failed for ${key}`);
    failedWrites.delete(key);
    return true;
  }).catch((err: unknown) => {
    failedWrites.add(key);
    console.warn('Config write failed for', key, err);
    return false;
  });
  pendingWrites.set(key, pending);
  void pending.then(() => { if (pendingWrites.get(key) === pending) pendingWrites.delete(key); });
  return pending;
}

/** Wait for configuration to reach disk before launching a dependent script. */
export async function cfgFlush(): Promise<void> {
  while (pendingWrites.size) await Promise.all(pendingWrites.values());
  if (failedWrites.size) throw new Error(`Failed to save configuration: ${[...failedWrites].join(', ')}`);
}

/** Retrieve a config value by key. Checks the in-memory cache first, then reads from disk. Returns the stored value, `defaultValue`, or `null`. */
export async function cfgGet(key: string, defaultValue?: string): Promise<string | undefined | null> {
  if (key in cache) return cache[key];
  const val = await readConfig(key);
  cache[key] = val ?? defaultValue;
  return cache[key];
}

/** Set a config value both in cache and on disk. */
export function cfgSet(key: string, val: string | undefined | null) {
  cache[key] = val;
  try { localStorage.setItem('sp_cfg_' + key, val ?? ''); } catch {}
  return writeConfig(key, val);
}

/** Remove one key (or all keys when called without argument) from the in-memory cache. */
export function cfgInvalidate(key?: string) {
  if (key) {
    delete cache[key];
  } else {
    for (const k of Object.keys(cache)) delete cache[k];
  }
}

/** Migrate legacy localStorage keys (`selectedLanguage`, `themeMode`, `themePreset`) to the new config system. Idempotent — only runs once. */
export async function migrateLocalStorage() {
  try {
    if (localStorage.getItem('_cfg_migrated')) return;
    const map: Record<string, string> = {
      selectedLanguage: 'lang',
      themeMode: 'theme',
      themePreset: 'theme_preset',
    };
    for (const [oldKey, newKey] of Object.entries(map)) {
      const val = localStorage.getItem(oldKey);
      if (val) {
        cache[newKey] = val;
        await writeConfig(newKey, val);
      }
    }
    localStorage.removeItem('themeMode');
    localStorage.removeItem('themePreset');
    localStorage.removeItem('clockFormat');
    localStorage.setItem('_cfg_migrated', '1');
  } catch (e) {
    console.warn('Migration failed:', e);
  }
}
