import { defineConfig } from "vite";

// ビルド結果は .app の Resources/editor にそのまま入る（project.yml のフォルダ参照）。
// アプリは独自の URL スキームで読むので、パスは相対にしておく。
export default defineConfig({
  base: "./",
  build: {
    outDir: "dist/editor",
    emptyOutDir: true,
    chunkSizeWarningLimit: 8000,
  },
  worker: { format: "es" },
});
