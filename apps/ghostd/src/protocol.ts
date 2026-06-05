import type { CellData, CursorState } from "@wterm/core";

export interface PackedRow {
  index: number;
  cells: CellData[];
}

export interface SnapshotMessage {
  type: "snapshot";
  sessionId: string;
  role: ClientRole;
  cols: number;
  rows: number;
  cursor: CursorState;
  mouseReporting: boolean;
  scrollback: CellData[][];
  scrollbackLineLens: number[];
  viewport: PackedRow[];
}

export interface RowsMessage {
  type: "rows";
  cursor: CursorState;
  rows: PackedRow[];
}

export interface ExitMessage {
  type: "exit";
  exitCode: number;
}

export interface RoleMessage {
  type: "role";
  role: ClientRole;
}

export interface InputMessage {
  type: "input";
  data: string;
}

export interface ResizeMessage {
  type: "resize";
  cols: number;
  rows: number;
}

export interface ClaimWriterMessage {
  type: "claimWriter";
}

export interface ScrollMessage {
  type: "scroll";
  rows: number;
  direction: "up" | "down";
}

export type ClientRole = "writer" | "reader";
export type ClientMessage =
  | InputMessage
  | ResizeMessage
  | ClaimWriterMessage
  | ScrollMessage;
export type ServerMessage =
  | SnapshotMessage
  | RowsMessage
  | RoleMessage
  | ExitMessage;
