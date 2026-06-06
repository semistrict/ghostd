import { GhostdTerminalApp } from "@ghostd/react";
import { createRoot } from "react-dom/client";

const rootElement = document.getElementById("root");

if (!rootElement) {
  throw new Error("ghostd web root element not found");
}

createRoot(rootElement).render(<GhostdTerminalApp />);
