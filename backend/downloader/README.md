# Morit downloader backend

Morit의 Flutter 앱에서 미디어 추출을 제거하고 `yt-dlp`와 FFmpeg를 서버에서
실행하는 단일 프로세스 API입니다. 분석 결과의 불투명한 `selection_id`만 다시
받기 때문에 앱에서 임의의 yt-dlp 포맷 문자열, 실행 인자 또는 원본 미디어 URL을
주입할 수 없습니다.

## 실행

```bash
docker build -t morit-downloader backend/downloader
docker run --rm -p 8080:8080 \
  -e SUPABASE_URL=https://PROJECT.supabase.co \
  -e SUPABASE_PUBLISHABLE_KEY=PUBLIC_KEY \
  -e PUBLIC_BASE_URL=https://download.example.com \
  -v morit-downloads:/data \
  morit-downloader
```

운영 환경에서는 HTTPS 리버스 프록시 뒤에 두고 `/data`를 임시 볼륨으로
마운트합니다. 이 구현은 진행률과 취소 상태를 메모리에 보유하므로 Dockerfile처럼
worker를 1개만 실행합니다. 여러 인스턴스가 필요해질 때만 공유 작업 큐와 객체
스토리지로 옮겨야 합니다.

리버스 프록시의 access log에서는 `/v1/files`와 `/v1/transfers` 쿼리 문자열을
반드시 제거합니다. Docker 기본 명령도 파일 티켓이 로그에 남지 않도록 Uvicorn
access log를 끕니다. yt-dlp 컨테이너의 외부 통신은 배포 방화벽에서 loopback,
RFC1918, link-local 및 클라우드 metadata 대역으로 나가지 못하게 제한합니다.

필수 환경 변수:

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY` 또는 기존 `SUPABASE_ANON_KEY`

주요 선택 환경 변수:

- `COBALT_API_URL`, `COBALT_API_KEY`: 접근 권한이 있는 자체 호스팅 Cobalt
- `PUBLIC_BASE_URL`: 앱에 반환할 다운로드 API의 외부 HTTPS origin
- `DOWNLOAD_ALLOWED_HOSTS`: 기본 플랫폼 외 허용할 도메인(쉼표 구분)
- `MAX_CONCURRENT_JOBS`(실행 기본 2), `MAX_ACTIVE_JOBS_PER_USER`(대기 포함 기본 60)
- `MAX_JOBS`(활성 작업 기본 200), `MAX_RETAINED_JOBS`(완료 기록 기본 1000)
- `MAX_RETAINED_BYTES`(완료 파일 보관 한도 기본 20 GiB)
- `MAX_ANALYSES_PER_MINUTE`(계정당 기본 20)
- `MAX_RETAINED_JOBS_PER_USER`(기본 200), `MAX_RETAINED_BYTES_PER_USER`(기본 10 GiB)
- `MAX_CONCURRENT_ANALYSES`(기본 4), `MAX_PLAYLIST_ITEMS`(기본 60)
- `MAX_ANALYZE_OUTPUT_BYTES`(기본 64 MiB)
- `MAX_FILE_BYTES`(기본 2 GiB), `VALIDATION_TIMEOUT_SECONDS`(기본 600)
- `ANALYSIS_TTL_SECONDS`(기본 900), `FILE_TTL_SECONDS`(기본 604800/7일)
- `YT_DLP_JS_RUNTIME`: `deno`(기본), `node`, `quickjs`
- `YT_DLP_FORCE_IPV6=true`: IPv6가 구성된 배포에서 YouTube yt-dlp 연결을 IPv6로 강제
- `DEV_AUTH_BYPASS=true`: 로컬 테스트 전용. 이때도 `Bearer dev-local`이 필요함

`DEV_AUTH_BYPASS`는 운영에서 절대 활성화하지 않습니다. Supabase의 service-role
키나 Cobalt API 키는 앱 번들에 넣지 않고 이 서버 환경 변수에만 둡니다.

## API

- `POST /v1/analyze` — `{ "url": "https://..." }`
- `POST /v1/jobs` — `{ "analysis_id": "...", "selection_id": "...", "request_id": "..." }`
- `GET /v1/jobs/{id}` — 상태와 진행률
- `DELETE /v1/jobs/{id}` — 취소
- `GET /v1/transfers/{id}?ticket=...` — Android 백그라운드 전달용 상태
- `GET|HEAD /v1/files/{id}?ticket=...` — 검증된 완료 파일, Range 지원

파일 티켓은 충분히 긴 난수이며 완료 후 기본 7일(`FILE_TTL_SECONDS`) 동안 재시도와 Range
요청에 재사용할 수 있습니다. 분석·작업 API는 Supabase access token을
`Authorization: Bearer ...`로 요구합니다.
단, `MAX_RETAINED_JOBS` 또는 `MAX_RETAINED_BYTES` 한도에 먼저 도달하면 가장
오래된 완료 파일부터 제거됩니다. 운영 볼륨 크기에 맞춰 이 두 값을 조정하십시오.

## 동작과 보안 경계

- HTTPS, 사용자 정보 없는 URL, 허용 도메인, 공개 DNS 주소만 받습니다.
- yt-dlp는 `--ignore-config`, 인자 배열, `shell=False`로 실행하며 쿠키·netrc·사용자
  설정을 읽지 않습니다.
- 분석 개수, 플레이리스트 항목, 프로세스 출력, 실행 시간, 동시 작업 수, 파일
  크기와 리디렉션 횟수를 제한합니다.
- `.part` 파일은 공개하지 않습니다. 완료 후 ffprobe로 스트림과 컨테이너를
  확인하고 FFmpeg로 파일 끝까지 실제 디코딩합니다. 검증된 MIME/확장자로
  원자적으로 ready 디렉터리로 이동하며 실패·취소 파일은 삭제합니다.
- 로그에는 전체 입력 URL, 쿼리 토큰, bearer, Cobalt 키를 남기지 않습니다.
- 완료 파일과 ticket 메타데이터는 `/data`에 원자적으로 기록되어 단일 인스턴스
  재시작 뒤에도 남은 보관 기간 동안 다시 받을 수 있습니다. 실행 중이던 부분
  다운로드는 재시작 시 안전하게 폐기하고 앱의 재시도로 새 작업을 만듭니다.

Cobalt의 공식 호스팅 API는 봇 보호가 적용되어 있고 제3자 앱 용도로 제공되지
않습니다. `api.cobalt.tools`를 기본값으로 사용하지 말고, Cobalt 문서에 따라
직접 운영하거나 인스턴스 소유자의 명시적 허가를 받은 주소만 설정하십시오.
분석 결과마다 사용할 엔진을 고정하며, yt-dlp 실패 시 다른 자산이나 품질을
조용히 내려받지 않습니다. Cobalt는 해당 엔진으로 분석되어 선택된 결과에만
사용됩니다.

공개 콘텐츠라도 플랫폼이 로그인·쿠키·PO token을 요구하면 `AUTH_REQUIRED` 등
실제 오류를 반환합니다. 사용자 쿠키를 APK나 이 API에 임의 저장하는 우회는
포함하지 않았습니다.

## 확인

Docker 이미지는 공식 Deno 2.9.4 바이너리와 PyPI의 `yt-dlp[default]`
(`yt-dlp-ejs` 포함)을 사용합니다. 호스트 테스트 시에도 Python, yt-dlp,
yt-dlp-ejs, FFmpeg와 Deno 2.3+ 또는 Node 22+가 있어야 YouTube EJS 경로까지
동일하게 검증됩니다.

```bash
cd backend/downloader
python test_app.py
```

테스트는 URL 신뢰 경계, 품질 선택의 asset 그룹, 캐러셀 개별 asset, ffprobe
완료 검증, 파일 HEAD/Range를 확인합니다.

## 선택적 Cobalt compose

`compose.yaml`은 공식 `ghcr.io/imputnet/cobalt:11`과 downloader를 같은
Docker bridge에 실행합니다. Cobalt는 호스트에 포트를 공개하지 않으며 downloader만
`http://cobalt:9000`으로 접근합니다. Cobalt 컨테이너는 init 프로세스와
read-only root filesystem으로 실행됩니다.

```bash
cd backend/downloader
cp .env.example .env
# .env의 Supabase와 PUBLIC_BASE_URL 값 설정
docker compose up -d --build
```

`.env`, `cobalt-keys.json`, `cookies.json`, `secrets/`는 Git과 Docker build
context에서 제외됩니다. `.env.example`에는 placeholder만 있으며 실제 API key나
쿠키를 저장하지 않습니다. compose 내부 Cobalt는 외부 포트가 없으므로 API key를
요구하지 않습니다. Cobalt를 별도 서버로 노출할 때만 HTTPS, Cobalt 인증, 방화벽을
구성하고 `COBALT_API_KEY`를 런타임 secret으로 전달하십시오.

downloader의 HTTP 예외는 정확히 `http://cobalt:9000` origin에만 적용됩니다.
`localhost`, IP 주소, 다른 포트와 다른 private HTTP 호스트는 계속 거부됩니다.
Cobalt가 반환한 파일 URL은 구성된 Cobalt와 same-origin이거나 공개 DNS로 확인된
HTTPS일 때만 허용되며, origin이 바뀌는 redirect에는 Cobalt API key를 전달하지
않습니다.

Cobalt는 보조 엔진입니다. yt-dlp의 Instagram extractor가 반환한 단일 root 또는
각 carousel entry를 독립적으로 판정합니다. format·직접 URL·확장자·재생 시간이
없는 이미지 entry에서만, 서명된 `instagram.*.fna.fbcdn.net` 원본 후보가 정확히
하나일 때 `instagram-image`로 처리합니다. 변환 파라미터가 없거나 crop/resize가
없는 원본 변환만 허용합니다. mixed carousel의 정상 video/audio entry는 그대로
yt-dlp 선택으로 유지합니다. 작업 시 동일 entry ID·index를 다시 분석해 서명 URL을
갱신하고 Content-Type, Content-Encoding, Content-Length, 공개 DNS, FFprobe와 FFmpeg
전체 디코딩을 검증합니다. 일반 영상 thumbnail은 이 경로로 승격하지 않습니다.

검증 fixture `https://www.instagram.com/p/DaBUYYOjNgA/`는 2026-07-25 기준:

- yt-dlp 단독: 5개 `instagram-image`, 각각 WebP, 서로 다른 SHA-256, 전체 디코딩 통과
- Cobalt 11.7.1: `picker`, `photo` 5개

단일 이미지 fixture `https://www.instagram.com/p/DZh1sR_NqWR/`도 yt-dlp
단독으로 JPEG 1개(1448×1931, MJPEG) 분석·다운로드·전체 디코딩을 통과했습니다.
mixed carousel은 image entry와 정상 video entry가 각각 `instagram-image`와
`yt-dlp`로 남는 회귀 테스트를 포함합니다. 과거 공개 mixed fixture는 현재
Instagram의 익명 접근 제한으로 live 회귀에 사용할 수 없어 통과로 기록하지
않습니다.

작업이 생성된 뒤에는 yt-dlp 작업을 Cobalt로 자동 교체하지 않습니다. 재시도 시에도
분석에서 선택된 engine과 asset identity를 유지합니다.
