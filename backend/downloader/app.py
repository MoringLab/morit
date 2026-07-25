from __future__ import annotations

import asyncio
import hashlib
import hmac
import importlib.util
import ipaddress
import json
import logging
import mimetypes
import os
import re
import secrets
import shutil
import signal
import socket
import sys
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Annotated
from urllib.parse import parse_qsl, quote, urljoin, urlsplit, urlunsplit

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field


APP_DIR = Path(__file__).resolve().parent
DATA_DIR = Path(os.getenv("DATA_DIR", str(APP_DIR / "data"))).resolve()
JOB_DIR = DATA_DIR / "jobs"
JOB_DIR.mkdir(parents=True, exist_ok=True)

MAX_ANALYSES = int(os.getenv("MAX_ANALYSES", "200"))
MAX_JOBS = int(os.getenv("MAX_JOBS", "200"))
MAX_RETAINED_JOBS = int(os.getenv("MAX_RETAINED_JOBS", "1000"))
MAX_RETAINED_BYTES = int(
    os.getenv("MAX_RETAINED_BYTES", str(20 * 1024 * 1024 * 1024))
)
MAX_RETAINED_JOBS_PER_USER = int(os.getenv("MAX_RETAINED_JOBS_PER_USER", "200"))
MAX_RETAINED_BYTES_PER_USER = int(
    os.getenv("MAX_RETAINED_BYTES_PER_USER", str(10 * 1024 * 1024 * 1024))
)
MAX_ANALYSES_PER_MINUTE = int(os.getenv("MAX_ANALYSES_PER_MINUTE", "20"))
MAX_CONCURRENT_JOBS = int(os.getenv("MAX_CONCURRENT_JOBS", "2"))
MAX_ACTIVE_JOBS_PER_USER = int(os.getenv("MAX_ACTIVE_JOBS_PER_USER", "60"))
MAX_CONCURRENT_ANALYSES = int(os.getenv("MAX_CONCURRENT_ANALYSES", "4"))
MAX_FILE_BYTES = int(os.getenv("MAX_FILE_BYTES", str(2 * 1024 * 1024 * 1024)))
MAX_PLAYLIST_ITEMS = int(os.getenv("MAX_PLAYLIST_ITEMS", "60"))
MAX_ANALYZE_OUTPUT_BYTES = int(
    os.getenv("MAX_ANALYZE_OUTPUT_BYTES", str(64 * 1024 * 1024))
)
ANALYSIS_TTL_SECONDS = int(os.getenv("ANALYSIS_TTL_SECONDS", "900"))
FILE_TTL_SECONDS = int(os.getenv("FILE_TTL_SECONDS", "604800"))
ANALYZE_TIMEOUT_SECONDS = int(os.getenv("ANALYZE_TIMEOUT_SECONDS", "45"))
DOWNLOAD_TIMEOUT_SECONDS = int(os.getenv("DOWNLOAD_TIMEOUT_SECONDS", "1800"))
VALIDATION_TIMEOUT_SECONDS = int(os.getenv("VALIDATION_TIMEOUT_SECONDS", "600"))
YT_DLP_JS_RUNTIME = os.getenv("YT_DLP_JS_RUNTIME", "deno").lower()
if YT_DLP_JS_RUNTIME not in {"deno", "node", "quickjs"}:
    raise RuntimeError("YT_DLP_JS_RUNTIME must be deno, node, or quickjs")

SUPABASE_URL = os.getenv("SUPABASE_URL", "").rstrip("/")
SUPABASE_PUBLIC_KEY = (
    os.getenv("SUPABASE_PUBLISHABLE_KEY")
    or os.getenv("SUPABASE_ANON_KEY")
    or ""
)
DEV_AUTH_BYPASS = os.getenv("DEV_AUTH_BYPASS", "").lower() == "true"
COBALT_API_URL = os.getenv("COBALT_API_URL", "").rstrip("/")
COBALT_API_KEY = os.getenv("COBALT_API_KEY", "")
COBALT_COMPOSE_ORIGIN = "http://cobalt:9000"
PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "").rstrip("/")
if PUBLIC_BASE_URL:
    public_base = urlsplit(PUBLIC_BASE_URL)
    if (
        public_base.scheme != "https"
        or not public_base.hostname
        or public_base.username
        or public_base.password
        or public_base.query
        or public_base.fragment
        or public_base.path not in {"", "/"}
    ):
        raise RuntimeError("PUBLIC_BASE_URL must be an HTTPS origin without path or credentials")

logger = logging.getLogger("morit.downloader")
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logging.getLogger("httpx").setLevel(logging.WARNING)

DEFAULT_ALLOWED_HOSTS = {
    "youtube.com",
    "youtu.be",
    "x.com",
    "twitter.com",
    "instagram.com",
    "soundcloud.com",
    "facebook.com",
    "fb.watch",
    "threads.net",
    "threads.com",
    "tiktok.com",
    "bsky.app",
    "bluesky.app",
    "reddit.com",
    "redd.it",
    "pinterest.com",
    "pin.it",
    "snapchat.com",
    "linkedin.com",
    "lnkd.in",
    "tumblr.com",
    "twitch.tv",
    "vimeo.com",
    "dailymotion.com",
    "dai.ly",
    "discord.com",
    "discord.gg",
    "discordapp.com",
    "cdn.discordapp.com",
    "media.discordapp.net",
    "t.me",
    "telegram.me",
    "kakaostory.com",
    "story.kakao.com",
    "cafe.naver.com",
    "blog.naver.com",
    "band.us",
    "line.me",
    "medium.com",
    "substack.com",
    "wordpress.com",
    "behance.net",
    "flickr.com",
    "flic.kr",
    "imgur.com",
}
ALLOWED_HOSTS = DEFAULT_ALLOWED_HOSTS | {
    host.strip().lower().lstrip(".")
    for host in os.getenv("DOWNLOAD_ALLOWED_HOSTS", "").split(",")
    if host.strip()
}

IMAGE_EXTENSIONS = {"jpg", "jpeg", "png", "webp", "gif", "avif", "heic"}
VIDEO_EXTENSIONS = {"mp4", "m4v", "mov", "webm", "mkv", "avi", "ts"}
AUDIO_EXTENSIONS = {"m4a", "mp3", "aac", "opus", "ogg", "flac", "wav", "mka"}
COBALT_FIRST_PLATFORMS = {
    "facebook",
    "instagram",
    "threads",
    "tiktok",
    "x",
}
MIME_BY_EXTENSION = {
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "png": "image/png",
    "webp": "image/webp",
    "gif": "image/gif",
    "avif": "image/avif",
    "heic": "image/heic",
    "mp4": "video/mp4",
    "m4v": "video/x-m4v",
    "mov": "video/quicktime",
    "webm": "video/webm",
    "mkv": "video/x-matroska",
    "mka": "audio/x-matroska",
    "avi": "video/x-msvideo",
    "ts": "video/mp2t",
    "m4a": "audio/mp4",
    "mp3": "audio/mpeg",
    "aac": "audio/aac",
    "opus": "audio/ogg",
    "ogg": "audio/ogg",
    "flac": "audio/flac",
    "wav": "audio/wav",
}


class AnalyzeBody(BaseModel):
    url: str = Field(min_length=8, max_length=2048)


class JobBody(BaseModel):
    analysis_id: str = Field(min_length=8, max_length=100)
    selection_id: str = Field(min_length=8, max_length=100)
    request_id: str = Field(min_length=8, max_length=100)


@dataclass
class Selection:
    id: str
    asset_id: str
    kind: str
    label: str
    file_name: str
    mime_type: str
    extension: str
    width: int | None
    height: int | None
    bitrate: int | None
    size_bytes: int | None
    is_preview: bool
    recommended: bool
    engine: str
    format_selector: str | None = None
    playlist_item: int | None = None
    remote_url: str | None = None

    def public(self) -> dict[str, Any]:
        value = asdict(self)
        for key in ("engine", "format_selector", "playlist_item", "remote_url"):
            value.pop(key)
        return value


@dataclass
class Analysis:
    id: str
    user_id: str
    source_url: str
    provider: str
    title: str
    thumbnail_url: str | None
    selections: dict[str, Selection]
    created_at: float = field(default_factory=time.time)


@dataclass
class Job:
    id: str
    user_id: str
    request_id: str
    analysis_id: str
    selection: Selection
    source_url: str
    platform: str
    ticket: str
    status: str = "queued"
    stage: str = "queued"
    progress: float = 0.0
    error: dict[str, Any] | None = None
    file_path: Path | None = None
    file_name: str | None = None
    mime_type: str | None = None
    content_length: int | None = None
    created_at: float = field(default_factory=time.time)
    finished_at: float | None = None
    task: asyncio.Task[None] | None = None
    process: asyncio.subprocess.Process | None = None
    cancel_requested: bool = False


class EngineFailure(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        engine: str,
        platform: str,
        retryable: bool = False,
        raw: str = "",
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.engine = engine
        self.platform = platform
        self.retryable = retryable
        self.raw = raw
        self.log_id = uuid.uuid4().hex[:12]

    def public(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "message": self.message,
            "engine": self.engine,
            "platform": self.platform,
            "retryable": self.retryable,
            "log_id": self.log_id,
        }


analyses: dict[str, Analysis] = {}
jobs: dict[str, Job] = {}
auth_cache: dict[str, tuple[str, float]] = {}
analysis_history: dict[str, list[float]] = {}
# ponytail: one process keeps cancellation/progress honest; use a shared queue and
# object storage only when horizontal scaling is actually required.
job_slots = asyncio.Semaphore(MAX_CONCURRENT_JOBS)
analysis_slots = asyncio.Semaphore(MAX_CONCURRENT_ANALYSES)

app = FastAPI(title="Morit Downloader", version="1.0.0", docs_url=None, redoc_url=None)


def _persist_completed_job(job: Job) -> None:
    if not job.file_path or not job.file_name or not job.finished_at:
        return
    root = JOB_DIR / job.id
    metadata = {
        "id": job.id,
        "user_id": job.user_id,
        "request_id": job.request_id,
        "analysis_id": job.analysis_id,
        "platform": job.platform,
        "ticket": job.ticket,
        "selection": {
            key: value
            for key, value in asdict(job.selection).items()
            if key not in {"format_selector", "playlist_item", "remote_url"}
        },
        "file_name": job.file_name,
        "mime_type": job.mime_type,
        "content_length": job.content_length,
        "created_at": job.created_at,
        "finished_at": job.finished_at,
    }
    temporary = root / "job.json.tmp"
    temporary.write_text(json.dumps(metadata, separators=(",", ":")), encoding="utf-8")
    os.replace(temporary, root / "job.json")


def _restore_completed_jobs() -> None:
    now = time.time()
    for root in JOB_DIR.iterdir():
        if not root.is_dir():
            continue
        if re.fullmatch(r"analyze-[0-9a-f]{32}", root.name):
            shutil.rmtree(root, ignore_errors=True)
            continue
        if not re.fullmatch(r"[0-9a-f]{32}", root.name):
            continue
        try:
            value = json.loads((root / "job.json").read_text(encoding="utf-8"))
            finished_at = float(value["finished_at"])
            file_name = Path(str(value["file_name"])).name
            file_path = (root / "ready" / file_name).resolve()
            if (
                now - finished_at > FILE_TTL_SECONDS
                or file_path.parent != (root / "ready").resolve()
                or not file_path.is_file()
                or file_path.stat().st_size != int(value["content_length"])
            ):
                raise ValueError("expired or incomplete retained job")
            selection_value = value["selection"]
            selection = Selection(
                **selection_value,
                format_selector=None,
                playlist_item=None,
                remote_url=None,
            )
            job = Job(
                id=str(value["id"]),
                user_id=str(value["user_id"]),
                request_id=str(value["request_id"]),
                analysis_id=str(value["analysis_id"]),
                selection=selection,
                source_url="",
                platform=str(value["platform"]),
                ticket=str(value["ticket"]),
                status="complete",
                stage="ready",
                progress=1.0,
                file_path=file_path,
                file_name=file_name,
                mime_type=str(value["mime_type"]),
                content_length=int(value["content_length"]),
                created_at=float(value["created_at"]),
                finished_at=finished_at,
            )
            jobs[job.id] = job
        except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError):
            shutil.rmtree(root, ignore_errors=True)


_restore_completed_jobs()


def _host_allowed(host: str) -> bool:
    return any(host == allowed or host.endswith("." + allowed) for allowed in ALLOWED_HOSTS)


def _validate_url_shape(raw_url: str, *, require_allowlist: bool = True) -> str:
    raw_url = raw_url.strip()
    try:
        parsed = urlsplit(raw_url)
        host = (parsed.hostname or "").encode("idna").decode("ascii").lower()
    except (UnicodeError, ValueError) as error:
        raise ValueError("유효하지 않은 URL입니다.") from error
    if parsed.scheme != "https":
        raise ValueError("HTTPS 링크만 지원합니다.")
    if parsed.username or parsed.password:
        raise ValueError("사용자 정보가 포함된 URL은 허용되지 않습니다.")
    if not host or parsed.port not in (None, 443):
        raise ValueError("유효하지 않은 호스트 또는 포트입니다.")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError("IP 주소 링크는 허용되지 않습니다.")
    if require_allowlist and not _host_allowed(host):
        raise ValueError(
            "지원 목록에 없는 도메인입니다. 운영자가 DOWNLOAD_ALLOWED_HOSTS에 추가할 수 있습니다."
        )
    return urlunsplit(("https", parsed.netloc, parsed.path or "/", parsed.query, ""))


async def _assert_public_dns(url: str) -> None:
    host = urlsplit(url).hostname
    if not host:
        raise ValueError("URL 호스트가 없습니다.")
    try:
        results = await asyncio.to_thread(
            socket.getaddrinfo, host, 443, type=socket.SOCK_STREAM
        )
    except socket.gaierror as error:
        raise ValueError("도메인 주소를 확인할 수 없습니다.") from error
    addresses = {item[4][0].split("%", 1)[0] for item in results}
    if not addresses or any(not ipaddress.ip_address(address).is_global for address in addresses):
        raise ValueError("공개 인터넷 주소가 아닌 대상은 허용되지 않습니다.")


async def validate_source_url(raw_url: str) -> str:
    normalized = _validate_url_shape(raw_url)
    await _assert_public_dns(normalized)
    return normalized


def _origin(url: str) -> tuple[str, str, int] | None:
    try:
        parsed = urlsplit(url)
        host = (parsed.hostname or "").encode("idna").decode("ascii").lower()
        port = parsed.port or (443 if parsed.scheme.lower() == "https" else 80)
    except (UnicodeError, ValueError):
        return None
    if not host or parsed.username or parsed.password:
        return None
    return parsed.scheme.lower(), host, port


def _same_origin(left: str, right: str) -> bool:
    left_origin = _origin(left)
    return left_origin is not None and left_origin == _origin(right)


def _compose_cobalt_url(url: str, *, require_origin_only: bool = False) -> str | None:
    url = url.strip()
    try:
        parsed = urlsplit(url)
    except ValueError:
        return None
    if _origin(url) != ("http", "cobalt", 9000):
        return None
    if require_origin_only and (
        parsed.path not in {"", "/"} or parsed.query or parsed.fragment
    ):
        return None
    return urlunsplit(
        ("http", "cobalt:9000", parsed.path or "/", parsed.query, "")
    )


async def _validate_cobalt_api_url() -> str:
    internal = _compose_cobalt_url(COBALT_API_URL, require_origin_only=True)
    if internal:
        return internal.rstrip("/")
    normalized = _validate_url_shape(COBALT_API_URL, require_allowlist=False)
    parsed = urlsplit(normalized)
    if parsed.path not in {"", "/"} or parsed.query:
        raise ValueError("Cobalt API URL must be an origin without path or query")
    await _assert_public_dns(normalized)
    return normalized.rstrip("/")


def _safe_name(value: str, fallback: str = "media") -> str:
    value = re.sub(r"[\x00-\x1f<>:\"/\\|?*]+", " ", value)
    value = re.sub(r"\s+", " ", value).strip(" .")
    return (value[:100] or fallback)


def _platform_from_url(url: str) -> str:
    host = (urlsplit(url).hostname or "").lower()
    for label, domains in (
        ("youtube", ("youtube.com", "youtu.be")),
        ("x", ("x.com", "twitter.com")),
        ("instagram", ("instagram.com",)),
        ("soundcloud", ("soundcloud.com",)),
        ("facebook", ("facebook.com", "fb.watch")),
        ("threads", ("threads.net",)),
        ("tiktok", ("tiktok.com",)),
        ("bluesky", ("bsky.app", "bluesky.app")),
        ("reddit", ("reddit.com", "redd.it")),
    ):
        if any(host == domain or host.endswith("." + domain) for domain in domains):
            return label
    return host.removeprefix("www.").split(".", 1)[0] or "unknown"


def _analyze_as_playlist(url: str) -> bool:
    parsed = urlsplit(url)
    host = (parsed.hostname or "").lower()
    return not (
        host == "youtu.be"
        or host.endswith(".youtu.be")
        or (
            (host == "youtube.com" or host.endswith(".youtube.com"))
            and (
                parsed.path.rstrip("/") == "/watch"
                or parsed.path.startswith(("/shorts/", "/live/", "/embed/"))
            )
        )
    )


def _extension_mime(extension: str, fallback: str) -> str:
    return MIME_BY_EXTENSION.get(
        extension.lower(), mimetypes.guess_type("x." + extension)[0] or fallback
    )


def _kind_for_format(item: dict[str, Any]) -> str:
    extension = str(item.get("ext") or "").lower()
    if extension in IMAGE_EXTENSIONS:
        return "image"
    if str(item.get("vcodec") or "none") != "none":
        return "video"
    if str(item.get("acodec") or "none") != "none":
        return "audio"
    return "unknown"


def _asset_id(root: dict[str, Any], entry: dict[str, Any], index: int) -> str:
    identity = f"{root.get('extractor_key')}:{entry.get('id')}:{index}"
    return hashlib.sha256(identity.encode()).hexdigest()[:20]


def _size_for_formats(items: list[dict[str, Any]]) -> int | None:
    values = [
        item.get("filesize") or item.get("filesize_approx")
        for item in items
        if item.get("filesize") or item.get("filesize_approx")
    ]
    try:
        return sum(int(value) for value in values)
    except (TypeError, ValueError):
        return None


def _instagram_original_image_url(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = urlsplit(value)
        host = (parsed.hostname or "").lower()
        query_items = parse_qsl(parsed.query, keep_blank_values=True)
        query = dict(query_items)
    except ValueError:
        return None
    if (
        parsed.scheme != "https"
        or parsed.username
        or parsed.password
        or parsed.port not in (None, 443)
        or not re.fullmatch(r"instagram\.[a-z0-9-]+\.fna\.fbcdn\.net", host)
        or Path(parsed.path).suffix.lower() not in {".jpg", ".jpeg", ".png", ".webp"}
        or len(query_items) != len(query)
        or not all(query.get(key) for key in ("oh", "oe", "ig_cache_key"))
    ):
        return None
    transform = query.get("stp")
    if transform and (
        not re.fullmatch(r"dst-(?:jpg|webp)(?:_[a-z0-9.]+)*", transform)
        or re.search(r"(?:^|_)(?:c\d|[sp]\d+x\d+)", transform)
    ):
        return None
    return urlunsplit(("https", parsed.netloc, parsed.path, parsed.query, ""))


def _instagram_image_urls(
    info: dict[str, Any], entries: list[dict[str, Any]]
) -> list[str | None]:
    if (
        not entries
        or str(info.get("extractor_key") or info.get("extractor") or "").lower()
        != "instagram"
    ):
        return [None] * len(entries)
    urls: list[str | None] = []
    for entry in entries:
        if (
            str(entry.get("extractor_key") or entry.get("extractor") or "").lower()
            != "instagram"
            or entry.get("formats")
            or entry.get("duration") is not None
            or entry.get("url")
            or entry.get("ext")
        ):
            urls.append(None)
            continue
        originals = [
            (bool(dict(parse_qsl(urlsplit(url).query)).get("stp")), url)
            for thumbnail in entry.get("thumbnails") or []
            if isinstance(thumbnail, dict)
            and (url := _instagram_original_image_url(thumbnail.get("url")))
        ]
        if not originals:
            urls.append(None)
            continue
        preferred_rank = min(rank for rank, _ in originals)
        preferred = [url for rank, url in originals if rank == preferred_rank]
        urls.append(preferred[0] if len(preferred) == 1 else None)
    return urls


def _build_ytdlp_selections(
    info: dict[str, Any], source_url: str
) -> tuple[str, str | None, list[Selection]]:
    root_title = str(info.get("title") or "media")
    thumbnail = info.get("thumbnail")
    raw_entries = info.get("entries")
    entries = [entry for entry in raw_entries or [] if isinstance(entry, dict)]
    if not entries:
        entries = [info]
    entries = entries[:MAX_PLAYLIST_ITEMS]
    instagram_images = _instagram_image_urls(info, entries)
    selections: list[Selection] = []

    for entry_index, entry in enumerate(entries, 1):
        formats = [
            item for item in entry.get("formats") or [] if isinstance(item, dict)
        ]
        title = str(entry.get("title") or root_title or "media")
        base = _safe_name(title)
        asset_id = _asset_id(info, entry, entry_index)
        playlist_item = (
            int(entry.get("playlist_index") or entry_index) if raw_entries else None
        )

        remote_url = instagram_images[entry_index - 1]
        if remote_url:
            extension = Path(urlsplit(remote_url).path).suffix.lower().lstrip(".")
            selections.append(
                Selection(
                    id=secrets.token_urlsafe(12),
                    asset_id=asset_id,
                    kind="image",
                    label=f"사진 {entry_index}",
                    file_name=f"{base}-{entry_index}.{extension}",
                    mime_type=_extension_mime(extension, "image/jpeg"),
                    extension=extension,
                    width=None,
                    height=None,
                    bitrate=None,
                    size_bytes=None,
                    is_preview=False,
                    recommended=True,
                    engine="instagram-image",
                    playlist_item=playlist_item,
                    remote_url=remote_url,
                )
            )
            continue

        image_formats = [item for item in formats if _kind_for_format(item) == "image"]
        if image_formats:
            best = max(
                image_formats,
                key=lambda item: (
                    int(item.get("width") or 0) * int(item.get("height") or 0),
                    int(item.get("filesize") or item.get("filesize_approx") or 0),
                ),
            )
            extension = str(best.get("ext") or "jpg").lower()
            selections.append(
                Selection(
                    id=secrets.token_urlsafe(12),
                    asset_id=asset_id,
                    kind="image",
                    label=f"사진 {entry_index}" if len(entries) > 1 else "사진",
                    file_name=f"{base}.{extension}",
                    mime_type=_extension_mime(extension, "image/jpeg"),
                    extension=extension,
                    width=int(best.get("width") or 0) or None,
                    height=int(best.get("height") or 0) or None,
                    bitrate=None,
                    size_bytes=_size_for_formats([best]),
                    is_preview=False,
                    recommended=True,
                    engine="yt-dlp",
                    format_selector=str(best.get("format_id") or "best"),
                    playlist_item=playlist_item,
                )
            )
            continue

        video_formats = [
            item for item in formats if _kind_for_format(item) == "video"
        ]
        audio_formats = [
            item for item in formats if _kind_for_format(item) == "audio"
        ]
        heights = sorted(
            {int(item.get("height") or 0) for item in video_formats if item.get("height")},
            reverse=True,
        )[:7]
        if video_formats:
            if not heights:
                heights = [0]
            for quality_index, height in enumerate(heights):
                matching_video = [
                    item
                    for item in video_formats
                    if not height or int(item.get("height") or 0) <= height
                ]
                best_video = max(
                    matching_video or video_formats,
                    key=lambda item: (
                        int(item.get("height") or 0),
                        str(item.get("vcodec") or "").startswith(("avc1", "h264")),
                        int(item.get("tbr") or 0),
                    ),
                )
                best_audio = max(
                    audio_formats,
                    key=lambda item: int(item.get("abr") or item.get("tbr") or 0),
                    default={},
                )
                video_id = str(best_video.get("format_id") or "bestvideo")
                audio_id = str(best_audio.get("format_id") or "")
                selector = (
                    f"{video_id}+{audio_id}"
                    if str(best_video.get("acodec") or "none") == "none"
                    and audio_id
                    else video_id
                )
                label = f"{height}p" if height else "최고 화질"
                selections.append(
                    Selection(
                        id=secrets.token_urlsafe(12),
                        asset_id=asset_id,
                        kind="video",
                        label=label,
                        file_name=f"{base}-{label.replace(' ', '-')}.mp4",
                        mime_type="video/mp4",
                        extension="mp4",
                        width=int(best_video.get("width") or 0) or None,
                        height=int(best_video.get("height") or 0) or None,
                        bitrate=int(best_video.get("tbr") or 0) or None,
                        size_bytes=_size_for_formats(
                            [item for item in (best_video, best_audio) if item]
                        ),
                        is_preview=False,
                        recommended=quality_index == 0,
                        engine="yt-dlp",
                        format_selector=selector,
                        playlist_item=playlist_item,
                    )
                )

        if audio_formats:
            bitrates = sorted(
                {
                    int(item.get("abr") or item.get("tbr") or 0)
                    for item in audio_formats
                    if item.get("abr") or item.get("tbr")
                },
                reverse=True,
            )[:4]
            if not bitrates:
                bitrates = [0]
            for audio_index, bitrate in enumerate(bitrates):
                candidates = [
                    item
                    for item in audio_formats
                    if not bitrate
                    or int(item.get("abr") or item.get("tbr") or 0) <= bitrate
                ]
                chosen = max(
                    candidates or audio_formats,
                    key=lambda item: int(item.get("abr") or item.get("tbr") or 0),
                )
                format_id = str(chosen.get("format_id") or "bestaudio")
                label = f"오디오 {bitrate} kbps" if bitrate else "오디오"
                selections.append(
                    Selection(
                        id=secrets.token_urlsafe(12),
                        asset_id=asset_id,
                        kind="audio",
                        label=label,
                        file_name=f"{base}.m4a",
                        mime_type="audio/mp4",
                        extension="m4a",
                        width=None,
                        height=None,
                        bitrate=bitrate or None,
                        size_bytes=_size_for_formats([chosen]),
                        is_preview=False,
                        recommended=not video_formats and audio_index == 0,
                        engine="yt-dlp",
                        format_selector=format_id,
                        playlist_item=playlist_item,
                    )
                )

    if not selections:
        raise EngineFailure(
            "MEDIA_NOT_FOUND",
            "게시물에서 다운로드 가능한 원본 미디어를 찾지 못했습니다.",
            engine="yt-dlp",
            platform=_platform_from_url(source_url),
        )
    return root_title, str(thumbnail) if thumbnail else None, selections


async def _read_limited(
    stream: asyncio.StreamReader,
    limit: int,
    *,
    engine: str = "yt-dlp",
    platform: str = "unknown",
) -> bytes:
    result = bytearray()
    while chunk := await stream.read(64 * 1024):
        result.extend(chunk)
        if len(result) > limit:
            raise EngineFailure(
                "ENGINE_OUTPUT_LIMIT",
                "엔진 응답이 허용 크기를 초과했습니다.",
                engine=engine,
                platform=platform,
            )
    return bytes(result)


def _subprocess_env(temp_dir: Path) -> dict[str, str]:
    allowed = (
        "PATH",
        "SYSTEMROOT",
        "WINDIR",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "LANG",
        "LC_ALL",
    )
    env = {key: os.environ[key] for key in allowed if key in os.environ}
    env.update({"PYTHONUTF8": "1", "HOME": str(temp_dir), "TMPDIR": str(temp_dir)})
    return env


def _process_group_options() -> dict[str, Any]:
    return {} if os.name == "nt" else {"start_new_session": True}


async def _kill_process_tree(process: asyncio.subprocess.Process) -> None:
    if process.returncode is not None:
        return
    try:
        if os.name == "nt":
            killer = await asyncio.create_subprocess_exec(
                "taskkill",
                "/PID",
                str(process.pid),
                "/T",
                "/F",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(killer.wait(), 5)
        else:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                await asyncio.wait_for(process.wait(), 3)
            except TimeoutError:
                os.killpg(process.pid, signal.SIGKILL)
    except (FileNotFoundError, ProcessLookupError, PermissionError, TimeoutError):
        process.kill()
    if process.returncode is None:
        try:
            await asyncio.wait_for(process.wait(), 5)
        except TimeoutError:
            process.kill()
            await process.wait()


def _redact(raw: str, secrets_to_remove: tuple[str, ...] = ()) -> str:
    value = raw
    for secret in secrets_to_remove:
        if secret:
            value = value.replace(secret, "<redacted>")
    value = re.sub(
        r"https?://[^\s\"'<>]+",
        lambda match: (
            f"{urlsplit(match.group(0).rstrip('.,;)')).scheme}://"
            f"{urlsplit(match.group(0).rstrip('.,;)')).hostname or 'redacted'}/…"
        ),
        value,
    )
    return value[-4000:]


def _map_engine_failure(
    raw: str, *, engine: str, platform: str
) -> EngineFailure:
    lower = raw.lower()
    cases = (
        (("unsupported url", "no suitable extractor"), "UNSUPPORTED_URL", "이 플랫폼 또는 URL 형식은 현재 엔진에서 지원하지 않습니다.", False),
        (("login required", "cookies", "sign in"), "AUTH_REQUIRED", "로그인 또는 세션이 필요한 콘텐츠입니다.", False),
        (("private", "not accessible"), "PRIVATE_OR_RESTRICTED", "비공개이거나 접근이 제한된 콘텐츠입니다.", False),
        (("geo", "not available in your country"), "GEO_RESTRICTED", "지역 제한으로 콘텐츠에 접근할 수 없습니다.", False),
        (("429", "too many requests"), "RATE_LIMITED", "플랫폼 요청 제한에 도달했습니다. 잠시 후 다시 시도해주세요.", True),
        (("no video formats", "no media", "requested format is not available"), "MEDIA_NOT_FOUND", "게시물에서 선택 가능한 원본 미디어를 찾지 못했습니다.", False),
        (("ffmpeg", "postprocessing"), "POSTPROCESS_FAILED", "미디어 병합 또는 변환에 실패했습니다.", True),
        (("unavailable", "removed", "not found"), "CONTENT_UNAVAILABLE", "삭제되었거나 현재 사용할 수 없는 콘텐츠입니다.", False),
    )
    for needles, code, message, retryable in cases:
        if any(needle in lower for needle in needles):
            return EngineFailure(
                code,
                message,
                engine=engine,
                platform=platform,
                retryable=retryable,
                raw=raw,
            )
    return EngineFailure(
        "ENGINE_FAILED",
        "다운로드 엔진이 콘텐츠를 처리하지 못했습니다.",
        engine=engine,
        platform=platform,
        retryable=True,
        raw=raw,
    )


async def _analyze_ytdlp(
    source_url: str,
) -> tuple[str, str | None, list[Selection]]:
    platform = _platform_from_url(source_url)
    temp_dir = JOB_DIR / ("analyze-" + uuid.uuid4().hex)
    temp_dir.mkdir()
    command = [
        sys.executable,
        "-m",
        "yt_dlp",
        "--ignore-config",
        "--js-runtimes",
        YT_DLP_JS_RUNTIME,
        "--dump-single-json",
        "--skip-download",
        "--ignore-no-formats-error",
        "--socket-timeout",
        "15",
        "--extractor-retries",
        "2",
        "--retries",
        "2",
        "--fragment-retries",
        "2",
        "--no-warnings",
    ]
    if _analyze_as_playlist(source_url):
        command.extend(["--yes-playlist", "--playlist-end", str(MAX_PLAYLIST_ITEMS)])
    else:
        command.append("--no-playlist")
    command.append(source_url)
    process: asyncio.subprocess.Process | None = None
    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=temp_dir,
            env=_subprocess_env(temp_dir),
            **_process_group_options(),
        )
        stdout_task = asyncio.create_task(
            _read_limited(process.stdout, MAX_ANALYZE_OUTPUT_BYTES)
        )
        stderr_task = asyncio.create_task(_read_limited(process.stderr, 512 * 1024))
        try:
            stdout, stderr = await asyncio.wait_for(
                asyncio.gather(stdout_task, stderr_task), ANALYZE_TIMEOUT_SECONDS
            )
            return_code = await process.wait()
        except TimeoutError as error:
            await _kill_process_tree(process)
            raise EngineFailure(
                "ENGINE_TIMEOUT",
                "플랫폼 분석 시간이 초과되었습니다.",
                engine="yt-dlp",
                platform=platform,
                retryable=True,
            ) from error
        raw_error = stderr.decode("utf-8", "replace")
        if return_code:
            raise _map_engine_failure(
                raw_error, engine="yt-dlp", platform=platform
            )
        try:
            info = json.loads(stdout)
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            raise EngineFailure(
                "INVALID_ENGINE_RESPONSE",
                "분석 엔진이 올바르지 않은 결과를 반환했습니다.",
                engine="yt-dlp",
                platform=platform,
                raw=raw_error,
            ) from error
        return _build_ytdlp_selections(info, source_url)
    finally:
        if process and process.returncode is None:
            await _kill_process_tree(process)
        shutil.rmtree(temp_dir, ignore_errors=True)


async def _analyze_cobalt(
    source_url: str,
    video_quality: str = "max",
) -> tuple[str, str | None, list[Selection]]:
    platform = _platform_from_url(source_url)
    if not COBALT_API_URL:
        raise EngineFailure(
            "COBALT_NOT_CONFIGURED",
            "보조 다운로드 엔진이 구성되지 않았습니다.",
            engine="cobalt",
            platform=platform,
        )
    try:
        cobalt_url = await _validate_cobalt_api_url()
    except ValueError as error:
        raise EngineFailure(
            "COBALT_CONFIGURATION_ERROR",
            "Cobalt 서버 주소가 안전하지 않거나 유효하지 않습니다.",
            engine="cobalt",
            platform=platform,
        ) from error
    headers = {"Accept": "application/json", "Content-Type": "application/json"}
    if COBALT_API_KEY:
        headers["Authorization"] = f"Api-Key {COBALT_API_KEY}"
    try:
        async with httpx.AsyncClient(timeout=45, follow_redirects=False) as client:
            response = await client.post(
                cobalt_url.rstrip("/") + "/",
                headers=headers,
                json={
                    "url": source_url,
                    "downloadMode": "auto",
                    "videoQuality": video_quality,
                    "filenameStyle": "basic",
                    "alwaysProxy": True,
                    "localProcessing": "disabled",
                },
            )
    except httpx.HTTPError as error:
        raise EngineFailure(
            "COBALT_UNAVAILABLE",
            "Cobalt 서버에 연결할 수 없습니다.",
            engine="cobalt",
            platform=platform,
            retryable=True,
            raw=str(error),
        ) from error
    if response.status_code == 429:
        raise EngineFailure(
            "RATE_LIMITED",
            "Cobalt 요청 제한에 도달했습니다.",
            engine="cobalt",
            platform=platform,
            retryable=True,
        )
    try:
        data = response.json()
    except ValueError as error:
        raise EngineFailure(
            "INVALID_ENGINE_RESPONSE",
            "Cobalt가 올바르지 않은 결과를 반환했습니다.",
            engine="cobalt",
            platform=platform,
            raw=response.text,
        ) from error
    if response.is_error or data.get("status") == "error":
        cobalt_code = str((data.get("error") or {}).get("code") or response.status_code)
        failure = _map_engine_failure(
            cobalt_code, engine="cobalt", platform=platform
        )
        failure.raw = response.text
        raise failure

    selections: list[Selection] = []
    status = data.get("status")
    picker = data.get("picker") if status == "picker" else None
    if isinstance(picker, list):
        for index, item in enumerate(picker[:MAX_PLAYLIST_ITEMS], 1):
            if not isinstance(item, dict) or not item.get("url"):
                continue
            kind = {"photo": "image", "gif": "image"}.get(
                str(item.get("type")), "video"
            )
            extension = "jpg" if kind == "image" else "mp4"
            selections.append(
                Selection(
                    id=secrets.token_urlsafe(12),
                    asset_id=hashlib.sha256(
                        f"cobalt:{source_url}:{index}".encode()
                    ).hexdigest()[:20],
                    kind=kind,
                    label=f"{'사진' if kind == 'image' else '영상'} {index}",
                    file_name=f"{platform}-{index}.{extension}",
                    mime_type=_extension_mime(extension, "application/octet-stream"),
                    extension=extension,
                    width=None,
                    height=None,
                    bitrate=None,
                    size_bytes=None,
                    is_preview=False,
                    recommended=True,
                    engine="cobalt",
                    playlist_item=index,
                    remote_url=str(item["url"]),
                )
            )
        if data.get("audio"):
            selections.append(
                Selection(
                    id=secrets.token_urlsafe(12),
                    asset_id=hashlib.sha256(
                        f"cobalt:{source_url}:audio".encode()
                    ).hexdigest()[:20],
                    kind="audio",
                    label="오디오",
                    file_name=_safe_name(str(data.get("audioFilename") or platform)) + ".m4a",
                    mime_type="audio/mp4",
                    extension="m4a",
                    width=None,
                    height=None,
                    bitrate=None,
                    size_bytes=None,
                    is_preview=False,
                    recommended=False,
                    engine="cobalt",
                    remote_url=str(data["audio"]),
                )
            )
    elif status in {"tunnel", "redirect"} and data.get("url"):
        filename = _safe_name(str(data.get("filename") or platform))
        suffix = Path(filename).suffix.lower().lstrip(".") or "mp4"
        kind = (
            "image"
            if suffix in IMAGE_EXTENSIONS
            else "audio"
            if suffix in AUDIO_EXTENSIONS
            else "video"
        )
        selections.append(
            Selection(
                id=secrets.token_urlsafe(12),
                asset_id=hashlib.sha256(f"cobalt:{source_url}".encode()).hexdigest()[:20],
                kind=kind,
                label={"image": "사진", "audio": "오디오", "video": "최고 화질"}[kind],
                file_name=filename if Path(filename).suffix else f"{filename}.{suffix}",
                mime_type=_extension_mime(suffix, "application/octet-stream"),
                extension=suffix,
                width=None,
                height=None,
                bitrate=None,
                size_bytes=None,
                is_preview=False,
                recommended=True,
                engine="cobalt",
                remote_url=str(data["url"]),
            )
        )
    if not selections:
        raise EngineFailure(
            "MEDIA_NOT_FOUND",
            "Cobalt가 선택 가능한 미디어를 반환하지 않았습니다.",
            engine="cobalt",
            platform=platform,
            raw=response.text,
        )
    return platform, None, selections


def _cobalt_video_quality(label: str) -> str:
    match = re.search(r"\b(144|240|360|480|720|1080|1440|2160|4320)p\b", label)
    return match.group(1) if match else "max"


async def _verify_supabase_token(token: str) -> str:
    digest = hashlib.sha256(token.encode()).hexdigest()
    cached = auth_cache.get(digest)
    if cached and cached[1] > time.time():
        return cached[0]
    if not SUPABASE_URL or not SUPABASE_PUBLIC_KEY:
        raise HTTPException(503, detail={"code": "AUTH_NOT_CONFIGURED"})
    if not SUPABASE_URL.startswith("https://"):
        raise HTTPException(503, detail={"code": "AUTH_URL_INSECURE"})
    try:
        async with httpx.AsyncClient(timeout=8, follow_redirects=False) as client:
            response = await client.get(
                f"{SUPABASE_URL}/auth/v1/user",
                headers={
                    "apikey": SUPABASE_PUBLIC_KEY,
                    "Authorization": f"Bearer {token}",
                    "Accept": "application/json",
                },
            )
    except httpx.HTTPError as error:
        logger.warning("supabase_auth_unavailable type=%s", type(error).__name__)
        raise HTTPException(503, detail={"code": "AUTH_UNAVAILABLE"}) from error
    if response.status_code != 200:
        raise HTTPException(401, detail={"code": "INVALID_TOKEN"})
    try:
        user_id = str(response.json()["id"])
    except (ValueError, KeyError, TypeError) as error:
        raise HTTPException(401, detail={"code": "INVALID_TOKEN_RESPONSE"}) from error
    if len(auth_cache) >= 512:
        auth_cache.clear()
    auth_cache[digest] = (user_id, time.time() + 30)
    return user_id


async def current_user(
    authorization: Annotated[str | None, Header()] = None,
) -> str:
    if DEV_AUTH_BYPASS:
        if authorization != "Bearer dev-local":
            raise HTTPException(401, detail={"code": "DEV_TOKEN_REQUIRED"})
        return "dev-local"
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, detail={"code": "TOKEN_REQUIRED"})
    token = authorization[7:].strip()
    if not token:
        raise HTTPException(401, detail={"code": "TOKEN_REQUIRED"})
    return await _verify_supabase_token(token)


def _clean_expired() -> None:
    now = time.time()
    for analysis_id, analysis in list(analyses.items()):
        if now - analysis.created_at > ANALYSIS_TTL_SECONDS:
            analyses.pop(analysis_id, None)
    for job_id, job in list(jobs.items()):
        if (
            job.status in {"complete", "failed", "canceled"}
            and job.finished_at
            and now - job.finished_at > FILE_TTL_SECONDS
        ):
            jobs.pop(job_id, None)
            shutil.rmtree(JOB_DIR / job_id, ignore_errors=True)
    while len(analyses) > MAX_ANALYSES:
        analyses.pop(min(analyses, key=lambda key: analyses[key].created_at), None)
    completed = sorted(
        [
            job
            for job in jobs.values()
            if job.status in {"complete", "failed", "canceled"}
        ],
        key=lambda item: item.created_at,
    )
    for user_id in {job.user_id for job in completed}:
        owned = [job for job in completed if job.user_id == user_id]
        owned_bytes = sum(job.content_length or 0 for job in owned)
        while owned and (
            len(owned) > MAX_RETAINED_JOBS_PER_USER
            or owned_bytes > MAX_RETAINED_BYTES_PER_USER
        ):
            oldest = owned.pop(0)
            completed.remove(oldest)
            owned_bytes -= oldest.content_length or 0
            jobs.pop(oldest.id, None)
            shutil.rmtree(JOB_DIR / oldest.id, ignore_errors=True)
    retained_bytes = sum(job.content_length or 0 for job in completed)
    while completed and (
        len(completed) > MAX_RETAINED_JOBS
        or retained_bytes > MAX_RETAINED_BYTES
    ):
        oldest = completed.pop(0)
        retained_bytes -= oldest.content_length or 0
        jobs.pop(oldest.id, None)
        shutil.rmtree(JOB_DIR / oldest.id, ignore_errors=True)


def _cached_analysis(user_id: str, source_url: str) -> Analysis | None:
    # ponytail: MAX_ANALYSES bounds this scan; add a second index only if profiling
    # shows these 200 in-memory entries matter next to network extraction.
    return next(
        (
            value
            for value in reversed(analyses.values())
            if value.user_id == user_id and value.source_url == source_url
        ),
        None,
    )


def _analysis_public(value: Analysis, *, cached: bool) -> dict[str, Any]:
    return {
        "analysis_id": value.id,
        "source_url": value.source_url,
        "provider": value.provider,
        "title": value.title,
        "thumbnail_url": value.thumbnail_url,
        "selections": [item.public() for item in value.selections.values()],
        "cached": cached,
    }


def _log_failure(failure: EngineFailure, source_url: str) -> None:
    logger.error(
        "engine_failure log_id=%s engine=%s platform=%s code=%s details=%s",
        failure.log_id,
        failure.engine,
        failure.platform,
        failure.code,
        _redact(failure.raw, (source_url, COBALT_API_KEY)),
    )


@app.get("/health")
async def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "yt_dlp": shutil.which("yt-dlp") is not None
        or importlib.util.find_spec("yt_dlp") is not None,
        "yt_dlp_ejs": importlib.util.find_spec("yt_dlp_ejs") is not None,
        "js_runtime": YT_DLP_JS_RUNTIME
        if shutil.which(YT_DLP_JS_RUNTIME)
        else None,
        "ffmpeg": shutil.which("ffmpeg") is not None,
        "ffprobe": shutil.which("ffprobe") is not None,
        "cobalt": bool(COBALT_API_URL),
    }


@app.post("/v1/analyze")
async def analyze(
    body: AnalyzeBody, user_id: str = Depends(current_user)
) -> dict[str, Any]:
    _clean_expired()
    try:
        source_url = await validate_source_url(body.url)
    except ValueError as error:
        raise HTTPException(
            400, detail={"code": "UNSAFE_OR_UNSUPPORTED_URL", "message": str(error)}
        ) from error
    cached = _cached_analysis(user_id, source_url)
    if cached:
        logger.info(
            "analysis_complete platform=%s cached=true elapsed_ms=0 selections=%s",
            cached.provider,
            len(cached.selections),
        )
        return _analysis_public(cached, cached=True)
    now = time.time()
    recent = [
        value for value in analysis_history.get(user_id, []) if now - value < 60
    ]
    if len(recent) >= MAX_ANALYSES_PER_MINUTE:
        raise HTTPException(
            429,
            detail={
                "code": "ANALYSIS_RATE_LIMITED",
                "message": "분석 요청이 너무 많습니다. 잠시 후 다시 시도해주세요.",
                "retryable": True,
            },
        )
    recent.append(now)
    analysis_history[user_id] = recent
    platform = _platform_from_url(source_url)
    started = time.perf_counter()
    try:
        try:
            await asyncio.wait_for(analysis_slots.acquire(), 0.05)
        except TimeoutError as error:
            raise HTTPException(
                429,
                detail={
                    "code": "ANALYSIS_CAPACITY_REACHED",
                    "message": "동시 분석 요청이 많습니다. 잠시 후 다시 시도해주세요.",
                },
            ) from error
        try:
            engines = (
                (_analyze_cobalt, _analyze_ytdlp)
                if COBALT_API_URL and platform in COBALT_FIRST_PLATFORMS
                else (_analyze_ytdlp, _analyze_cobalt)
            )
            try:
                title, thumbnail, selections_list = await engines[0](source_url)
            except EngineFailure as primary:
                _log_failure(primary, source_url)
                if not COBALT_API_URL:
                    raise
                title, thumbnail, selections_list = await engines[1](source_url)
        finally:
            analysis_slots.release()
    except EngineFailure as failure:
        _log_failure(failure, source_url)
        status = 422 if not failure.retryable else 502
        raise HTTPException(status, detail=failure.public()) from failure
    analysis_id = secrets.token_urlsafe(18)
    stored = Analysis(
        id=analysis_id,
        user_id=user_id,
        source_url=source_url,
        provider=platform,
        title=title,
        thumbnail_url=thumbnail,
        selections={item.id: item for item in selections_list},
    )
    analyses[analysis_id] = stored
    logger.info(
        "analysis_complete platform=%s cached=false elapsed_ms=%s selections=%s",
        platform,
        round((time.perf_counter() - started) * 1000),
        len(selections_list),
    )
    return _analysis_public(stored, cached=False)


def _job_public(job: Job, request: Request | None = None) -> dict[str, Any]:
    base = PUBLIC_BASE_URL or (str(request.base_url).rstrip("/") if request else "")
    transfer_relative = f"/v1/transfers/{job.id}?ticket={quote(job.ticket)}"
    file_value = None
    if job.status == "complete" and job.file_path:
        relative = f"/v1/files/{job.id}?ticket={quote(job.ticket)}"
        url = base + relative if base else relative
        file_value = {
            "url": url,
            "file_name": job.file_name,
            "mime_type": job.mime_type,
            "kind": job.selection.kind,
            "content_length": job.content_length,
        }
    return {
        "id": job.id,
        "status": job.status,
        "stage": job.stage,
        "progress": round(job.progress, 4),
        "engine": job.selection.engine,
        "platform": job.platform,
        "error": job.error,
        "file": file_value,
        "transfer_url": base + transfer_relative if base else transfer_relative,
    }


@app.post("/v1/jobs")
async def create_job(
    body: JobBody,
    request: Request,
    user_id: str = Depends(current_user),
) -> dict[str, Any]:
    _clean_expired()
    existing = next(
        (
            job
            for job in jobs.values()
            if job.user_id == user_id
            and job.request_id == body.request_id
            and job.status in {"queued", "running", "complete"}
        ),
        None,
    )
    if existing:
        return _job_public(existing, request)
    analysis = analyses.get(body.analysis_id)
    if not analysis or analysis.user_id != user_id:
        raise HTTPException(404, detail={"code": "ANALYSIS_NOT_FOUND"})
    selection = analysis.selections.get(body.selection_id)
    if not selection:
        raise HTTPException(404, detail={"code": "SELECTION_NOT_FOUND"})
    active_jobs = [
        existing
        for existing in jobs.values()
        if existing.status in {"queued", "running"}
    ]
    if len(active_jobs) >= MAX_JOBS:
        raise HTTPException(
            429,
            detail={
                "code": "JOB_CAPACITY_REACHED",
                "message": "서버의 활성 다운로드 한도에 도달했습니다.",
                "retryable": True,
            },
        )
    if sum(existing.user_id == user_id for existing in active_jobs) >= MAX_ACTIVE_JOBS_PER_USER:
        raise HTTPException(
            429,
            detail={
                "code": "USER_JOB_LIMIT_REACHED",
                "message": "계정의 동시 다운로드 한도에 도달했습니다.",
                "retryable": True,
            },
        )
    job_id = uuid.uuid4().hex
    job = Job(
        id=job_id,
        user_id=user_id,
        request_id=body.request_id,
        analysis_id=analysis.id,
        selection=selection,
        source_url=analysis.source_url,
        platform=analysis.provider,
        ticket=secrets.token_urlsafe(32),
    )
    jobs[job_id] = job
    job.task = asyncio.create_task(_run_job(job))
    return _job_public(job, request)


@app.get("/v1/transfers/{job_id}")
async def get_transfer(
    job_id: str,
    request: Request,
    ticket: Annotated[str, Query(min_length=32, max_length=100)],
) -> dict[str, Any]:
    _clean_expired()
    job = jobs.get(job_id)
    if (
        not job
        or not hmac.compare_digest(ticket, job.ticket)
        or (
            job.finished_at
            and time.time() - job.finished_at > FILE_TTL_SECONDS
        )
    ):
        raise HTTPException(404, detail={"code": "TRANSFER_NOT_FOUND"})
    return _job_public(job, request)


@app.get("/v1/jobs/{job_id}")
async def get_job(
    job_id: str,
    request: Request,
    user_id: str = Depends(current_user),
) -> dict[str, Any]:
    _clean_expired()
    job = jobs.get(job_id)
    if not job or job.user_id != user_id:
        raise HTTPException(404, detail={"code": "JOB_NOT_FOUND"})
    return _job_public(job, request)


@app.delete("/v1/jobs/{job_id}")
async def cancel_job(
    job_id: str,
    request: Request,
    user_id: str = Depends(current_user),
) -> dict[str, Any]:
    job = jobs.get(job_id)
    if not job or job.user_id != user_id:
        raise HTTPException(404, detail={"code": "JOB_NOT_FOUND"})
    if job.status in {"complete", "failed", "canceled"}:
        return _job_public(job, request)
    job.cancel_requested = True
    job.stage = "canceling"
    if job.process and job.process.returncode is None:
        await _kill_process_tree(job.process)
    if job.task:
        job.task.cancel()
        try:
            await asyncio.wait_for(asyncio.shield(job.task), 5)
        except asyncio.CancelledError:
            pass
        except TimeoutError:
            pass
    return _job_public(job, request)


async def _consume_progress(
    job: Job, stream: asyncio.StreamReader, errors: bytearray
) -> None:
    while line := await stream.readline():
        if line.startswith(b"MORIT|"):
            parts = line.decode("utf-8", "replace").strip().split("|")
            if len(parts) >= 6:
                downloaded = _to_int(parts[1])
                total = _to_int(parts[2]) or _to_int(parts[3])
                if downloaded is not None and total:
                    job.progress = min(0.94, max(job.progress, downloaded / total * 0.94))
                else:
                    fragment_index = _to_int(parts[4])
                    fragment_count = _to_int(parts[5])
                    if fragment_index is not None and fragment_count:
                        job.progress = min(
                            0.94,
                            max(job.progress, fragment_index / fragment_count * 0.94),
                        )
            continue
        if b"[Merger]" in line or b"[ExtractAudio]" in line or b"[VideoRemuxer]" in line:
            job.stage = "processing"
            job.progress = max(job.progress, 0.94)
        errors.extend(line)
        if len(errors) > 512 * 1024:
            del errors[: len(errors) - 512 * 1024]


def _to_int(value: Any) -> int | None:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


async def _download_instagram_image_once(
    job: Job, work_dir: Path, *, refresh: bool
) -> Path:
    current = job.selection
    if refresh or not current.remote_url:
        _, _, refreshed = await _analyze_ytdlp(job.source_url)
        current = next(
            (
                item
                for item in refreshed
                if item.engine == "instagram-image"
                and item.kind == "image"
                and item.asset_id == job.selection.asset_id
                and item.playlist_item == job.selection.playlist_item
            ),
            None,
        )
    url = _instagram_original_image_url(current.remote_url if current else None)
    if not current or not url:
        raise EngineFailure(
            "INSTAGRAM_IMAGE_EXPIRED",
            "Instagram 이미지 주소를 동일한 게시물 항목에서 다시 확인하지 못했습니다.",
            engine="instagram-image",
            platform=job.platform,
            retryable=True,
        )
    await _assert_public_dns(url)
    destination = work_dir / f"media.{current.extension}"
    headers = {
        "Accept-Encoding": "identity",
        "Referer": "https://www.instagram.com/",
        "User-Agent": (
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36"
        ),
    }
    received = 0
    exact_length: int | None = None
    try:
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(30, read=120), follow_redirects=False
        ) as client:
            for _ in range(4):
                async with client.stream("GET", url, headers=headers) as response:
                    if response.status_code in {301, 302, 303, 307, 308}:
                        location = response.headers.get("location")
                        next_url = (
                            _instagram_original_image_url(urljoin(url, location))
                            if location
                            else None
                        )
                        if not next_url:
                            raise EngineFailure(
                                "UNSAFE_IMAGE_REDIRECT",
                                "Instagram 이미지가 허용되지 않은 주소로 이동했습니다.",
                                engine="instagram-image",
                                platform=job.platform,
                            )
                        await _assert_public_dns(next_url)
                        url = next_url
                        continue
                    if response.status_code == 429:
                        raise EngineFailure(
                            "RATE_LIMITED",
                            "Instagram 이미지 요청 제한에 도달했습니다.",
                            engine="instagram-image",
                            platform=job.platform,
                            retryable=True,
                        )
                    if response.is_error:
                        raise EngineFailure(
                            "INSTAGRAM_IMAGE_DOWNLOAD_FAILED",
                            "Instagram 원본 이미지를 내려받지 못했습니다.",
                            engine="instagram-image",
                            platform=job.platform,
                            retryable=response.status_code >= 500,
                            raw=f"HTTP {response.status_code}",
                        )
                    content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
                    if content_type not in {
                        "image/jpeg",
                        "image/png",
                        "image/webp",
                    }:
                        raise EngineFailure(
                            "INVALID_CONTENT_TYPE",
                            "Instagram 원본 이미지의 Content-Type이 올바르지 않습니다.",
                            engine="instagram-image",
                            platform=job.platform,
                            raw=content_type,
                        )
                    exact_length = _to_int(response.headers.get("content-length"))
                    if exact_length and exact_length > MAX_FILE_BYTES:
                        raise EngineFailure(
                            "FILE_TOO_LARGE",
                            "이미지가 서버의 최대 다운로드 크기를 초과합니다.",
                            engine="instagram-image",
                            platform=job.platform,
                        )
                    content_encoding = response.headers.get(
                        "content-encoding", ""
                    ).strip().lower()
                    if content_encoding not in {"", "identity"}:
                        raise EngineFailure(
                            "INVALID_CONTENT_ENCODING",
                            "Instagram 원본 이미지가 예상하지 않은 방식으로 압축 전송되었습니다.",
                            engine="instagram-image",
                            platform=job.platform,
                            raw=content_encoding,
                        )
                    with destination.open("wb") as output:
                        async for chunk in response.aiter_raw(256 * 1024):
                            if job.cancel_requested:
                                raise asyncio.CancelledError
                            received += len(chunk)
                            if received > MAX_FILE_BYTES:
                                raise EngineFailure(
                                    "FILE_TOO_LARGE",
                                    "이미지가 서버의 최대 다운로드 크기를 초과합니다.",
                                    engine="instagram-image",
                                    platform=job.platform,
                                )
                            output.write(chunk)
                            if exact_length:
                                job.progress = min(
                                    0.94, received / exact_length * 0.94
                                )
                    if exact_length is not None and received != exact_length:
                        raise EngineFailure(
                            "CONTENT_LENGTH_MISMATCH",
                            "수신한 이미지 크기가 Content-Length와 일치하지 않습니다.",
                            engine="instagram-image",
                            platform=job.platform,
                            retryable=True,
                        )
                    return destination
    except httpx.HTTPError as error:
        raise EngineFailure(
            "INSTAGRAM_IMAGE_DOWNLOAD_FAILED",
            "Instagram 이미지 서버에 연결하지 못했습니다.",
            engine="instagram-image",
            platform=job.platform,
            retryable=True,
            raw=str(error),
        ) from error
    raise EngineFailure(
        "TOO_MANY_REDIRECTS",
        "Instagram 이미지 리디렉션 횟수를 초과했습니다.",
        engine="instagram-image",
        platform=job.platform,
    )


async def _download_instagram_image(job: Job, work_dir: Path) -> Path:
    for attempt in range(3):
        try:
            return await _download_instagram_image_once(
                job, work_dir, refresh=attempt > 0
            )
        except EngineFailure as failure:
            if not failure.retryable or attempt == 2:
                raise
            for partial in work_dir.glob("media.*"):
                partial.unlink(missing_ok=True)
            await asyncio.sleep(0.5 * (attempt + 1))
    raise AssertionError("unreachable")


async def _download_instagram_image_bounded(job: Job, work_dir: Path) -> Path:
    try:
        return await asyncio.wait_for(
            _download_instagram_image(job, work_dir), DOWNLOAD_TIMEOUT_SECONDS
        )
    except TimeoutError as error:
        raise EngineFailure(
            "DOWNLOAD_TIMEOUT",
            "Instagram 이미지 다운로드 제한 시간을 초과했습니다.",
            engine="instagram-image",
            platform=job.platform,
            retryable=True,
        ) from error


async def _download_ytdlp(job: Job, work_dir: Path) -> Path:
    selection = job.selection
    command = [
        sys.executable,
        "-m",
        "yt_dlp",
        "--ignore-config",
        "--js-runtimes",
        YT_DLP_JS_RUNTIME,
        "--newline",
        "--progress",
        "--progress-template",
        "download:MORIT|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.fragment_index)s|%(progress.fragment_count)s",
        "--socket-timeout",
        "20",
        "--retries",
        "3",
        "--fragment-retries",
        "3",
        "--file-access-retries",
        "3",
        "--abort-on-unavailable-fragments",
        "--no-keep-fragments",
        "--max-filesize",
        str(MAX_FILE_BYTES),
        "--paths",
        f"temp:{work_dir / 'temp'}",
        "-o",
        str(work_dir / "media.%(ext)s"),
        "-f",
        str(selection.format_selector),
    ]
    if selection.playlist_item:
        command.extend(["--yes-playlist", "--playlist-items", str(selection.playlist_item)])
    else:
        command.append("--no-playlist")
    if selection.kind == "audio":
        command.extend(["--extract-audio", "--audio-format", "m4a", "--audio-quality", "0"])
    elif selection.kind == "video":
        command.extend(["--merge-output-format", "mp4/mkv/webm"])
    command.append(job.source_url)

    process = await asyncio.create_subprocess_exec(
        *command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=work_dir,
        env=_subprocess_env(work_dir),
        **_process_group_options(),
    )
    job.process = process
    stderr = bytearray()
    stdout_task = asyncio.create_task(_consume_progress(job, process.stdout, stderr))
    stderr_task = asyncio.create_task(_consume_progress(job, process.stderr, stderr))
    try:
        return_code = await asyncio.wait_for(process.wait(), DOWNLOAD_TIMEOUT_SECONDS)
        await asyncio.gather(stdout_task, stderr_task)
    except asyncio.CancelledError:
        await _kill_process_tree(process)
        raise
    except TimeoutError as error:
        await _kill_process_tree(process)
        raise EngineFailure(
            "DOWNLOAD_TIMEOUT",
            "다운로드 제한 시간을 초과했습니다.",
            engine="yt-dlp",
            platform=job.platform,
            retryable=True,
        ) from error
    finally:
        job.process = None
    if job.cancel_requested:
        raise asyncio.CancelledError
    if return_code:
        raise _map_engine_failure(
            stderr.decode("utf-8", "replace"),
            engine="yt-dlp",
            platform=job.platform,
        )
    candidates = [
        path
        for path in work_dir.glob("media.*")
        if path.is_file()
        and not path.name.endswith((".part", ".ytdl"))
        and path.stat().st_size > 0
    ]
    if len(candidates) != 1:
        raise EngineFailure(
            "INCOMPLETE_DOWNLOAD",
            "완료된 미디어 파일을 정확히 확인하지 못했습니다.",
            engine="yt-dlp",
            platform=job.platform,
            retryable=True,
            raw="\n".join(path.name for path in work_dir.iterdir()),
        )
    return candidates[0]


async def _safe_remote_url(url: str) -> str:
    internal = _compose_cobalt_url(url)
    if internal and _same_origin(internal, COBALT_API_URL):
        return internal
    try:
        normalized = _validate_url_shape(url, require_allowlist=False)
        await _assert_public_dns(normalized)
    except ValueError as error:
        raise EngineFailure(
            "UNSAFE_ENGINE_URL",
            "보조 엔진이 안전하지 않은 파일 주소를 반환했습니다.",
            engine="cobalt",
            platform="unknown",
        ) from error
    return normalized


async def _download_cobalt(
    job: Job, work_dir: Path, *, refresh: bool = False
) -> Path:
    current = job.selection
    if refresh or not current.remote_url:
        _, _, refreshed = await _analyze_cobalt(
            job.source_url, _cobalt_video_quality(job.selection.label)
        )
        current = next(
            (
                item
                for item in refreshed
                if item.kind == job.selection.kind
                and (
                    item.asset_id == job.selection.asset_id
                    or (
                        job.selection.playlist_item is not None
                        and item.playlist_item == job.selection.playlist_item
                    )
                )
            ),
            None,
        )
    if current is None or not current.remote_url:
        raise EngineFailure(
            "COBALT_SELECTION_EXPIRED",
            "Cobalt에서 선택한 미디어 주소를 다시 발급받지 못했습니다.",
            engine="cobalt",
            platform=job.platform,
            retryable=True,
        )
    url = await _safe_remote_url(current.remote_url)
    destination = work_dir / ("media." + job.selection.extension)
    headers = {"Accept-Encoding": "identity"}
    if COBALT_API_KEY and _same_origin(url, COBALT_API_URL):
        headers["Authorization"] = f"Api-Key {COBALT_API_KEY}"
    received = 0
    expected: int | None = None
    exact_length: int | None = None
    async with httpx.AsyncClient(timeout=httpx.Timeout(30, read=120), follow_redirects=False) as client:
        for _ in range(6):
            async with client.stream("GET", url, headers=headers) as response:
                if response.status_code in {301, 302, 303, 307, 308}:
                    next_url = response.headers.get("location")
                    if not next_url:
                        raise EngineFailure(
                            "INVALID_REDIRECT",
                            "다운로드 리디렉션 주소가 없습니다.",
                            engine="cobalt",
                            platform=job.platform,
                        )
                    url = await _safe_remote_url(urljoin(url, next_url))
                    if not _same_origin(url, COBALT_API_URL):
                        headers.pop("Authorization", None)
                    continue
                if response.status_code == 429:
                    raise EngineFailure(
                        "RATE_LIMITED",
                        "Cobalt 터널 요청 제한에 도달했습니다.",
                        engine="cobalt",
                        platform=job.platform,
                        retryable=True,
                    )
                if response.is_error:
                    raise EngineFailure(
                        "COBALT_DOWNLOAD_FAILED",
                        "Cobalt가 파일을 전달하지 못했습니다.",
                        engine="cobalt",
                        platform=job.platform,
                        retryable=response.status_code >= 500,
                        raw=f"HTTP {response.status_code}",
                    )
                content_encoding = response.headers.get(
                    "content-encoding", ""
                ).strip().lower()
                if content_encoding not in {"", "identity"}:
                    raise EngineFailure(
                        "INVALID_CONTENT_ENCODING",
                        "Cobalt 파일이 예상하지 않은 방식으로 압축 전송되었습니다.",
                        engine="cobalt",
                        platform=job.platform,
                        raw=content_encoding,
                    )
                content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
                if content_type.startswith("text/") or content_type in {
                    "application/json",
                    "application/xml",
                }:
                    raise EngineFailure(
                        "INVALID_CONTENT_TYPE",
                        "미디어 대신 오류 문서가 반환되었습니다.",
                        engine="cobalt",
                        platform=job.platform,
                        raw=content_type,
                    )
                expected_prefix = {
                    "image": "image/",
                    "audio": "audio/",
                    "video": "video/",
                }[job.selection.kind]
                if (
                    content_type
                    and content_type != "application/octet-stream"
                    and not content_type.startswith(expected_prefix)
                ):
                    raise EngineFailure(
                        "CONTENT_TYPE_MISMATCH",
                        "응답 Content-Type이 선택한 미디어 형식과 일치하지 않습니다.",
                        engine="cobalt",
                        platform=job.platform,
                        raw=content_type,
                    )
                exact_length = _to_int(response.headers.get("content-length"))
                expected = exact_length or _to_int(
                    response.headers.get("estimated-content-length")
                )
                if expected and expected > MAX_FILE_BYTES:
                    raise EngineFailure(
                        "FILE_TOO_LARGE",
                        "파일이 서버의 최대 다운로드 크기를 초과합니다.",
                        engine="cobalt",
                        platform=job.platform,
                    )
                with destination.open("wb") as output:
                    async for chunk in response.aiter_raw(256 * 1024):
                        if job.cancel_requested:
                            raise asyncio.CancelledError
                        received += len(chunk)
                        if received > MAX_FILE_BYTES:
                            raise EngineFailure(
                                "FILE_TOO_LARGE",
                                "파일이 서버의 최대 다운로드 크기를 초과합니다.",
                                engine="cobalt",
                                platform=job.platform,
                            )
                        output.write(chunk)
                        if expected:
                            job.progress = min(0.94, received / expected * 0.94)
                if exact_length is not None and received != exact_length:
                    raise EngineFailure(
                        "CONTENT_LENGTH_MISMATCH",
                        "수신한 파일 크기가 Content-Length와 일치하지 않습니다.",
                        engine="cobalt",
                        platform=job.platform,
                        retryable=True,
                    )
                return destination
        raise EngineFailure(
            "TOO_MANY_REDIRECTS",
            "다운로드 리디렉션 횟수를 초과했습니다.",
            engine="cobalt",
            platform=job.platform,
        )


async def _download_cobalt_bounded(job: Job, work_dir: Path) -> Path:
    async def download() -> Path:
        for attempt in range(2):
            try:
                return await _download_cobalt(job, work_dir, refresh=attempt > 0)
            except EngineFailure as failure:
                if not failure.retryable or attempt:
                    raise
                for partial in work_dir.glob("media.*"):
                    partial.unlink(missing_ok=True)
        raise AssertionError("unreachable")

    try:
        return await asyncio.wait_for(
            download(), DOWNLOAD_TIMEOUT_SECONDS
        )
    except TimeoutError as error:
        raise EngineFailure(
            "DOWNLOAD_TIMEOUT",
            "Cobalt 다운로드 제한 시간을 초과했습니다.",
            engine="cobalt",
            platform=job.platform,
            retryable=True,
        ) from error


async def _probe(path: Path) -> dict[str, Any]:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=format_name,duration,size:stream=codec_type,codec_name,width,height",
        "-of",
        "json",
        str(path),
    ]
    process: asyncio.subprocess.Process | None = None
    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=path.parent,
            env=_subprocess_env(path.parent),
            **_process_group_options(),
        )
        stdout_task = asyncio.create_task(
            _read_limited(
                process.stdout,
                1024 * 1024,
                engine="validator",
                platform="server",
            )
        )
        stderr_task = asyncio.create_task(
            _read_limited(
                process.stderr,
                512 * 1024,
                engine="validator",
                platform="server",
            )
        )
        stdout, stderr, return_code = await asyncio.wait_for(
            asyncio.gather(stdout_task, stderr_task, process.wait()), 30
        )
    except FileNotFoundError as error:
        raise EngineFailure(
            "FFPROBE_UNAVAILABLE",
            "서버의 미디어 검증 도구를 사용할 수 없습니다.",
            engine="validator",
            platform="server",
            raw=str(error),
        ) from error
    except TimeoutError as error:
        if process:
            await _kill_process_tree(process)
        raise EngineFailure(
            "FFPROBE_TIMEOUT",
            "미디어 컨테이너 검증 시간이 초과되었습니다.",
            engine="validator",
            platform="server",
            retryable=True,
        ) from error
    finally:
        if process and process.returncode is None:
            await _kill_process_tree(process)
    if return_code:
        raise EngineFailure(
            "INVALID_MEDIA",
            "완료 파일을 미디어로 검증하지 못했습니다.",
            engine="validator",
            platform="server",
            raw=stderr.decode("utf-8", "replace"),
        )
    try:
        return json.loads(stdout)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise EngineFailure(
            "INVALID_MEDIA",
            "미디어 검증 결과가 올바르지 않습니다.",
            engine="validator",
            platform="server",
        ) from error


async def _decode_check(path: Path) -> None:
    command = [
        "ffmpeg",
        "-v",
        "error",
        "-xerror",
        "-i",
        str(path),
        "-map",
        "0:v:0?",
        "-map",
        "0:a:0?",
        "-c",
        "copy",
        "-f",
        "null",
        "-",
    ]
    process: asyncio.subprocess.Process | None = None
    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
            cwd=path.parent,
            env=_subprocess_env(path.parent),
            **_process_group_options(),
        )
        stderr_task = asyncio.create_task(
            _read_limited(
                process.stderr,
                512 * 1024,
                engine="validator",
                platform="server",
            )
        )
        try:
            stderr, return_code = await asyncio.wait_for(
                asyncio.gather(stderr_task, process.wait()),
                VALIDATION_TIMEOUT_SECONDS,
            )
        except TimeoutError as error:
            await _kill_process_tree(process)
            raise EngineFailure(
                "VALIDATION_TIMEOUT",
                "완료 파일 재생 검증 시간이 초과되었습니다.",
                engine="validator",
                platform="server",
                retryable=True,
            ) from error
    except FileNotFoundError as error:
        raise EngineFailure(
            "FFMPEG_UNAVAILABLE",
            "서버의 미디어 디코딩 검증 도구를 사용할 수 없습니다.",
            engine="validator",
            platform="server",
        ) from error
    finally:
        if process and process.returncode is None:
            await _kill_process_tree(process)
    if return_code:
        raise EngineFailure(
            "DECODE_VALIDATION_FAILED",
            "완료 파일을 끝까지 디코딩하지 못해 손상 파일로 처리했습니다.",
            engine="validator",
            platform="server",
            raw=stderr.decode("utf-8", "replace"),
        )


def _extension_from_probe(probe: dict[str, Any], original: str, kind: str) -> str:
    extension = Path(original).suffix.lower().lstrip(".")
    format_names = set(str((probe.get("format") or {}).get("format_name") or "").split(","))
    codecs = {
        str(stream.get("codec_name") or "")
        for stream in probe.get("streams") or []
        if isinstance(stream, dict)
    }
    if kind == "image":
        for codec, detected in (
            ("mjpeg", "jpg"),
            ("png", "png"),
            ("webp", "webp"),
            ("gif", "gif"),
            ("av1", "avif"),
            ("hevc", "heic"),
        ):
            if codec in codecs:
                return detected
        return extension if extension in IMAGE_EXTENSIONS else ""
    if "webm" in format_names:
        return "webm"
    if "matroska" in format_names:
        return "mka" if kind == "audio" else "mkv"
    if "mp3" in format_names:
        return "mp3"
    if "ogg" in format_names:
        return "ogg"
    if "flac" in format_names:
        return "flac"
    if "wav" in format_names:
        return "wav"
    if "mov" in format_names or "mp4" in format_names or "m4a" in format_names:
        return "m4a" if kind == "audio" else "mp4"
    return extension


async def _validate_media(
    path: Path, expected_kind: str, *, require_audio: bool = False
) -> tuple[str, str, int]:
    size = path.stat().st_size if path.exists() else 0
    if size < 32 or size > MAX_FILE_BYTES:
        raise EngineFailure(
            "INVALID_FILE_SIZE",
            "완료 파일 크기가 유효하지 않습니다.",
            engine="validator",
            platform="server",
        )
    probe = await _probe(path)
    streams = probe.get("streams") or []
    stream_types = {item.get("codec_type") for item in streams if isinstance(item, dict)}
    if expected_kind == "audio" and "audio" not in stream_types:
        raise EngineFailure(
            "MISSING_AUDIO_STREAM",
            "완료 파일에 오디오 스트림이 없습니다.",
            engine="validator",
            platform="server",
        )
    if require_audio and "audio" not in stream_types:
        raise EngineFailure(
            "MISSING_AUDIO_STREAM",
            "병합된 완료 파일에 선택한 오디오 스트림이 없습니다.",
            engine="validator",
            platform="server",
        )
    if expected_kind in {"video", "image"} and "video" not in stream_types:
        raise EngineFailure(
            "MISSING_VIDEO_STREAM",
            "완료 파일에 영상 또는 이미지 스트림이 없습니다.",
            engine="validator",
            platform="server",
        )
    if expected_kind == "image":
        codecs = {
            str(item.get("codec_name") or "")
            for item in streams
            if isinstance(item, dict) and item.get("codec_type") == "video"
        }
        if not codecs.intersection({"mjpeg", "png", "webp", "gif", "av1", "hevc"}):
            raise EngineFailure(
                "MEDIA_KIND_MISMATCH",
                "사진 선택 결과가 실제 이미지 파일이 아닙니다.",
                engine="validator",
                platform="server",
            )
    extension = _extension_from_probe(probe, path.name, expected_kind)
    if not extension:
        raise EngineFailure(
            "UNKNOWN_CONTAINER",
            "완료 파일의 컨테이너 형식을 확인하지 못했습니다.",
            engine="validator",
            platform="server",
        )
    await _decode_check(path)
    mime = (
        "audio/webm"
        if expected_kind == "audio" and extension == "webm"
        else _extension_mime(extension, "application/octet-stream")
    )
    return extension, mime, size


async def _run_job(job: Job) -> None:
    root = JOB_DIR / job.id
    work = root / "work"
    ready = root / "ready"
    work.mkdir(parents=True, exist_ok=True)
    ready.mkdir()
    started = time.perf_counter()
    try:
        async with job_slots:
            if job.cancel_requested:
                raise asyncio.CancelledError
            job.status = "running"
            job.stage = "downloading"
            if job.selection.engine == "cobalt":
                candidate = await _download_cobalt_bounded(job, work)
            elif job.selection.engine == "instagram-image":
                candidate = await _download_instagram_image_bounded(job, work)
            else:
                candidate = await _download_ytdlp(job, work)
            if job.cancel_requested:
                raise asyncio.CancelledError
            job.stage = "verifying"
            job.progress = max(job.progress, 0.96)
            extension, mime, size = await _validate_media(
                candidate,
                job.selection.kind,
                require_audio=(
                    job.selection.engine == "yt-dlp"
                    and job.selection.kind == "video"
                    and "+" in (job.selection.format_selector or "")
                ),
            )
            final_stem = _safe_name(Path(job.selection.file_name).stem)
            final_name = f"{final_stem}.{extension}"
            final_path = ready / final_name
            os.replace(candidate, final_path)
            shutil.rmtree(work, ignore_errors=True)
            job.file_path = final_path
            job.file_name = final_name
            job.mime_type = mime
            job.content_length = size
            job.progress = 1.0
            job.stage = "ready"
            job.status = "complete"
            job.finished_at = time.time()
            _persist_completed_job(job)
    except asyncio.CancelledError:
        failed_stage = job.stage
        job.status = "canceled"
        job.stage = "canceled"
        job.error = {
            "code": "CANCELED",
            "message": "사용자가 다운로드를 취소했습니다.",
            "engine": job.selection.engine,
            "platform": job.platform,
            "retryable": True,
            "stage": failed_stage,
        }
        shutil.rmtree(root, ignore_errors=True)
    except EngineFailure as failure:
        failed_stage = job.stage
        if failure.platform == "server":
            failure.platform = job.platform
        _log_failure(failure, job.source_url)
        job.status = "failed"
        job.stage = "failed"
        job.error = failure.public()
        job.error["stage"] = failed_stage
        shutil.rmtree(root, ignore_errors=True)
    except Exception as error:
        failed_stage = job.stage
        failure = EngineFailure(
            "INTERNAL_ERROR",
            "서버에서 다운로드를 완료하지 못했습니다.",
            engine=job.selection.engine,
            platform=job.platform,
            retryable=True,
            raw=f"{type(error).__name__}: {error}",
        )
        _log_failure(failure, job.source_url)
        job.status = "failed"
        job.stage = "failed"
        job.error = failure.public()
        job.error["stage"] = failed_stage
        shutil.rmtree(root, ignore_errors=True)
    finally:
        job.process = None
        if job.finished_at is None:
            job.finished_at = time.time()
        logger.info(
            "job_complete platform=%s engine=%s status=%s elapsed_ms=%s bytes=%s",
            job.platform,
            job.selection.engine,
            job.status,
            round((time.perf_counter() - started) * 1000),
            job.content_length or 0,
        )


@app.api_route("/v1/files/{job_id}", methods=["GET", "HEAD"])
async def get_file(
    job_id: str,
    ticket: Annotated[str, Query(min_length=32, max_length=100)],
) -> FileResponse:
    _clean_expired()
    job = jobs.get(job_id)
    if (
        not job
        or job.status != "complete"
        or not job.file_path
        or not job.file_path.is_file()
        or not hmac.compare_digest(ticket, job.ticket)
        or not job.finished_at
        or time.time() - job.finished_at > FILE_TTL_SECONDS
    ):
        raise HTTPException(404, detail={"code": "FILE_NOT_FOUND"})
    return FileResponse(
        path=job.file_path,
        media_type=job.mime_type,
        filename=job.file_name,
        headers={
            "Cache-Control": "private, no-store",
            "Accept-Ranges": "bytes",
            "X-Content-Type-Options": "nosniff",
        },
    )
