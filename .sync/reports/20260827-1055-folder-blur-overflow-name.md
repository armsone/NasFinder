# NasFinder folder blur and Android Overflow name sync report

- Sync group: `nasfinder`
- Started: 2026-08-27 09:04 KST
- Completed source/compile verification: 2026-08-27 11:01 KST
- Elapsed: 1h 57m
- Public release/site scope: not requested; no external release, TestFlight, GitHub Release, or NasFinder.com work performed
- Internal finish: NasFinder 2.2.2 and Mac helper 2.3.2 use build `202608271106`; verified apps were installed where permissions allowed and repository commits/pushes are tracked by Git rather than duplicated in this report

## Contract result

| Requirement | Apple consumer | Mac producer | Android producer/consumer | Status |
|---|---|---|---|---|
| Folder blur formula | Reads the producer-baked sheet and keeps folder display-time blur disabled | Samples the unblurred final 12x12 sheet and applies `clamp((share - 0.20) / 0.80, 0...1) * 2.5pt` once | Uses the same dp formula, converts it to the canonical sheet pixel scale, and skips the separate binary file-thumbnail display blur for directories | Source and compile/test verified |
| 0–20% no blur | No consumer re-blur | Inclusive zero-radius floor | Inclusive zero-radius floor | Unit verified |
| Maximum 2.5pt, no accumulation | No second layer | Parents use unblurred child tiles; only the final sheet is blurred | Parents use raw child sheets; only the final sheet is blurred; folder renderers opt out of file blur | Source and unit verified |
| Android Overflow actual name | Reference behavior only | Not applicable | Shared Browser/Inbox `RemoteBrowserCoverFlow` displays `items[selectedIndex].name` in bottom-center chrome | Source and compile/test verified |

The existing `v1-folder-<digest>.jpg` vault filename and lookup contract are unchanged. A producer run atomically replaces an existing folder sheet, so legacy fixed-blur JPEGs remain readable and migrate when regenerated. A full immediate migration still requires the existing explicit Mac `새로하기` flow; this task did not delete or regenerate user vault data.

## Verification

| Project | Verification | Result |
|---|---|---|
| SuperThumbnail-MacOS | `swift test` | 92 tests passed, 0 failures |
| SuperThumbnail-MacOS | `./build_app.sh` after 316 GiB free-space check | Universal signed app build succeeded and signature validation passed |
| NasFinder-Android | Focused `FolderSuperThumbnailPolicyTest` + `SuperThumbnailVaultAndSessionTest` + `InboxParityContractTest` | Gradle build/test succeeded; `compileDebugKotlin` succeeded; same-name safe replacement is covered |
| NasFinder-Android | `ThumbnailSkinToneRenderingContractTest` | Passed |
| NasFinder Apple | iPhone `FolderSuperThumbnailTests`; signed iPhone build/install; Mac Catalyst build | Related device tests passed; NasFinder 2.2.2 (202608271106) installed and relaunched on BK_iPhone17pro; signed Mac Catalyst app built and launched from its verified artifact |
| All touched repositories | `git diff --check` and source-path inspection | Passed |

## Evidence and open verification

- `.parity/ledger.json` records both rows as `implemented_source_only`.
- No deterministic post-change phone/tablet/TV Overflow screenshots were captured.
- No regenerated NAS folder sheet was inspected side-by-side on Apple and Android.
- Therefore rendered visual parity and full runtime synchronization are intentionally not claimed.
- `/Applications/NasFinder.app` is root-owned, so the Mac Catalyst replacement was not performed without administrator authorization; the verified 2.2.2 artifact did launch successfully from its build location.
- `/Applications/NasFinder Super Thumbnail.app` was data-preservingly replaced with 2.3.2 (202608271106), signature-checked, and relaunched.

## Attempt history and resolved blocks

- Gemini Android edit was blocked by its headless file-read permission path; no Gemini changes were accepted.
- Claude Fable reached its session limit after Apple source drafting and Android investigation.
- Work resumed with Claude Sonnet, then integration corrected the draft from display-time compounding to a single producer-owned blur and completed cross-repository verification.
- One Android test edit was initially inserted in the wrong test scope and failed `compileDebugUnitTestKotlin`; the test was moved to the folder-vault case and the same focused test then passed.

## Preserved unrelated work

- NasFinder: modified `AGENTS.md`; untracked `3525`, `CLAUDE.md`, `default.profraw` were not changed by this task.
- NasFinder-Android: untracked `.kotlin/`, `AGENTS.md`, `dist/` were not changed by this task.
