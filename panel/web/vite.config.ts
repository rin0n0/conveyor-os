import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "../webdist",
    emptyOutDir: true,
    target: "esnext",
  },
  server: {
    proxy: {
      "/api": "http://127.0.0.1:7070",
    },
  },
});
