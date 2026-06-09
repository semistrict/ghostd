import { decode, encode } from "@msgpack/msgpack";
import type {
  CellData,
  CursorState,
  TerminalCore,
  UnhandledSequence,
} from "./types.js";
import type {
  ClientMessage,
  ClientRole,
  CellRange,
  PackedRow,
  ServerMessage,
  TerminalId,
  TerminalSummary,
} from "./protocol.js";
import { decodeServerMessage, encodeClientMessage } from "./protocol.js";

const DEFAULT_COLOR = 256;

const BLANK_CELL: CellData = {
  char: 32,
  fg: DEFAULT_COLOR,
  bg: DEFAULT_COLOR,
  flags: 0,
};

function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export type RemoteTerminalCoreEventMap = {
  open: Event;
  close: CloseEvent;
  error: Event;
  update: void;
  roleChange: ClientRole;
  terminals: TerminalSummary[];
  terminalCreated: TerminalSummary;
  terminalClosed: TerminalId;
};

export type RemoteTerminalTransport = "websocket" | "event-stream";

export class RemoteTerminalCore implements TerminalCore {
  private terminalId: TerminalId = 0;
  private cols = 80;
  private rows = 24;
  private viewport: CellData[][] = [];
  private scrollback: CellData[][] = [];
  private scrollbackLineLens: number[] = [];
  private dirtyRows = new Set<number>();
  private cursor: CursorState = { row: 0, col: 0, visible: true };
  private ws: WebSocket | null = null;
  private eventSource: EventSource | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private transport: RemoteTerminalTransport = "websocket";
  private role: ClientRole = "reader";
  private forceNextResize = false;
  private mouseReporting = false;
  private reconnect = true;
  private connectedUrl: string | null = null;
  private inputUrl: string | null = null;
  private inputQueue: Promise<void> = Promise.resolve();
  private pendingInput = "";
  private pendingInputTimer: ReturnType<typeof setTimeout> | null = null;
  private listeners = new Map<keyof RemoteTerminalCoreEventMap, Set<(value: never) => void>>();

  onUpdate: (() => void) | null = null;
  onRoleChange: ((role: ClientRole) => void) | null = null;
  onTerminalCreated: ((terminal: TerminalSummary) => void) | null = null;
  onTerminals: ((terminals: TerminalSummary[]) => void) | null = null;
  onTerminalClosed: ((terminalId: TerminalId) => void) | null = null;

  constructor(terminalId: TerminalId = 0) {
    this.terminalId = terminalId;
  }

  on<K extends keyof RemoteTerminalCoreEventMap>(
    event: K,
    listener: (value: RemoteTerminalCoreEventMap[K]) => void,
  ): () => void {
    let listeners = this.listeners.get(event);
    if (!listeners) {
      listeners = new Set();
      this.listeners.set(event, listeners);
    }
    listeners.add(listener as (value: never) => void);

    return () => this.off(event, listener);
  }

  off<K extends keyof RemoteTerminalCoreEventMap>(
    event: K,
    listener: (value: RemoteTerminalCoreEventMap[K]) => void,
  ): void {
    this.listeners.get(event)?.delete(listener as (value: never) => void);
  }

  init(cols: number, rows: number): void {
    this.cols = cols;
    this.rows = rows;
    this.viewport = Array.from({ length: rows }, () => this.blankRow());
    for (let row = 0; row < rows; row++) this.dirtyRows.add(row);
  }

  resize(cols: number, rows: number): void {
    if (this.role !== "writer") return;
    const force = this.forceNextResize;
    this.forceNextResize = false;
    if (!force && cols === this.cols && rows === this.rows) return;
    this.cols = cols;
    this.rows = rows;
    this.viewport = this.resizeViewport(cols, rows);
    for (let row = 0; row < rows; row++) this.dirtyRows.add(row);
    this.send({ type: "resize", terminalId: this.terminalId, cols, rows });
  }

  connect(
    url: string,
    options: {
      inputUrl?: string;
      reconnect?: boolean;
      transport?: RemoteTerminalTransport;
    } = {},
  ): void {
    this.disconnect();
    this.connectedUrl = url;
    this.inputUrl = options.inputUrl ?? null;
    this.reconnect = options.reconnect ?? true;
    this.transport = options.transport ?? "websocket";
    if (this.transport === "event-stream") this.openEventStream(url);
    else this.openSocket(url);
  }

  disconnect(): void {
    this.connectedUrl = null;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    const ws = this.ws;
    this.ws = null;
    ws?.close();
    const eventSource = this.eventSource;
    this.eventSource = null;
    eventSource?.close();
  }

  getTerminalId(): TerminalId {
    return this.terminalId;
  }

  createTerminal(cols: number, rows: number): void {
    this.send({ type: "createTerminal", cols, rows });
  }

  listTerminals(): void {
    this.send({ type: "listTerminals" });
  }

  writeString(str: string): void {
    this.sendInput(str);
  }

  writeRaw(data: Uint8Array): void {
    this.sendInput(new TextDecoder().decode(data));
  }

  getRole(): ClientRole {
    return this.role;
  }

  claimWriter(): void {
    if (this.role === "writer") return;
    this.send({ type: "claimWriter", terminalId: this.terminalId });
  }

  wantsMouseInput(): boolean {
    return this.mouseReporting;
  }

  scrollViewport(rows: number, direction: "up" | "down"): void {
    if (this.role !== "writer") return;
    this.send({ type: "scroll", terminalId: this.terminalId, rows, direction });
  }

  forceResize(): void {
    this.forceNextResize = true;
  }

  getCell(row: number, col: number): CellData {
    return this.viewport[row]?.[col] ?? BLANK_CELL;
  }

  isDirtyRow(row: number): boolean {
    return this.dirtyRows.has(row);
  }

  clearDirty(): void {
    this.dirtyRows.clear();
  }

  getCols(): number {
    return this.cols;
  }

  getRows(): number {
    return this.rows;
  }

  getCursor(): CursorState {
    return this.cursor;
  }

  cursorKeysApp(): boolean {
    return false;
  }

  bracketedPaste(): boolean {
    return false;
  }

  usingAltScreen(): boolean {
    return false;
  }

  getTitle(): string | null {
    return null;
  }

  getResponse(): string | null {
    return null;
  }

  getScrollbackCount(): number {
    return this.scrollback.length;
  }

  getScrollbackCell(offset: number, col: number): CellData {
    return this.scrollback[offset]?.[col] ?? BLANK_CELL;
  }

  getScrollbackLineLen(offset: number): number {
    return this.scrollbackLineLens[offset] ?? 0;
  }

  getUnhandledSequences(): UnhandledSequence[] {
    return [];
  }

  private openSocket(url: string): void {
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    this.ws = ws;

    ws.onopen = (event) => {
      if (this.ws !== ws) return;
      this.emit("open", event);
    };

    ws.onmessage = (event) => {
      if (this.ws !== ws) return;
      const bytes =
        event.data instanceof ArrayBuffer
          ? new Uint8Array(event.data)
          : new Uint8Array(event.data as ArrayBufferLike);
      this.applyWireBytes(bytes);
    };

    ws.onerror = (event) => {
      if (this.ws !== ws) return;
      this.emit("error", event);
    };

    ws.onclose = (event) => {
      if (this.ws !== ws) return;
      this.ws = null;
      this.emit("close", event);
      if (!this.reconnect || !this.connectedUrl) return;
      this.reconnectTimer = setTimeout(() => {
        if (!this.connectedUrl) return;
        this.openSocket(this.connectedUrl);
      }, 1000);
    };
  }

  private openEventStream(url: string): void {
    const eventSource = new EventSource(url);
    this.eventSource = eventSource;

    eventSource.onopen = (event) => {
      if (this.eventSource !== eventSource) return;
      this.emit("open", event);
    };

    eventSource.onmessage = (event) => {
      if (this.eventSource !== eventSource) return;
      this.applyWireBytes(base64ToBytes(event.data));
    };

    eventSource.onerror = (event) => {
      if (this.eventSource !== eventSource) return;
      this.emit("error", event);
      if (eventSource.readyState === EventSource.CLOSED) {
        this.eventSource = null;
        this.emit("close", new CloseEvent("close"));
        if (!this.reconnect || !this.connectedUrl) return;
        this.reconnectTimer = setTimeout(() => {
          if (!this.connectedUrl) return;
          this.openEventStream(this.connectedUrl);
        }, 1000);
      }
    };
  }

  private applyWireBytes(bytes: Uint8Array): void {
    this.applyMessage(decodeServerMessage(decode(bytes)));
    this.onUpdate?.();
    this.emit("update", undefined);
  }

  private applyMessage(message: ServerMessage): void {
    if (message.type === "snapshot") {
      const resized = message.cols !== this.cols || message.rows !== this.rows;
      const terminalChanged = message.terminalId !== this.terminalId;
      this.terminalId = message.terminalId;
      this.cols = message.cols;
      this.rows = message.rows;
      this.setRole(message.role, terminalChanged);
      this.cursor = message.cursor;
      this.mouseReporting = message.mouseReporting;
      this.scrollback = message.scrollback;
      this.scrollbackLineLens = message.scrollbackLineLens;
      if (resized || this.viewport.length !== this.rows) {
        this.viewport = Array.from({ length: this.rows }, () => this.blankRow());
      }
      this.applyRows(message.viewport);
      return;
    }

    if (message.type === "rows") {
      this.cursor = message.cursor;
      this.applyRanges(message.ranges);
      return;
    }

    if (message.type === "role") {
      if (message.terminalId !== this.terminalId) return;
      this.setRole(message.role);
      return;
    }

    if (message.type === "terminals") {
      this.onTerminals?.(message.terminals);
      this.emit("terminals", message.terminals);
      return;
    }

    if (message.type === "terminalCreated") {
      this.onTerminalCreated?.(message.terminal);
      this.emit("terminalCreated", message.terminal);
      return;
    }

    if (message.type === "terminalClosed") {
      this.onTerminalClosed?.(message.terminalId);
      this.emit("terminalClosed", message.terminalId);
    }
  }

  private applyRows(rows: PackedRow[]): void {
    for (const row of rows) {
      if (this.rowsEqual(this.viewport[row.index], row.cells)) continue;
      this.viewport[row.index] = row.cells;
      this.dirtyRows.add(row.index);
    }
  }

  private applyRanges(ranges: CellRange[]): void {
    for (const range of ranges) {
      if (range.row < 0 || range.row >= this.rows) continue;
      const row = this.viewport[range.row] ?? this.blankRow();
      let changed = false;
      for (let i = 0; i < range.cells.length; i++) {
        const col = range.col + i;
        if (col < 0 || col >= this.cols) continue;
        if (this.cellsEqual(row[col], range.cells[i])) continue;
        row[col] = range.cells[i];
        changed = true;
      }
      if (!changed) continue;
      this.viewport[range.row] = row;
      this.dirtyRows.add(range.row);
    }
  }

  private blankRow(): CellData[] {
    return Array.from({ length: this.cols }, () => BLANK_CELL);
  }

  private resizeViewport(cols: number, rows: number): CellData[][] {
    return Array.from({ length: rows }, (_, row) => {
      const existing = this.viewport[row] ?? [];
      return Array.from(
        { length: cols },
        (_, col) => existing[col] ?? BLANK_CELL,
      );
    });
  }

  private rowsEqual(a: CellData[] | undefined, b: CellData[]): boolean {
    if (!a || a.length !== b.length) return false;
    for (let i = 0; i < b.length; i++) {
      if (!this.cellsEqual(a[i], b[i])) return false;
    }
    return true;
  }

  private cellsEqual(a: CellData | undefined, b: CellData): boolean {
    return (
      !!a &&
      a.char === b.char &&
      a.fg === b.fg &&
      a.bg === b.bg &&
      a.flags === b.flags &&
      a.fgRgb === b.fgRgb &&
      a.bgRgb === b.bgRgb
    );
  }

  private setRole(role: ClientRole, forceNotify = false): void {
    if (this.role === role && !forceNotify) return;
    this.role = role;
    this.onRoleChange?.(role);
    this.emit("roleChange", role);
  }

  private sendInput(data: string): void {
    if (this.role !== "writer") return;
    if (this.transport === "event-stream") {
      this.pendingInput += data;
      if (this.pendingInputTimer) {
        clearTimeout(this.pendingInputTimer);
        this.pendingInputTimer = null;
      }
      if (data.includes("\r") || data.includes("\n")) {
        this.flushPendingInput();
      } else {
        this.pendingInputTimer = setTimeout(() => this.flushPendingInput(), 50);
      }
      return;
    }
    this.send({ type: "input", terminalId: this.terminalId, data });
  }

  private flushPendingInput(): void {
    if (this.pendingInputTimer) {
      clearTimeout(this.pendingInputTimer);
      this.pendingInputTimer = null;
    }
    const pendingInput = this.pendingInput;
    this.pendingInput = "";
    if (!pendingInput) return;
    this.send({ type: "input", terminalId: this.terminalId, data: pendingInput });
  }

  private send(message: ClientMessage): void {
    const bytes = encode(encodeClientMessage(message));
    if (this.transport === "event-stream") {
      if (!this.inputUrl) return;
      this.inputQueue = this.inputQueue
        .then(() => fetch(this.inputUrl!, {
        body: bytes,
        headers: { "Content-Type": "application/octet-stream" },
        method: "POST",
        }))
        .then(() => undefined, () => undefined);
      return;
    }
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(bytes);
  }

  private emit<K extends keyof RemoteTerminalCoreEventMap>(
    event: K,
    value: RemoteTerminalCoreEventMap[K],
  ): void {
    for (const listener of this.listeners.get(event) ?? []) {
      listener(value as never);
    }
  }
}
