import { GhostdWebTerminal } from "@ghostd-web/dom";
import "@ghostd-web/dom/css";
import { RemoteTerminalCore } from "./remote-core.js";
import type { ClientRole, TerminalId, TerminalSummary } from "./protocol.js";

const container = document.getElementById("terminal")!;
const status = document.getElementById("status")!;
const tabs = document.getElementById("tabs")!;
const newTerminalButton =
  document.querySelector<HTMLButtonElement>("#new-terminal")!;
const claimWriterButton =
  document.querySelector<HTMLButtonElement>("#claim-writer")!;
const core = new RemoteTerminalCore();
const term = new GhostdWebTerminal(container, {
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
let activeTerminalId: TerminalId = 0;
let terminals = new Map<TerminalId, TerminalSummary>([
  [
    0,
    {
      terminalId: 0,
      title: null,
      pwd: null,
      cols: 80,
      rows: 24,
      role: "reader",
      writerConnected: false,
    },
  ],
]);
const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
const terminalUrl = (terminalId: TerminalId) =>
  `${proto}//${window.location.host}/terminal/${terminalId}.ws`;

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
  const style = getComputedStyle(container);
  const verticalPadding =
    Number.parseFloat(style.paddingTop) + Number.parseFloat(style.paddingBottom);
  const availableHeight = Math.max(0, container.clientHeight - verticalPadding);

  return {
    cols: Math.max(1, Math.floor(cell.grid.clientWidth / cell.charWidth)),
    rows: Math.max(1, Math.floor(availableHeight / cell.rowHeight)),
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

function terminalLabel(terminal: TerminalSummary): string {
  const title = terminal.title ?? `term ${terminal.terminalId}`;
  return terminal.pwd ? `${title} ${terminal.pwd}` : title;
}

function renderTabs(): void {
  tabs.replaceChildren(
    ...Array.from(terminals.values())
      .sort((a, b) => a.terminalId - b.terminalId)
      .map((terminal) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "terminal-tab";
        button.dataset.terminalTab = String(terminal.terminalId);
        button.setAttribute("role", "tab");
        button.setAttribute(
          "aria-selected",
          String(terminal.terminalId === activeTerminalId),
        );
        button.textContent = terminalLabel(terminal);
        button.addEventListener("click", () => switchTerminal(terminal.terminalId));
        return button;
      }),
  );
}

function resetRenderState(): void {
  lastSentCols = core.getCols();
  lastSentRows = core.getRows();
  renderedCols = core.getCols();
  renderedRows = core.getRows();
  term.resize(renderedCols, renderedRows);
  term.write(new Uint8Array());
}

function switchTerminal(terminalId: TerminalId): void {
  activeTerminalId = terminalId;
  renderTabs();
  core.connect(terminalUrl(terminalId));
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

core.onTerminals = (nextTerminals) => {
  terminals = new Map(nextTerminals.map((terminal) => [terminal.terminalId, terminal]));
  if (!terminals.has(activeTerminalId)) {
    activeTerminalId = terminals.keys().next().value ?? 0;
  }
  renderTabs();
};

core.onTerminalCreated = (terminal) => {
  terminals.set(terminal.terminalId, terminal);
  switchTerminal(terminal.terminalId);
};

core.onTerminalClosed = (terminalId) => {
  terminals.delete(terminalId);
  if (terminalId === activeTerminalId) {
    activeTerminalId = terminals.keys().next().value ?? 0;
    switchTerminal(activeTerminalId);
  } else {
    renderTabs();
  }
};

claimWriterButton.addEventListener("click", () => core.claimWriter());
newTerminalButton.addEventListener("click", () => {
  const size = measureTerminal() ?? { cols: core.getCols(), rows: core.getRows() };
  core.createTerminal(size.cols, size.rows);
});
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

renderTabs();
core.connect(terminalUrl(activeTerminalId));
