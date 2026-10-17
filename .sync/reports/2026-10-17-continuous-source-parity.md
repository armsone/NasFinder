# Continuous media sources — scoped implementation and runtime evidence

- Request: match iPhone continuous source pages and verify mixed selection -> bottom tray -> copy/editor, build and replacement install.
- Started 2026-10-17 19:51 KST. This is scoped synchronization, not whole-product parity. Existing dirty work preserved; no commit, push, release, TestFlight, website change, test runner or lint.
- Apple 2.14.2 -> 2.15.0 / 202610171956; Android 2.15.0 -> 2.15.1 / 416672 (202610172012).

## Delivered

Apple seven horizontally navigable source pages: photos, calendar, PhoneHard, favorites, NAS/network, files, Google Photos. Shared ordered thumbnail tray with remove, preview, copy, editor; selections retained on source switching/cancellation. Existing favorite thumbnail renderer reused. Files browse user-granted folder inline with security-scope bookmark; provider errors have retry/choose-folder actions. Google uses existing authenticated official picker inside the source page. Platform Google UI differs from Android embedded picker; no claim of identical service UI.

Android source-reentry / resume / completed-copy revision refresh for PhoneHard and favorites. Existing basket, browsing path and source selection preserved.

## Direct runtime observations (CUA; originals preserved)

| Target | Observation | Boundary |
|---|---|---|
| Android 2.15.0 | Files + Photos selected together, tray2; NAS browse and Google inline grid kept tray1; Photos + PhoneHard tray2 -> editor2 image scenes; X removed selection without removing originals | No cloud item import/export generated |
| Android 2.15.0 | One photo copied into own `codexverify1958`; success alert and actual 5,139,542-byte copy. Editor staged two files with same SHA256 as own copy | New refresh correction was subsequent version |
| Android 2.15.1 | While media screen remained open, own empty PhoneHard folder created externally; favorites -> PhoneHard showed it immediately. After exact folder removal, same switch removed it from UI | Directly verifies source reentry refresh; no repeat whole-media-screen entry |
| Mac Apple 2.15.0 | Photos IMG_7858.HEIC + own synthetic PNG from Files folder: ordered tray2 -> own destination folder copied2 success -> editor2 sources /4seconds in tray order | Common Apple implementation, distinct from physical iPhone evidence |
| Mac final correction | Favorites now visible as existing thumbnail tile grid. App/4 iOS extensions correct version and strict codesign successful | Full pixel comparison not performed |
| iPhone Apple 2.15.0 | Physical iPhone: photo -> PhoneHard -> favorites thumbnails -> NAS favorite directory; append IMG_8543.mov. Shared tray2. Files and authenticated Google official photo grid remain in parent with tray2 | No Google item downloaded |
| iPhone Apple 2.15.0 | Copy destination dialog opened and cancellation kept tray2. Editor loaded both NAS video and photo (31seconds source,12second trailer); close/cancel kept tray2 | Actual copy bytes checked on Mac/Android, iPhone destination was cancelled |
| iPhone Apple 2.15.0 | Initial editor order was reversed (NAS before photo) despite tray photo first. Assigned narrow correction to preserve initial source order only for unified selector | Final corrective build/runtime recorded below |

## Build/install evidence

- Android `assembleDebug`: exit0 BUILD SUCCESSFUL (47seconds). Replacement `adb install -r`: Success; launcher started; installed 2.15.1/code416672. Local APK and installed base.apk SHA256 match: `51c2e99c141106a2ca3a1232493108aa2e506bec3c9f3d44c5ff2eedc73b02ab`.
- Apple initial iOS/Mac builds succeeded; first Mac process stayed after BUILD SUCCEEDED, signatures verified then exact own xcode/lock process terminated (wrapper143 caused by TM termination, not source compile failure).
- Second correction iOS exit0 BUILD SUCCEEDED20:22:11, Mac exit0 BUILD SUCCEEDED20:22:45. Strict codesign exit0. App + DocumentPicker/FileProvider/Share/Widget versions 2.15.0/202610171956. Data-preserved designated iPhone install and Mac replacement/relaunch completed.
- Final order correction is a third build of same candidate; record below.
- Detailed worker records: `2026-10-17-apple-source-pages-2.15.0.md`, Android `.parity/source-refresh-2.15.1.md`.

## Cleanup and limitations

- Own Mac copied2/staged2 files hashes matched by pair, then exact owned destination and staged session directory removed. Own Files folder bookmark key removed; app restart normal manifest reconciliation dropped removed records; saved editors0 observed afterward.
- Own Android copied file + exactly known two staged files hashed equal, removed only these and own empty folders. Final PhoneHard source showed only original Music/test folders. No original/NAS/cloud files changed.
- iPhone copy/new-folder creation cancelled, no persistent copy/folder created. Editor source staging is the normal app temporary-cache lifecycle; no unrelated cache or user editor removed.
- Initial coordinate actions on mirrors were unreliable; 150ms click duration recovered reliable iPhone taps. Keyboard navigation used on Android. Never adb input/monkey/UIAutomator. One initial worker used osascript for app quit despite task restriction; subsequent corrections used exact process termination, no further AppleScript.
- Gemini initial absolute read failure recovered by repository-relative paths. Later build account_busy was reassigned to available Claude without touching other job. Obsolete ponytail path resolved to installed plugin skill.
- Full paired pixel rendering, every provider's import/export, iPad/TV physical rendering and generated-video export were not exercised. Existing unrelated parity rows remain open; registry baseline unchanged.

## Work allocation / evidence limits

Claude Sonnet5.5/low Apple implementation and corrections, Gemini SECONDARY gemini-3.8-flash-low/low Android refresh, Claude Sonnet5.5/low Android build/install. Codex TM task integration, real UI checks and evidence. No forced extra workers or independent source audit.
Actual initial Apple usage: input64/cache-create87831/cache-read2169992/output38545/thinking12610. Gemini refresh: input327692/output12470/cache-read6260231/total340162 (provider reported fields, not inferred accounting). Per-run remaining subscription quota not inferred. Other worker usage only where raw result provides it; unknown otherwise.

## Subsequent direct evidence / correction

- Physical iPhone Google Photos authenticated official grid actually rendered within source page with mixed basket2 retained. X removed NAS then photo ->1 ->0; parent Back returned dashboard. No Google asset selected or downloaded.
- Order correction cause: editor unconditionally applied chronological order. Unified selector now opts into input order through `keepsSelectionOrder`; existing other entry routes retain default chronological order and explicit sorting remains available. Third iOS/Mac builds succeeded and were signed/reinstalled/relaunched. Final physical recheck pending below.
- Fourth narrow correction suppresses PhoneHard searchable modifier only inside embedded media selector to prevent toolbar leaking into another source; ordinary file browser search retained. Its install/runtime evidence follows.
- Ledger structural validation:82rows/4complete/78open, gateexit3 for existing unresolved whole-product verification. No rows promoted to matched without paired artifacts; current source implementation and runtime traces recorded as scoped evidence.
- Actual order-correction Claude modelusage input32/output7648/cachecreate23922/cacheread316362/thinking605. Provider list-cost estimate0.2038682USD is not subscription consumption.

## Final installed build (20:31 KST)

- Fourth iOS/Mac builds exit0 BUILD SUCCEEDED, strict codesign verified for built iOS/Mac and installed Mac. iPhone data-preserved installation/relaunch and Mac exact PID replacement/relaunch completed. Mac installed executable SHA256 equals final build artifact (TM direct check20:32).
- Physical iPhone final build: select photo -> PhoneHard -> favorites. No `현재 폴더 검색` toolbar remains; shared basket1 retained; favorite thumbnails shown. Append NAS IMG_8543.mov -> basket2 in photo-then-video order. Final editor rendering recheck follows.
- Search-correction Claude actualusage input26/output5088/cachecreate16971/cacheread201398/thinking557. All Claude workers actual model Sonnet5.5/low.

## Final direct recheck

- Physical iPhone final2.15.0: photo first, NAS video second in bottom tray; editor source badges now photo1,video2 (12second trailer/31second input), confirming order correction. Close/cancel retained basket2. No video export generated. Normal process relaunch after own verification cleared in-memory verification selection/draft; user originals unchanged.
- Copy verification boundary remains exact: Mac actualmixedcopy2 and Android actualcopy1, iPhone destination dialog/cancel route observed. Authenticated Google grid rendered; Google download/export not claimed.
- Completed scoped work 2026-10-17 20:33:13 KST; elapsed 40.3 minutes from recorded monotonic start.
