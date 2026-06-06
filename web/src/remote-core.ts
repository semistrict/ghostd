import type {
  CellData,
  CursorState,
  TerminalCore,
  UnhandledSequence,
} from "@wterm/core";
import { decode, encode } from "@msgpack/msgpack";
import type {
  ClientMessage,
  ClientRole,
  PackedRow,
  ServerMessage,
  TerminalId,
} from "./protocol.js";
import {
  decodeServerMessage,
  encodeClientMessage,
} from "./protocol.js";

const DEFAULT_COLOR = 256;

const BLANK_CELL: CellData = {
  char: 32,
  fg: DEFAULT_COLOR,
  bg: DEFAULT_COLOR,
  flags: 0,
};

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
  private role: ClientRole = "reader";
  private forceNextResize = false;
  private mouseReporting = false;

  onUpdate: (() => void) | null = null;
  onRoleChange: ((role: ClientRole) => void) | null = null;

  constructor(terminalId: TerminalId = 0) {
    this.terminalId = terminalId;
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

  connect(url: string): void {
    this.ws?.close();
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    this.ws = ws;

    ws.onmessage = (event) => {
      const bytes =
        event.data instanceof ArrayBuffer
          ? new Uint8Array(event.data)
          : new Uint8Array(event.data as ArrayBufferLike);
      this.applyMessage(decodeServerMessage(decode(bytes)));
      this.onUpdate?.();
    };

    ws.onclose = () => {
      if (this.ws === ws) {
        this.ws = null;
        setTimeout(() => this.connect(url), 1000);
      }
    };
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

  private applyMessage(message: ServerMessage): void {
    if (message.type === "snapshot") {
      const resized = message.cols !== this.cols || message.rows !== this.rows;
      this.terminalId = message.terminalId;
      this.cols = message.cols;
      this.rows = message.rows;
      this.setRole(message.role);
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
      this.applyRows(message.rows);
      return;
    }

    if (message.type === "role") {
      this.setRole(message.role);
    }
  }

  private applyRows(rows: PackedRow[]): void {
    for (const row of rows) {
      if (this.rowsEqual(this.viewport[row.index], row.cells)) continue;
      this.viewport[row.index] = row.cells;
      this.dirtyRows.add(row.index);
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
  }

  private sendInput(data: string): void {
    if (this.role !== "writer") return;
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.send({ type: "input", terminalId: this.terminalId, data });
  }

  private send(message: ClientMessage): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(encode(encodeClientMessage(message)));
  }
}
