# iPhone actual copy and video export verification

- 2026-10-17 20:38–20:46 KST, physical designated iPhone, installed NasFinder2.15.0/build202610171956. Codex TM performed runtime integration check via CUA. Same logical source-flow task; prior routing reused. No source edits, build, test framework, lint, Git, release or website operations this turn.
- Selected local Photos IMG_7858.HEIC first + NAS favorite 로드무비/IMG_8543.mov second. Common bottom tray2 retained. Copy destination own folder CodexVerify-20261017-2039 created through app. Actual PhoneHard folder contained IMG_7858.HEIC approx2MB and IMG_8543.mov approx30MB/27seconds, both thumbnails rendered. Copy completion physically verified by opening destination, not merely opening destination dialog.
- Re-entered media selection, gathered the same photo+NAS video in same order, entered editor and pressed actual12second trailer creation. Generated MP4 auto-played on iPhone; multiple distinct road-video frames and advancing/looping timeline observed. Local extracted frame0.1second verified selected photo, frame1second verified NAS road video. Full-file decode exit0 with no decoder errors. Audio track present; audible listening was not independently assessed. Background music was not selected, so this is not a fresh ducking measurement.
- MP4 exact file existed in new own session tmp/NasFinderTrailer-D2820B90-1B35-4EAC-9A73-10C0F14BFBF2/trailer-E818D83F-8864-4AF0-A314-17C45D9D9116.mp4. Received to local task folder for ffprobe/decode only. Metadata below. UI requests12seconds; container duration12.5s, coded video11.766667s/audio11.75s. No claim of exact12second container duration or every production mode/cloud-provider export.
- Navigation observation: after opening copied folder from embedded PhoneHard, the visible top Back returned to dashboard and ended the current selection session. Reselection was needed for the subsequent export check. This is a remaining navigation behavior to improve; no repair was performed in this runtime-only follow-up.
- AppGroup devicectl listing SharedInbox failed; root listing exposes Library only. Therefore copied-file byte hashes on iPhone were not verified. Actual destination UI names/sizes/thumbnails are the copy evidence. AppDataContainer tmp session/output listing and export copy succeeded. Do not treat AppGroup listing failure as copy failure.

## Cleanup explicitly authorized by user

User replied “확인용 사본과 예고편을 정리하세요”. Used app normal saved-edits delete confirmation to discard exactly own2-source/12second editor: saved-edits empty observed. Own session subsequently absent via exact devicectl path (listing fails after successful prior listing; no broad cache delete). Used normal PhoneHard context deletion and confirmation for exactly CodexVerify-20261017-2039 and its2copied files. UI showed “1개 항목 삭제 완료” and only preexisting Music folder remained. No photo-library/NAS originals modified. Local received MP4 and two extracted PNGs removed afterward; retained only non-content metadata/report. No original media uploaded to an external service.

## Export metadata

```json
{
  "programs": [],
  "stream_groups": [],
  "streams": [
    {
      "codec_name": "aac",
      "codec_type": "audio",
      "duration": "11.750000"
    },
    {
      "codec_name": "h264",
      "codec_type": "video",
      "width": 1080,
      "height": 1440,
      "duration": "11.766667"
    }
  ],
  "format": {
    "duration": "12.500000",
    "size": "8314209"
  },
  "sha256": "99f289941a300c013c035c52080330cdb41b891c03094ea05ebd1ef5ceb71e86"
}
```
