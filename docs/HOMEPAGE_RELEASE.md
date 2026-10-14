

## 홈페이지 배포 정보 자동 연결

이 제품의 홈페이지 등록 key: `NasFinder-Mac`. 기존 제품의 단순 버전업에서는 홈페이지 소스의 버전·빌드·다운로드·예비 주소를 수정하지 않습니다.

최종 서명·패키징 파일과 실제 제품 버전으로 `release.json`을 만들고 GitHub 릴리스 자산에 함께 게시합니다. 빌드·Android 내부 코드는 현재 빌드의 확인된 값만 넣습니다. 생성 도구는 파일명·크기·SHA-256을 기록하며 기존 앱 서명·업데이터·appcast 검증을 대체하지 않습니다. 파일과 배포 정보를 준비한 뒤 릴리스를 공개하고, 홈페이지의 표시 버전과 실제 다운로드가 일치하는지 확인합니다.

공통 절차와 스키마는 [홈페이지 다운로드 자동화 안내](https://github.com/armsone/Hanstree.com/blob/main/docs/automatic-downloads.md)를 따릅니다. 로컬 도구는 홈페이지 체크아웃의 `build/release-metadata.mjs`입니다.

```sh
node ../NasFinder.com/build/release-metadata.mjs \
  --version "$PRODUCT_VERSION" --artifact "NasFinder-Mac=$FINAL_PACKAGE" \
  --output "$RELEASE_DIRECTORY/release.json"
```

명령은 프로젝트 루트에서 실행하고, 위 변수는 실제 빌드의 값과 경로로 설정합니다. 확인된 빌드가 있으면 `--build`, Android 내부 코드가 있으면 `--version-code`를 추가합니다. 기존 `gh release create` 또는 초안 업로드 명령에 생성한 `release.json`도 포함합니다.

새 제품·플랫폼·파일명 규칙 등록, 기능 설명·이미지·지원 정책·개인정보 안내의 실제 변경이 있을 때만 홈페이지를 별도로 수정합니다. TestFlight는 기존 심사·공개 확인 절차를 유지합니다.
