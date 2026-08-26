# Super Thumbnail frame, folder blur, and Android navigation sync

- Started: 2026-08-25 19:46:44 KST
- Completed: 2026-08-25 20:21:45 KST
- Elapsed: 35m 01.789s
- Scope: NasFinder Apple app, MacSuperThumbnail helper, NasFinder Android app
- Excluded by latest owner direction: NasFinder.com

## Owner contract

1. A video Super Thumbnail starts at `duration * 3/13`.
2. Black means black pixels cover at least 50% of the full sampled frame, including exactly 50%.
3. Only a black primary retries at `duration * 6/13`.
4. A non-black retry wins; a black or failed retry retains the primary.
5. A folder sheet keeps the existing 42% skin-tone trigger, receives exactly one final 1.5pt blur, and parents never re-blur child artwork.
6. A stored Super Thumbnail remains higher priority than standard/server thumbnail caches.
7. Android navigation must publish the target screen immediately; credential, connection, and listing work must not block buttons or Back.

## Before and after

| Platform | Previous actual producer position | Corrected producer position |
| --- | --- | --- |
| Mac helper | `min(duration * 0.1, 3 seconds)`; no 3/13 contract | exact 3/13; conditional exact 6/13 retry |
| iPhone/iPad app | VLC Super Thumbnail paths used 0.30, 0.65, midpoint-derived retry, or 0 in fallback paths | all complete-file Super Thumbnail VLC paths use 3/13; retry uses 6/13 only under the shared black-frame rule |
| Android phone/tablet/TV | Super worker reused the standard thumbnail path, allowing server intro art or a time-zero sync frame | dedicated Super Thumbnail path bypasses server/time-zero video fallback and extracts exact 3/13 then conditional 6/13 with `OPTION_CLOSEST` |

All implementations sample the full downscaled 32x32 frame, count luminance at or below 5% as black, and apply the inclusive 50% frame threshold.

## Folder blur

- Canonical sheet: 384px displayed as 192pt.
- Final blur: 1.5pt = 3px radius at the canonical sheet.
- Mac helper stores/rebuilds unblurred child tiles for parent composition.
- Android keeps run-scoped raw child sheets and never consumes a persisted blurred folder JPEG as a parent input.
- Apple display consumers no longer add another skin-tone blur to an already producer-blurred folder sheet.

## Android navigation latency

Pre-change SM-F968N reproduction showed a connection tap remaining on the dashboard while NAS DNS/connection/listing activity ran; the destination listing appeared only after a multi-second pause. The same deferred remote work affected hierarchical Back because parent navigation reused the same path.

The Android ViewModel now publishes an empty/loading Browser destination before launching remote work. Credential reads, old-service close, service creation, connection testing, picker listing, and normal directory listing cross `Dispatchers.IO`. Generation checks prevent stale listings from replacing a newer route. The Browser hides a misleading empty-folder state while loading.

## Validation

- Mac helper: `swift test --package-path MacSuperThumbnail` — 48 tests passed.
- iPhone device: focused `NasFinderTests/SuperThumbnailVideoFramePolicyTests` and `NasFinderTests/FolderSuperThumbnailTests` through `scripts/xcodebuild_project.sh` — passed on device `74D48C61-26C8-52CC-9D03-EA0F900001DD`.
- Android: focused Super Thumbnail, folder policy, and navigation latency tests — 19 tests passed.
- Android: full `./gradlew test` and signed `assembleReleaseQa` — passed for 2.2.0 (`versionCode 341065`, build `202608252025`).
- Android SM-F968N: the signed candidate was installed with app data preserved. Connection tap exposed the Browser/loading state immediately; toolbar Back and system Back each returned to the dashboard before remote work completed.
- Contract YAML parsed successfully; Android parity ledger JSON parsed successfully.
- Matchup classification: source/test/build aligned. Post-regeneration image comparison and post-install Android tap/Back timing remain intentionally open because regeneration and installation were not requested.

## Cache and old thumbnail cleanup

- Mac app caches moved recoverably to `/Users/armsone/.Trash/NasFinder-thumbnail-cache-cleanup-20260825-1954`: `RemoteThumbnails.v2`, `SuperThumbnails.v1`, and `FileProviderThumbnails.v1`, total 67MB.
- Android standard thumbnail cache cleared through the app UI: 73.7MB / 386 files to 0B / 0 files. Super Thumbnail cache was already 0B.
- NAS root `/Volumes/home`: 2,604 exact `.NasFinder-Vault` directories moved without failure to the recoverable hidden archive `/Volumes/home/.NasFinder-Vault-archive-20260825-1958` while preserving relative paths.
- No media originals, credentials, app settings, or general app data were removed.

## Remaining runtime work

- Owner will regenerate Super Thumbnails from two Macs.
- NasFinder Super Thumbnail 2.2.0 was signed, notarized, stapled, installed in `/Applications`, and relaunched. Public release publication is recorded separately by the release task.
- After regeneration, capture the same folder on iPhone/iPad/Mac and Android phone/tablet/TV to close visual priority/frame/blur parity rows.
- After regenerated media exists, record folder tap and parent-folder timing against a populated hierarchy; the connection, toolbar Back, and system Back latency paths are verified on the current SM-F968N candidate.

## Worktree preservation

Pre-existing unrelated Apple changes and untracked files were preserved. No commit, push, app installation, TestFlight, GitHub Release, or website deployment was performed.
