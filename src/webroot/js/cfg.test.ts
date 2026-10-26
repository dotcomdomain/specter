import { describe, expect, it, beforeEach, vi } from 'vitest'
import { cfgGet, cfgSet, cfgInvalidate, setDataDir, migrateLocalStorage, cfgInit } from './cfg.js'

vi.mock('./bridge.js', () => ({
  exec: vi.fn(() => Promise.resolve({ stdout: '', stderr: '', code: 0 })),
}))

beforeEach(() => {
  vi.clearAllMocks()
  setDataDir('/data/adb/specter')
  cfgInvalidate()
  localStorage.clear()
})

describe('cfg (caching layer)', () => {
  it('cfgGet returns cached value after cfgSet', async () => {
    cfgSet('test_key', 'test_value')
    const val = await cfgGet('test_key')
    expect(val).toBe('test_value')
  })

  it('cfgSet overwrites existing value', async () => {
    cfgSet('test_key', 'first')
    cfgSet('test_key', 'second')
    const val = await cfgGet('test_key')
    expect(val).toBe('second')
  })

  it('cfgGet returns defaultValue when not cached', async () => {
    const val = await cfgGet('nonexistent', 'default')
    expect(val).toBe('default')
  })

  it('cfgGet returns undefined when key missing and no default', async () => {
    const val = await cfgGet('nonexistent')
    expect(val).toBeUndefined()
  })

  it('cfgInvalidate removes single key', async () => {
    cfgSet('temp', 'value')
    expect(await cfgGet('temp')).toBe('value')
    cfgInvalidate('temp')
    expect(await cfgGet('temp')).toBeUndefined()
  })

  it('cfgInvalidate with no args clears all cache', async () => {
    cfgSet('a', '1')
    cfgSet('b', '2')
    cfgInvalidate()
    expect(await cfgGet('a')).toBeUndefined()
    expect(await cfgGet('b')).toBeUndefined()
  })

  it('migrateLocalStorage migrates keys', async () => {
    localStorage.setItem('selectedLanguage', 'en')
    localStorage.setItem('themeMode', 'dark')
    await migrateLocalStorage()
    expect(await cfgGet('lang')).toBe('en')
    expect(await cfgGet('theme')).toBe('dark')
    expect(localStorage.getItem('_cfg_migrated')).toBe('1')
  })

  it('migrateLocalStorage only runs once', async () => {
    localStorage.setItem('selectedLanguage', 'en')
    await migrateLocalStorage()
    localStorage.setItem('selectedLanguage', 'fr')
    await migrateLocalStorage()
    expect(await cfgGet('lang')).toBe('en')
  })
})

// These exercise ordering at the bridge boundary rather than the cache alone.
describe('configuration persistence', () => {
  it('serializes overlapping writes and flushes the latest selection', async () => {
    const { exec } = await import('./bridge.js');
    const { cfgFlush } = await import('./cfg.js');
    let finish!: (value: any) => void;
    vi.mocked(exec).mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
    const first = cfgSet('provider', 'old');
    const second = cfgSet('provider', 'new');
    await vi.waitFor(() => expect(finish).toBeDefined());
    expect(exec).toHaveBeenCalledTimes(1);
    let flushed = false;
    const flush = cfgFlush().then(() => { flushed = true; });
    expect(flushed).toBe(false);
    finish({ code: 0, stdout: '', stderr: '' });
    await Promise.all([first, second, flush]);
    expect(exec).toHaveBeenLastCalledWith(expect.stringContaining("printf '%s' 'new'"));
  });

  it('reports nonzero bridge exits and allows a successful retry', async () => {
    const { exec } = await import('./bridge.js');
    const { cfgFlush } = await import('./cfg.js');
    vi.mocked(exec).mockResolvedValueOnce({ code: 1, stdout: '', stderr: 'Permission denied' });
    expect(await cfgSet('provider', 'TAKR')).toBe(false);
    await expect(cfgFlush()).rejects.toThrow('provider');
    await cfgSet('provider', 'TAKR');
    await expect(cfgFlush()).resolves.toBeUndefined();
  });
});


describe('disk configuration is authoritative', () => {
  it('refreshes preloaded localStorage values from the backend, including empty values', async () => {
    const { exec } = await import('./bridge.js');
    (window as any).__preloadedCfg = { keybox_provider: 'KOW', keybox_custom_value: 'old.xml' };
    localStorage.setItem('sp_cfg_keybox_provider', 'KOW');
    vi.mocked(exec).mockResolvedValueOnce({ code: 0, stdout: 'CFG:keybox_provider\nauto\nCFG:keybox_custom_value\n\n', stderr: '' });
    await cfgInit();
    expect(await cfgGet('keybox_provider')).toBe('auto');
    expect(await cfgGet('keybox_custom_value')).toBe('');
    expect(localStorage.getItem('sp_cfg_keybox_provider')).toBe('auto');
    delete (window as any).__preloadedCfg;
  });
});
