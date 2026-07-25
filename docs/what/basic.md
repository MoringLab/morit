# Morit — 프로젝트 상세 분석

## 한 줄 요약

**Morit**은 Android에서 링크·메모·사진·영상·파일을 하나의 앱으로 수집·저장·다운로드하는 Flutter 기반 개인 캡처·스토리지 앱입니다.

---

## 기본 정보

| 항목 | 내용 |
|------|------|
| 앱 이름 | **Morit** (`morit`) |
| 버전 | `1.5.0+8` |
| 플랫폼 | Android-first (Flutter, iOS 지원 준비 중) |
| 언어 | Dart (Flutter) + Kotlin (Android 네이티브) + Python (백엔드) |
| Dart SDK | `^3.11.5` |
| 최신 빌드 | `2026-07-25T16:18:24+09:00` — APK 크기 약 56.6 MB |
| 배포 APK | `dist/morit-release.apk` (v2/v3 서명, Android 17 에뮬레이터 검증 완료) |

---

## 앱의 목적과 핵심 기능

### 🗂️ 개인 캡처·스토리지 (메인)

- Android **공유 메뉴**에서 링크·메모·사진·영상·파일을 수신해 저장
- **폴더** 계층으로 항목 분류, 드래그 앤 드롭 계층 이동 트리 지원
- 파일·메모 길게 누르면 이동 트리 열림 → 머무름 자동 펼침, 가장자리 자동 스크롤, 실행 취소

### ⬇️ 미디어 다운로드

- **yt-dlp + FFmpeg** 기반 서버에서 YouTube, Instagram, X, SoundCloud 등 미디어 분석·다운로드
- Flutter는 URL 입력·품질 선택·진행 표시만 담당, 실제 추출/병합/검증은 서버에서 수행
- 진행률: 분석 → 원본 다운로드 → 병합 → 변환 → 검증 단계별 표시
- 완료 파일은 `Pictures/Morit`, `Movies/Morit`, `Music/Morit`, `Download/Morit`에 저장
- 선택적 self-hosted **Cobalt** fallback 지원

### ✅ 오늘 할 일 (Today)

- 앱 홈에 최대 3개 표시, 앱·알림에서 동일한 중앙 모달로 접근
- 완료 항목은 노란 형광펜 애니메이션과 함께 당일 표시, 다음 날 자동 제거
- 잠금화면 편집: 기기 잠금 해제 / 잠금 해제 없이 허용 / Morit PIN 중 선택

---

## 기술 스택

### Flutter 앱 (Dart)

| 패키지 | 용도 |
|--------|------|
| `supabase_flutter ^2.16.0` | 인증 + DB + Storage 백엔드 |
| `flutter_secure_storage ^10.3.1` | Android Keystore 기반 세션/PIN 저장 |
| `file_picker ^11.0.2` | 파일 첨부 선택 |
| `url_launcher ^6.3.2` | 외부 링크 열기 |
| `uuid ^4.6.0` | 항목 ID 생성 |
| `shared_preferences ^2.5.5` | 로컬 설정 저장 |

### 백엔드 (Python)

- **Flask** 기반 다운로드 서버 (`backend/morit-download/app.py`, ~88 KB)
- Docker Compose로 배포 (`compose.yaml`, `Dockerfile`)
- yt-dlp + FFmpeg 파이프라인
- Supabase 세션 검증 후 인증된 사용자만 다운로드 허용
- 지원 도메인·공개 IP·시간·크기·사용자별 동시 작업 수 제한

### 데이터베이스 (Supabase)

- Supabase PostgreSQL + Row Level Security (RLS)
- 11개 마이그레이션 (`202607230001` ~ `202607230011`)
- Edge Function 포함
- 신규 프로젝트: `supabase/baseline/morit_schema.sql` → 마이그레이션 순서대로 적용

---

## 프로젝트 구조

```
moring_allin1_app/
├── lib/
│   ├── auth/                   # 재사용 인증 모듈 (Moring 브랜드 공통)
│   │   ├── auth_controller.dart    # 로그인·가입·OTP·MFA·복구 로직
│   │   ├── auth_models.dart        # 인증 관련 데이터 모델
│   │   ├── auth_widgets.dart       # 인증 UI 위젯
│   │   └── moring_auth.dart        # 공개 export (다른 앱에서 재사용)
│   ├── core/                   # 빌드 설정 + Keystore 기반 Supabase 세션 저장소
│   ├── morit/
│   │   ├── data/
│   │   │   ├── morit_models.dart           # 폴더·항목·첨부 데이터 모델
│   │   │   └── morit_attachment_store.dart # Storage 업로드·다운로드
│   │   ├── media/              # 다운로드 백엔드 클라이언트 + 미디어 선택 모델
│   │   ├── platform/
│   │   │   └── morit_platform.dart  # Flutter↔Kotlin 타입 경계
│   │   ├── today/
│   │   │   └── today_overlay.dart   # 오늘 할 일 공통 모달
│   │   ├── morit_controller.dart    # 로컬 캐시·동기화·유스케이스 조정 (130 KB!)
│   │   └── folder_drop_tree.dart    # 계층 이동 드래그 트리
│   └── main.dart               # Material UI + 의존성 조립 (157 KB!)
├── android/                    # Kotlin: 공유 수신·DownloadManager·알림·잠금화면
├── supabase/
│   ├── baseline/               # 신규 프로젝트용 전체 스키마
│   ├── migrations/             # 11개 증분 SQL 마이그레이션
│   └── functions/              # Supabase Edge Functions
├── backend/
│   └── morit-download/         # Python Flask 다운로드 서버
│       ├── app.py              # 메인 서버 (~88 KB, yt-dlp + FFmpeg)
│       ├── Dockerfile
│       ├── compose.yaml
│       └── test_app.py         # 서버 테스트
├── config/                     # local.json.example (Supabase URL/키 설정)
├── dist/
│   ├── morit-release.apk       # 배포용 릴리스 APK (56.6 MB)
│   └── build-info.txt          # 빌드 메타데이터 및 검증 결과
└── docs/
    ├── app_logo.png / app_logo_transparent.png
    ├── security-audit.md       # 보안 감사 결과
    └── download-redesign-report.md
```

---

## 보안 설계

| 영역 | 내용 |
|------|------|
| 세션 저장 | Android Keystore 기반 암호화 저장소 |
| RLS | 온보딩 완료 + 필요 시 AAL2 MFA까지 DB에서 검증 |
| 공개 프로필 | PII 없는 `profile_directory` 뷰만 공개 |
| 클라우드 백업 | Android 백업·기기 이전·cleartext HTTP 차단 |
| 딥링크 | `morit://auth/callback` 하나만 허용 |
| Morit PIN | 연속 5회 실패 시 30초 잠금, 로컬에만 저장 |
| 다운로드 보안 | DownloadManager에 Supabase 토큰 미전달, 단기 opaque ticket URL만 전달 |
| APK 시크릿 스캔 | `sb_secret_0`, `service_role_jwt_0`, `private_keys_0` — 모두 0건 검출 |

---

## 파일 업로드 정책

| 파일 크기 | 방식 |
|-----------|------|
| ≤ 6 MiB | 표준 단일 업로드 |
| > 6 MiB | TUS 프로토콜, 6 MiB 청크 + offset 복구 |

- 원본 파일명은 DB 메타데이터에 보존
- Storage 키 형식: `user_id/item_id/attachment_id/file.ext`
- 생성·수정 중 저장 전까지 변경 보류 (취소 시 기존 데이터 보존)

---

## 재사용 가능한 인증 모듈

`lib/auth/` 모듈은 **Moring 브랜드 앱 공통 인증 라이브러리**로 설계됐습니다.

```dart
// 다른 Moring 앱에서 재사용
import 'package:morit/auth/moring_auth.dart';

// MoringAuthConfig, MoringAuthController, MoringAuthGate 만 설정하면
// 같은 인증 정책 즉시 재사용 가능
```

---

## 빌드 및 배포

```powershell
# 로컬 설정 파일 준비
cp config/local.json.example config/local.json
# → Supabase URL, anon/publishable 키, DOWNLOAD_API_URL 입력

# 빌드
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define-from-file=config/local.json

# ADB 설치
& "$env:LOCALAPPDATA\Android\sdk\platform-tools\adb.exe" install -r .\dist\morit-release.apk
```

> **중요**: `service_role`, `sb_secret_`, Cobalt API key 등 서버 키는 APK에 포함 불가 (빌드 시 거부됨)

---

## 검증 결과 (최신 빌드 기준)

```
flutter_analyze ✓
flutter_test 60/60 ✓
backend_pycompile ✓
backend_test_app ✓
docker_compose_config ✓
docker_image_build ✓
android_unit 5/5 ✓
compileDebugKotlin ✓
release_install ✓
cold_launch ✓
검증 기기: Android 17 에뮬레이터 (API 37)
```

---

## iOS 지원 현황

현재 **Android-first** 설계이며, iOS는 같은 Dart 계약 위에:
- Share Extension
- Widget / Live Activity
- 파일 전송 구현

을 추가해야 합니다. Android의 ongoing 알림·잠금화면 Activity는 그대로 사용 불가.

---

## 프로젝트 맥락 (Luverse / Moring)

- 상위 폴더명 `Luverse_moring`으로 보아 **Luverse** 브랜드 하위 **Moring** 서비스군의 일부
- `moring_allin1_app` — Moring 서비스의 **모든 기능을 하나로 통합한 앱** (All-in-One)
- `moring_auth.dart` 공개 export로 다른 Moring 앱에서 인증 모듈 재사용 가능
- Git 커밋 내역은 없음 (현재 `main` 브랜치에 커밋 없음 — 로컬 작업 중)
