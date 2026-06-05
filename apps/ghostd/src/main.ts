import { WTerm } from "@wterm/dom";
import "@wterm/dom/css";
import { RemoteTerminalCore } from "./remote-core.js";
import type { ClientRole } from "./protocol.js";

const container = document.getElementById("terminal")!;
const status = document.getElementById("status")!;
const claimWriterButton =
  document.querySelector<HTMLButtonElement>("#claim-writer")!;
const core = new RemoteTerminalCore();
const term = new WTerm(container, {
  core,
  cols: 80,
  rows: 24,
  autoResize: false,
  onData: (data) => core.writeString(data),
});

await term.init();

let lastSentCols = core.getCols();
let lastSentRows = core.getRows();
let renderedCols = core.getCols();
let renderedRows = core.getRows();

function measureCellSize(): {
  grid: HTMLElement;
  charWidth: number;
  rowHeight: number;
} | null {
  const grid = container.querySelector<HTMLElement>(".term-grid");
  if (!grid) return null;

  const probe = document.createElement("span");
  probe.textContent = "W";
  probe.style.visibility = "hidden";
  probe.style.position = "absolute";
  grid.appendChild(probe);
  const charWidth = probe.getBoundingClientRect().width;
  probe.remove();

  const rowHeight =
    Number.parseFloat(getComputedStyle(container).getPropertyValue("--term-row-height")) ||
    17;
  if (charWidth <= 0 || rowHeight <= 0) return null;

  return { grid, charWidth, rowHeight };
}

function measureTerminal(): { cols: number; rows: number } | null {
  const cell = measureCellSize();
  if (!cell) return null;

  return {
    cols: Math.max(1, Math.floor(cell.grid.clientWidth / cell.charWidth)),
    rows: Math.max(1, Math.floor(cell.grid.clientHeight / cell.rowHeight)),
  };
}

function syncWriterSize(options: { force?: boolean } = {}): void {
  if (core.getRole() !== "writer") return;
  const size = measureTerminal();
  if (!size) return;
  if (
    !options.force &&
    size.cols === lastSentCols &&
    size.rows === lastSentRows &&
    size.cols === core.getCols() &&
    size.rows === core.getRows()
  ) {
    return;
  }
  lastSentCols = size.cols;
  lastSentRows = size.rows;
  if (size.cols === renderedCols && size.rows === renderedRows) {
    if (options.force) core.forceResize();
    core.resize(size.cols, size.rows);
    return;
  }
  if (options.force) core.forceResize();
  renderedCols = size.cols;
  renderedRows = size.rows;
  term.resize(size.cols, size.rows);
}

core.onUpdate = () => {
  const cols = core.getCols();
  const rows = core.getRows();
  if (cols !== renderedCols || rows !== renderedRows) {
    renderedCols = cols;
    renderedRows = rows;
    term.resize(cols, rows);
  }
  term.write(new Uint8Array());
};

core.onRoleChange = (role: ClientRole) => {
  status.textContent = role;
  claimWriterButton.hidden = role !== "reader";
  container.classList.toggle("is-reader", role === "reader");
  container.classList.toggle("is-writer", role === "writer");
  if (role === "writer") {
    term.focus();
    requestAnimationFrame(() => syncWriterSize({ force: true }));
  }
};

claimWriterButton.addEventListener("click", () => core.claimWriter());
window.addEventListener("resize", () => {
  requestAnimationFrame(() => syncWriterSize());
});

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function sendWheelInput(event: WheelEvent): void {
  if (core.getRole() !== "writer") return;
  if (event.deltaX === 0 && event.deltaY === 0) return;

  if (!core.wantsMouseInput()) {
    event.preventDefault();
    const cell = measureCellSize();
    const rowHeight = cell?.rowHeight ?? 17;
    const rows = clamp(Math.ceil(Math.abs(event.deltaY) / rowHeight), 1, 8);
    core.scrollViewport(rows, event.deltaY < 0 ? "up" : "down");
    return;
  }

  const cell = measureCellSize();
  if (!cell) return;

  const bounds = cell.grid.getBoundingClientRect();
  const col = clamp(
    Math.floor((event.clientX - bounds.left) / cell.charWidth) + 1,
    1,
    core.getCols(),
  );
  const row = clamp(
    Math.floor((event.clientY - bounds.top) / cell.rowHeight) + 1,
    1,
    core.getRows(),
  );
  const button =
    Math.abs(event.deltaX) > Math.abs(event.deltaY)
      ? event.deltaX > 0
        ? 67
        : 66
      : event.deltaY > 0
        ? 65
        : 64;

  event.preventDefault();
  core.writeString(`\x1b[<${button};${col};${row}M`);
}

container.addEventListener("wheel", sendWheelInput, { passive: false });

new ResizeObserver(() => syncWriterSize()).observe(container);

const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
core.connect(`${proto}//${window.location.host}/api/terminal`);
