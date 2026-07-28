import fs from "node:fs";
import path from "node:path";

/**
 * After build, inline the entry JS and CSS into index.html as inline
 * `<script>` and `<style>` blocks. This works around a Chromium CORS
 * restriction: Proton serves the page under `proton://app/`, which is
 * treated as an opaque origin. Cross-origin loads of `./assets/...`
 * are blocked (Access to ... from origin 'null'), so the JS/CSS never
 * reach the page.
 *
 * Inlining sidesteps the load entirely (no URL fetch) at the cost of
 * bloating the HTML by ~30 KB. That's fine for our app size.
 */
function inlineEntryAssetsPlugin() {
  return {
    name: "inline-entry-assets",
    apply: "build",
    enforce: "post",
    writeBundle(options) {
      const indexPath = path.join(options.dir, "index.html");
      let html = fs.readFileSync(indexPath, "utf8");
      // Inline the JS entry.
      html = html.replace(
        /<script\s+type="module"\s+crossorigin\s+src="\.\/assets\/([^"]+\.js)"><\/script>/,
        (_, jsName) => {
          const js = fs.readFileSync(path.join(options.dir, "assets", jsName), "utf8");
          return `<script type="module">\n${js}\n</script>`;
        },
      );
      // Inline the CSS entry.
      html = html.replace(
        /<link\s+rel="stylesheet"\s+crossorigin\s+href="\.\/assets\/([^"]+\.css)">/,
        (_, cssName) => {
          const css = fs.readFileSync(path.join(options.dir, "assets", cssName), "utf8");
          return `<style>${css}</style>`;
        },
      );
      fs.writeFileSync(indexPath, html);
      // Drop the now-unused asset files.
      fs.rmSync(path.join(options.dir, "assets"), { recursive: true, force: true });
    },
  };
}

export default {
  base: "./",
  build: {
    assetsInlineLimit: 65536,
  },
  plugins: [inlineEntryAssetsPlugin()],
};
