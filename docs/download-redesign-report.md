# Morit 다운로드 재설계 결과

기준 시각: 2026-07-25 (Asia/Seoul)

## 결론

앱의 HTML/OG 태그 기반 추출 경로를 운영 다운로드 경로에서 제거하고, URL 분석부터
원본 수집, yt-dlp/Cobalt 처리, FFmpeg 병합·변환, 완료 검증까지 서버가 담당하도록
재설계했다. Flutter는 URL/공유 입력, 자산·품질 선택, 진행률과 결과 표시만 담당한다.
Android는 검증이 끝난 파일만 공용 미디어 폴더로 내려받는다.

코드, 백엔드 이미지, 서명 APK는 생성·검증됐다. 다만 현재
`config/local.json`에는 `DOWNLOAD_API_URL`이 없고 영구 공개 HTTPS 백엔드도 배포되지
않았다. 따라서 이번 APK는 설치·실행할 수 있는 백엔드 준비형 빌드이며, 다운로드 탭은
서버 배포 전에는 "다운로드 서버가 설정되지 않았습니다"라고 정확히 중단한다. 임시
터널이나 개발 우회 인증을 APK에 넣어 완료로 가장하지 않았다.

## 기존 실패 원인

1. 플랫폼 이름 목록은 많았지만 실제 추출기는 Bluesky·직접 파일·정적 HTML 일부에
   불과했다. 기존 Supabase `morit-download` Edge Function도 프록시 비활성 상태로
   `410 proxy_disabled`를 반환했다.
2. OG/JSON-LD 파싱은 JavaScript, 서명 URL, 세션, HLS/DASH 자산과 영상·오디오
   병합을 처리할 수 없다. 그 결과 썸네일·아이콘·미리보기 리소스를 원본으로 오인하거나
   캐러셀 첫 장만 반환했다.
3. 앱이 원본 CDN URL을 직접 선검사하고 다시 DownloadManager에 넘겨 서명 URL을
   소모하거나 만료시키는 경쟁 조건이 있었다. 필요한 쿠키·헤더가 유지되지 않는
   플랫폼도 있었다.
4. 적응형 영상의 영상/오디오 스트림을 병합하지 않고 MIME·확장자를 추정해 저장해
   0바이트, HTML 오류 문서, 잘못된 컨테이너 또는 무음 파일이 완료로 남을 수 있었다.
5. 서버 준비 단계와 기기 전송 단계를 구분하지 않아 Android
   `STATUS_PENDING`이 "시스템에서 시작을 준비하고 있습니다"로 무한 표시됐다.
6. 앱 전용 저장소 또는 잘못된 공용 경로를 사용한 이전 파일은 갤러리와 내 파일에서
   발견되지 않았다.

## 구현한 파이프라인

1. 공유 링크와 다운로드 탭의 직접 입력을 동일한
   `DownloadBackendClient.analyzeDetailed` 경로로 보낸다.
2. 서버가 URL 형식, 허용 도메인, 공개 DNS와 사용자 Supabase 세션을 검증한다.
3. yt-dlp를 기본 분석 엔진으로 사용하고, 설정된 자체 호스팅 Cobalt를 보조 분석
   엔진으로 사용한다. 분석 결과에는 원본 URL이나 실행 인자 대신 불투명한
   `analysis_id`, `selection_id`, `asset_id`만 반환한다.
4. 사진 캐러셀은 자산마다 하나를 기본 선택하고, 영상·오디오는 자산당 한 품질만
   선택한다. 개별 선택/해제와 `모두 선택`을 지원한다.
5. 선택한 엔진과 자산 ID를 작업에 고정한다. 실패했다고 다른 엔진의 비슷한 자산으로
   조용히 바꾸지 않으므로 잘못된 게시물 파일을 받을 수 없다.
6. yt-dlp가 정확한 포맷 ID를 내려받고 FFmpeg가 병합·리먹싱·오디오 변환을 수행한다.
   임시 파일은 작업별 비공개 디렉터리에 저장한다.
7. 서버가 Content-Type, Content-Length, 최대 크기, ffprobe 스트림, 영상+오디오
   병합 결과의 오디오 존재 여부와 FFmpeg 전체 디코딩을 검증한다. 검증을 통과한
   파일만 원자적으로 `ready` 디렉터리에 공개하며 실패·취소 파일은 삭제한다.
8. Android API 29 이상은 영속 JobScheduler가 불투명 transfer ticket으로 서버
   상태를 이어서 확인한다. 완료 후 DownloadManager에 최종 파일 URL, MIME, 이름과
   검증된 Content-Length만 전달한다. API 29 미만 fallback도 같은 길이 검증을 한다.
9. 기기 완료 단계에서 실제 파일 크기, 매직 바이트, 컨테이너 트랙과 사용 가능한
   디코더를 다시 확인한다. 실패 파일은 제거한다.
10. 파일은 종류별로 `Pictures/Morit`, `Movies/Morit`, `Music/Morit`,
    `Download/Morit`에 저장되어 갤러리 또는 내 파일에서 확인할 수 있다.

## 엔진과 오류 처리

- `Selection.engine`으로 yt-dlp, Cobalt, Instagram 원본 이미지 작업을 분리했다.
  분석기·다운로더 함수와 단일 작업 dispatcher 경계가 있어 새 엔진은 선택 생성과
  작업 handler만 추가하면 된다.
- yt-dlp/Cobalt/validator 오류는 `platform`, `engine`, `code`, `stage`,
  `retryable`, 공개 `log_id`를 유지한다. Flutter도 이 진단 ID를 숨기지 않는다.
- 다운로드 취소는 서버 프로세스 트리, 임시 파일, Android JobScheduler와
  DownloadManager를 함께 정리한다. 사용자 재시도는 원본 링크를 다시 분석해 만료된
  서명 URL을 재사용하지 않는다.
- Cobalt 11은 downloader와 전용 Docker bridge만 공유하고 host port를 노출하지
  않으며 `read_only`와 `init`을 사용한다. 내부 HTTP 예외는 정확히
  `http://cobalt:9000` 하나뿐이다.
- Cobalt가 반환한 파일 URL은 구성된 동일 origin 또는 공개 DNS의 HTTPS만 허용한다.
  cross-origin redirect에는 Cobalt API key를 전달하지 않는다.

## Instagram 사진 수정

yt-dlp의 Instagram extractor가 이미지 캐러셀 entry에 `formats` 없이 원본 후보를
`thumbnails`로 반환하는 실제 동작을 별도 처리했다. Instagram에만 한정해
`instagram.<region>.fna.fbcdn.net`, HTTPS/443, 이미지 확장자, 중복 없는
`oh`/`oe`/`ig_cache_key`, resize/crop 변환이 없는 서명 URL만 원본으로 허용한다.
분석에서 받은 서명 URL로 즉시 스트리밍하고, 만료·전송 실패 시에만 동일 entry ID와
playlist index를 다시 분석해 서명을 갱신한다. 각 redirect마다 URL과 공개 DNS를
다시 검증한다. 일반 영상 entry는 계속 yt-dlp가
처리하므로 혼합 캐러셀의 영상 경로를 덮어쓰지 않는다.

## 2026-07-25 성능 최적화

- 앱은 동일 계정·URL의 성공한 분석을 10분간 최대 20건 캐시하고 HTTP 연결을
  재사용한다. 서버도 사용자별 분석을 기존 15분 TTL 안에서 재사용하므로 캐시 적중
  요청은 yt-dlp/Cobalt를 다시 실행하지 않는다.
- 다운로드 상태 저장은 오늘 할 일 알림 재생성과 분리해, 작업 생성 전에 무관한
  네이티브 알림 동기화를 기다리지 않는다.
- Instagram, X, Facebook, Threads, TikTok은 Cobalt를 먼저 사용하고 실패할 때만
  yt-dlp로 전환한다. YouTube는 품질 목록을 보존하기 위해 yt-dlp를 우선한다.
- Cobalt/Instagram 파일은 분석 응답의 미디어 URL로 바로 스트리밍하고, 재시도 가능한
  실패가 발생한 경우에만 URL을 갱신한다. 256 KiB 청크와 Android DownloadManager
  저장 경로는 유지해 전체 파일의 메모리 복사를 만들지 않는다.
- FFmpeg 완료 검증은 전체 재디코딩 대신 전체 패킷 demux/stream-copy 검증으로
  변경했다. ffprobe의 컨테이너·코덱·스트림 검증과 Content-Length 검증은 유지한다.
- Android JobService는 한 번 조회 후 최소 10초 재예약하던 흐름을 제거하고,
  처음 두 번 750ms, 이후 2초 간격으로 활성 작업을 이어서 확인한다. 서버 준비
  단계부터 ongoing 진행 알림을 표시하고 여러 작업이면 남은 작업 수도 표시한다.
  DownloadManager가 실제 파일 저장을 넘겨받으면 시스템 진행 알림으로 전환한다.
- 완료 알림에는 파일 열기, 시스템 다운로드 목록 열기, 공유 액션을 제공한다.
  후보 크기가 0 또는 미확인이면 `0B` 대신 `계산 중`으로 표시하고, 서버 또는
  DownloadManager가 실제 크기를 확인하면 다운로드 기록에 자동 반영한다.

동일 Oracle E2 Micro, 동일 공개 fixture에서 `time.perf_counter`로 측정했다.

| 구간 | 이전 | 최적화 후 |
|---|---:|---:|
| Instagram 5장 게시물 최초 분석 | 9.462초 | 0.980초 |
| Instagram 동일 URL 재분석 | 9.462초 수준 | 0.002초 |
| Instagram 첫 사진 서버 작업 완료 | 1.614초 | 중앙값 0.713초 (0.872/0.713/0.691) |
| YouTube 품질 목록 최초 분석 | 19.973초 | 17.011초 |
| YouTube 동일 URL 서버 재조회 | 19.973초 수준 | 0.078초 |
| Android 서버 완료 감지 간격 | JobScheduler 최소 10초 | 활성 작업 최대 약 2초 |

YouTube 최초 분석은 yt-dlp의 JavaScript challenge와 품질 열거가 지배하므로 네트워크
상태에 따라 변동한다. 품질 선택을 없애고 Cobalt 단일 최고 화질만 반환하는 방식은
요구사항을 훼손하므로 적용하지 않았다. 앱 캐시 적중 시에는 위 78ms 서버 호출도 없다.

## 보안 점검

- APK에는 공개 Supabase publishable/anon key와 공개 백엔드 origin만 들어갈 수 있다.
  `sb_secret_`, `service_role` key, Cobalt API key, 쿠키와 서버 비밀값은 빌드 설정과
  저장소에서 제외했다.
- 분석·작업 API에는 현재 Supabase access token을 사용하지만 Android
  DownloadManager에는 전달하지 않는다. 기기 전송에는 수명이 제한된 불투명 ticket만
  사용한다.
- 서버/transfer/file URL은 HTTPS, no-userinfo, same-origin 규칙을 적용한다. 응답
  크기와 리디렉션도 제한한다.
- 최종 APK 검사: `sb_secret_` 0, service-role JWT 0, private key 0,
  `.env`/`key.properties`/keystore ZIP entry 0, JWT 1개는 role=`anon`이다.
- 초기 URL과 직접 HTTP client 경로는 애플리케이션에서 공개 DNS를 확인한다. 다만
  yt-dlp subprocess가 내부에서 따라가는 2차 URL까지 앱 코드가 가로챌 수는 없으므로,
  운영 배포에서는 RFC1918, loopback, link-local, 클라우드 metadata 대역에 대한
  egress 방화벽 차단이 필수다.

## 실제 공개 URL 검증

2026-07-25에 Docker 백엔드에서 수행했다.

| 플랫폼/fixture | 결과 |
|---|---|
| YouTube `dQw4w9WgXcQ` | 240p MP4, 5,693,562 bytes, 영상+오디오 병합, ffprobe와 전체 디코딩 통과 |
| X 공개 게시물 | MP4 57,279 bytes, Range 206, 전체 파일 검증 통과 |
| SoundCloud 공개 트랙 | M4A 8,013,076 bytes, Range 206, 전체 디코딩 통과 |
| Instagram `DaBUYYOjNgA` | 사진 5개 분석·다운로드, 모두 WebP 1440×1800, 38,070/25,536/28,280/26,020/59,442 bytes, Content-Length 일치, SHA-256 5개 모두 다름 |
| Instagram `DZh1sR_NqWR` | 단일 JPEG 1개, 1448×1931, 512,158 bytes, 전체 디코딩 통과 |
| Instagram `DZpodR4At9k` | 사진 자산 5개 분석 |
| Instagram `BQ0eAlwhDrw` | 영상 자산 3개 분석 |
| Instagram Reel `Chunk8-jurw` | 자산 1개, 영상 품질 2개 분석 |
| Instagram Highlight `18090946048123978` | 자산 59개, 영상/오디오 선택 172개 분석 |
| Instagram Story 공개 fixture | 플랫폼이 익명 요청에 로그인을 요구해 `AUTH_REQUIRED`와 log ID 반환 |
| Cobalt 11.7.1 + `DaBUYYOjNgA` | picker 사진 5개, 첫 WebP 다운로드·전체 디코딩 통과 |

과거 사진+영상 mixed fixture는 현재 Instagram이 익명 접근을 제한해 live 성공으로
기록하지 않았다. 혼합 entry가 이미지=`instagram-image`, 영상=`yt-dlp`로 분리되는
회귀 테스트만 통과했다.

## 자동·빌드·Android 검증

- `flutter analyze`: 오류 0
- `flutter test`: 61/61 통과
- Android Kotlin 컴파일: 통과
- Android JVM 단위 테스트: 5/5 통과
- `python -m py_compile app.py test_app.py`: 통과
- `python test_app.py`: URL trust, selection, 디코딩, HEAD/Range, 재시작 보존,
  retention 테스트 통과
- `docker compose config --quiet`: 통과
- 최종 downloader Docker 이미지 빌드: 통과
- Cobalt compose: 공식 `ghcr.io/imputnet/cobalt:11`, host port 없음,
  `read_only=true`, `init=true`, health 통과
- 릴리스 APK: v2/v3 서명 통과, Android 17/API 37 에뮬레이터에 `adb install -r`
  성공, 버전 `1.5.0+8`, 콜드 실행 fatal crash 0
- APK SHA-256:
  `BA48DC68E5AE227775FB95BF4EBCE28ED6171047DFB64A0834B374AFC1E9C7ED`

## Oracle Always Free 배포

- 도쿄 홈 리전에 `VM.Standard.E2.1.Micro`(1 OCPU, 1 GB)와 기본 46.6 GB
  부트 볼륨을 배포했다. 두 자원 모두 Always Free 한도 안이며 유료 계정 업그레이드,
  유료 로드 밸런서, 유료 DNS는 사용하지 않았다.
- A1 Flex 1 OCPU/6 GB는 도쿄 AD-1 용량 부족으로 두 번 거절되어 자원이 생성되지
  않았다. 즉시 사용 가능한 E2 Micro로 전환하고 2 GB swap을 추가했다.
- 백엔드는 GitHub `MoringLab/morit`의 `2010bd0`을 사용한다. downloader는
  `127.0.0.1:8080`에만 바인딩하고 Cobalt는 Docker 내부 네트워크에만 노출한다.
- Caddy가 무료 `sslip.io` 호스트명으로 Let's Encrypt 인증서를 자동 갱신하며
  80은 443으로 리디렉션한다. OCI 보안 목록과 서버 iptables는 22/80/443만
  인바운드 허용한다.
- 공개 `/health`에서 yt-dlp, yt-dlp-ejs, Deno, FFmpeg/ffprobe, Cobalt가 모두
  `true`임을 확인했고, 인증 없는 `/v1/analyze`는 401을 반환했다.
- 무료 VM 메모리 한계 때문에 동시 분석과 다운로드를 각각 1개로 제한했다.
  Docker와 Caddy는 부팅 자동 시작, 두 컨테이너는 `unless-stopped`로 설정했다.
- Docker JSON 로그는 컨테이너당 10 MB × 3개로 회전한다. 서버 전체 재부팅 후
  2 GB swap, 22/80/443 iptables 규칙, Docker, Caddy, downloader와 Cobalt가
  자동 복구되고 외부 HTTPS health가 다시 정상 응답하는 것을 확인했다.

## 남은 외부 조건과 제약

1. **물리 기기 미검증:** 현재 연결 대상은 Android 17/API 37 에뮬레이터뿐이다.
   삼성 One UI 물리 기기의 갤러리/내 파일 노출, 절전·재부팅, 실제 재생과 장시간
   백그라운드 작업은 아직 통과로 주장할 수 없다.
2. **앱 E2E 미검증:** 로그인 테스트 계정이 없어 Flutter 앱에서
   분석→품질 선택→다운로드→외부 앱 재생 전체 흐름은 물리 기기에서 수행하지 못했다.
   배포 endpoint의 공개 health/TLS/인증 차단과 Android 저장 계층 자동 검증은
   각각 통과했다.
3. **무료 VM 처리량:** E2 Micro는 동시 1개 작업용이다. 여러 사용자가 동시에
   다운로드하거나 고화질 변환이 잦아지면 A1 Always Free 용량 확보 후 이전해야 한다.
4. **인증/DRM 우회 없음:** 로그인·쿠키가 필요한 Story, 비공개 게시물, DRM,
   지역 제한은 정확한 실패로 반환한다. 사용자 쿠키나 플랫폼 토큰을 APK/서버에
   저장하는 우회는 구현하지 않았다.
5. **코덱:** 최고 화질이 VP9/AV1뿐인 콘텐츠는 구형 Android에서 디코더가 없을 수
   있다. 현재는 깨진 완료로 남기지 않고 기기 검증 단계에서 실패시킨다. 구형 기기까지
   강제 호환해야 할 때 H.264/AAC 트랜스코딩 옵션과 서버 용량 정책을 추가해야 한다.
6. **단일 worker:** 현재 작업 상태는 단일 프로세스와 `/data`에 맞춰져 있다. 여러
   인스턴스로 확장할 때 공유 큐와 객체 스토리지가 필요하다.
7. **iOS:** 백엔드 API와 Flutter 선택/상태 모델은 공통으로 사용할 수 있다.
   Android JobScheduler/DownloadManager에 대응하는 iOS background URLSession,
   Share Extension과 Files/Photos 저장 구현 및 iOS 기기 검증은 후속 작업이다.

## 참고한 공식 구현

- [Cobalt 인스턴스 운영 문서](https://github.com/imputnet/cobalt/blob/main/docs/run-an-instance.md)
- [Cobalt API 문서](https://github.com/imputnet/cobalt/blob/main/docs/api.md)
- [yt-dlp README](https://github.com/yt-dlp/yt-dlp/blob/master/README.md)
- [yt-dlp Instagram 이미지 캐러셀 이슈](https://github.com/yt-dlp/yt-dlp/issues/17077)
