# Morit

Android 공유 메뉴에서 링크·메모·사진·영상·파일을 모으는 Flutter 앱입니다. 인증과 데이터 접근은 Supabase RLS로 보호하고, Android 다운로드·공유·알림 기능은 타입이 지정된 플랫폼 경계를 통해 Kotlin과 연결합니다.

## 설치

```powershell
& "$env:LOCALAPPDATA\Android\sdk\platform-tools\adb.exe" install -r .\dist\morit-release.apk
```

기존 디버그 서명 앱이 설치돼 있으면 서명이 달라 한 번 삭제한 뒤 설치해야 합니다. 이후 릴리스는 같은 `android/keystore/morit-release-v2.jks`로 서명해야 업데이트 설치가 가능합니다.

## 로컬 설정과 빌드

`config/local.json.example`을 `config/local.json`으로 복사하고 Supabase URL,
**anon 또는 publishable 키**, 배포한 다운로드 백엔드의 공개 HTTPS URL을
넣습니다. 모바일 APK는 해독 가능한 공개 배포물이므로 `service_role`,
`sb_secret_`, Cobalt API key 등 서버 키는 사용할 수 없으며 빌드 시에도
거부됩니다.

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define-from-file=config/local.json
```

릴리스 빌드에는 Git에서 제외된 `android/key.properties`와 개인 키스토어가 필요합니다. 키스토어와 비밀번호를 별도 보안 저장소에 백업하고 저장소·메신저·CI 로그에 올리지 마세요.

## 구조

```text
lib/
  auth/       재사용 가능한 로그인·가입·OTP·온보딩·MFA·복구 모듈
  core/       빌드 설정과 Keystore 기반 Supabase 세션 저장소
  morit/
    data/     폴더·항목·첨부·다운로드 데이터 모델과 Storage 전송
    media/    다운로드 백엔드 클라이언트와 미디어 선택 모델
    platform/ Flutter↔네이티브 타입 경계
    today/    앱·알림이 함께 쓰는 오늘 할 일 모달
    morit_controller.dart  로컬 캐시·동기화·유스케이스 조정
  main.dart   Material UI와 의존성 조립
android/      Kotlin 공유 수신·DownloadManager·알림
supabase/     SQL migration, schema baseline, Edge Function
backend/
  downloader/ 인증된 yt-dlp·FFmpeg 작업 서버와 선택적 Cobalt fallback
```

다른 Moring 앱은 `package:morit/auth/moring_auth.dart`를 가져와 `MoringAuthConfig`, `MoringAuthController`, `MoringAuthGate`만 설정하면 같은 인증 정책을 재사용할 수 있습니다.

## 다운로드·공유·오늘 할 일

- 다운로드 탭의 URL 입력과 Android 공유 링크는 동일한 인증 백엔드
  파이프라인을 사용합니다. Flutter는 URL 입력·미디어/품질 선택·진행 상태만
  담당하고, 플랫폼 추출·분리 스트림 다운로드·FFmpeg 병합/리먹싱·완료 검증은
  서버의 yt-dlp 엔진이 담당합니다.
- 분석 결과는 게시물 자산별로 묶이며 carousel 사진은 모두 기본 선택되고,
  영상·오디오는 자산당 한 품질만 선택됩니다. 썸네일·아이콘·광고 리소스는
  다운로드 후보로 만들지 않습니다.
- 서버는 임시 파일에서 yt-dlp 종료 상태, 실제 크기, ffprobe 스트림과
  FFmpeg decode를 검증한 파일만 공개합니다. 앱에는 원본 CDN URL이나
  서버 format selector 대신 짧은 수명의 opaque ID와 최종 파일 ticket만
  전달됩니다.
- 서버 처리 진행률은 분석·원본 다운로드·병합·변환·검증 단계로 표시됩니다.
  완료된 최종 파일은 기존 Android 검증 경로에서 다시 크기, 시그니처,
  영상·오디오 트랙과 기기 디코더를 확인합니다.
- `다운로드`는 메모를 만들지 않고 기기에만 저장합니다. `저장`을 선택한 경우에만 메모를 만들고 완료 파일을 첨부로 복사해 동기화합니다. `file://`와 Android `content://` 완료 URI를 모두 처리하고 중간 파일은 정리합니다.
- 다운로드는 미디어 종류에 따라 Android 공용 저장소의 `Pictures/Morit`, `Movies/Morit`, `Music/Morit`, `Download/Morit`에 저장돼 내 파일과 갤러리에서 찾을 수 있습니다. 서버와 기기 작업 모두 취소·다시 시도·일시 중지를 지원하며, Android `DownloadManager`에는 바이트 단위 사용자 일시정지 API가 없어 다시 시작하면 서버 분석부터 다시 수행합니다.
- `오늘 할 일`은 앱 홈에 3개까지만 보이고, 앱·알림의 `모두 보기/목록`이 같은 중앙 모달을 엽니다. 알림 체크는 완료만 처리하며, 우측에는 아이콘형 `추가`·`목록`만 둡니다. 수정은 전체 목록 모달 안에서만 제공합니다.
- 완료 항목은 노란 형광펜 애니메이션과 함께 당일에 남고, 다음 날짜에는 완료 항목을 제외하며 미완료 항목만 설정에 따라 이월합니다.
- 잠금화면 편집은 `기기 잠금 해제`, `잠금 해제 없이 허용`, `Morit PIN` 중 선택합니다. 특수 오버레이 권한 없이 투명 Activity를 사용하고, 사용할 수 없으면 일반 앱 화면으로 연결합니다.
- 사진·영상·일반 파일은 메모·오늘 할 일·알림의 첨부로 저장합니다. 원본 파일명은 DB 메타데이터에 보존하고 Storage 키는 `user_id/item_id/attachment_id/file.ext` ASCII 경로를 사용합니다. 생성·수정 중에는 저장 전까지 변경을 보류해 취소 시 기존 데이터를 보존합니다. 6 MiB 이하는 표준 업로드, 초과 파일은 6 MiB TUS 청크와 offset 복구를 사용하며 업로드 상태·진행률·명시적 재시도·실패 원인을 표시합니다.
- 파일·메모·오늘 할 일·폴더를 길게 누르면 계층형 이동 트리가 열립니다. 머무름 자동 펼침, 가장자리 자동 스크롤, 루트·상위 이동, 금지 대상 비활성화, 경로 미리보기와 실행 취소를 지원합니다.
- YouTube, Instagram, X, SoundCloud 등은 yt-dlp extractor가 반환하는 실제
  플랫폼 오류를 보존합니다. 로그인·지역·연령·DRM 제한은 공개 콘텐츠 없음으로
  뭉개지 않고 엔진·플랫폼·단계·오류 코드와 함께 표시합니다. 선택적으로
  self-hosted Cobalt를 서버 fallback으로 설정할 수 있지만 공식 hosted API를
  앱에서 직접 호출하거나 Cobalt key를 APK에 넣지 않습니다.

## 데이터베이스

운영 프로젝트에는 `202607230008_harden_attachments_and_profiles.sql`,
`202607230009_prevent_folder_cycles.sql`,
`202607230010_allow_reminder_attachments.sql`,
`202607230011_scope_shared_storage_policies.sql`까지 적용돼 있습니다. 새
프로젝트는 `supabase/baseline/morit_schema.sql`을 적용한 뒤 번호 순서대로
migration을 적용합니다. 기존 프로젝트에는 baseline을 다시 적용하지
않습니다.

## 보안 경계

- Supabase 세션과 PKCE verifier는 Android Keystore 기반 secure storage에 저장됩니다.
- `public.profiles`는 자기 행과 관리자만 읽을 수 있습니다. 익명 공개 정보는 PII가 없는 읽기 전용 `public.profile_directory`만 사용합니다.
- Morit 데이터와 비공개 Storage는 소유자 ID뿐 아니라 온보딩 완료 및 필요한 경우 AAL2 MFA까지 RLS에서 확인합니다.
- Android 클라우드 백업·기기 간 데이터 이전·cleartext HTTP를 차단하고, 딥링크는 `morit://auth/callback` 하나만 허용합니다.
- Morit PIN은 secure storage에만 두고 연속 5회 실패하면 30초 동안 확인을 제한합니다. PIN과 잠금화면 정책은 기기 로컬 설정이며 원격 DB로 보내지 않습니다.
- 기존 Supabase 임의 URL 프록시는 SSRF·비용 공격 위험 때문에 계속
  비활성화돼 있습니다. 별도 다운로드 서버는 Supabase 세션을 검증하고,
  지원 도메인·공개 IP·시간·크기·사용자별 동시 작업 수를 제한합니다.
- Android DownloadManager에는 Supabase bearer, 쿠키, 원본 URL을 넘기지
  않습니다. 검증된 완료 파일에만 사용할 수 있는 짧은 수명의 opaque ticket
  URL과 정확한 MIME/파일명만 전달합니다.
- 공유 파일은 최대 20개, 실제 복사 바이트 합계 500 MiB로 제한하며 `메모 1개 + 첨부 N개`로 원자적인 로컬 handoff를 만듭니다.

Dart의 데이터·동기화·미디어 Provider는 플랫폼 코드와 분리돼 있습니다.
iOS에서는 같은 계약 위에 Share Extension, Widget/Live Activity와 파일 전송
구현을 추가해야 하며 Android의 ongoing 알림·잠금화면 Activity를 그대로
사용하지 않습니다.

상세 감사 결과와 남은 운영 항목은 `docs/security-audit.md`에 있습니다.
다운로드 서버 실행·배포 설정은 `backend/downloader/README.md`에 있습니다.
