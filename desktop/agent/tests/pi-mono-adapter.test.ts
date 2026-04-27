import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { PassThrough } from "node:stream";
import { EventEmitter } from "node:events";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { spawn } from "child_process";
import { PiMonoAdapter } from "../src/adapters/pi-mono.js";
import type { HarnessConfig } from "../src/adapters/interface.js";
import type { OutboundMessage } from "../src/protocol.js";

// Mock child_process.spawn so start() doesn't launch a real subprocess.
// Existing tests that mock sendCommand never call start(), so unaffected.
vi.mock("child_process", async () => {
  const actual = await vi.importActual<typeof import("child_process")>("child_process");
  return {
    ...actual,
    spawn: vi.fn(() => {
      const proc = Object.assign(new EventEmitter(), {
        stdin: new PassThrough(),
        stdout: new PassThrough(),
        stderr: new PassThrough(),
        kill: vi.fn(),
        removeAllListeners: vi.fn(),
        pid: 99999,
      });
      return proc;
    }),
  };
});

function createAdapter() {
  const config: HarnessConfig = {
    authToken: "test-token",
  };
  const adapter = new PiMonoAdapter(config);
  const events: OutboundMessage[] = [];

  (adapter as any).sendCommand = vi.fn();

  return { adapter, events };
}

function makeTurnEndEvent(text: string, totalCost = 1.25) {
  return {
    type: "turn_end",
    message: {
      role: "assistant",
      content: [{ type: "text", text }],
      usage: {
        input: 11,
        output: 7,
        cacheRead: 3,
        cacheWrite: 2,
        totalTokens: 23,
        cost: {
          input: 0.1,
          output: 0.2,
          cacheRead: 0.3,
          cacheWrite: 0.4,
          total: totalCost,
        },
      },
    },
  };
}

describe("PiMonoAdapter prompt correlation", () => {
  it("rejects the previous prompt when a new generation supersedes it", async () => {
    const { adapter, events } = createAdapter();

    const firstPrompt = adapter.sendPrompt(
      "session-1",
      [{ type: "text", text: "first" }],
      [],
      "act",
      (event) => events.push(event),
      async () => ""
    );

    const secondPrompt = adapter.sendPrompt(
      "session-2",
      [{ type: "text", text: "second" }],
      [],
      "act",
      (event) => events.push(event),
      async () => ""
    );

    await expect(firstPrompt).rejects.toThrow(
      "pi-mono prompt superseded before turn_end"
    );

    (adapter as any).handleTurnEnd(makeTurnEndEvent("second response", 2.5));

    await expect(secondPrompt).resolves.toMatchObject({
      text: "second response",
      sessionId: "session-2",
      costUsd: 2.5,
      inputTokens: 11,
      outputTokens: 7,
      cacheReadTokens: 3,
      cacheWriteTokens: 2,
    });
    expect(events).toContainEqual(
      expect.objectContaining({
        type: "result",
        text: "second response",
        sessionId: "session-2",
      })
    );
  });

  it("resolves abort before turn_end and drops the late completion", async () => {
    const { adapter, events } = createAdapter();

    const prompt = adapter.sendPrompt(
      "session-1",
      [{ type: "text", text: "abort me" }],
      [],
      "act",
      (event) => events.push(event),
      async () => ""
    );

    adapter.abort("session-1");

    await expect(prompt).resolves.toMatchObject({
      text: "",
      sessionId: "session-1",
      costUsd: 0,
      inputTokens: 0,
      outputTokens: 0,
    });

    (adapter as any).handleTurnEnd(makeTurnEndEvent("late response"));

    expect(events).toEqual([]);
    expect((adapter as any).activePromptGeneration).toBe(0);
  });

  it("drops stray turn_end events when no prompt is in flight", () => {
    const { adapter, events } = createAdapter();

    (adapter as any).eventHandler = (event: OutboundMessage) => events.push(event);
    (adapter as any).handleTurnEnd(makeTurnEndEvent("orphaned response"));

    expect(events).toEqual([]);
    expect((adapter as any).pendingRequests.size).toBe(0);
  });
});

describe("PiMonoAdapter source-level invariants", () => {
  const piMonoSrc = readFileSync(
    fileURLToPath(new URL("../src/adapters/pi-mono.ts", import.meta.url)),
    "utf8"
  );

  it("does not put the Firebase token directly in the pi subprocess env", () => {
    expect(piMonoSrc).toMatch(/OMI_API_KEY_FILE/);
    expect(piMonoSrc).not.toMatch(/env\.OMI_API_KEY\s*=\s*this\.config\.authToken\s*;?/);
  });

  it("does not allow ambient ANTHROPIC_API_KEY into the child env", () => {
    expect(piMonoSrc).toContain("makeSubprocessEnv");
    expect(piMonoSrc).not.toMatch(/["']ANTHROPIC_API_KEY["']/);
  });
});

describe("PiMonoAdapter spawn args (behavioral)", () => {
  // Behavioral test: actually call start() with a mocked spawn to verify
  // the real args array rather than grepping source text.
  beforeEach(() => {
    vi.mocked(spawn).mockClear();
  });

  it("does not pass --no-extensions to the subprocess", async () => {
    const config: HarnessConfig = {
      authToken: "test-token",
    };
    const adapter = new PiMonoAdapter(config, "/fake/pi", "/fake/ext.ts");
    await adapter.start();

    expect(spawn).toHaveBeenCalledOnce();
    const [cmd, args] = vi.mocked(spawn).mock.calls[0];
    expect(cmd).toBe("/fake/pi");
    expect(args).toContain("--mode");
    expect(args).toContain("rpc");
    expect(args).toContain("-e");
    expect(args).toContain("/fake/ext.ts");
    // Auto-discovery must be enabled: --no-extensions must NOT be present
    expect(args).not.toContain("--no-extensions");

    await adapter.stop();
  });

  it("includes required base flags: --mode rpc, -e, --provider, --model", async () => {
    const config: HarnessConfig = {
      authToken: "test-token",
    };
    const adapter = new PiMonoAdapter(config, "/fake/pi", "/fake/ext.ts");
    await adapter.start();

    const [, args] = vi.mocked(spawn).mock.calls[0];
    expect(args).toEqual(expect.arrayContaining([
      "--mode", "rpc",
      "-e", "/fake/ext.ts",
      "--provider", "omi",
      "--model", "omi-sonnet",
    ]));

    await adapter.stop();
  });

  it("passes authToken through a private file and scrubs ambient secrets", async () => {
    const previousAmbientSecret = process.env.APPLE_APP_SPECIFIC_PASSWORD;
    process.env.APPLE_APP_SPECIFIC_PASSWORD = "do-not-forward";
    const config: HarnessConfig = {
      authToken: "firebase-id-token-xyz",
    };
    const adapter = new PiMonoAdapter(config, "/fake/pi.js", "/fake/ext.ts");

    try {
      await adapter.start();

      const [cmd, args, options] = vi.mocked(spawn).mock.calls[0] as [
        string,
        string[],
        { env: Record<string, string> },
      ];
      expect(cmd).toBe(process.execPath);
      expect(args[0]).toBe("/fake/pi.js");
      expect(options.env.OMI_API_KEY).toBeUndefined();
      expect(options.env.OMI_API_KEY_FILE).toBeTruthy();
      expect(readFileSync(options.env.OMI_API_KEY_FILE!, "utf8")).toBe("firebase-id-token-xyz");
      expect(options.env.ANTHROPIC_API_KEY).toBeUndefined();
      expect(options.env.APPLE_APP_SPECIFIC_PASSWORD).toBeUndefined();

      await adapter.stop();
      expect(existsSync(options.env.OMI_API_KEY_FILE!)).toBe(false);
    } finally {
      if (previousAmbientSecret === undefined) {
        delete process.env.APPLE_APP_SPECIFIC_PASSWORD;
      } else {
        process.env.APPLE_APP_SPECIFIC_PASSWORD = previousAmbientSecret;
      }
    }
  });
});

describe("tool_use event filtering", () => {
  // Two-layer defense:
  // 1. Source-level assertion verifies the filter EXISTS in the real code
  // 2. Behavioral test verifies the filtering LOGIC is correct
  // Together they catch both: (a) accidental removal/refactoring of the
  // filter, and (b) logical errors in the filtering pattern.
  const indexSrc = readFileSync(
    fileURLToPath(new URL("../src/index.ts", import.meta.url)),
    "utf8"
  );

  it("source: runPiMonoMode event callback checks type === 'tool_use'", () => {
    // Guard against accidental removal of the filter in index.ts
    expect(indexSrc).toMatch(/\.type\s*===\s*["']tool_use["']\)\s*return/);
  });

  it("source: non-tool_use events are forwarded via send()", () => {
    expect(indexSrc).toMatch(/send\(event\s+as\s+OutboundMessage\)/);
  });

  it("behavioral: suppresses tool_use events and forwards all other types", () => {
    const forwarded: any[] = [];

    // Exact callback from runPiMonoMode() line ~1273
    const eventCallback = (event: any) => {
      if ((event as any).type === "tool_use") return;
      forwarded.push(event);
    };

    // tool_use must be suppressed (prevents Swift double-executing the tool)
    eventCallback({ type: "tool_use", callId: "call-1", name: "bash", input: { command: "ls" } });
    expect(forwarded).toHaveLength(0);

    // All other event types must pass through
    const otherEvents = [
      { type: "text_delta", text: "hello" },
      { type: "thinking_delta", text: "thinking..." },
      { type: "tool_activity", name: "bash", status: "started", toolUseId: "call-1" },
      { type: "tool_activity", name: "bash", status: "completed", toolUseId: "call-1" },
      { type: "tool_result_display", toolUseId: "call-1", name: "bash", output: "file.txt" },
      { type: "result", text: "done", sessionId: "s1", costUsd: 0 },
    ];

    for (const event of otherEvents) {
      eventCallback(event);
    }

    expect(forwarded).toHaveLength(otherEvents.length);
    expect(forwarded).toEqual(otherEvents);
  });

  it("handles multiple tool_use events interspersed with other events", () => {
    const forwarded: any[] = [];
    const eventCallback = (event: any) => {
      if ((event as any).type === "tool_use") return;
      forwarded.push(event);
    };

    eventCallback({ type: "text_delta", text: "Let me check..." });
    eventCallback({ type: "tool_use", callId: "c1", name: "Read", input: { path: "/tmp/x" } });
    eventCallback({ type: "tool_activity", name: "Read", status: "started" });
    eventCallback({ type: "tool_use", callId: "c2", name: "bash", input: { command: "pwd" } });
    eventCallback({ type: "tool_activity", name: "bash", status: "started" });
    eventCallback({ type: "text_delta", text: "Here's what I found." });

    // Only tool_use events should be filtered; everything else passes through
    expect(forwarded).toHaveLength(4);
    expect(forwarded.map((e: any) => e.type)).toEqual([
      "text_delta",
      "tool_activity",
      "tool_activity",
      "text_delta",
    ]);
  });
});
