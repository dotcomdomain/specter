import { beforeEach, describe, expect, it, vi } from 'vitest';
import { populateProviders, wireKeyboxInstallButton } from './keybox-ui.js';
import { cfgFlush, cfgInvalidate, cfgSet, setDataDir } from './cfg.js';
import { exec } from './bridge.js';
import { fetchJson } from './utils.js';
import { runAction } from './actions.js';
import { showErrorDialog } from './dialog.js';
import { refreshKeyboxStatus } from './device.js';

vi.mock('./bridge.js', () => ({ exec: vi.fn(), getModuleDir: () => '/module' }));
vi.mock('./utils.js', async importOriginal => ({ ...await importOriginal<typeof import('./utils.js')>(), fetchJson: vi.fn() }));
vi.mock('./i18n.js', () => ({ getTranslation: () => null }));
vi.mock('./actions.js', () => ({ runAction: vi.fn() }));
vi.mock('./dialog.js', () => ({ showErrorDialog: vi.fn() }));
vi.mock('./device.js', () => ({ refreshKeyboxStatus: vi.fn() }));
vi.mock('./subpage.js', () => ({ openSubPage: vi.fn() }));
vi.mock('./file-browser.js', () => ({ openFileBrowser: vi.fn() }));

beforeEach(async () => {
  await cfgFlush();
  vi.clearAllMocks();
  cfgInvalidate();
  localStorage.clear();
  setDataDir('/data/adb/specter');
  vi.mocked(exec).mockResolvedValue({ code: 0, stdout: '', stderr: '' });
  vi.mocked(runAction).mockResolvedValue(true);
  vi.mocked(fetchJson).mockResolvedValue({ entries: [{ source: 'TAKR' }] });
  document.body.innerHTML = '<select id="kb-provider"><option value="auto">Auto</option></select><div class="keybox-install-card"><span class="kic-spinner hidden"></span><button id="kb-install-btn">Install</button></div>';
});

describe('provider selection and installation', () => {
  it('replaces a removed saved provider with Auto on disk and in the select', async () => {
    await cfgSet('keybox_provider', 'KOW');
    await populateProviders();
    await cfgFlush();
    expect((document.getElementById('kb-provider') as HTMLSelectElement).value).toBe('auto');
    expect(exec).toHaveBeenLastCalledWith(expect.stringContaining("printf '%s' 'auto'"));
  });

  it('restores a valid saved provider instead of using the initial Auto option', async () => {
    await cfgSet('keybox_provider', 'TAKR');
    await populateProviders();
    expect((document.getElementById('kb-provider') as HTMLSelectElement).value).toBe('TAKR');
  });

  it('waits for provider and custom-source saves before starting the script', async () => {
    await populateProviders();
    let finish!: (value: { code: number; stdout: string; stderr: string }) => void;
    vi.mocked(exec).mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
    const select = document.getElementById('kb-provider') as HTMLSelectElement;
    select.value = 'TAKR';
    select.dispatchEvent(new Event('change'));
    wireKeyboxInstallButton();
    document.getElementById('kb-install-btn')!.click();
    await vi.waitFor(() => expect(finish).toBeDefined());
    expect(runAction).not.toHaveBeenCalled();
    finish({ code: 0, stdout: '', stderr: '' });
    await vi.waitFor(() => expect(runAction).toHaveBeenCalledWith('keybox.sh'));
    await vi.waitFor(() => expect((document.getElementById('kb-install-btn') as HTMLButtonElement).disabled).toBe(false));
  });

  it('shows config failures and does not launch with stale disk settings', async () => {
    await populateProviders();
    vi.mocked(exec).mockResolvedValue({ code: 1, stdout: '', stderr: 'Permission denied' });
    wireKeyboxInstallButton();
    document.getElementById('kb-install-btn')!.click();
    await vi.waitFor(() => expect(showErrorDialog).toHaveBeenCalledWith('Error Details', expect.stringContaining('Failed to save configuration')));
    expect(runAction).not.toHaveBeenCalled();
    // Recover these keys so a failed save cannot leak into another test.
    vi.mocked(exec).mockResolvedValue({ code: 0, stdout: '', stderr: '' });
    await Promise.all(['keybox_provider', 'keybox_custom_type', 'keybox_custom_value'].map(key => cfgSet(key, '')));
  });

  it('keeps failed script output visible without refreshing status as success', async () => {
    await populateProviders();
    vi.mocked(runAction).mockResolvedValue(false);
    wireKeyboxInstallButton();
    document.getElementById('kb-install-btn')!.click();
    await vi.waitFor(() => expect(runAction).toHaveBeenCalled());
    await vi.waitFor(() => expect((document.getElementById('kb-install-btn') as HTMLButtonElement).disabled).toBe(false));
    expect(refreshKeyboxStatus).not.toHaveBeenCalled();
  });
});
