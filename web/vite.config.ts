import { defineConfig } from "vite";

export default defineConfig({
  root: "web",
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
  server: {
    allowedHosts: ["ghostd-web.localhost"],
  },
});
