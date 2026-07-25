# Morit 보안·구조 감사

감사일: 2026-07-24

## 조치한 문제

1. Flutter 소스에 있던 Supabase URL·공개 키 상수를 제거하고 `--dart-define-from-file` 설정으로 이동했다. 서버 키 형식은 빌드 전 검증에서 거부한다.
2. 기본 SharedPreferences 인증 저장소를 Android Keystore 기반 secure storage로 교체하고 기존 세션·PKCE 값을 일회성 이전 후 삭제한다.
3. 디버그 키로 서명되던 release 빌드를 차단하고 별도 release 키가 없으면 빌드가 실패하도록 했다.
4. Android 백업·평문 HTTP를 차단하고 OAuth/recovery 딥링크를 정확한 scheme/host/path로 제한했다.
5. 로그인·Google OAuth·이메일 OTP 가입·온보딩·TOTP MFA·비밀번호 복구를 `lib/auth` 독립 모듈로 분리했다. 화면은 Supabase를 직접 호출하지 않는다.
6. `public.profiles`의 익명 전체 행/PII 노출과 자기 권한 상승 가능 정책을 제거했다. 공개 정보는 민감 필드가 없는 동기화 테이블로 분리하고, 권한 필드는 서버 trigger가 보호한다.
7. Morit 테이블·Storage RLS에 프로필 완료와 MFA AAL 검사를 추가했다. UI gate 이전의 백그라운드 load/sync도 차단했다.
8. 임의 URL Edge Function 프록시를 410 응답으로 비활성화하고 앱은 HTTPS 직접 다운로드만 사용한다.
9. 공유 URI·텍스트·파일 수·실제 누적 복사 크기, 다운로드 URL·파일명·헤더·열기 경로를 Flutter와 Kotlin 양쪽에서 제한했다.
10. 계정 간 폴더/항목 참조를 막는 복합 FK와 `user_id` 일관성 제약을 적용했다.
11. 다운로드가 `대기 중`에 고착되던 상태 동기화 오류를 수정했다. 이 기기에서 생성한 작업만 Android `DownloadManager` 상태와 연결하고, 다른 기기의 원격 레코드는 로컬 작업으로 오인하지 않는다.
12. 다운로드 진행률·완료·실패 원인·일시정지·재시도·취소를 처리하고, 네이티브 조회가 일시적으로 실패해도 작업을 중복 생성하거나 즉시 실패시키지 않는다. 일시정지는 안전하게 작업을 제거한 뒤 재개 시 처음부터 다시 받는다.
13. 후보 CDN URL과 요청 헤더는 Supabase나 SharedPreferences에 저장하지 않는다. 원본 페이지 URL만 저장하고 재시도할 때 다시 분석하며, 허용 헤더도 `Referer`와 `User-Agent`로 제한했다.
14. `MediaProvider` 인터페이스와 레지스트리로 링크 분석을 화면·저장소·다운로드 계층에서 분리했다. 공개 HTTPS 직접 미디어와 공개 페이지 메타데이터를 분석하며 요청된 29개 플랫폼을 도메인 경계와 링크 형식으로 판별한다.
15. Android 공유 진입은 별도 반투명 `ShareActivity`에서 처리한다. 공유 페이로드를 먼저 검증한 뒤 저장 가능한 후보를 표시하며 사용자가 형식을 명시적으로 선택해야 다운로드한다.
16. “오늘 할 일” 알림은 비공개·ongoing 맞춤 알림으로 구현했다. 최대 4개 행의 완료 체크와 아이콘형 `추가`·`목록`만 제공하며, 수정은 목록 모달 안으로 한정했다. 체크는 Activity를 열지 않는 명시적·불변 Broadcast `PendingIntent`만 사용한다.
17. 로그아웃·접근 권한 강제 해제 시 이 기기의 활성 다운로드, 앱 소유 파일, 오늘 할 일 알림과 로컬 사용자 캐시를 정리한다. Android 클라우드 백업과 기기 이전에서도 앱 데이터·설정·DB를 제외했다.
18. 잠금화면 편집은 `device_unlock`, `allow_locked`, `morit_pin`으로 분리했다. 기본값은 기기 잠금 해제이며, 잠금 없이 허용한 경우에만 알림 수신기가 즉시 완료 상태를 바꾼다. Morit PIN은 secure storage에만 저장하고 5회 실패 시 30초 제한한다.
19. 사진·영상·파일을 `morit.attachments`와 private Storage의 메모 첨부로 통합했다. 로컬 경로는 원격 payload에서 제외하고, 소유자/메모/Storage 경로 정합성·RLS·업로드 상태·보상 삭제를 DB와 클라이언트 양쪽에서 검사한다.
20. 6 MiB 초과 파일은 Supabase 권장 TUS 6 MiB 청크와 `HEAD` offset 복구로 전송한다. 운영 로그의 TUS `413`은 네트워크 오류가 아니라 프로젝트/서버 업로드 크기 제한으로 분류하고 정확한 실패 문구를 표시한다.
21. Android 공유 파일 여러 개는 별도 항목 여러 개가 아니라 `메모 1개 + 첨부 N개` handoff로 저장하며, 기존 photo/video/file 행은 ID·폴더·즐겨찾기·시간·경로를 보존해 메모+첨부로 이전한다.
22. 폴더는 소유자 복합 FK와 클라이언트 descendant 검사에 더해, 서버 trigger가 자기참조와 조상→자손 이동을 차단한다. 사용자별 advisory transaction lock으로 동시 트리 변경도 직렬화한다.
23. 열린 첨부 상세 화면은 controller 상태를 구독해 추가·삭제·재시도·진행률을 즉시 갱신한다. 원격 삭제된 업로드 파일의 앱 샌드박스 사본도 다음 동기화에서 정리한다.
24. 메모·오늘 할 일·알림 생성과 수정은 선택한 파일과 삭제 대상을 저장 전까지 화면 상태로만 유지한다. 취소는 기존 데이터를 건드리지 않고, 저장할 때 검증·복사 완료 후 한 번에 항목과 첨부 상태를 반영한다.
25. `morit.enforce_attachment_memo()`는 소유자 검사를 유지하면서 `memo`와 `reminder`만 허용하도록 운영 DB에서 교체했다. 독립 photo/video/file 생성 경로는 제거했으며 기존 legacy 종류의 읽기 호환성은 유지한다.
26. Storage `POST 400`의 직접 원인은 표시용 한글 파일명을 객체 키에 사용한 것이었다. DB의 원본 `file_name`은 보존하되 객체 경로는 `user_id/item_id/attachment_id/file.ext` 형식의 ASCII 전용 키로 분리했다. 실패·대기 중인 이전 비ASCII 경로는 재시도할 때 새 경로로 교체한다.
27. 업로드 실패는 `InvalidKey`, 권한, 버킷 없음, 중복, 용량 초과, 속도 제한, DB FK 등으로 구분한다. `failed` 항목을 매 동기화 때 무한 재시도하지 않고 사용자의 명시적 재시도만 `pending`으로 되돌린다. 보상 삭제 실패가 최초 업로드 오류를 덮어쓰지 않게 했다.
28. 공용 Storage UPDATE/DELETE 정책이 버킷 조건 없이 사용자 ID 접두사만 검사하던 우회 가능성을 발견했다. 운영 migration `scope_shared_storage_policies`로 해당 정책을 원래 대상인 `post-attachments` 버킷에 한정해 `morit-files`의 `morit.can_access()` 정책을 우회하지 못하게 했다.
29. 메모·오늘 할 일·폴더의 길게 누르기 이동을 계층형 폴더 트리로 통합했다. 600ms 머무름 자동 펼침, 가장자리 자동 스크롤, 루트·상위 폴더 드롭, 자기 자신·자손 비활성화, 이동 경로 미리보기와 이동 후 실행 취소를 제공한다.
30. 찾기 탭의 루트 목록은 `folder_id IS NULL`인 항목만 표시한다. 폴더 화면은 현재 폴더명 하나만 상단에 두고, 필요할 때만 조상 경로 메뉴를 열어 상위 폴더로 이동한다.
31. 홈의 빠른 저장과 오늘 할 일은 22px 좌우 여백, 18px radius, 64px 행 높이를 유지하면서 외곽선과 장식용 아이콘 박스를 제거한 평면 Toss 스타일로 정리했다. 최근 항목은 부모 카드를 제거해 각 행의 배경이 투명하게 보이도록 복원했다.
32. 루트·홈에서 시작한 드래그는 보이는 폴더 타일에 직접 놓고, 실제 폴더 화면 내부에서 시작한 드래그만 계층형 `폴더로 이동` 바텀시트를 표시하도록 드래그 문맥을 분리했다.
33. 플랫폼 레지스트리는 YouTube, Instagram, Facebook, Threads, TikTok, X, Bluesky, Reddit, Pinterest, Snapchat, LinkedIn, Tumblr, Twitch, Vimeo, Dailymotion, Discord, Telegram, KakaoStory, Naver Cafe·Blog·Band, LINE, Medium, Substack, WordPress, Behance, Flickr, Imgur, SoundCloud를 판별한다. 로그인 필요, 접근 거부, 404, 429, 서버 오류, TLS, timeout, 비공개 미디어 없음은 서로 다른 실패 코드로 반환한다.
34. 완료 파일이 내 파일·갤러리에 보이지 않던 직접 원인은 `DownloadManager` 대상을 앱 전용 외부 디렉터리로 지정한 것이었다. Android 10 이상은 미디어 종류별 공용 `Pictures/Morit`, `Movies/Morit`, `Music/Morit`, `Download/Morit`에 저장하고, Android 7~9는 제한된 저장소 권한과 미디어 스캔을 사용하도록 수정했다. 기존 앱 전용 완료 파일은 원본을 보존하면서 공용 MediaStore에 한 번만 게시한다.
35. 완료 파일 열기가 앱 소유 경로 검사에 막히던 문제는 파일 경로를 직접 전달하지 않고 `DownloadManager.getUriForDownloadedFile()`의 content URI와 읽기 권한을 사용해 해결했다. 다운로드 대기 중부터 실제 공용 저장 위치를 화면에 표시한다.
36. 일반 다운로드가 0바이트 `PENDING` 상태에 무기한 머무르던 경우는 마지막 상태 변경 시각을 추적해 2분 후 실패·재시도 상태로 전환한다. Wi-Fi 전용 작업은 timeout에서 제외하고, 특정 Wi-Fi transport만 강제하던 조건을 비종량 네트워크 조건으로 교체했다.
37. 한 장의 대표 이미지만 잡히던 원인은 OG/Twitter 태그 위주의 후보 수집이었다. 반복 `img`·`video`·`audio`·`source`, `srcset`, JSON-LD와 공개 JSON의 미디어 배열을 제한된 깊이로 분석하고 URL을 중복 제거한다. OG/Twitter 썸네일, 프로필, 아이콘, 광고와 플레이어 URL은 최종 후보에서 제외하고 실제 후보는 종류와 무관하게 개별·전체 선택할 수 있다.
38. 직접 링크는 redirect 단계마다 공개 HTTPS 여부를 다시 검사하고 실제 응답의 상태, MIME, 확장자, `Content-Disposition`과 첫 512바이트 형식이 일치할 때만 다운로드한다. 2 MiB를 넘는 HTML은 필요한 앞부분까지만 안전하게 분석하며, HLS/DASH 전용 소스는 손상된 단일 파일로 저장하지 않고 명시적인 적응형 스트림 미지원 오류를 반환한다.
39. Bluesky는 공개 AppView의 post embed에서 `fullsize` 이미지만 읽는 전용 Provider를 추가했다. 외부 카드와 thumb는 제외하며 실제 공개 5장 갤러리에서 원본 5개를 모두 추출·응답 검증했다.
40. Android 완료 검증은 DownloadManager의 content URI를 열어 실제 크기와 JPEG/PNG/GIF/WebP/MP4/M4A/WebM/MP3/Ogg/WAV 시그니처를 검사한다. 영상·오디오는 `MediaExtractor` 트랙과 `MediaCodecList` 디코더까지 확인하고, 실패 시 파일과 MediaStore 행을 제거한 뒤 정확한 오류를 Flutter에 반환한다.
41. `다운로드`와 `저장` 흐름을 분리했다. 전자는 item 없이 공용 기기에만 저장하며, 후자는 메모를 만든 뒤 완료 파일을 `file://` 또는 `content://`에서 앱 imports로 복사해 첨부·동기화한다. 파일명+크기로 중복을 막고 content URI 중간 파일은 항상 정리한다.
42. 잠금화면 정책 payload를 확인하기 전에는 할 일 데이터를 렌더링하지 않는다. `allow_locked`만 잠금 중 즉시 편집을 허용하고, `device_unlock`은 사용자가 명시적으로 요청한 뒤 시스템 인증을 열며, `morit_pin`은 잠금 중에만 전용 PIN을 요구한다.
43. 홈 헤더, 빠른 저장, 오늘 할 일, 입력·버튼·모달을 Material 3 기반 18px radius와 공통 여백으로 정리했다. 오늘 할 일은 전체 개수, 행 전체 길게 누르기 재정렬, 여러 줄 모두를 덮는 완료 마커를 제공하며 현재 폴더의 `+ 추가`와 하위 폴더 생성은 해당 폴더를 기본 대상으로 사용한다.

## 검증 기준

- `flutter analyze`: 경고와 오류 0건
- `flutter test`: 전체 53개 자동화 테스트 통과
- `:app:compileDebugKotlin`: 성공
- `:app:lintDebug`: 성공, 오류 0건. KTX·compound drawable·도구 버전 등 비차단 경고 23건
- Android API 37 에뮬레이터 실다운로드: JPEG 44,891바이트와 MP4 788,493바이트를 각각 `Pictures/Morit`, `Movies/Morit`에 저장하고 MIME·크기·MediaStore 행을 확인. Google Photos가 두 content URI를 열었고 MP4는 기기 디코더 검증 통과
- HTML 559바이트를 MP4로 위장한 다운로드: `integrityFailure`와 구체적인 HTML 응답 오류를 반환하고 파일·MediaStore 행 제거 확인
- 공개 URL 분석: 직접 JPEG 1/1, Bluesky 공개 갤러리 원본 5/5 응답 검증. YouTube는 HLS/DASH, Vimeo·X는 직접 원본 없음, TikTok 샘플은 네트워크 응답 실패로 정확히 분리하며 플레이어·아바타·UI 이미지는 후보 0개
- 오늘 할 일 알림: 체크가 Activity를 열지 않고 complete 이벤트 1회만 기록, 수정 아이콘 없음, 추가·목록 icon-only, 최대 2줄 텍스트 확인. API 37 secure PIN 잠금에서 `device_unlock` 시스템 인증 화면 확인
- 익명 REST의 `public.profiles`: 401 차단
- 익명 `profile_directory`: 공개 필드만 반환하며 `email`, `birth_date`, `permission_level` 없음
- 익명 `get_permission_level` RPC 실행 권한: 없음
- 신규 auth 사용자→profile 생성 trigger: rollback형 DB smoke 통과, 테스트 사용자 잔존 0건
- Morit 테이블 6개와 Storage 정책 4개: RLS와 `morit.can_access()` gate 포함
- 첨부/폴더/Storage 정책 migration: 운영 적용 완료. attachment RLS=true, private bucket=true, anon `profiles` SELECT=false, 폴더 cycle 및 reminder 첨부 rollback smoke 통과, `scope_shared_storage_policies` 적용 확인
- 운영 정합성 재조회: `morit.attachments` 0행, `morit-files` 객체 0개, 업로드 완료 행의 객체 누락 0건, 고아 객체 0건
- release APK SHA-256: `927DD3C1972692D0D080DA337F90AE86F4DBF351FCE05BB5AD19E915212DA487` (`dist/build-info.txt`에도 기록)
- release APK: Android 17/API 37 에뮬레이터 `adb install -r` 업데이트, 버전 `1.5.0+8` 콜드 스타트에서 치명 로그 0건
- release APK 서명: 전용 인증서의 v2/v3 서명 검증 통과, 키스토어·서명 비밀번호·`sb_secret_`·`service_role` JWT·완전한 private-key block 포함 0건
- APK 압축 내용 검사: `.env`, `key.properties`, `.jks`, `.keystore`, 실제 private-key block 포함 0건
- APK JWT 검사: 1개, role=`anon`; `service_role` JWT와 `sb_secret_` 포함 0건. 포함된 Supabase URL과 anon JWT는 공개 클라이언트 설정으로 예상된 값이며 서버 비밀값이 아니다

## 남은 운영 항목

- Supabase의 유출 비밀번호 차단은 현재 요금제에서 활성화할 수 없다. 최소 비밀번호 길이는 8자로 상향했다.
- 공유 Supabase 프로젝트의 PostgreSQL 버전에 보안 업데이트가 남아 있어 대시보드에서 유지보수 일정을 잡아야 한다.
- 약관 동의 시각·버전 컬럼은 기존 호환 스키마에 없어 서버 감사 기록으로 남지 않는다. 법적 요구가 정해지면 별도 append-only 동의 테이블을 추가해야 한다.
- 콘텐츠 오프라인 캐시는 앱 샌드박스의 SharedPreferences에 평문으로 존재한다. Android 백업은 차단했고 로그아웃 시 사용자 캐시를 삭제하지만, 높은 위협 모델에서는 암호화 DB로 교체해야 한다.
- 현재 Android `DownloadManager` 경로는 공개 HTTPS 미디어 전용이다. 제목·설명·URL·요청 헤더가 시스템 다운로드 DB에 기록될 수 있으므로 인증 토큰·쿠키·비공개 URL은 전달하지 않는다. 향후 비공개 다운로드가 필요하면 Cronet과 WorkManager/foreground service 기반 전송기로 교체해야 한다.
- 소셜 다운로드는 정적 HTML 대신 별도 인증 백엔드의 yt-dlp/Cobalt·FFmpeg 경로를 사용한다. 공개 콘텐츠의 HLS/DASH 병합과 서명 URL 갱신을 서버가 처리하지만 로그인·사용자 쿠키가 필요한 콘텐츠, DRM, 지역 제한은 우회하지 않는다. yt-dlp subprocess의 2차 요청에는 운영 egress 방화벽으로 사설·metadata 대역을 차단해야 한다.
- 현재 `config/local.json`에는 `DOWNLOAD_API_URL`이 없고 영구 공개 HTTPS 백엔드도 배포되지 않았다. 배포 전 APK의 다운로드 탭은 서버 미설정 오류로 안전하게 중단하며, 상세 상태와 실URL 검증 결과는 `docs/download-redesign-report.md`에 기록했다.
- 일시정지는 바이트 범위 이어받기가 아니라 작업을 취소하고 재개 시 처음부터 다시 다운로드하는 방식이다.
- 맞춤 Android 알림은 시스템 제한으로 펼침 상태에서도 작업 4개까지만 직접 표시한다. 설정의 더 큰 노출 수는 남은 개수 안내와 전체 목록 연결에 사용한다.
- 자정 이월 알람은 정확 알람 권한을 요구하지 않는 inexact 방식이므로 절전 상태에서는 늦을 수 있다. 앱 재개·재부팅·시간/시간대 변경 때도 날짜를 다시 정규화한다.
- 현재 연결된 Android 대상은 API 37 에뮬레이터뿐이다. 삼성 One UI 물리기기의 공용 폴더·갤러리 노출, 잠금화면, 생체/기기 인증, 제조사별 알림 높이와 절전·다운로드 정책은 별도 실기기 회귀 테스트가 필요하다.
- 실제 로그인 세션이 없어 새 첨부를 운영 Storage에 올리는 Android E2E는 실행하지 못했다. 로컬 TUS 서버에서 첫 청크 500 오류 후 offset 복구와 완료를 검증했고, 운영 DB/버킷/RLS 구성은 확인했다.
- 운영 버킷의 DB 설정은 500 MiB지만 실제 TUS 요청에서 `413`이 관찰돼 프로젝트/플랫폼의 더 낮은 전역 제한을 대시보드에서 확인해야 한다. 앱은 이를 네트워크 오류가 아니라 서버 허용 크기 초과로 표시한다.
- Supabase 보안 Advisor에는 Morit 스키마의 신규 경고가 없지만, 같은 공유 프로젝트의 `public`·`business` 등 다른 앱 영역에는 기존 [Security Definer view](https://supabase.com/docs/guides/database/database-linter?lint=0010_security_definer_view)와 [mutable search path](https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable) 경고가 남아 있다. 다른 앱을 깨뜨릴 수 있어 이번 범위에서는 수정하지 않았으며 별도 프로젝트 차원의 감사가 필요하다.
- iOS는 공통 Dart 계층과 플랫폼 계약만 준비돼 있다. Share Extension과 Widget/Live Activity의 상호작용 제한에 맞춘 Swift 구현 및 iOS 기기 테스트는 후속 범위다.
- 이 작업 폴더에는 `.git` 디렉터리가 없어 과거 커밋에 포함됐던 비밀값까지는 검사할 수 없다.
- `profile_directory` 도입으로 공개 프로필을 직접 `profiles`에서 읽던 다른 앱은 안전한 디렉터리로 전환해야 한다. 관리자/service-role 경로와 자기 프로필 인증 흐름은 유지된다.
- 실제 메일함과 테스트 계정이 제공되지 않아 이메일 OTP 수신, Google 계정 선택, TOTP 성공, recovery 링크 완료, 인증 후 CRUD·동기화·오늘 할 일 알림 액션·SNS 실다운로드까지의 외부 서비스 E2E는 실행하지 않았다. 관련 상태·검증 로직, DB trigger/RLS, 미인증 gate와 화면 전환은 각각 자동·DB·에뮬레이터 테스트로 검증했다.
