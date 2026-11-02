# Discovery implementation — 0.9.1

## Delivered

- Native Discover surface inside the existing AppKit library: responsive music cards, Radio/TV switch, source attribution, daily rotation, save/hide/play actions and accessible native controls.
- Deterministic history/favorites/interest ranking with diversified cold-start selection. Only existing successful-playback recents are used; no additional tracking.
- Independent strict recommendation safety policy. Conflicting sensitive metadata from any indexed source rejects an endpoint; unknown categories are withheld. Live broadcasts remain unverifiable from metadata alone.
- SQLite FTS5 index, bound queries, source-scoped records, conservative endpoint identity, persisted provenance and flags, cache migration, source invalidation, age/row/storage limits and corrupt-index recovery.
- Local-only search; explicit bounded directory refresh and per-source failures. First-page indexing is deliberate and labeled partial coverage. Ordinary browsing incrementally expands the index.
- Local M3U/PLS import preview and bounded app-managed copies. HLS manifests are not imported as catalogs. Imported copies can be managed in existing directory preferences.
- Optional Foundation Models structured query extraction using only SystemLanguageModel.default. No cloud routing or model tools. Five-second UI fallback and stale-result protection.
- Existing playback pipeline and macOS 13 deployment baseline retained; shared index/recommendation files included in iOS project configuration.

## Deliberate limits

The product specification includes later phases, not all of which ship here. This release does not implement generic JSON directories, EPG, embeddings, cross-device sync, whole-directory snapshot crawling, complete language/country natural-language interpretation, or the iOS Discover surface. Icecast YP remains retired.

Recommendations are music-focused. Most general TV/movie/news/talk listings are withheld rather than treated as safe from incomplete metadata. Existing TV browsing remains separate and retains user settings.

No automatic stream probing occurs: the existing URLSession transport does not guarantee destination binding against DNS rebinding. Deep HLS validation and rich per-endpoint playback observations remain follow-up work. Reachability is not described as proof of decodability. Temporary DNS, permission and server errors no longer cause two-strike permanent exclusion.

The index is capped at 100,000 rows and approximately 48 MiB database pages, leaving room for rollback journals and the existing 16 MiB page cache within the planned 128 MiB budget. It returns a bounded 5,000-candidate set for UI searches/recommendations, and never claims completeness. Favorites are outside the disposable index. No raw typed queries are persisted.

## Validation

See `.work/discovery-tests.log`, `.work/discovery-network.log`, `.work/discovery-ai.log`, and `.work/discovery-build.log` for local results. Wide and narrow UI captures use synthetic stations in a separate `.work/discover-preview` data directory, without modifying the user's real library. No public-station playback or rights clearance is implied by fixture tests.

The three-query on-device AI smoke test verifies actual guided generation for ambient, jazz and classical. It is not the specification's larger multilingual quality evaluation. A long playback soak, VoiceOver audit, all-OS runtime matrix, comprehensive security transport tests and full source-terms audit remain release gates before broad distribution.

## Recorded results (November 2, 2026)

- 276 deterministic checks passed, including 36 discovery/health additions.
- 31 local-server network checks passed, including zero-request local search, offline persistence and source-disable invalidation.
- 3 actual on-device AI genre smoke checks passed.
- 50,000 synthetic listings ingested in 0.83 seconds; 100 warm name queries had 1.79 ms p95; database size 28,590,080 bytes. This is an index microbenchmark, not end-to-end UI latency or an RSS measurement.
- Release build succeeded; bundle short version and build version are 0.9.1. FoundationModels is weak-linked, preserving the macOS 13 deployment baseline.
- Native screenshots inspected at 1000×700 and 480×600. Compact cards use one full-width column; wide cards use two.
