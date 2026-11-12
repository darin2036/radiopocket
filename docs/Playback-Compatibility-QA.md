# Native playback and compatibility verification

November 12, 2026 — RadioPocket 0.12.0, macOS local build.

- Release build succeeded; bundle version verified as 0.12.0.
- `./test.sh`: 434 checks passed, including compatibility, playback evidence expiry/persistence, mirror selection and updated mood deduplication regressions.
- `./test-network.sh`: 37 checks passed, including compatibility cache isolation and reranking cached quality views with fresh playback evidence. Its compile inputs now include the existing UserAgent and StationArtwork dependencies.
- `./test-discovery-ui.sh`: 11 native loading/lifetime checks passed.
- Real decoder fixtures passed: explicit PLS and disguised playlist recovery from a broken first mirror; AAC/ICY pause, rewind and return to live; Opus; HLS; dropped connection recovery; stalled connection recovery. Visualizer output was verified where applicable. Mirror recovery was repeated against the final build after cancellation locking changed.
- Native UI inspection verified unpressed About buttons on first opening and after switching pages, 0.12.0 in About, and the General Preferences Compatibility Mode label, radio/TV description, toggle and saved preference.

The prior mood test failure reproduced at the starting revision: its assertions still required repeats across moods, contrary to the implemented cross-mood deduplication. Tests and Moods documentation now cover unique endpoints and station names, sparse catalogs and genre fit under reordered plans. The mood selector behavior was preserved.

QA used isolated data and bundles under `.work/`. The web repository was unchanged. This validation covers the macOS app and local media fixtures; physical iOS and live broadcaster availability were not verified.
