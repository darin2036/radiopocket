# Radio Pocket: Local-First Discovery Engine

Version: 1.0 — November 2, 2026  
Status: implementation-ready product proposal; no application code changed  
Target: existing RadioPocket macOS app; shared core remains usable by its iOS app

## 1. Outcome and boundaries

Help listeners find independent radio and internet TV across sources they choose, including obscure stations that popularity-based lists overlook. Evolve the existing player rather than build a replacement.

**Required invariants**

- Zero app-operated cloud services: no backend, account server, proxy, hosted index, telemetry collector, remote recommendation service, or cloud inference.
- Discovery works without AI. Cached metadata search works without internet; live streams and directory refreshes still require connectivity.
- Third-party directories and broadcasters remain network dependencies. “Local-first” does not mean anonymous, entirely offline, or independent of all servers.
- All indexing, ranking, preferences, favorites, and optional inference run locally. No inference fallback to Private Cloud Compute or another provider.
- Keep the existing playback pipeline, compact classic player, supported codecs, and macOS 13 baseline. Optional AI must not raise the minimum OS for the app.
- No recording, rebroadcasting, DRM bypass, paywall bypass, unauthorized stream extraction, or bundled mass TV catalog.
- Icecast directory discovery stays retired and disabled. The owner reports inconsistent results. Do not restore it in the MVP. Icecast-hosted streams obtained through other directories or user sources remain eligible for ordinary validation and playback.

Success means a user can add a source, search its indexed stations alongside other enabled sources, understand why a result appears, and tune in without an app service or AI dependency.

## 2. Verified application baseline

Inspected repository: `/Users/darinlaframboise/Development/radiopocket`. Findings are from source and documentation, not a fresh playback test or audit of every provider.

| Existing component | Present behavior | Implementation direction |
|---|---|---|
| `Package.swift` | Swift tools 5.9, macOS 13; executable plus C EQ/Vorbis targets | Preserve deployment baseline; use system libraries where possible |
| `Directory.swift` | `RadioListing`, `DirectoryQuery`, `DirectoryPage`, `RadioBrowserDirectory`, `RadioDirectory` actor | Adapt existing federation into local indexing; retain provider pagination |
| `DirectorySources.swift` | `DirectorySource`, `DirectoryBackend`, built-in and custom adapters | Extend source capabilities and provenance; do not replace all adapters |
| `StationCache.swift` | Versioned JSON browse-page cache; 300 files/16 MiB; typed queries not persisted | Retain during staged migration; index returned records without storing query text |
| `StationSearch.swift` | Case/diacritic folding, all-word matching and prefix ranking | Reuse normalization; preserve Jump to Station behavior |
| `StationHealth.swift` | Header probes and persistent dead-station suppression | Add evidence levels; separate transport failure from codec incompatibility |
| `Library.swift` | Favorites and successful-playback recents | Preserve IDs and files; do not replace with index records |
| `DiscoveryView.swift` | AppKit library with genre navigation, filters and paging | Add local search, source status and optional AI within this window |
| `RadioEngine.swift`, `StreamSources.swift` | Native decoding, HLS support and AVPlayer fallback | Receive existing `Station` values; discovery stays off audio threads |
| `DirectorySources.swift`, `VideoWindow.swift` | 40media and user TV lists; radio/TV classification and TV safety filters | Extend TV metadata search without replacing video playback |
| `Tests/main.swift`, `Tests/DirectoryNetwork.swift`, `test.sh` | Existing test harness and separate network tests | Add deterministic fixtures to existing workflow |

Current radio sources include Radio Browser, SomaFM, laut.fm, Radio Paradise, Curated Internet Radio Streams, IPRD, Junguler and rrradio. Larger catalogs are opt-in. macOS defaults also include 40media TV. Custom Radio Browser servers and hosted radio/TV playlists already exist; the current custom-source cap is eight. Preserve saved choices and deletion tombstones.

The `.icecast` enum case exists only for decoding older settings; it has no active backend. This is intentional product behavior.

Existing documentation describes click reporting to Radio Browser on explicit directory tuning, background cached-page refreshes, no artwork downloads, and local history capped at 30 unique successful stations. Preserve these facts in migration messaging. A local-first redesign must not silently claim these current requests do not exist.

Documentation and code differ on some cache timings. Use tested source behavior as the migration baseline, and reconcile `README.md` and `Resources/DIRECTORY-SOURCES.md` when implementation changes land.

## 3. User experience

### Primary flows

1. **Find a station:** Open LIB, type a name, genre or language. Show indexed matches immediately, with source labels and filters. A visible “Search enabled directories” action expands coverage online; do not transmit each keystroke by default.
2. **Bring a collection:** Preferences → Directories → Add accepts a hosted M3U/PLS, Radio Browser-compatible endpoint, or a local playlist file. Show a bounded import preview, source label, valid/rejected counts and duplicate count before saving. Adding a source authorizes fetching that source, not scanning the surrounding web.
3. **Explore:** Choose “Explore independent streams” for a diversified local result set, constrained by selected genres, language, country and media type. Describe it as exploration of indexed sources, not proof of independence or a complete internet census.
4. **Use natural language, optionally:** “French ambient radio, preferably high quality” becomes editable filter chips. Results appear through normal search even if AI is unavailable or times out. Ambiguous words remain text terms rather than invented hard filters.
5. **Inspect a result:** Show provenance, published metadata, local observations with timestamps, playback support, homepage, and reason for recommendation. Label AI-inferred tags separately.
6. **Tune in:** Use existing playback entry points. A probe failure does not permanently block an explicit play attempt. TV stays visibly separate from radio and respects existing safety preferences.

### States and controls

- Empty index: offer existing directories and source import; do not present a blank search as “no stations exist.”
- Offline: “Searching saved listings; live playback needs a connection.” Show index timestamp and source coverage.
- Partial failure: keep results from healthy sources and provide per-source retry. Never interrupt playing audio.
- Unknown fields: offer “Include stations with unknown metadata”; never interpret missing bitrate as zero-quality or missing country as the user's country.
- AI state: Off / Available / Unavailable with reason / Working. No upgrade or Apple Intelligence setup requirement to use discovery.
- Keyboard navigation, VoiceOver labels, selection stability and existing player shortcuts remain functional. No autoplay on search, focus, import or AI output.
- Add pause refresh, clear discovery data, reset recommendations, and per-source enable/remove controls in existing Preferences. Avoid a separate configuration dashboard.

## 4. Source federation and coverage

Federation is client-side fan-out to independent endpoints plus a local index. It is not peer-to-peer gossip, a new server protocol, or a promise of global sort order over remote catalogs.

| Source class | Scope | Policy |
|---|---|---|
| Existing Radio Browser adapter | Public radio search, stable source IDs | Keep mirror discovery/failover and documented API behavior |
| Existing broadcaster adapters | Published broadcaster catalogs/links | Preserve each provider's metadata and attribution |
| Existing opt-in full catalogs | Radio playlist collections | Preserve caps and opt-in status; index only approved fetched records |
| User hosted M3U/PLS | Radio and TV | Bounded parsing, conditional refresh, source-scoped permissions |
| User local M3U/PLS | Radio and TV | Copy parsed metadata; persistent file access only if explicit reimport/watch is enabled |
| User Radio Browser API | Compatible directory | No credentials bundled; restrict to configured endpoint |
| Generic JSON directory | Phase 2 | Versioned declarative schema; no downloaded executable plugins |
| Icecast YP | Deferred experiment only | Disabled; no automatic retry/reintroduction in release defaults |

Radio Browser documents mirror discovery and stable UUIDs; do not persist server-local numeric station IDs. Use descriptive User-Agent headers and avoid dependence on one mirror. [Radio Browser API](https://api.radio-browser.info/), [request reference](https://docs.radio-browser.info/).

Each source declares `supportsSearch`, `supportsPaging`, `supportsSnapshot`, `mediaTypes`, response/entry limits, refresh interval, attribution, terms URL and coverage status. Coverage is `partial`, `snapshotComplete`, or `unknown`, with fetched time. A paginated search result is always partial unless the entire advertised snapshot has been successfully imported.

Incremental indexing of fetched pages is MVP. Full-catalog indexing requires a user-enabled source and an explicit bounded snapshot operation; never enumerate all remote search pages just to fill the database.

Remote results retain per-source cursors. Continue a source's cursor even when local filtering empties a page. Merge by identity, not shared page offsets. Search sessions carry a generation ID; late responses cannot replace a newer query. Sort the indexed candidate set locally and label provider-only ordering as partial.

## 5. Architecture and internal APIs

```text
Existing AppKit discovery UI / iOS browser
                 |
          DiscoveryCoordinator
          /        |          
 Local search   Source sync   Optional LocalAIInterpreter
      |             |              | local typed query only
 SQLite index   Existing adapters  |
      |             |              |
 Provenance + normalization <------+
      |
 Existing Station / Library / RadioEngine
      |
 Direct broadcaster connection
```

Use Swift actors for the index writer, refresh scheduling and AI session ownership. UI updates stay on the main actor. Network, parsing, database work and inference must never enter audio rendering callbacks.

Suggested new files: `DiscoveryCoordinator.swift`, `DiscoveryIndex.swift`, `DiscoveryModels.swift`, `DiscoverySync.swift`, `DiscoveryRanking.swift`, `DiscoveryNetworkPolicy.swift`, `LocalDiscoveryAI.swift`. Keep system SQLite integration small and isolated; adding a package dependency requires a documented benefit against the project's current dependency-free approach.

The following is an **interface contract**, not drop-in compiling code. Supporting DTOs must be implemented and bridged to existing types.

```swift
protocol DiscoveryIndex: Sendable {
    func ingest(_ batch: SourceBatch) async throws -> IngestReport
    func search(_ query: SearchSpec, cursor: LocalCursor?) async throws -> SearchPage
    func removeSource(_ sourceID: String) async throws
}

protocol LocalQueryInterpreter: Sendable {
    func availability() async -> AIAvailability
    func interpret(_ text: String, vocabulary: SearchVocabulary) async throws -> SearchIntent
}

// Public facade consumed by existing controllers.
// SearchPolicy: localOnly | localThenRemoteExplicit
// Every event identifies the query generation and source.
protocol DiscoveryService: Sendable {
    func search(_ query: SearchSpec, policy: SearchPolicy)
        -> AsyncThrowingStream<SearchEvent, Error>
    func refresh(sourceID: String, reason: RefreshReason) async throws -> SyncReport
    func validate(endpointID: String, mode: ProbeMode) async -> HealthObservation
}
```

`SearchSpec`: free text, media type, genres, languages, country, codecs, minimum bitrate, unknown-field policy, enabled source IDs, sort and limit. Cap UI query text at 500 characters; use bound SQL parameters and escape FTS operators.

`SearchPage`: stable local IDs, opaque snapshot cursor, total indexed match count where available, coverage, warnings, per-source state and timestamp. Cap a page at 100 rows. Cursor includes query fingerprint and index generation; invalidate explicitly on incompatible changes.

`SearchIntent`: original query, literal terms, proposed filters, soft preferences and unresolved terms. No URL, source installation, playback or filesystem instructions.

Errors distinguish cancellation, offline, unauthorized, rate-limited, too-large, invalid-format, incompatible-schema and storage failure. They carry safe display text; raw URL credentials and response bodies must not appear in diagnostics.

No local HTTP daemon or external control API is required. Existing `radiopocket://` handling remains the playback handoff.

## 6. Data model, indexing and migration

Use a versioned SQLite database with FTS5, transactions, foreign keys and a single writer. Verify FTS5 availability in the actual build configuration before selecting this implementation; do not assume SwiftPM already links SQLite.

| Table | Important fields |
|---|---|
| `sources` | id, kind, enabled, endpoint reference, policy, coverage, last success, ETag, Last-Modified |
| `listings` | internal ID, source ID, source-native ID, station ID, raw/published metadata, fetched time, revision |
| `stations` | local UUID, display name, media type, normalized fields, user overrides |
| `endpoints` | ID, station ID, exact URL, conservative identity key, declared codec/bitrate, credential reference |
| `listing_endpoints` | listing ID, endpoint ID; provenance survives deduplication |
| `observations` | endpoint ID, transport status, content evidence, decoder result, checked time, expiry |
| `inferences` | station ID, tag, model/build identifier, input hash, generated time, evidence IDs |
| `preferences` | explicit likes/dislikes and optional local affinity summaries |
| `station_fts` | indexed name, tags, language, country, description; linked to stable station ID |

Favorites remain durable in `Library`; the index is rebuildable. Existing recents remain capped as today. Recommendation history is off by default; explicit favorites and selected filters are enough for MVP recommendations.

Normalization:

- Preserve original display strings; reuse `StationSearch.fold` for matching. Normalize known language/country codes; keep unknown values null.
- Identity is `(sourceID, nativeID)` where available. Across sources, merge exact/conservatively normalized endpoints while retaining all listings.
- Lowercase URL scheme/host and remove default ports; preserve path case, query strings, signed parameters, trailing slash and HTTP-versus-HTTPS distinction. Do not strip arbitrary tracking-looking parameters.
- Names alone never auto-merge. Multiple endpoints can belong to a station only with source evidence or explicit user action. Do not assume shared CDN hosts imply station identity.
- User overrides outrank published display fields. Recent local codec observations may outrank declared technical fields; keep both visible. Conflicting editorial tags remain source-attributed.
- HLS rendition URLs are playback variants, not separate stations. An M3U8 containing `#EXT-X-` tags is a stream manifest, not a catalog of channels.

Ranking without AI: apply hard filters, then lexical relevance, explicit preferences, endpoint support and recent successful playback evidence. Diversity reranking limits repeated broadcasters and near-duplicates. Use a deterministic daily local seed for exploration. Popularity is an optional small, source-normalized signal; do not compare raw votes/clicks across unrelated directories. Expose factual explanations such as “Matches ambient; not in favorites; played successfully yesterday.” No fabricated audience counts or “independent” certification.

Initial index budget: 100,000 listings, 128 MiB total discovery storage including database/WAL and old page cache, 30-day eviction for unpinned stale metadata. These are engineering targets, not measured current performance. Stop ingestion with a visible partial-coverage warning before caps; evict old unpinned entries first. Favorites and source configuration survive eviction.

Migration is additive: create index, import valid existing page-cache records, retain original IDs and user settings, then index new adapter results. Do not infer a complete catalog from cached pages. Use an atomic schema transaction and a migration marker; interruption can safely restart. On corruption, quarantine the index and rebuild while keeping favorites usable. Legacy dead-station records become low-confidence historical observations, not permanent exclusions. Rollback can disable the index and use the existing directory flow.

## 7. Refresh and resource policy

- Preserve existing background policy checks for offline, expensive/constrained network, low power and thermal pressure. Background indexing is opt-out; source addition does not override system conditions.
- Default source refresh floor: six hours, adjusted upward for provider terms and Retry-After. User refresh bypasses local freshness only, never server rate limits.
- Use conditional requests where supported; commit complete parsed batches transactionally. Only a successfully completed snapshot may mark missing listings withdrawn; partial pages and failed refreshes cannot delete unseen records.
- Start with two directory requests globally, one per host, and at least 1.5 seconds between background requests to a host. Exponential backoff with jitter; halt a source after repeated failures and show its status.
- Preserve current adapter-specific limits: do not replace existing large-feed limits with a single small universal cap. Enforce both compressed and expanded byte limits and entry limits.
- No automatic catalog-wide stream checks, artwork fetching or media previews. Cancel obsolete interactive work; background tasks yield to playback and active UI.
- Source disable excludes its listings from discovery immediately. Remove deletes its cached/indexed provenance; favorites remain explicitly user-owned with a “source removed” label. Recompute merged station fields from remaining enabled provenance.

## 8. Stream validation and network safety

Current `StreamProbe` treats many non-HTML 2xx responses as alive and can suppress doubtful endpoints after two strikes. This does not prove decodability. Replace this binary interpretation gradually with separate transport, content and playback evidence.

States: untested, reachable, recognized-media, playback-confirmed, temporarily-failing, authentication-required, restricted, unsupported, withdrawn. Every state has a timestamp and scope. A directory's reported health is separate from an on-device observation.

Validation ladder:

1. Parse and enforce URL policy, without network access.
2. If explicitly requested or permitted for visible results, bounded HTTP GET; HEAD is an optional hint, never a requirement. Stop after headers/small body.
3. Recognize bounded M3U/PLS/HLS or media signatures. Follow playlists to depth 3 and redirects to 5, with cycle detection and the same destination policy at every hop.
4. Optional explicit deep check reads one bounded media segment or sample. Actual playback success is the strongest local evidence; never play audible previews during validation.

Probe defaults: two concurrent checks, one per host, eight-second total timeout, 64 KiB ordinary sniff limit, 256 KiB playlist limit; explicit HLS deep check at most 2 MiB and 12 seconds. Mark oversized samples inconclusive rather than dead. Stream bodies incrementally so cancellation stops reception even if a server ignores Range.

HTTP 401/403 means restricted/authentication may be required, not permanently dead. 429 obeys Retry-After. Timeouts, DNS failures and 5xx are temporary; local offline errors do not penalize a station. 404/410 are endpoint observations, with retry available. Unsupported codecs remain discoverable with a compatibility label. Successful playback resets failure evidence. Start with 72-hour positive evidence and a 12-hour retry interval for transient failures; no silent 14-day hiding based on two generic failures in the new model.

Network trust boundary:

- Accept HTTP(S) streams; HTTPS preferred. Legacy HTTP gets a visible insecure-transport label and no secret headers. Never disable certificate validation globally.
- Remote directories cannot trigger requests to loopback, link-local, private, multicast, unspecified or reserved destinations. Check IPv4/IPv6, mapped addresses, DNS answers, redirects and nested manifests; hostname-string checks alone are insufficient.
- Prevent DNS rebinding by validating the actual connected destination through an appropriate transport policy. If the chosen stack cannot guarantee this, disable automatic probing for that path and require explicit user playback. Record this limitation instead of claiming protection from a preliminary lookup.
- Explicitly added LAN sources may receive a scoped local-network exception. Do not apply that exception to arbitrary public-directory results.
- Never forward authorization across hosts. Secrets belong in Keychain; redact userinfo and query secrets in logs/exports. MVP needs no OAuth, cookie login or paid IPTV authentication flows.
- Disable XML external entities/DTDs for future XML feeds; bound nesting, line length and decoded text. Never execute playlist directives, JavaScript, shell commands or downloaded adapter code.
- Apply destination checks to logos, homepages and TV segment/key URLs if those features fetch them. AVPlayer-managed requests need a separate feasibility review; do not promise full per-request interception without proving it.

## 9. Optional on-device Apple Foundation Models

AFM here means **Apple's on-device system language model**, accessed through the Foundation Models framework. Framework availability alone does not establish that an operation is local: Apple's current framework also describes server model options. This product must explicitly bind only the on-device model and never choose cloud routing. [Apple framework overview](https://developer.apple.com/foundation-models-framework/).

Apple documents availability checks using `SystemLanguageModel.default`, guided structured generation and tool calling. Use runtime availability rather than hardware-name guesses. Eligible hardware, supported OS/region, Apple Intelligence enablement and model readiness can affect availability. Keep a compile guard and OS availability guard around the optional module. Validate exact symbols and deployment requirements against the installed SDK before implementation. [Apple generation and availability guidance](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models).

| Task | With optional AFM | Without AI |
|---|---|---|
| Natural-language query | Produce a constrained `SearchIntent` | Literal keyword search, synonym dictionary and editable filters |
| Metadata cleanup | Suggest bounded genre/language tags from supplied text | Normalize published tags with versioned mappings |
| Similar stations | Interpret soft preferences within retrieved candidates | Tag overlap, favorite affinity and diversity ranking |
| Result explanation | Short grounded wording using supplied evidence | Deterministic explanation templates |
| Find new URLs | Not an AFM responsibility | Enabled source adapters/imports |
| Stream health/legal status | Never infer as fact | Network/playback evidence and source/legal review |

AFM is not a crawler, authoritative station database, guaranteed multilingual translator, codec detector, audio classifier or rights-verification service. Do not assume the framework exposes a general embedding API. MVP uses no vector database, model training, adapters or audio transcription.

Implementation sequence: show deterministic results immediately; request optional structured intent; validate returned fields against known enums/vocabulary; show interpreted chips; rerun normal local retrieval. For explanations, send only the selected candidate metadata and evidence. Do not send entire catalogs or raw playlist bodies. Keep the AI contribution optional and reversible.

Use a fresh bounded session per interaction, at most 12 short candidate summaries, and an input/output budget below the deployed model's supported context. Apple documents a 4,096-token context for the system model in its generation guidance; treat that as a conservative baseline, not a promise across future models. Catch context overflow and retry once with fewer candidates, then fall back. Use a five-second interactive deadline; late results cannot mutate an obsolete search. Cancel when the window closes or query changes.

No tools are needed for MVP interpretation. If later tools are added, permit only bounded local `searchIndex` and `lookupStation` with validated arguments. No network-fetch, add-source, playback, file-write or shell tool. Treat all directory text as untrusted data, including text that asks the model to ignore its instructions. Reject invented IDs and URLs regardless of guided generation.

Suggested capability facade: `unavailableOS`, `unavailableDevice`, `disabled`, `modelNotReady`, `unsupportedLanguage`, `available`, `temporarilyUnavailable`. Map actual SDK cases into these app-owned states. Turning AI off stops generation and clears transient prompts; generated annotations can be cleared independently. Invalidate stored inferences when input metadata or model configuration changes.

Model assets are managed by the OS and may require prior download. The app must work before that download and must not present optional OS provisioning as an app-operated service. Core privacy acceptance tests must prove that inference itself does not invoke remote models.

## 10. Privacy, licensing and DMCA

### Data and request inventory

| Data/action | Location or recipient | Default |
|---|---|---|
| Favorites/source configuration | Local application storage | Persist |
| Cached metadata/index/health | Local cache storage | Bounded and clearable |
| Typed query | Memory/local index; source only on explicit online expansion | Do not persist query strings |
| AI prompt/output | On-device model/session; optional local annotations | AI off until enabled |
| Playback | Broadcaster/CDN receives IP and normal request details | Only on user action |
| Source refresh | Enabled directory sees IP and requested endpoint/query | Disclosed and controllable |
| Radio Browser click reporting | Directory receives station click | New preference, off for new installs; make upgrade change explicit |
| Personalization history | Local only | Off; favorites remain usable |
| Diagnostics | Local redacted logs | No automatic upload |

Review the directory's current reporting requirements before suppressing click calls; if a provider requires incompatible tracking, disclose it and disable that integration rather than secretly report. Never report clicks from probes or AI recommendations.

“Clear discovery data” removes database, WAL, old page cache, health evidence and AI annotations. Favorites/source settings require separate explicit deletion. Explain that local data may be included in OS backups; do not claim deletion from historical backups. User exports omit credentials and listening history unless explicitly selected.

### Rights and attribution

The product is a player and discovery client. Public accessibility, a working URL, user submission or a directory license does not establish permission to redistribute a broadcast. The app does not certify legality of a channel.

Radio Browser identifies its data as public domain and its server software separately as GPL; consuming an API is distinct from incorporating its server code. [Radio Browser](https://www.radio-browser.info/). Preserve notices already in `Resources/DIRECTORY-SOURCES.md` and `Resources/THIRD-PARTY.md`. Maintain a source review record covering metadata license, API terms, attribution, caching/redistribution rules, logo rights and review date. Unknown rights do not become permissive because an adapter exists.

For TV, prefer broadcaster-published feeds and user-provided lists. Do not bundle unreviewed IPTV collections, bypass geo-restrictions, harvest signed URLs from protected pages, or claim keyword safety filters establish rights clearance. Existing TV adult/unreliable filters remain user controls, not legal judgments. No EPG ingestion or program artwork in MVP; those introduce additional metadata rights and refresh costs.

A “Report source concern” action prepares a local support draft containing only the selected listing/provenance; the user chooses whether to send it. Product maintainers review complaints about bundled sources and can remove/update those sources through ordinary releases. No central kill-switch or mandatory app service is introduced. Older installed/offline versions may retain cached entries until refresh, expiry or user deletion; disclose this operational limitation.

DMCA safe harbor is conditional and fact-specific; being a player or linking rather than hosting does not automatically confer protection. Section 512 includes information-location tools. Obtain counsel's assessment of applicable obligations before public distribution, including notice handling and designated-agent requirements if applicable, and equivalent non-US obligations. Do not invent a compliance guarantee. [U.S. Copyright Office Section 512 resources](https://copyright.gov/512/).

## 11. Delivery milestones

Estimates assume one engineer familiar with this codebase and exclude external legal review. Gates matter more than dates.

| Phase | Estimate | Deliverable and exit gate |
|---|---|---|
| M0 — Baseline and contracts | 2–3 days | Record playback/search fixtures, current source settings and network inventory; confirm SQLite/SDK integration and migration model |
| M1 — Local index MVP | 5–7 days | Incremental ingest from existing adapters/cache, local FTS/filtering, provenance, source enable/remove, migration and recovery; existing favorites/playback regressions pass |
| M2 — Federation and validation MVP | 4–6 days | Explicit online expansion, bounded import of local/hosted playlists, per-source cursors/status, safe probes, partial results; all network/privacy gates pass |
| M3 — Discovery UX and release | 3–5 days | Diversified exploration, explanations, unknown-field controls, storage controls, documentation; non-AI product ships on macOS 13 |
| M4 — Optional AFM | 3–5 days | Runtime-gated structured intent, local-only inference, timeout/refusal/context fallbacks, quality evaluation; no minimum-OS increase |
| Later | Separate estimates | Generic JSON sources, iOS UI parity, optional source-specific EPG, richer local recommendations |

Icecast YP is not a committed milestone. Reconsider only after an explicit product decision and a separate reliability experiment demonstrates useful, reproducible results, acceptable load and clear directory access terms. Icecast's documentation identifies its YP directory, but does not establish current feed reliability or a reuse license. [Icecast YP documentation](https://www.icecast.org/docs/icecast-latest/yp/).

## 12. Acceptance criteria and test plan

Use fixture directories and a controlled local HTTP test server by default. Public endpoint checks are opt-in smoke tests, never mandatory deterministic CI dependencies. Test-only permission to connect to loopback must not leak into production policy.

| ID | Required evidence |
|---|---|
| A01 | With AI unavailable/off, a user imports a source, searches, filters, explores, saves a favorite and tunes through the existing engine |
| A02 | With outbound traffic blocked, previously indexed metadata/favorites remain searchable; no false promise of offline live playback |
| A03 | Network capture shows no app-owned service or remote inference call; local-only typing produces no directory requests |
| A04 | For a 50,000-listing fixture on a recorded Apple Silicon test Mac, warm search p95 ≤150 ms and first cached list ≤300 ms over 100 queries; measure separately from remote latency |
| A05 | Import 50,000 fixtures with peak additional discovery RSS ≤100 MiB and total discovery disk ≤128 MiB; interrupted/capped import leaves a valid index and partial status |
| A06 | Duplicate endpoint listings merge without losing sources; same-name/different-endpoint stations remain separate; signed query strings and stable favorites IDs survive migration |
| A07 | A failed/empty filtered provider page does not terminate other sources or erase unseen records; cancellation prevents stale results replacing new queries |
| A08 | Source disable removes its recommendations immediately; removal preserves favorites and removes that source's indexed provenance |
| A09 | Redirect loops, oversized/chunked bodies, malformed playlists, decompression bombs and recursive catalogs terminate within limits |
| A10 | IPv4/IPv6 local destinations, public-to-private redirects and DNS rebinding fixtures cannot trigger automatic private-network probes; explicit LAN permission is narrowly scoped |
| A11 | 403, 429, offline, unsupported codecs and transient DNS failure produce distinct appropriate status; no generic two-strike permanent hiding |
| A12 | HLS manifests remain one stream, with renditions resolved by playback; actual video/audio evidence overrides uncertain catalog labels without losing provenance |
| A13 | AI returning invented IDs, URLs, malformed fields or prompt-injection instructions cannot install sources, fetch URLs or start playback |
| A14 | AI unavailable, unsupported language, refusal, timeout and context exhaustion all leave deterministic search usable; older OS launches without Foundation Models linkage failure |
| A15 | At least 60 fixed query examples cover names, countries, genres, languages and ambiguity; AFM produces valid schema in 100% of accepted outputs and correct intended filters on ≥90% of unambiguous cases; reject/fallback otherwise |
| A16 | Clear-data removes all discovery stores and inference artifacts; logs/export contain no credentials or raw private query history |
| A17 | Existing MP3/AAC/Opus/Vorbis/HLS and TV regression cases remain functional; browsing/indexing causes no audible interruption in a 30-minute playback workload |
| A18 | Keyboard/VoiceOver workflows remain usable; switching radio/TV and existing safety preferences filter both cached and live results |
| A19 | Legacy disabled/removed source choices persist, `.icecast` stays retired, and no newly enabled source appears because of migration |
| A20 | Each built-in adapter has documented access terms/attribution and explicit request/entry limits before release |

Run the repository's existing `./test.sh`, relevant deterministic additions, and `./build.sh` in implementation phases. Because `test.sh` enumerates source files explicitly, update its file list when adding tested components. Verify optional AI compilation with a compatible SDK and runtime behavior on both an eligible device and a non-AI environment. No app tests were run for this document-only deliverable.

## 13. Risks and decisions for coding agents

| Risk | Response |
|---|---|
| Directory instability or retirement | Isolate adapters; cached search survives; expose partial coverage; no dependency on Icecast YP |
| Provider terms or data license change | Versioned source review records; disable/remove affected adapters through updates |
| Index grows beyond lightweight app goals | Incremental coverage, hard caps and measurable memory/disk gates; do not import whole internet catalogs by default |
| Network validation differs from playback stack | Separate observation confidence; explicitly review AVPlayer and redirect paths before claiming protections |
| Poor metadata hides lesser-known stations | Unknown-field option, provenance and diversity; no mandatory popularity threshold |
| AFM hallucination or poor language support | Schema validation, limited context, evidence-only explanation, deterministic fallback |
| Legacy migration loses user data | Additive index, stable library IDs, restartable transaction, rollback |
| CDN/stream restrictions change | Treat health as local time-stamped evidence, not universal availability |
| Copyright complaints without a central backend | Reviewed bundled sources, documented support process and release updates; acknowledge offline-version limitations |

Coding-agent execution order: baseline fixtures → data contracts → SQLite proof → incremental ingest → local query/ranking → source state/cursors → import/security → UX → optional AFM. Keep each stage independently buildable. Do not rewrite audio DSP, switch to a web UI, add a hosted service, re-enable Icecast, or raise the deployment target to implement discovery.

Before implementation, resolve only these technical choices from the project itself: exact SQLite linkage in `build.sh` and SwiftPM; installed Xcode SDK/AFM availability; existing iOS shared-file inclusion; and which network layer can enforce destination policy. The product defaults above stand unless the owner changes them.

## 14. Source and verification notes

External documentation checked November 2, 2026. Repository observations are listed in section 2. Proposed performance budgets, milestones, schemas and feature policies are design decisions, not claims about already implemented behavior.

- [Apple Foundation Models framework](https://developer.apple.com/foundation-models-framework/) — on-device and server options; explicitly choose on-device only.
- [Apple generation, availability and context guidance](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models) — runtime availability, guided generation, tools and bounded sessions.
- [Apple HTTP Live Streaming](https://developer.apple.com/documentation/http-live-streaming) — native HLS context; retain RadioPocket's existing playback implementation.
- [Radio Browser API](https://api.radio-browser.info/) and [request reference](https://docs.radio-browser.info/) — mirror selection, stable IDs and request conventions.
- [Radio Browser homepage](https://www.radio-browser.info/) — data/software license distinction.
- [Icecast YP documentation](https://www.icecast.org/docs/icecast-latest/yp/) — directory context only; not a reliability endorsement.
- [U.S. Copyright Office Section 512](https://copyright.gov/512/) — conditional safe-harbor framework and information-location tools.
