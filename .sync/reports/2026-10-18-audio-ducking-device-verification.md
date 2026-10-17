# 원음 연동 배경음악: 실제 iPhone·Android 출력 확인

확인일 2026-10-18, 01:39–02:20 KST. 기능 확인 완료. 현재 설치 버전 양쪽2.15.2(Apple build202610172050, Android code416673). 소스 수정·빌드·재설치 없음: 실제 출력에서 감소와 회복을 확인하여 불필요한 수정/버전 변경을 하지 않았다. Git 커밋·푸시·릴리즈·TestFlight·홈페이지 변경·테스트 러너 없음.

## 방법
사용자 원본 대신 이 확인을 위해 12초짜리 실제 MP4를 만들었다. 화면은 시간 표시가 있는 움직이는 색상 패턴, 원음은440Hz 정현파로0–4초진폭0.003/4–8초진폭0.5/8–12초진폭0.003. 배경음은2200Hz 진폭0.12의12초WAV. 양쪽 앱의 실제 미디어 선택→뮤직비디오(원본12초전체)→음악선택→자동조절켜기/끄기→출력생성 경로를 UI로 실행했다. 합성 함수를 별도 호출하거나 테스트용 앱/훅을 만들지 않았다.

완성 파일을 지정 기기 앱 저장소에서 가져와 전체 디코딩 검사(ffmpeg오류없음) 및1초 구간의440Hz/2200Hz 직교투영으로 각 성분의 진폭dBFS를 측정했다. 측정 결과는 옆 JSON에 보존. 청취 품질 평가나 실제 대사/다양한 codec·여러 장면 컷·짧은 음악 반복 경계 전체 검증을 뜻하지 않는다.

| 기기/설정 | 조용한 원음(2–3초) BGM | 큰 원음(6–7초) BGM | 다시 조용함(10–11초) BGM | 판정 |
|---|---:|---:|---:|---|
| iPhone 자동켜기 | -22.496dBFS | -33.291dBFS | -22.505dBFS | 10.795dB 감소 후 회복 |
| Android 자동켜기 | -20.628dBFS | -33.404dBFS | -20.628dBFS | 12.776dB 감소 후 회복 |
| iPhone 자동끄기(1/5/10초 시작구간) | -22.1583dBFS | -22.1580dBFS | -22.1582dBFS | 일정 |
| Android 자동끄기(1/5/10초 시작구간) | -19.8507dBFS | -19.8501dBFS | -19.8524dBFS | 일정 |

자동켜기 출력의 원음440Hz: iPhone 조용함-50.468/큰원음-6.022dBFS, Android-50.559/-6.034dBFS. 원본 입력의 진폭(-50.46/-6.02dBFS)에 부합하여 원음 크기를 바꾸는 대신 음악이 줄어든 것을 구분했다. 양쪽 기본 음악 게인이 기존 구현에서 서로 달라 절대 수치는 다르며, 감소/회복 동작이 확인됐다.

## 실제 산출물
- iPhone 지정기기00008150-001E342C3C87801C: 실제 생성후 재생,12초MP4 두개. ownworkspace tmp/NasFinderTrailer-A48BDE5F-725E-4236-88E8-41D61F16FC6E. 켜기 trailer-33E9B3DA-92B3-49C3-8988-DF0CF1C01995.mp4 /끄기 trailer-89CEA5D3-F01E-4D14-B4A8-55C1C4ECBAAB.mp4. 재생설정으로 복귀해 스위치해제후 재생성했다.
- Android SM_F968N 192.168.0.253:39513: 켜기 cache/trailers/b0061cf8-4436-4044-ab8e-e99674da3e25/trailer-c42b3218-aa56-49fc-9f1c-7310f1200ec9.mp4, 끄기 cache/trailers/19495023-ba65-4225-815f-92261d418b9f/trailer-5e43612d-3b64-4627-804b-393c019d86e0.mp4. 각12.02초, 앱자동재생 확인.
- 모든4출력 전체디코딩exit0. 해시·코덱·시간·크기는JSON.

## 협업 및 판단 경계
삼대장 절차로 Gemini PRIMARY Apple 경로를 읽기 검토했다. SECONDARY는 네이티브read_file권한이 자동거절되어 절대경로 제거/파일전용 실행에서도 같은 오류를 확인했다. 보호를 해제하지 않았으며 필요한3파일 원문을 승인된 동일 계정의 작업 프롬프트에 직접 제공해 도구 호출 없는 분석으로 완료했다. 읽기 권한 설정 자체는 바꾸지 않았다. 두 경로 요청모델gemini-3.8-flash-low/low; 실제 모델ID는 결과에서 별도 반환되지 않음.
SECONDARY가 제기한 byte-order·decoder 가능성은 이번 실기기 출력과 구별되는 가설이며, 이 폰에서 PCM 이상이나 자동조절 실패는 재현되지 않아 추측성 수정은 하지 않았다. 외부 조사가 결과를 바꾸지 않는 기존 로컬 구현과 실제 산출물 확인이므로 외부조사 비적용.

## 확인용 데이터 정리
Android ownfixture files/SharedInbox/CodexDucking-20261018, Music/CodexDucking-BGM.wav, /data/local/tmp/CodexDucking-20261018 및 위2개 exactsession 제거. 기존232개 trailer파일 보존 확인. NAS /Volumes/home/CodexDucking-20261018 및 iCloud Drive/CodexDucking-20261018 제거.
iPhone은 기존 페어링의 정상 House Arrest 파일 도구로 이 작업의 Documents/CodexDucking-BGM.wav, Documents/CodexDucking-quiet-loud-quiet.mp4 및 위 exactsession만 제거. Documents에는 기존Received Photos만 남고 tmp내CodexDucking일치0 확인. 앱 재실행으로 이 작업의 인메모리 편집상태 제거.
**미정리: iPhone 폰하드 Music에 네트워크 '사용'으로 가져온 CodexDucking-BGM.wav 1개(약1.2MB).** 앱그룹을 devicectl로 조회하면Library만 노출되어 정상 파일명령으로 해당파일을 확인/삭제하지 못했다. UI영구삭제는 도구정책상 행동직전 확인이 필요하므로 부재중 강행하지 않았다. 사용자 원본음악은 변경하지 않았다.
