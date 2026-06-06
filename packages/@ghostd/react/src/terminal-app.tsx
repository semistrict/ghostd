import {
  ghostdTerminalWebSocketUrl,
  RemoteTerminalCore,
  type ClientRole,
  type TerminalId,
  type TerminalSummary,
} from "@ghostd-web/client";
import { GhostdWebTerminal } from "@ghostd-web/dom";
import { useEffect, useMemo, useRef, useState } from "react";

import "./styles.css";

export interface GhostdTerminalAppProps {
  baseUrl?: string | URL;
  initialTerminalId?: TerminalId;
  cols?: number;
  rows?: number;
  className?: string;
  terminalClassName?: string;
}

type ConnectionState = "connecting" | "open" | "closed" | "error";

type SizeState = {
  lastSentCols: number;
  lastSentRows: number;
  renderedCols: number;
  renderedRows: number;
};

function defaultTerminal(terminalId: TerminalId, cols: number, rows: number) {
  return new Map<TerminalId, TerminalSummary>([
    [
      terminalId,
      {
        terminalId,
        title: null,
        pwd: null,
        cols,
        rows,
        role: "reader",
        writerConnected: false,
      },
    ],
  ]);
}

function terminalLabel(terminal: TerminalSummary): string {
  const title = terminal.title ?? `term ${terminal.terminalId}`;
  return terminal.pwd ? `${title} ${terminal.pwd}` : title;
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function resolveBaseUrl(baseUrl: string | URL | undefined): URL {
  if (baseUrl) return new URL(String(baseUrl), window.location.href);
  return new URL(".", window.location.href);
}

export function GhostdTerminalApp({
  baseUrl,
  initialTerminalId = 0,
  cols = 80,
  rows = 24,
  className,
  terminalClassName,
}: GhostdTerminalAppProps) {
  const terminalElementRef = useRef<HTMLDivElement | null>(null);
  const coreRef = useRef<RemoteTerminalCore | null>(null);
  const terminalRef = useRef<GhostdWebTerminal | null>(null);
  const activeTerminalIdRef = useRef<TerminalId>(initialTerminalId);
  const pendingCreatedTerminalRef = useRef(false);
  const sizeRef = useRef<SizeState>({
    lastSentCols: cols,
    lastSentRows: rows,
    renderedCols: cols,
    renderedRows: rows,
  });
  const [activeTerminalId, setActiveTerminalId] =
    useState<TerminalId>(initialTerminalId);
  const [terminals, setTerminals] = useState(() =>
    defaultTerminal(initialTerminalId, cols, rows),
  );
  const terminalsRef = useRef(defaultTerminal(initialTerminalId, cols, rows));
  const [role, setRole] = useState<ClientRole>("reader");
  const [connectionState, setConnectionState] =
    useState<ConnectionState>("connecting");
  const baseUrlValue = String(baseUrl ?? ".");

  function setCurrentTerminalId(terminalId: TerminalId): void {
    activeTerminalIdRef.current = terminalId;
    setActiveTerminalId(terminalId);
  }

  function setTerminalMap(nextTerminals: Map<TerminalId, TerminalSummary>): void {
    terminalsRef.current = nextTerminals;
    setTerminals(nextTerminals);
  }

  const sortedTerminals = useMemo(
    () =>
      Array.from(terminals.values()).sort(
        (left, right) => left.terminalId - right.terminalId,
      ),
    [terminals],
  );

  useEffect(() => {
    const currentTerminalElement = terminalElementRef.current;
    if (currentTerminalElement === null) return;
    const terminalElement: HTMLDivElement = currentTerminalElement;

    let disposed = false;
    const core = new RemoteTerminalCore(initialTerminalId);
    const terminal = new GhostdWebTerminal(terminalElement, {
      core,
      cols,
      rows,
      autoResize: false,
      onData: (data) => core.writeString(data),
    });
    const base = resolveBaseUrl(baseUrlValue);
    const cleanupCallbacks: Array<() => void> = [];
    let resizeObserver: ResizeObserver | null = null;

    coreRef.current = core;
    terminalRef.current = terminal;
    sizeRef.current = {
      lastSentCols: cols,
      lastSentRows: rows,
      renderedCols: cols,
      renderedRows: rows,
    };

    function terminalUrl(terminalId: TerminalId) {
      return ghostdTerminalWebSocketUrl(base, terminalId);
    }

    function measureCellSize(): {
      grid: HTMLElement;
      charWidth: number;
      rowHeight: number;
    } | null {
      const grid = terminalElement.querySelector<HTMLElement>(".term-grid");
      if (!grid) return null;

      const probe = document.createElement("span");
      probe.textContent = "W";
      probe.style.visibility = "hidden";
      probe.style.position = "absolute";
      grid.appendChild(probe);
      const charWidth = probe.getBoundingClientRect().width;
      probe.remove();

      const rowHeight =
        Number.parseFloat(
          getComputedStyle(terminalElement).getPropertyValue(
            "--term-row-height",
          ),
        ) || 17;
      if (charWidth <= 0 || rowHeight <= 0) return null;

      return { grid, charWidth, rowHeight };
    }

    function measureTerminal(): { cols: number; rows: number } | null {
      const cell = measureCellSize();
      if (!cell) return null;
      const style = getComputedStyle(terminalElement);
      const verticalPadding =
        Number.parseFloat(style.paddingTop) +
        Number.parseFloat(style.paddingBottom);
      const availableHeight = Math.max(
        0,
        terminalElement.clientHeight - verticalPadding,
      );

      return {
        cols: Math.max(1, Math.floor(cell.grid.clientWidth / cell.charWidth)),
        rows: Math.max(1, Math.floor(availableHeight / cell.rowHeight)),
      };
    }

    function syncWriterSize(options: { force?: boolean } = {}): void {
      if (core.getRole() !== "writer") return;
      const size = measureTerminal();
      if (!size) return;
      const current = sizeRef.current;
      if (
        !options.force &&
        size.cols === current.lastSentCols &&
        size.rows === current.lastSentRows &&
        size.cols === core.getCols() &&
        size.rows === core.getRows()
      ) {
        return;
      }

      current.lastSentCols = size.cols;
      current.lastSentRows = size.rows;

      if (
        size.cols === current.renderedCols &&
        size.rows === current.renderedRows
      ) {
        if (options.force) core.forceResize();
        core.resize(size.cols, size.rows);
        return;
      }

      if (options.force) core.forceResize();
      current.renderedCols = size.cols;
      current.renderedRows = size.rows;
      terminal.resize(size.cols, size.rows);
    }

    function switchTerminal(terminalId: TerminalId): void {
      if (disposed) return;
      setCurrentTerminalId(terminalId);
      setConnectionState("connecting");
      core.connect(terminalUrl(terminalId));
    }

    function sendWheelInput(event: WheelEvent): void {
      if (core.getRole() !== "writer") return;
      if (event.deltaX === 0 && event.deltaY === 0) return;

      if (!core.wantsMouseInput()) {
        event.preventDefault();
        const rowHeight = measureCellSize()?.rowHeight ?? 17;
        const scrollRows = clamp(
          Math.ceil(Math.abs(event.deltaY) / rowHeight),
          1,
          8,
        );
        core.scrollViewport(scrollRows, event.deltaY < 0 ? "up" : "down");
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

    core.onUpdate = () => {
      const nextCols = core.getCols();
      const nextRows = core.getRows();
      const current = sizeRef.current;

      if (
        nextCols !== current.renderedCols ||
        nextRows !== current.renderedRows
      ) {
        current.renderedCols = nextCols;
        current.renderedRows = nextRows;
        terminal.resize(nextCols, nextRows);
      }

      terminal.write(new Uint8Array());
    };

    core.onRoleChange = (nextRole) => {
      setRole(nextRole);
      terminalElement.classList.toggle("is-reader", nextRole === "reader");
      terminalElement.classList.toggle("is-writer", nextRole === "writer");
      if (nextRole === "writer") {
        terminal.focus();
        requestAnimationFrame(() => syncWriterSize({ force: true }));
      }
    };

    core.onTerminals = (nextTerminals) => {
      const previousTerminals = terminalsRef.current;
      const next = new Map(
        nextTerminals.map((terminal) => [terminal.terminalId, terminal]),
      );
      const createdTerminal = pendingCreatedTerminalRef.current
        ? nextTerminals.find(
            (terminal) => !previousTerminals.has(terminal.terminalId),
          )
        : undefined;

      setTerminalMap(next);

      if (createdTerminal) {
        pendingCreatedTerminalRef.current = false;
        switchTerminal(createdTerminal.terminalId);
        return;
      }

      const currentTerminalId = activeTerminalIdRef.current;
      if (!next.has(currentTerminalId) && next.size > 0) {
        setCurrentTerminalId(next.keys().next().value ?? 0);
      }
    };

    core.onTerminalCreated = (createdTerminal) => {
      pendingCreatedTerminalRef.current = false;
      const next = new Map(terminalsRef.current).set(
        createdTerminal.terminalId,
        createdTerminal,
      );
      setTerminalMap(next);
      switchTerminal(createdTerminal.terminalId);
    };

    core.onTerminalClosed = (terminalId) => {
      const next = new Map(terminalsRef.current);
      next.delete(terminalId);
      setTerminalMap(next);
      if (terminalId === activeTerminalIdRef.current) {
        switchTerminal(next.keys().next().value ?? 0);
      }
    };

    cleanupCallbacks.push(core.on("open", () => setConnectionState("open")));
    cleanupCallbacks.push(core.on("close", () => setConnectionState("closed")));
    cleanupCallbacks.push(core.on("error", () => setConnectionState("error")));

    void terminal.init().then(() => {
      if (disposed) return;
      resizeObserver = new ResizeObserver(() => syncWriterSize());
      resizeObserver.observe(terminalElement);
      terminalElement.addEventListener("wheel", sendWheelInput, {
        passive: false,
      });
      switchTerminal(initialTerminalId);
    });

    return () => {
      disposed = true;
      terminalElement.removeEventListener("wheel", sendWheelInput);
      resizeObserver?.disconnect();
      cleanupCallbacks.forEach((cleanup) => cleanup());
      core.disconnect();
      terminal.destroy();
      if (coreRef.current === core) coreRef.current = null;
      if (terminalRef.current === terminal) terminalRef.current = null;
    };
  }, [baseUrlValue, cols, initialTerminalId, rows]);

  function handleSwitchTerminal(terminalId: TerminalId) {
    setCurrentTerminalId(terminalId);
    setConnectionState("connecting");
    coreRef.current?.connect(
      ghostdTerminalWebSocketUrl(resolveBaseUrl(baseUrlValue), terminalId),
    );
  }

  function handleCreateTerminal() {
    const core = coreRef.current;
    if (!core) return;
    pendingCreatedTerminalRef.current = true;
    core.createTerminal(core.getCols(), core.getRows());
  }

  return (
    <div className={["ghostd-react-shell", className].filter(Boolean).join(" ")}>
      <div className="ghostd-react-status-bar">
        <div
          id="tabs"
          aria-label="terminals"
          className="ghostd-react-tabs"
          role="tablist"
        >
          {sortedTerminals.map((terminal) => (
            <button
              aria-selected={terminal.terminalId === activeTerminalId}
              className="ghostd-react-tab terminal-tab"
              data-terminal-tab={terminal.terminalId}
              key={terminal.terminalId}
              onClick={() => handleSwitchTerminal(terminal.terminalId)}
              role="tab"
              type="button"
            >
              {terminalLabel(terminal)}
            </button>
          ))}
        </div>
        <button
          id="new-terminal"
          aria-label="new terminal"
          className="ghostd-react-button"
          onClick={handleCreateTerminal}
          type="button"
        >
          +
        </button>
        <span className="ghostd-react-role">
          role:{" "}
          <span id="status" className="ghostd-react-role-value">
            {role}
          </span>
        </span>
        <button
          id="claim-writer"
          className="ghostd-react-button"
          hidden={role !== "reader"}
          onClick={() => coreRef.current?.claimWriter()}
          type="button"
        >
          steal write
        </button>
        <span className="ghostd-react-spacer" />
        <span className="ghostd-react-connection">
          connection:{" "}
          <span
            className="ghostd-react-connection-value"
            data-state={connectionState}
          >
            {connectionState}
          </span>
        </span>
      </div>
      <div
        id="terminal"
        className={["ghostd-react-terminal", terminalClassName]
          .filter(Boolean)
          .join(" ")}
        ref={terminalElementRef}
      />
    </div>
  );
}
