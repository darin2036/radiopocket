# Contextual Moods

Moods is a separate Mac My Library entry immediately below Discover. It is an on-device radio concierge with two browsing levels:

1. A local greeting (“Good evening, Darin”) and a few mood/activity cards, such as Happy hour, Party time or Rainy-day retreat. The first name comes from the Mac profile and never enters the model prompt or weather request.
2. Selecting a mood immediately shows its playable station cards. There is no collection selection step. All moods returns to the greeting and mood cards.

These are ephemeral collections of live stations, not hosted song playlists. Station endpoints always come from enabled installed directories. Empty collections and moods are omitted. Curation preserves discovery's quality floor, safe metadata rules, language choices, feedback, favorites and optional recent-listening signals. Each mood chooses up to four suitable stations from the candidates still available in plan order. A station already shown in a mood is withheld from later moods, matching both normalized endpoints and station names so alternate stream addresses do not repeat the station. The four slots are shared across the mood’s musical directions. Empty moods are omitted. Mood genre fit leads ranking, with personal affinity as a bounded secondary signal.

## Onboard AI planning

With “Use on-device AI for searches and moods” enabled in Your mix, Apple Foundation Models proposes the activity names, short invitations, artwork keys, collection names and matching genres. The prompt contains:

- The local calendar day, weekday/weekend and morning/afternoon/evening/late-night bucket.
- Known weather category, or an explicit unknown marker.
- A known calendar occasion, or an explicit none marker.
- Counts of eligible stations by genre from the enabled directories.
- Bounded local genre-affinity signals and selected broadcast languages.

The AI decides what music suits the moment. It receives no station URLs, station names, raw listening history, city coordinates or personal name. It cannot invent station identities. The local selector resolves its genre-based plan to real stations afterward.

Planning uses greedy sampling and a canonical prompt: ordering is stable, and minutes/request timestamps are omitted. Up to eight successful plans are cached in memory by prompt context and enabled-source identity. Changing the period, local day, weather category, preferences or available genre counts creates a new context. Same-context reloads reuse the plan; station eligibility is still recalculated. Plans are not hosted, uploaded or saved as playlists. Greedy generation is stable for the same prompt/model; model updates may change results across launches.

Bounded guided output is validated for title/description lengths, artwork keys, structure, unique names, and available genre vocabulary. Contradictory weekend/time-of-day/known-occasion suggestions and unsupported weather artwork are dropped. If no usable plan remains, AI is unavailable, or generation exceeds 20 seconds, deterministic local suggestions stay available. A completed AI response does not replace a mood while the user is browsing inside it; it is cached for the next reload. Clearing discovery data also clears cached plans.

The built-in occasion calendar currently supplies New Year's Day, Valentine's Day, Halloween, Christmas Day and New Year's Eve using the local Gregorian date. These are optional inspiration, not assumptions about observance. Country-specific and movable holidays are not inferred. Time buckets are morning 05:00–11:59, afternoon 12:00–16:59, evening 17:00–21:59, and late night 22:00–04:59. Weekend detection uses the local calendar.

## Optional city weather

On first opening Moods without a saved weather area, an inline introduction offers **Use my location** and **Not now**. Nothing requests device location merely by opening Moods. Use my location explicitly invokes macOS Location Services permission and performs one nearby-city lookup. Core Location reverse-geocodes the result through Apple; coordinates are rounded to a 0.05-degree grid (roughly 5 km) before local storage or weather requests. The location manager stops after the fix, with cancellation and timeout handling. A missing app-bundle usage description safely directs the user to manual city selection instead of requesting permission.

Not now persists the dismissal across launches, leaving weather disabled. Existing saved cities bypass the introduction. Denied/restricted access offers directions to System Settings and a manual-city fallback; it does not repeatedly invoke the permission prompt.

**Your mix → Weather** contains Use my location, Choose city and Turn weather off. Location lookup and city searches are explicit actions; detected/selected city changes stay in the preferences draft until Apply. Cancel preserves the previous weather choice (macOS permission already granted is independently managed by the OS). Turning weather off removes the saved area and keeps the first-use introduction dismissed. The same Weather tab is linked from the Moods header.

This is a saved nearby area, not continuous device tracking. After travelling, Use my location again to update the city. Manual searches still use Open-Meteo geocoding. Only the rounded device-derived area or chosen manual-city coordinates are sent to the weather provider. The signed Mac bundle includes the location usage descriptions in `build.sh`.

While Moods is visible, city-level weather is checked through Open-Meteo with a 15-minute in-memory cache, including failures. Requests have cancellation, timeouts, HTTP/JSON validation, coordinate checks, an accepted-response size limit and a two-hour freshness check. Failed or stale weather becomes unknown, with a time-only fallback. Device-local time controls the greeting even when the selected city is elsewhere. No station or listening data goes to the weather provider.

Weather attribution links to Open-Meteo; the attribution tooltip credits GeoNames for location data. Provider references: [forecast API](https://open-meteo.com/en/docs), [geocoding](https://open-meteo.com/en/docs/geocoding-api), [terms](https://open-meteo.com/en/terms). The integrated public endpoint permits non-commercial use; commercial distribution requires an appropriate provider plan/integration. No paid service has been provisioned.

## Verification

Offline regression checks cover time boundaries, weekends, known occasions, greeting, canonical context/cache keys, weather code handling, persistence, location-coordinate rounding, first-use skip, later weather enable/disable, draft application, structural validation, contradictory AI context, language eligibility, endpoint membership, hierarchy construction, unique stations across moods (including alternate addresses), sparse-catalog omission, and genre fit when the plan order changes. Native fixture QA covers regular/compact layouts, sidebar placement, mood → playable stations and back navigation. Live city/weather requests and live onboard model generation are also exercised.

Inspiration: [Songza's contextual Concierge](https://www.afb.org/aw/15/9/15537). Foundation Models sampling reference: [Apple's greedy sampling documentation](https://developer.apple.com/documentation/foundationmodels/generationoptions/samplingmode-swift.struct/greedy).

The system permission grant/deny flow requires interactive testing in the built `.app`; automated QA does not ask for the developer's location. The location manager is instantiated on the main run loop, performs no background updates, and cancels pending work when its owning sheet/window closes. Reference: [Apple location authorization guidance](https://developer.apple.com/documentation/CoreLocation/requesting-authorization-to-use-location-services).

## Explainer

Routine technical footer text in Moods is replaced by **How moods work**, opening a transient popover titled **Your little radio concierge**. It uses the approved friendly explanation of contextual suggestions, mood → station browsing, and live radio choosing the songs. The on-device AI sentence appears only when that preference is enabled. **Sounds good**, Return or clicking outside dismisses it. Operational loading and important errors remain visible when needed; ordinary Discover keeps its existing footer.

The settled header is one welcome line, with no day/time subtitle, city/weather row or duplicate prompt heading. Initial weather setup remains available; later weather choices live in Your mix. AFM supplies up to six short, playful greeting options alongside the mood plan. Validated options are selected stably by local day and period, with varied local fallback greetings when AI is unavailable. Names stay local. Weather attribution remains in the Weather settings tab.

Location permission waits are bounded, including the initial authorization wait. The build script refuses to replace a running target bundle: replacing it in place can invalidate macOS location identity verification and prevent the permission prompt.

Mood cards use a compact 148-point height with 18-point semibold titles and 12-point action text. The home grid keeps two columns down to a 420-point panel width, then stacks. Stable title-based vector backdrops vary between waves, diagonal ribbons, record grooves, confetti and hills. Station-card responsive layout remains unchanged.

The mood grid uses one shared column width, including an incomplete final row, and reflows between one and three columns. Tight or short viewports use 108-point cards, smaller icons, 15-point titles and 8-point gutters. Regular cards retain 148-point height and 16–18-point titles. The page greeting responds to panel width at 19, 23 and 28 points.

## Loading transitions

Switching between Discover and Moods clears the prior surface synchronously. Initial loading uses a native indeterminate indicator (a static waveform with Reduce Motion); existing feeds remain visible during background refreshes. Empty results and errors stop the indicator. Mood context, ranking, weather-based rebuilding and AI-plan resolution run off the main actor, with generation checks before rendering; Moods skips the unused Discover ranking pass. `./test-discovery-ui.sh` exercises the native view transitions and loader cleanup.

## Stable browsing session

Once rendered, the Moods collections and station order remain fixed until an explicit refresh, preference/source change, or a new visit. Time-of-day timers no longer rebuild an open Moods view. Availability checks continue saving evidence without reranking it, and late weather/AI results are cached for the next load. Playback history does not reload Moods; favorite buttons repaint from the same feed. Bringing an already-visible library window forward preserves the session.
