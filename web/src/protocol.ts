import type { CellData, CursorState } from "@ghostd-web/core";

export type TerminalId = number;
export type ClientRole = "writer" | "reader";
export type WireClientMessage =
  | [ClientOpcode.Input, TerminalId, string]
  | [ClientOpcode.Resize, TerminalId, number, number]
  | [ClientOpcode.ClaimWriter, TerminalId]
  | [ClientOpcode.Scroll, TerminalId, number, WireScrollDirection]
  | [ClientOpcode.ListTerminals]
  | [ClientOpcode.CreateTerminal, number, number]
  | [ClientOpcode.CloseTerminal, TerminalId];
export type WireServerMessage =
  | [
      ServerOpcode.Snapshot,
      TerminalId,
      number,
      number,
      WireRole,
      WireCursor,
      boolean,
      WireCell[][],
      number[],
      WirePackedRow[],
    ]
  | [ServerOpcode.Rows, TerminalId, WireCursor, WirePackedRow[]]
  | [ServerOpcode.Role, TerminalId, WireRole]
  | [ServerOpcode.Exit, TerminalId, number]
  | [ServerOpcode.Terminals, WireTerminalSummary[]]
  | [ServerOpcode.TerminalCreated, WireTerminalSummary]
  | [ServerOpcode.TerminalClosed, TerminalId, number | null];

export const enum ClientOpcode {
  Input = 1,
  Resize = 2,
  ClaimWriter = 3,
  Scroll = 4,
  ListTerminals = 5,
  CreateTerminal = 6,
  CloseTerminal = 7,
}

export const enum ServerOpcode {
  Snapshot = 1,
  Rows = 2,
  Role = 3,
  Exit = 4,
  Terminals = 5,
  TerminalCreated = 6,
  TerminalClosed = 7,
}

const enum WireRole {
  Reader = 0,
  Writer = 1,
}

const enum WireScrollDirection {
  Up = 0,
  Down = 1,
}

type WireCursor = [number, number, boolean];
type WireCell =
  | [number, number, number, number]
  | [number, number, number, number, number | null, number | null];
type WirePackedRow = [number, WireCell[]];
type WireTerminalSummary = [
  TerminalId,
  string | null,
  number,
  number,
  WireRole,
  boolean,
];

export interface PackedRow {
  index: number;
  cells: CellData[];
}

export interface TerminalSummary {
  terminalId: TerminalId;
  title: string | null;
  cols: number;
  rows: number;
  role: ClientRole;
  writerConnected: boolean;
}

export interface TerminalMessage {
  terminalId: TerminalId;
}

export interface TerminalsMessage {
  type: "terminals";
  terminals: TerminalSummary[];
}

export interface TerminalCreatedMessage {
  type: "terminalCreated";
  terminal: TerminalSummary;
}

export interface TerminalClosedMessage extends TerminalMessage {
  type: "terminalClosed";
  exitCode: number | null;
}

export interface SnapshotMessage extends TerminalMessage {
  type: "snapshot";
  cols: number;
  rows: number;
  role: ClientRole;
  cursor: CursorState;
  mouseReporting: boolean;
  scrollback: CellData[][];
  scrollbackLineLens: number[];
  viewport: PackedRow[];
}

export interface RowsMessage extends TerminalMessage {
  type: "rows";
  cursor: CursorState;
  rows: PackedRow[];
}

export interface ExitMessage extends TerminalMessage {
  type: "exit";
  exitCode: number;
}

export interface RoleMessage extends TerminalMessage {
  type: "role";
  role: ClientRole;
}

export interface InputMessage extends TerminalMessage {
  type: "input";
  data: string;
}

export interface ResizeMessage extends TerminalMessage {
  type: "resize";
  cols: number;
  rows: number;
}

export interface ClaimWriterMessage extends TerminalMessage {
  type: "claimWriter";
}

export interface ListTerminalsMessage {
  type: "listTerminals";
}

export interface CreateTerminalMessage {
  type: "createTerminal";
  cols: number;
  rows: number;
}

export interface CloseTerminalMessage extends TerminalMessage {
  type: "closeTerminal";
}

export interface ScrollMessage extends TerminalMessage {
  type: "scroll";
  rows: number;
  direction: "up" | "down";
}

export type ClientMessage =
  | InputMessage
  | ResizeMessage
  | ClaimWriterMessage
  | ListTerminalsMessage
  | CreateTerminalMessage
  | CloseTerminalMessage
  | ScrollMessage;
export type ServerMessage =
  | SnapshotMessage
  | RowsMessage
  | RoleMessage
  | ExitMessage
  | TerminalsMessage
  | TerminalCreatedMessage
  | TerminalClosedMessage;

export function encodeClientMessage(message: ClientMessage): WireClientMessage {
  switch (message.type) {
    case "input":
      return [ClientOpcode.Input, message.terminalId, message.data];
    case "resize":
      return [
        ClientOpcode.Resize,
        message.terminalId,
        message.cols,
        message.rows,
      ];
    case "claimWriter":
      return [ClientOpcode.ClaimWriter, message.terminalId];
    case "scroll":
      return [
        ClientOpcode.Scroll,
        message.terminalId,
        message.rows,
        message.direction === "up" ? WireScrollDirection.Up : WireScrollDirection.Down,
      ];
    case "listTerminals":
      return [ClientOpcode.ListTerminals];
    case "createTerminal":
      return [ClientOpcode.CreateTerminal, message.cols, message.rows];
    case "closeTerminal":
      return [ClientOpcode.CloseTerminal, message.terminalId];
  }
}

export function decodeServerMessage(message: unknown): ServerMessage {
  if (!Array.isArray(message) || typeof message[0] !== "number") {
    throw new Error("invalid ghostd protocol message");
  }

  switch (message[0]) {
    case ServerOpcode.Snapshot:
      return decodeSnapshot(message);
    case ServerOpcode.Rows:
      return {
        type: "rows",
        terminalId: numberAt(message, 1),
        cursor: decodeCursor(message[2]),
        rows: decodeRows(message[3]),
      };
    case ServerOpcode.Role:
      return {
        type: "role",
        terminalId: numberAt(message, 1),
        role: decodeRole(numberAt(message, 2)),
      };
    case ServerOpcode.Exit:
      return {
        type: "exit",
        terminalId: numberAt(message, 1),
        exitCode: numberAt(message, 2),
      };
    case ServerOpcode.Terminals:
      return {
        type: "terminals",
        terminals: arrayAt(message, 1).map(decodeTerminalSummary),
      };
    case ServerOpcode.TerminalCreated:
      return {
        type: "terminalCreated",
        terminal: decodeTerminalSummary(message[1]),
      };
    case ServerOpcode.TerminalClosed:
      return {
        type: "terminalClosed",
        terminalId: numberAt(message, 1),
        exitCode: message[2] === null ? null : numberAt(message, 2),
      };
    default:
      throw new Error(`unknown ghostd protocol opcode ${message[0]}`);
  }
}

function decodeSnapshot(message: unknown[]): SnapshotMessage {
  return {
    type: "snapshot",
    terminalId: numberAt(message, 1),
    cols: numberAt(message, 2),
    rows: numberAt(message, 3),
    role: decodeRole(numberAt(message, 4)),
    cursor: decodeCursor(message[5]),
    mouseReporting: Boolean(message[6]),
    scrollback: arrayAt(message, 7).map(decodeCells),
    scrollbackLineLens: arrayAt(message, 8).map((value) => numberValue(value)),
    viewport: decodeRows(message[9]),
  };
}

function decodeTerminalSummary(value: unknown): TerminalSummary {
  const summary = arrayValue(value);
  return {
    terminalId: numberAt(summary, 0),
    title: summary[1] === null ? null : String(summary[1]),
    cols: numberAt(summary, 2),
    rows: numberAt(summary, 3),
    role: decodeRole(numberAt(summary, 4)),
    writerConnected: Boolean(summary[5]),
  };
}

function decodeRows(value: unknown): PackedRow[] {
  return arrayValue(value).map((row) => {
    const packed = arrayValue(row);
    return {
      index: numberAt(packed, 0),
      cells: decodeCells(packed[1]),
    };
  });
}

function decodeCells(value: unknown): CellData[] {
  return arrayValue(value).map((cell) => {
    const packed = arrayValue(cell);
    const out: CellData = {
      char: numberAt(packed, 0),
      fg: numberAt(packed, 1),
      bg: numberAt(packed, 2),
      flags: numberAt(packed, 3),
    };
    if (packed.length > 4 && packed[4] !== null) out.fgRgb = numberAt(packed, 4);
    if (packed.length > 5 && packed[5] !== null) out.bgRgb = numberAt(packed, 5);
    return out;
  });
}

function decodeCursor(value: unknown): CursorState {
  const cursor = arrayValue(value);
  return {
    row: numberAt(cursor, 0),
    col: numberAt(cursor, 1),
    visible: Boolean(cursor[2]),
  };
}

function decodeRole(value: number): ClientRole {
  return value === WireRole.Writer ? "writer" : "reader";
}

function arrayAt(values: unknown[], index: number): unknown[] {
  return arrayValue(values[index]);
}

function numberAt(values: unknown[], index: number): number {
  return numberValue(values[index]);
}

function arrayValue(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error("invalid ghostd protocol array");
  return value;
}

function numberValue(value: unknown): number {
  if (typeof value !== "number") throw new Error("invalid ghostd protocol number");
  return value;
}
