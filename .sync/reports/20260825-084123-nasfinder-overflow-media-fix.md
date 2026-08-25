# NasFinder Android overflow/media sync report

## Time

- Start: 2026-08-25 08:41:23 KST
- End: 2026-08-25 09:32:10 KST
- Elapsed: 50m 47s

## Agent usage (remaining amount)

| Agent/model | Start | End | Decrease | Work |
|---|---:|---:|---:|---|
| Codex | weekly 79% | weekly 77% | 2%p | integration, source review, build/install, real-device verification |
| Gemini | 5h 81.8189%, weekly 73.7598% | 5h 73.5679%, weekly 72.3846% | 5h 8.2510%p, weekly 1.3752%p | Android draft fixes and review |
| Claude/Fable | weekly Claude 89%, Fable 78% | weekly Claude 88%, Fable 78% | Claude 1%p, Fable 0%p | not invoked in this scoped fix; global account value changed independently |
| Huygens | unavailable | unavailable | unavailable | product contract inventory |
| Dalton | unavailable | unavailable | unavailable | Android inventory/Google Photos integration |
| Wegener | unavailable | unavailable | unavailable | parity-ledger review |

CCMB exposes model/account remaining percentages, not per-subagent token totals. Per-subagent quantities are therefore recorded as unavailable rather than estimated.

## Actual synchronized items

| Item | iOS reference | Android result | Verification |
|---|---|---|---|
| Overflow center square | adaptive centered square | adaptive square enlarged about 4.5% | policy test/build/device bounds |
| Overflow reflection | lower edge fades to transparent | offscreen DstIn alpha mask | source/test/build; capture still open |
| Center activation | selected hero opens deterministically | selected/index activation unified | source/test/device activation |
| Remote playback preparation | visible loading then automatic play | preparing indicator + `playWhenReady` | device transition observed |
| Progressive streaming | maximum 8 MiB playback range | 8 MiB read-ahead with in-session reuse | unit test + live Synology MP4 |
| Interrupted range read | cancellation is normal lifecycle | normalized to InterruptedIOException | unit test + no post-fix loader exception |
| First-position restore | restore only once | READY seek loop removed | source/test/live playback |
| Incomplete cache | only complete known-size files accepted | stale/truncated files rejected | contract test/build |
| Playback failure | actionable recovery | retry/external open/close | source/test; forced failure trace open |
| Landscape fill | media behind overlay chrome | no Scaffold top gap | installed window fills 2160x1584 |
| Video system chrome | immersive player | status/navigation/caption bars hidden and restored on exit | WindowManager runtime state |
| Image rotation behavior | same single-image viewer in portrait/landscape | removed landscape overflow/reflection substitution | source test/build/install |
| Photo orientation | EXIF-aware aspect | rotate/mirror EXIF normalized before fit | EXIF policy/source test/build |

## Errors and resolutions

| Error | Cause | Resolution |
|---|---|---|
| Video stayed on first frame | READY callback repeatedly sought to the same position, flushing codecs | restore initial position once and never seek to zero on READY |
| Temporary full-download route contradicted iOS | actual connection was Synology, not SFTP; diagnosis was applied to the wrong backend | restored Synology range streaming and matched iOS 8 MiB playback chunks |
| Many small remote reads buffered badly | Media3 consumer reads caused separate small remote calls | one 8 MiB range is retained and served to subsequent consumer reads |
| `Unexpected exception loading stream` loop | normal Media3 cancellation escaped as raw InterruptedException | convert interruption/cancellation to InterruptedIOException |
| Old 65 KiB cache could be treated as complete | cache hit did not compare known remote size | reject/delete size-mismatched cached files |
| Landscape top blank/system information visible | Scaffold padding and visible system bars reduced the video surface | video ignores content padding; immersive system bars with transient swipe behavior |
| First ledger validation failed | new evidence entries were strings, but schema requires evidence objects | created hashed behavior-trace evidence and updated ledger objects |
| Opened image changed into overflow in landscape | browser poster-to-overflow presentation was incorrectly reused inside the image viewer | removed the landscape-only alternate surface; one zoomable image viewer now survives rotation |
| Portrait photos rendered as landscape | preview bitmap decode ignored EXIF orientation | normalize all EXIF rotate/mirror variants before layout |

## Verification/status

- Focused tests: passed
- Full `testDebugUnitTest`: passed
- `assembleDebug`: passed
- APK SHA-256: `acb553b245a64d1a605e44098d7c143c7ff3bd171ef5c29d21b38ab8ba74bbd0`
- Installed/launched: SM-F968N, success
- Live Synology MP4: automatic playback continued over 15 seconds; decoder reported 23.98 fps; no post-fix unexpected loader/interrupt/playback exception
- Immersive window: status/navigation/caption bars requested hidden; app surface 2160x1584
- Sync YAML: parsed successfully
- Matchup ledger structure: 32 rows, 1 complete, 31 open
- Commit/push/release/site deployment: not performed; general sync and install did not authorize app repository publication, and no public build changed

## Unfinished

- Post-change Matchup capture pairs for overflow on folded phone, unfolded tri-fold/tablet and TV
- Live seek/cancel and forced network/decoder failure traces
- SFTP/SMB/WebDAV/FTP/cloud playback matrix and legacy external-player chooser
- Image portrait/landscape rendered capture pair remains open; source, tests, build and installation are complete
- Full product sync ledger: 31 rows remain open, so complete synchronization is not claimed
- NasFinder.com remains truthful as a next-public-build verification state; no public download was replaced
