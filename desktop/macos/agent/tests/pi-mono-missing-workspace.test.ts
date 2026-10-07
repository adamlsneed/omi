import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { EventEmitter } from "node:events";
import { afterEach, describe, expect, it, vi } from "vitest";
import { spawn } from "child_process";
import { PiMonoAdapter } from "../src/adapters/pi-mono.js";
import type { HarnessConfig } from "../src/adapters/interface.js";

vi.mock("child_process", async () => {
  const actual = await vi.importActual<typeof import("child_process")>("child_process");
  return {
    ...actual,
    spawn: vi.fn(() =>
      Object.assign(new EventEmitter(), {
        stdin: new PassThrough(),
        stdout: new PassThrough(),
        stderr: new PassThrough(),
        kill: vi.fn(),
        removeAllListeners: vi.fn(),
        pid: 99999 as number | undefined,
      }),
    ),
  };
});

// 2026-10-06: the main chat session was pinned to ~/Documents/Omi, the folder was
// deleted, and every chat turn crashed the agent runtime with an unhandled ENOENT.
describe("PiMonoAdapter with a missing working directory", () => {
  const roots: string[] = [];
  afterEach(() => {
    for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
  });

  function adapterWithCwd(cwd: string): PiMonoAdapter {
    const adapter = new PiMonoAdapter({} as HarnessConfig, "/usr/bin/true", "/dev/null");
    (adapter as any).currentWorkingDirectory = cwd;
    return adapter;
  }

  it("recreates a deleted working directory before spawning pi", async () => {
    const root = mkdtempSync(join(tmpdir(), "pi-mono-cwd-"));
    roots.push(root);
    const missing = join(root, "Documents", "Omi");
    const adapter = adapterWithCwd(missing);

    await adapter.start();

    expect(existsSync(missing)).toBe(true);
    expect(vi.mocked(spawn)).toHaveBeenLastCalledWith(
      "/usr/bin/true",
      expect.any(Array),
      expect.objectContaining({ cwd: missing }),
    );
  });

  it("survives a spawn failure and rejects the pending request instead of crashing", async () => {
    const root = mkdtempSync(join(tmpdir(), "pi-mono-cwd-"));
    roots.push(root);
    const adapter = adapterWithCwd(root);
    await adapter.start();

    const proc = vi.mocked(spawn).mock.results.at(-1)!.value as EventEmitter & { pid: number | undefined };
    proc.pid = undefined;
    const reject = vi.fn();
    (adapter as any).pendingRequests.set("1", { resolve: vi.fn(), reject });

    expect(() => proc.emit("error", Object.assign(new Error("spawn pi ENOENT"), { code: "ENOENT" }))).not.toThrow();
    expect((adapter as any).process).toBeNull();
    expect(reject).toHaveBeenCalledWith(expect.objectContaining({ message: expect.stringContaining("failed to start") }));
  });

  it("keeps a running process when a later error (such as a failed kill) is reported", async () => {
    const root = mkdtempSync(join(tmpdir(), "pi-mono-cwd-"));
    roots.push(root);
    const adapter = adapterWithCwd(root);
    await adapter.start();

    const proc = vi.mocked(spawn).mock.results.at(-1)!.value as EventEmitter;
    proc.emit("error", new Error("kill EPERM"));

    expect((adapter as any).process).toBe(proc);
  });
});
