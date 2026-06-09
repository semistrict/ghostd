import type { TerminalId } from "./protocol.js";

export function ghostdWebSocketBaseUrl(baseUrl: string | URL): URL {
  const url = new URL(String(baseUrl), globalThis.location?.href);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url;
}

export function ghostdTerminalWebSocketUrl(
  baseUrl: string | URL,
  terminalId: TerminalId,
  clientId?: string,
): string {
  const base = ghostdWebSocketBaseUrl(baseUrl);
  const url = new URL(`terminal/${terminalId}.ws`, base);

  for (const [key, value] of base.searchParams) {
    if (!url.searchParams.has(key)) url.searchParams.set(key, value);
  }
  if (clientId) url.searchParams.set("client", clientId);

  return url.toString();
}

export function ghostdTerminalEventSourceUrl(
  baseUrl: string | URL,
  terminalId: TerminalId,
  clientId: string,
): string {
  const base = new URL(String(baseUrl), globalThis.location?.href);
  const url = new URL(`terminal/${terminalId}.events`, base);

  for (const [key, value] of base.searchParams) {
    if (!url.searchParams.has(key)) url.searchParams.set(key, value);
  }
  url.searchParams.set("client", String(clientId));

  return url.toString();
}

export function ghostdTerminalInputUrl(
  baseUrl: string | URL,
  terminalId: TerminalId,
  clientId: string,
): string {
  const base = new URL(String(baseUrl), globalThis.location?.href);
  const url = new URL(`terminal/${terminalId}.input`, base);

  for (const [key, value] of base.searchParams) {
    if (!url.searchParams.has(key)) url.searchParams.set(key, value);
  }
  url.searchParams.set("client", String(clientId));

  return url.toString();
}
