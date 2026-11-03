# Discovery implementation — 0.9.1

## Delivered

- Native Discover surface inside the existing AppKit library: responsive music cards, Radio/TV switch, source attribution, daily rotation, save/play actions, reversible local thumbs feedback, website links, memory-only station artwork and subtle quality stars and accessible native controls.
- Deterministic history/favorites/interest ranking with diversified cold-start selection. Only existing successful-playback recents are used; no additional tracking.
- Independent strict recommendation safety policy. Conflicting sensitive metadata from any indexed source rejects an endpoint; unknown categories are withheld. Live broadcasts remain unverifiable from metadata alone.
- SQLite FTS5 index, bound queries, source-scoped records, conservative endpoint identity, persisted provenance and flags, cache migration, source invalidation, age/row/storage limits and corrupt-index recovery.
- Local-only search; explicit bounded directory refresh and per-source failures. First-page indexing is deliberate and labeled partial coverage. Ordinary browsing incrementally expands the index.
- Local M3U/PLS import preview and bounded app-managed copies. HLS manifests are not imported as catalogs. Imported copies can be managed in existing directory preferences.
- Optional Foundation Models structured query extraction using only SystemLanguageModel.default. No cloud routing or model tools. Five-second UI fallback and stale-result protection.
- Existing playback pipeline and macOS 13 deployment baseline retained; shared index/recommendation files included in iOS project configuration.

## Deliberate limits

The product specification includes later phases, not all of which ship here. This release does not implement generic JSON directories, EPG, embeddings, cross-device sync, whole-directory snapshot crawling, complete country natural-language interpretation, or the iOS Discover surface. Icecast YP remains retired.

Recommendations are music-focused. Most general TV/movie/news/talk listings are withheld rather than treated as safe from incomplete metadata. Existing TV browsing remains separate and retains user settings.

General station-browser probing remains disabled. Discovery has a separate pinned transport for bounded local reachability checks. Deep HLS validation and decoder-based probing remain follow-up work. Reachability is not described as proof of decodability. Temporary DNS, permission and server errors no longer cause two-strike permanent exclusion.

The index is capped at 100,000 rows and approximately 48 MiB database pages, leaving room for rollback journals and the existing 16 MiB page cache within the planned 128 MiB budget. It returns a bounded 5,000-candidate set for UI searches/recommendations, and never claims completeness. Favorites are outside the disposable index. No raw typed queries are persisted.

## Validation

See `.work/discovery-polish-tests.log`, `.work/discovery-polish-network.log`, `.work/discovery-polish-ai.log`, and `.work/discovery-polish-release.log` for local results. Wide and narrow UI captures use synthetic stations in a separate `.work/discover-preview` data directory, without modifying the user's real library. No public-station playback or rights clearance is implied by fixture tests.

The on-device AI smoke checks cover genre and explicit broadcast-language interpretation. It is not the specification's larger multilingual quality evaluation. A long playback soak, VoiceOver audit, all-OS runtime matrix, comprehensive security transport tests and full source-terms audit remain release gates before broad distribution.

## Recorded results (November 2, 2026)

- 304 deterministic checks passed, including discovery metadata, language preferences, artwork limits and feedback retention.
- 31 local-server network checks passed, including zero-request local search, offline persistence and source-disable invalidation.
- 5 actual on-device AI smoke checks passed, including French deep house and Japanese jazz.
- 50,000 synthetic listings ingested in 0.83 seconds; 100 warm name queries had 1.79 ms p95; database size 28,590,080 bytes. This is an index microbenchmark, not end-to-end UI latency or an RSS measurement.
- Release build succeeded; bundle short version and build version are 0.9.1. FoundationModels is weak-linked, preserving the macOS 13 deployment baseline.
- Native screenshots inspected at 1000×700 and 480×600. Compact cards use one full-width column; wide cards use two.

## Discovery presentation refinement

Your mix groups 72 genres and 32 broadcast languages in a native preferences sheet. Language matching uses directory metadata, with an explicit choice to include unknown languages. Feedback is a bounded local preference map, not an event stream. Downvoted candidates remain eligible in a lower shelf; safety exclusions always apply first. Recommendation scoring remains separate from presentation and source metadata.

Only artwork URLs are persisted. Visible-card images use an ephemeral session and memory cache, with two concurrent loads, bounded response/image sizes, no cookies, no disk image cache and no redirects. Private destination screening is preliminary, not socket-bound DNS validation. Broken or absent artwork uses a waveform fallback. Artwork can be disabled.

Discover candidate eligibility requires `RadioListing.quality >= 4` before ranking or shelf selection, including mood curation. Unknown quality is excluded. History, favorites and thumbs feedback cannot override this floor. Quality is a codec/bitrate estimate, not a successful-playback measurement.

## Local availability checks

`DiscoveryAvailability.swift` stores up to 5,000 endpoint-keyed check records for seven days, separate from quality and the browser dead-station list. Positive evidence gets a decaying ranking bonus for one hour; checks are reused for 15 minutes. Three failed responses at least 120 seconds apart temporarily exclude a candidate for 30 minutes. Successful playback or checks clear failures immediately; offline, restricted, unsafe or unsupported destinations remain inconclusive. Clear saved discovery data removes these records too.

On macOS, the system curl transport uses an explicit public IPv4 resolution pinned with `--resolve`, preserves HTTPS hostname verification, disables proxy/config/cookie/credential use, and follows no automatic redirects. Each manually followed redirect/playlist URL must pass validation again, with at most three requests per check. At most two checks run concurrently, six recommendations per batch. Each transfer has a six-second deadline and a 48 KiB response cap; no stream bytes are written to disk. OS DNS resolution is separate from the transfer timeout. IPv6-only destinations, encrypted HLS, PLS and unsupported media responses remain unconfirmed. Basic unencrypted HLS checks require a playlist followed by segment bytes. A response is reachability evidence, not proof of decodability or uninterrupted playback.

Checks run while a curated library view is open, obey background resource policy, and can be disabled under Your mix → Listening & privacy. No new app-operated cloud service or telemetry is involved. The transport is macOS-only; shared iOS code can read evidence but does not launch checks. Tests cover retry/expiry/recovery/persistence/ranking, private redirect rejection and HLS traversal; local-server tests exercise pinned transport, byte limits, redirects and timeout. Logs: `.work/availability-tests.log`, `.work/availability-network.log`, `.work/availability-release.log`.

Availability verification: 384 deterministic checks and 35 local-server network checks passed. Release-mode build succeeded at `.work/AvailabilityQA.app`; the running `dist/RadioPocket.app` was left intact. These checks verify reachability behavior, not a long-running public-station playback soak.

Station cards use an explicitly inset content stack (12 points on every edge), with content-driven height instead of a fixed 384-point shell. Artwork is 64 points tall normally and 44 in narrow or short viewports; two-line titles use 16 or 14 points. Recommendation text remains scrollable in a 30-point area. Play, save, feedback, quality and availability remain available.

## Curation CPU profiling — November 2, 2026

The running release process was sampled without interrupting playback; observed CPU during inspection was about 2–8%, so the reported 100% spike was not captured. A deterministic release-optimized benchmark of 1,000 synthetic eligible stations reproduced expensive curation: Moods context plus fallback selection took 4.050 seconds and Discover selection took 3.596 seconds. After optimization, the same fixture took 0.155 seconds and 0.030 seconds respectively. These are single-run local wall-time measurements of curation, excluding network, AI and playback—not total app CPU percentages. Logs and harness are in `.work/cpu-profile/`; the process sample is `.work/cpu-before-sample.txt`.

Genre phrases and aliases now normalize once into a lookup table; sorting computes each candidate's score, genre set and rotation key once. Latest provenance selection uses a maximum instead of sorting each group. Fresh weather updates reuse existing genre counts. Native card layout avoids unchanged frame/constraint/style assignments and redundant redraw requests. Unrelated library setting notifications do not rerank curated feeds. Safety filters, language matching, quality floor and ranking inputs remain in effect. Validation: 385 deterministic checks, nine native loading/snapshot checks, and a successful release build at `.work/PerformanceQA.app`.

## Idle resource limits

Optional discovery checks and speculative mood AI require an active app and an unobscured library, and still obey Low Power Mode, thermal and connection-cost policy. The retry timer has a 30-second tolerance so the system can group wakeups. New curation requests cancel their predecessor; station/collection loops cooperate with cancellation. Closing or leaving the curated view releases its feed, card views and artwork requests. Closing the library clears the artwork cache.

Artwork cache budget is 16 thumbnails / 4 MiB (NSCache limits are advisory, and visible views retain their own images). Existing memory-pressure/idle housekeeping now clears this disposable cache and releases hidden discovery content. Under memory pressure it also drops tiny AI plan caches and cancels optional AI/check tasks. Ordinary idle cleanup retains small plans to avoid repeating inference. AI planning captures a genre summary rather than the catalog, and no longer builds a second unused feed after generation. These are resource-policy improvements, not a measured total-RSS guarantee. Validation: 385 deterministic checks and 11 native loading/lifetime checks.
