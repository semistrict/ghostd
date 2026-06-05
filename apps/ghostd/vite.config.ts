import { defineConfig } from "vite";

export default defineConfig({
  server: {
    allowedHosts: ["ghostd.wterm.localhost"],
  },
});
