# Capability: pageAssets

- `list()` → `{ id, assets: [{ id, kind, name, url, sources }], inlineSvgs, summary }` for the
  page as it is now. Load lazy content first if it matters, then list again.
- `bundle({ inventoryId, kinds: ["image", "font", "stylesheet", "video"], assetIds })` →
  downloads them into a folder with a `manifest.json`. Use `kinds` for broad exports and
  `assetIds` for specific files. Scripts are skipped unless asked for by id.

Don't navigate to asset URLs to fetch them.
