import type { TerminalId } from "./protocol.js";

export function ghostdWebSocketBaseUrl(baseUrl: string | URL): URL {
  const url = new URL(String(baseUrl), globalThis.location?.href);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url;
}

export function ghostdTerminalWebSocketUrl(
  baseUrl: string | URL,
  terminalId: TerminalId,
): string {
  return new URL(`terminal/${terminalId}.ws`, ghostdWebSocketBaseUrl(baseUrl)).toString();
}
