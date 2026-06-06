export interface CellData {
  char: number;
  fg: number;
  bg: number;
  flags: number;
  fgRgb?: number;
  bgRgb?: number;
}

export interface CursorState {
  row: number;
  col: number;
  visible: boolean;
}

export interface UnhandledSequence {
  final: string;
  private: string;
  paramCount: number;
  params: number[];
}

export interface TerminalCore {
  init(cols: number, rows: number): void;
  resize(cols: number, rows: number): void;
  writeString(str: string): void;
  writeRaw(data: Uint8Array): void;
  getCell(row: number, col: number): CellData;
  isDirtyRow(row: number): boolean;
  clearDirty(): void;
  getCols(): number;
  getRows(): number;
  getCursor(): CursorState;
  cursorKeysApp(): boolean;
  bracketedPaste(): boolean;
  usingAltScreen(): boolean;
  getTitle(): string | null;
  getResponse(): string | null;
  getScrollbackCount(): number;
  getScrollbackCell(offset: number, col: number): CellData;
  getScrollbackLineLen(offset: number): number;
  getUnhandledSequences(): UnhandledSequence[];
}
