import { decode } from "@msgpack/msgpack";
import { expect, test } from "@playwright/test";
import fs from "node:fs/promises";
import path from "node:path";

type TraceEntry = Record<string, unknown> & { at: number; type: string };

declare global {
  interface Window {
    __ghostdTrace: TraceEntry[];
  }
}

function installFrontendTrace(): void {
  const start = Date.now();
  const trace: TraceEntry[] = [];
  const push = (entry: Omit<TraceEntry, "at">) => {
    trace.push({ at: Date.now() - start, ...entry });
  };

  Object.defineProperty(window, "__ghostdTrace", {
    configurable: true,
    value: trace,
  });

  const OriginalWebSocket = window.WebSocket;
  class TracedWebSocket extends OriginalWebSocket {
    constructor(url: string | URL, protocols?: string | string[]) {
      super(url, protocols);
      push({ type: "ws:new", url: String(url) });

      this.addEventListener("open", () => push({ type: "ws:open", url: String(url) }));
      this.addEventListener("close", (event) =>
        push({
          type: "ws:close",
          code: event.code,
          reason: event.reason,
          wasClean: event.wasClean,
        }),
      );
      this.addEventListener("error", () => push({ type: "ws:error" }));
      this.addEventListener("message", (event) => {
        void bytesFromMessage(event.data).then((bytes) => {
          push({
            type: "ws:message",
            byteLength: bytes.length,
            bytes: Array.from(bytes),
          });
        });
      });
    }

    send(data: string | ArrayBufferLike | Blob | ArrayBufferView): void {
      void bytesFromSend(data).then((bytes) => {
        push({
          type: "ws:send",
          byteLength: bytes.length,
          bytes: Array.from(bytes),
        });
      });
      super.send(data);
    }
  }

  Object.defineProperty(TracedWebSocket, "CONNECTING", {
    value: OriginalWebSocket.CONNECTING,
  });
  Object.defineProperty(TracedWebSocket, "OPEN", { value: OriginalWebSocket.OPEN });
  Object.defineProperty(TracedWebSocket, "CLOSING", { value: OriginalWebSocket.CLOSING });
  Object.defineProperty(TracedWebSocket, "CLOSED", { value: OriginalWebSocket.CLOSED });
  window.WebSocket = TracedWebSocket as typeof WebSocket;

  const originalRaf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = (callback) => {
    push({ type: "raf:schedule" });
    return originalRaf((time) => {
      push({ type: "raf:run" });
      callback(time);
    });
  };

  const originalSetTimeout = window.setTimeout.bind(window);
  window.setTimeout = ((handler: TimerHandler, timeout?: number, ...args: unknown[]) => {
    push({ type: "timeout:schedule", timeout: timeout ?? 0 });
    return originalSetTimeout(
      (...innerArgs: unknown[]) => {
        push({ type: "timeout:run", timeout: timeout ?? 0 });
        if (typeof handler === "function") {
          handler(...innerArgs);
        } else {
          // eslint-disable-next-line no-eval
          eval(handler);
        }
      },
      timeout,
      ...args,
    );
  }) as typeof window.setTimeout;

  const originalConsole = {
    debug: console.debug.bind(console),
    error: console.error.bind(console),
    info: console.info.bind(console),
    log: console.log.bind(console),
    warn: console.warn.bind(console),
  };
  for (const level of Object.keys(originalConsole) as Array<keyof typeof originalConsole>) {
    console[level] = (...args: unknown[]) => {
      push({ type: `console:${level}`, args: args.map(String) });
      originalConsole[level](...args);
    };
  }

  let terminalObserverInstalled = false;
  function observeTerminal(): boolean {
    const terminal = document.querySelector("#terminal");
    if (!terminal || terminalObserverInstalled) return Boolean(terminal);
    terminalObserverInstalled = true;
    const observer = new MutationObserver((records) => {
      push({
        type: "dom:mutation",
        records: records.length,
        childList: records.filter((record) => record.type === "childList").length,
        characterData: records.filter((record) => record.type === "characterData").length,
        rows: Array.from(document.querySelectorAll("#terminal .term-row"))
          .slice(0, 8)
          .map((row) => row.textContent),
      });
    });
    observer.observe(terminal, {
      childList: true,
      characterData: true,
      subtree: true,
    });
    return true;
  }

  window.addEventListener("DOMContentLoaded", () => {
    push({ type: "dom:content-loaded" });
    if (observeTerminal()) return;

    const rootObserver = new MutationObserver(() => {
      if (observeTerminal()) rootObserver.disconnect();
    });
    rootObserver.observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
  });

  function bytesFromMessage(data: unknown): Promise<Uint8Array> {
    if (data instanceof ArrayBuffer) return Promise.resolve(new Uint8Array(data));
    if (ArrayBuffer.isView(data)) {
      return Promise.resolve(
        new Uint8Array(data.buffer, data.byteOffset, data.byteLength),
      );
    }
    if (data instanceof Blob) {
      return data.arrayBuffer().then((buffer) => new Uint8Array(buffer));
    }
    return Promise.resolve(new TextEncoder().encode(String(data)));
  }

  function bytesFromSend(
    data: string | ArrayBufferLike | Blob | ArrayBufferView,
  ): Promise<Uint8Array> {
    if (typeof data === "string") return Promise.resolve(new TextEncoder().encode(data));
    return bytesFromMessage(data);
  }
}

function decodeMessages(trace: TraceEntry[]): TraceEntry[] {
  return trace.map((entry) => {
    if (
      (entry.type === "ws:message" || entry.type === "ws:send") &&
      Array.isArray(entry.bytes)
    ) {
      try {
        const decoded = decode(Uint8Array.from(entry.bytes as number[]));
        return { ...entry, decoded };
      } catch (error) {
        return { ...entry, decodeError: String(error) };
      }
    }
    return entry;
  });
}

async function setupTracedPage(page: import("@playwright/test").Page): Promise<void> {
  await page.addInitScript(installFrontendTrace);
  await page.goto("/");
  await expect(page.locator("#terminal .term-row").first()).toContainText("%");
}

async function collectTrace(
  page: import("@playwright/test").Page,
  testInfo: import("@playwright/test").TestInfo,
  consoleEntries: TraceEntry[],
  name: string,
): Promise<TraceEntry[]> {
  const rawTrace = await page.evaluate(() => window.__ghostdTrace);
  const trace = decodeMessages(rawTrace).concat(consoleEntries);
  const outputPath = path.join(testInfo.outputDir, `${name}.json`);
  await fs.mkdir(testInfo.outputDir, { recursive: true });
  await fs.writeFile(outputPath, JSON.stringify(trace, null, 2));
  await testInfo.attach(name, {
    path: outputPath,
    contentType: "application/json",
  });
  return trace;
}

function watchConsole(
  page: import("@playwright/test").Page,
  startedAt = Date.now(),
): TraceEntry[] {
  const consoleEntries: TraceEntry[] = [];
  page.on("console", (message) => {
    consoleEntries.push({
      at: Date.now() - startedAt,
      type: `browser-console:${message.type()}`,
      text: message.text(),
    });
  });
  return consoleEntries;
}

function decodedType(entry: TraceEntry): unknown {
  if (Array.isArray(entry.decoded)) {
    switch (entry.decoded[0]) {
      case 1:
        return "input";
      case 2:
        return "resize";
      case 3:
        return "claimWriter";
      case 4:
        return "scroll";
      case 5:
        return "listTerminals";
      case 6:
        return "createTerminal";
      case 7:
        return "closeTerminal";
      default:
        return null;
    }
  }
  if (typeof entry.decoded !== "object" || entry.decoded === null) return null;
  if (!("type" in entry.decoded)) return null;
  return entry.decoded.type;
}

function decodedServerType(entry: TraceEntry): unknown {
  if (Array.isArray(entry.decoded)) {
    switch (entry.decoded[0]) {
      case 1:
        return "snapshot";
      case 2:
        return "rows";
      case 3:
        return "role";
      case 4:
        return "exit";
      case 5:
        return "terminals";
      case 6:
        return "terminalCreated";
      case 7:
        return "terminalClosed";
      default:
        return null;
    }
  }
  if (typeof entry.decoded !== "object" || entry.decoded === null) return null;
  if (!("type" in entry.decoded)) return null;
  return entry.decoded.type;
}

async function terminalText(page: import("@playwright/test").Page): Promise<string> {
  return page.locator("#terminal").textContent();
}

function decodedData(entry: TraceEntry): unknown {
  if (Array.isArray(entry.decoded)) return entry.decoded[2];
  if (typeof entry.decoded !== "object" || entry.decoded === null) return null;
  if (!("data" in entry.decoded)) return null;
  return entry.decoded.data;
}

function resizeSendsAtOrAfter(trace: TraceEntry[], at: number | undefined): TraceEntry[] {
  return trace.filter(
    (entry) =>
      at !== undefined &&
      entry.at >= at &&
      entry.type === "ws:send" &&
      decodedType(entry) === "resize",
  );
}

function nonBlankRows(rows: unknown): number {
  if (!Array.isArray(rows)) return 0;
  return rows.filter((row) => typeof row === "string" && row.trim().length > 0).length;
}

test("typing trace records frontend activity and all websocket messages", async ({
  page,
}, testInfo) => {
  const consoleEntries = watchConsole(page);
  await setupTracedPage(page);

  await page.locator("#terminal").click();
  await page.keyboard.type("echo ghostd-flash-probe");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(1500);

  const trace = await collectTrace(
    page,
    testInfo,
    consoleEntries,
    "ghostd-frontend-trace",
  );

  const messages = trace.filter((entry) => entry.type === "ws:message");
  const sends = trace.filter((entry) => entry.type === "ws:send");
  const mutations = trace.filter((entry) => entry.type === "dom:mutation");
  const sockets = trace.filter((entry) => entry.type === "ws:new");
  const firstTypedInputAt = sends.find(
    (entry) => decodedType(entry) === "input" && decodedData(entry) === "e",
  )?.at;
  const resizeAfterTyping = resizeSendsAtOrAfter(trace, firstTypedInputAt);
  const rangeMessagesAfterTyping = trace.filter(
    (entry) =>
      firstTypedInputAt !== undefined &&
      entry.at >= firstTypedInputAt &&
      entry.type === "ws:message" &&
      decodedServerType(entry) === "rows",
  );
  const rangeLengths = rangeMessagesAfterTyping.flatMap((entry) => {
    if (!Array.isArray(entry.decoded)) return [];
    const ranges = entry.decoded[3];
    if (!Array.isArray(ranges)) return [];
    return ranges
      .filter((range): range is unknown[] => Array.isArray(range))
      .map((range) => (Array.isArray(range[2]) ? range[2].length : 0));
  });

  expect(messages.length, "server websocket messages").toBeGreaterThan(0);
  expect(sends.length, "client websocket messages").toBeGreaterThan(0);
  expect(mutations.length, "terminal DOM mutations").toBeGreaterThan(0);
  expect(sockets.some((entry) => String(entry.url).endsWith("/terminal/0.ws"))).toBe(
    true,
  );
  expect(resizeAfterTyping, "typing must not trigger resize churn").toHaveLength(0);
  expect(rangeLengths.length, "typing should receive cell-range updates").toBeGreaterThan(0);
  expect(
    Math.max(...rangeLengths),
    "typing should not receive full-row updates",
  ).toBeLessThan(80);
});

test("writer terminal fills the available viewport height", async ({ page }) => {
  await setupTracedPage(page);
  await expect(page.locator("#status")).toHaveText("writer");

  const expectedRows = await page.evaluate(() => {
    const terminal = document.querySelector<HTMLElement>("#terminal");
    if (!terminal) throw new Error("missing terminal");
    const style = getComputedStyle(terminal);
    const padding =
      Number.parseFloat(style.paddingTop) + Number.parseFloat(style.paddingBottom);
    const rowHeight =
      Number.parseFloat(style.getPropertyValue("--term-row-height")) || 17;
    return Math.floor((terminal.clientHeight - padding) / rowHeight);
  });

  await expect
    .poll(async () => page.locator("#terminal .term-row").count())
    .toBeGreaterThanOrEqual(expectedRows - 1);
});

test("REST terminal API returns terminal list plus text and html contents", async ({
  page,
}) => {
  await setupTracedPage(page);

  await page.locator("#terminal").click();
  await page.keyboard.type("echo ghostd-rest-probe");
  await page.keyboard.press("Enter");
  await expect(page.locator("#terminal")).toContainText("ghostd-rest-probe");

  const list = await page.request.get("/api/terminals");
  expect(list.ok()).toBe(true);
  expect(list.headers()["content-type"]).toContain("application/json");
  const json = await list.json();
  expect(json.terminals).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ id: 0, writerConnected: true }),
    ]),
  );

  const textByExtension = await page.request.get("/api/terminals/0.txt");
  expect(textByExtension.ok()).toBe(true);
  expect(textByExtension.headers()["content-type"]).toContain("text/plain");
  expect(await textByExtension.text()).toContain("ghostd-rest-probe");

  const htmlByAccept = await page.request.get("/api/terminals/0", {
    headers: { Accept: "text/html" },
  });
  expect(htmlByAccept.ok()).toBe(true);
  expect(htmlByAccept.headers()["content-type"]).toContain("text/html");
  expect(await htmlByAccept.text()).toContain("ghostd-rest-probe");

  const textBeatsAcceptWithExtension = await page.request.get("/api/terminals/0.txt", {
    headers: { Accept: "text/html" },
  });
  expect(textBeatsAcceptWithExtension.headers()["content-type"]).toContain(
    "text/plain",
  );
});

test("terminal title updates tab heading and REST metadata", async ({ page }) => {
  await setupTracedPage(page);

  await page.locator("#terminal").click();
  await page.keyboard.type("printf '\\033]0;ghostd-title-probe\\007'");
  await page.keyboard.press("Enter");

  await expect(page.locator('[data-terminal-tab="0"]')).toContainText(
    "ghostd-title-probe",
  );

  const list = await page.request.get("/api/terminals");
  expect(list.ok()).toBe(true);
  const json = await list.json();
  expect(json.terminals).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ id: 0, title: "ghostd-title-probe" }),
    ]),
  );
});

test("terminal pwd updates tab heading and REST metadata", async ({ page }) => {
  await setupTracedPage(page);

  await page.locator("#terminal").click();
  await page.keyboard.type(
    "printf '\\033]0;ghostd-pwd-title\\007\\033]7;file://localhost/tmp/ghostd-pwd-probe\\007'; sleep 1",
  );
  await page.keyboard.press("Enter");

  const tab = page.locator('[data-terminal-tab="0"]');
  await expect(tab).toContainText("ghostd-pwd-title");
  await expect(tab).toContainText("/tmp/ghostd-pwd-probe");

  const list = await page.request.get("/api/terminals");
  expect(list.ok()).toBe(true);
  const json = await list.json();
  expect(json.terminals).toEqual(
    expect.arrayContaining([
      expect.objectContaining({
        id: 0,
        title: "ghostd-pwd-title",
        pwd: "/tmp/ghostd-pwd-probe",
      }),
    ]),
  );
});

test("stealing writer keeps terminal visible and does not cause delayed resize churn", async ({
  browser,
}, testInfo) => {
  const writerPage = await browser.newPage();
  const readerPage = await browser.newPage();
  const writerConsole = watchConsole(writerPage);
  const readerConsole = watchConsole(readerPage);
  await setupTracedPage(writerPage);
  await setupTracedPage(readerPage);

  await expect(writerPage.locator("#status")).toHaveText("writer");
  await expect(readerPage.locator("#status")).toHaveText("reader");

  await readerPage.locator("#claim-writer").click();
  await expect(readerPage.locator("#status")).toHaveText("writer");
  await expect(readerPage.locator("#terminal .term-row").first()).toContainText("%");

  await readerPage.locator("#terminal").click();
  await readerPage.keyboard.type("echo stolen-writer-flash-probe");
  await readerPage.keyboard.press("Enter");
  await readerPage.waitForTimeout(1500);

  const readerTrace = await collectTrace(
    readerPage,
    testInfo,
    readerConsole,
    "ghostd-steal-writer-reader-trace",
  );
  await collectTrace(
    writerPage,
    testInfo,
    writerConsole,
    "ghostd-steal-writer-old-writer-trace",
  );

  const firstTypedInputAt = readerTrace.find(
    (entry) =>
      entry.type === "ws:send" &&
      decodedType(entry) === "input" &&
      decodedData(entry) === "e",
  )?.at;
  const claimWriterAt = readerTrace.find(
    (entry) => entry.type === "ws:send" && decodedType(entry) === "claimWriter",
  )?.at;
  const resizeAfterTyping = resizeSendsAtOrAfter(readerTrace, firstTypedInputAt);
  const blankMutations = readerTrace.filter(
    (entry) =>
      claimWriterAt !== undefined &&
      entry.at >= claimWriterAt &&
      entry.type === "dom:mutation" &&
      nonBlankRows(entry.rows) === 0,
  );

  expect(resizeAfterTyping, "stolen writer typing must not trigger resize churn").toHaveLength(0);
  expect(blankMutations, "steal-write path must not paint a blank terminal").toHaveLength(0);

  await writerPage.close();
  await readerPage.close();
});

test("tabbed terminals keep independent PTY state", async ({ page }) => {
  await setupTracedPage(page);

  await expect(page.locator('[data-terminal-tab="0"]')).toHaveAttribute(
    "aria-selected",
    "true",
  );

  await page.locator("#terminal").click();
  await page.keyboard.type("echo ghostd-terminal-zero");
  await page.keyboard.press("Enter");
  await expect(page.locator("#terminal")).toContainText("ghostd-terminal-zero");

  await page.locator("#new-terminal").click();
  const tabOne = page.locator('[data-terminal-tab="1"]');
  await expect(tabOne).toBeVisible();
  await expect(tabOne).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#terminal .term-row").first()).toContainText("%");

  await page.locator("#terminal").click();
  await page.keyboard.type("echo ghostd-terminal-one");
  await page.keyboard.press("Enter");
  await expect(page.locator("#terminal")).toContainText("ghostd-terminal-one");
  await expect(page.locator("#terminal")).not.toContainText("ghostd-terminal-zero");

  await page.locator('[data-terminal-tab="0"]').click();
  await expect(page.locator('[data-terminal-tab="0"]')).toHaveAttribute(
    "aria-selected",
    "true",
  );
  await expect(page.locator("#terminal")).toContainText("ghostd-terminal-zero");
  expect(await terminalText(page)).not.toContain("ghostd-terminal-one");

  await page.locator('[data-terminal-tab="1"]').click();
  await expect(page.locator("#terminal")).toContainText("ghostd-terminal-one");
  expect(await terminalText(page)).not.toContain("ghostd-terminal-zero");
});
