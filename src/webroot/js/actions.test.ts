import { beforeEach, describe, expect, it, vi } from 'vitest';
import { runAction } from './actions.js';
import { spawnScript } from './bridge.js';
import { showToast } from './toast.js';
import { showErrorDialog } from './dialog.js';
import { addEntry } from './history.js';
import type { ChildProcess } from './types.js';

vi.mock('./bridge.js', () => ({ spawnScript: vi.fn() }));
vi.mock('./terminal.js', () => ({ appendToOutput: vi.fn() }));
vi.mock('./toast.js', () => ({ showToast: vi.fn() }));
vi.mock('./dialog.js', () => ({ showErrorDialog: vi.fn() }));
vi.mock('./history.js', () => ({ addEntry: vi.fn() }));
vi.mock('./i18n.js', () => ({ getTranslation: () => null }));

let handlers: Record<string, Function>;
beforeEach(() => {
  vi.clearAllMocks();
  handlers = {};
  vi.mocked(spawnScript).mockReturnValue({
    stdout: { on: (_event, fn) => { handlers.stdout = fn; }, emit: vi.fn() },
    stderr: { on: (_event, fn) => { handlers.stderr = fn; }, emit: vi.fn() },
    on: (event: string, fn: Function) => { handlers[event] = fn; },
    emit: vi.fn(),
  } as ChildProcess);
});

describe('action results and diagnostics', () => {
  it('returns failure and retains the exact stderr for error details', async () => {
    const promise = runAction('keybox.sh');
    await vi.waitFor(() => expect(handlers.exit).toBeDefined());
    handlers.stderr!("Fatal: No versions for provider '<removed>'");
    handlers.exit!(1);
    expect(await promise).toBe(false);
    expect(addEntry).toHaveBeenCalledWith('keybox.sh', expect.stringContaining('<removed>'), 1);
    const options = vi.mocked(showToast).mock.calls[0]![1]!;
    options.onActionClick!();
    expect(showErrorDialog).toHaveBeenCalledWith('Error Details', "[!] Fatal: No versions for provider '<removed>'");
  });

  it('returns success only for a zero exit', async () => {
    const promise = runAction('keybox.sh');
    await vi.waitFor(() => expect(handlers.exit).toBeDefined());
    handlers.stdout!('Keybox installed successfully');
    handlers.exit!(0);
    expect(await promise).toBe(true);
  });

  it('returns failure for bridge timeouts', async () => {
    const promise = runAction('keybox.sh');
    await vi.waitFor(() => expect(handlers.error).toBeDefined());
    handlers.error!(new Error('Operation timed out'));
    expect(await promise).toBe(false);
    expect(addEntry).toHaveBeenCalledWith('keybox.sh', 'Operation timed out', 1);
  });
});
