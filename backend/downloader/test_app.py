import asyncio
import importlib.util
import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import replace
from pathlib import Path


os.environ.setdefault("DATA_DIR", tempfile.mkdtemp(prefix="morit-downloader-test-"))
os.environ.setdefault("DEV_AUTH_BYPASS", "true")

from fastapi.testclient import TestClient

import app as backend
from app import (
    Job,
    Selection,
    _build_ytdlp_selections,
    _compose_cobalt_url,
    _instagram_image_urls,
    _instagram_original_image_url,
    _persist_completed_job,
    _restore_completed_jobs,
    _safe_remote_url,
    _validate_cobalt_api_url,
    _validate_media,
    _validate_url_shape,
    app,
    analyses,
    jobs,
)


def expect_rejected(url: str) -> None:
    try:
        _validate_url_shape(url)
    except ValueError:
        return
    raise AssertionError(f"unsafe URL accepted: {url}")


def main() -> None:
    assert _validate_url_shape("https://youtu.be/abc") == "https://youtu.be/abc"
    for unsafe in (
        "http://youtube.com/watch?v=x",
        "https://user:pass@youtube.com/watch?v=x",
        "https://127.0.0.1/watch?v=x",
        "https://example.com/video",
    ):
        expect_rejected(unsafe)

    assert (
        _compose_cobalt_url("http://cobalt:9000/tunnel?id=one")
        == "http://cobalt:9000/tunnel?id=one"
    )
    for unsafe_cobalt in (
        "http://cobalt:9001/tunnel",
        "http://cobalt.example:9000/tunnel",
        "http://localhost:9000/tunnel",
        "http://169.254.169.254/latest/meta-data",
    ):
        assert _compose_cobalt_url(unsafe_cobalt) is None
    cobalt_url = backend.COBALT_API_URL
    try:
        backend.COBALT_API_URL = "http://cobalt:9000"
        assert asyncio.run(_validate_cobalt_api_url()) == "http://cobalt:9000"
        assert (
            asyncio.run(_safe_remote_url("http://cobalt:9000/tunnel?id=one"))
            == "http://cobalt:9000/tunnel?id=one"
        )
        for unsafe_cobalt in (
            "http://cobalt:9000/not-an-origin",
            "http://cobalt:9001",
            "http://localhost:9000",
        ):
            backend.COBALT_API_URL = unsafe_cobalt
            try:
                asyncio.run(_validate_cobalt_api_url())
            except ValueError:
                pass
            else:
                raise AssertionError(f"unsafe Cobalt API accepted: {unsafe_cobalt}")
    finally:
        backend.COBALT_API_URL = cobalt_url

    video_info = {
        "id": "one",
        "title": "sample",
        "extractor_key": "Youtube",
        "formats": [
            {
                "format_id": "137",
                "ext": "mp4",
                "vcodec": "h264",
                "acodec": "none",
                "width": 1920,
                "height": 1080,
                "tbr": 4500,
            },
            {
                "format_id": "136",
                "ext": "mp4",
                "vcodec": "h264",
                "acodec": "none",
                "width": 1280,
                "height": 720,
                "tbr": 2500,
            },
            {
                "format_id": "140",
                "ext": "m4a",
                "vcodec": "none",
                "acodec": "aac",
                "abr": 128,
            },
        ],
    }
    _, _, variants = _build_ytdlp_selections(
        video_info, "https://youtube.com/watch?v=one"
    )
    assert len({item.asset_id for item in variants}) == 1
    assert sum(item.recommended for item in variants) == 1
    assert all(item.format_selector for item in variants)

    gallery_info = {
        "id": "gallery",
        "title": "gallery",
        "extractor_key": "Instagram",
        "entries": [
            {
                "id": "a",
                "formats": [
                    {
                        "format_id": "a",
                        "ext": "jpg",
                        "vcodec": "none",
                        "acodec": "none",
                        "width": 100,
                        "height": 100,
                    }
                ],
            },
            {
                "id": "b",
                "formats": [
                    {
                        "format_id": "b",
                        "ext": "jpg",
                        "vcodec": "none",
                        "acodec": "none",
                        "width": 100,
                        "height": 100,
                    }
                ],
            },
        ],
    }
    _, _, photos = _build_ytdlp_selections(
        gallery_info, "https://instagram.com/p/gallery"
    )
    assert len(photos) == 2
    assert len({item.asset_id for item in photos}) == 2

    original = (
        "https://instagram.ficn1-1.fna.fbcdn.net/v/t51.2885-15/example.webp"
        "?oh=signed&oe=expiry&ig_cache_key=asset"
    )
    full_transform = original + "&stp=dst-webp_e35_tt6"
    resized = original + "&stp=dst-webp_s320x320"
    cropped = original + "&stp=dst-webp_c0.280.1440.1440"
    assert _instagram_original_image_url(original) == original
    assert _instagram_original_image_url(full_transform) == full_transform
    assert _instagram_original_image_url(resized) is None
    assert _instagram_original_image_url(cropped) is None
    for unsafe_instagram_image in (
        original.replace("https://", "http://"),
        original.replace("https://", "https://user:pass@"),
        original.replace(".net/", ".net:444/"),
        original.replace(
            "instagram.ficn1-1.fna.fbcdn.net",
            "instagram.ficn1-1.fna.fbcdn.net.evil.com",
        ),
        original.replace("instagram.ficn1-1.fna.fbcdn.net", "localhost"),
        original.replace("instagram.ficn1-1.fna.fbcdn.net", "127.0.0.1"),
        original.replace("oh=signed&", ""),
        original.replace("&oe=expiry", ""),
        original.replace("&ig_cache_key=asset", ""),
        original.replace("oh=signed", "oh="),
        original.replace("example.webp", "example.svg"),
        original + "&oh=duplicate",
    ):
        assert _instagram_original_image_url(unsafe_instagram_image) is None
    image_carousel = {
        "id": "carousel",
        "title": "photos",
        "extractor": "Instagram",
        "extractor_key": "Instagram",
        "entries": [
            {
                "id": "photo-a",
                "extractor": "Instagram",
                "extractor_key": "Instagram",
                "formats": [],
                "thumbnails": [{"url": original}, {"url": resized}],
            },
            {
                "id": "photo-b",
                "extractor": "Instagram",
                "extractor_key": "Instagram",
                "formats": [],
                "thumbnails": [
                    {
                        "url": original.replace("asset", "asset-b").replace(
                            "example", "example-b"
                        )
                    }
                ],
            },
        ],
    }
    carousel_urls = _instagram_image_urls(
        image_carousel, image_carousel["entries"]
    )
    assert carousel_urls and len(carousel_urls) == 2
    _, _, carousel_photos = _build_ytdlp_selections(
        image_carousel, "https://instagram.com/p/carousel"
    )
    assert [item.engine for item in carousel_photos] == [
        "instagram-image",
        "instagram-image",
    ]
    assert len({item.asset_id for item in carousel_photos}) == 2
    one_entry = dict(image_carousel["entries"][0])
    one_entry.update(
        {
            "title": "one photo",
            "webpage_url": "https://www.instagram.com/p/one/",
        }
    )
    assert _instagram_image_urls(one_entry, [one_entry]) == [original]
    mixed_video = dict(image_carousel["entries"][1])
    mixed_video["formats"] = [{"format_id": "video", "vcodec": "h264"}]
    assert _instagram_image_urls(
        image_carousel, [image_carousel["entries"][0], mixed_video]
    ) == [original, None]
    mixed_info = dict(image_carousel)
    mixed_info["entries"] = [image_carousel["entries"][0], mixed_video]
    _, _, mixed_selections = _build_ytdlp_selections(
        mixed_info, "https://instagram.com/p/mixed"
    )
    assert [item.kind for item in mixed_selections] == ["image", "video"]
    assert [item.engine for item in mixed_selections] == [
        "instagram-image",
        "yt-dlp",
    ]

    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise AssertionError("ffmpeg and ffprobe are required")
    root = Path(os.environ["DATA_DIR"])
    sample = root / "sample.mp4"
    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=64x64:d=0.25",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-y",
            str(sample),
        ],
        check=True,
    )
    extension, mime, size = asyncio.run(_validate_media(sample, "video"))
    assert (extension, mime) == ("mp4", "video/mp4")
    assert size == sample.stat().st_size
    try:
        asyncio.run(_validate_media(sample, "video", require_audio=True))
    except backend.EngineFailure as failure:
        assert failure.code == "MISSING_AUDIO_STREAM"
    else:
        raise AssertionError("merged video without its selected audio stream was accepted")

    selection = Selection(
        id="selection-id",
        asset_id="asset-id",
        kind="video",
        label="test",
        file_name="sample.mp4",
        mime_type=mime,
        extension=extension,
        width=64,
        height=64,
        bitrate=None,
        size_bytes=size,
        is_preview=False,
        recommended=True,
        engine="yt-dlp",
        format_selector="best",
    )
    job = Job(
        id="range-test",
        user_id="dev-local",
        request_id="range-request",
        analysis_id="analysis",
        selection=selection,
        source_url="https://youtu.be/test",
        platform="youtube",
        ticket="t" * 40,
        status="complete",
        stage="ready",
        progress=1,
        file_path=sample,
        file_name=sample.name,
        mime_type=mime,
        content_length=size,
        finished_at=time.time(),
    )
    jobs[job.id] = job
    with TestClient(app) as client:
        ranged = client.get(
            f"/v1/files/{job.id}?ticket={job.ticket}",
            headers={"Range": "bytes=0-3"},
        )
        assert ranged.status_code == 206
        assert len(ranged.content) == 4
        assert ranged.headers["content-range"].startswith("bytes 0-3/")
        head = client.head(f"/v1/files/{job.id}?ticket={job.ticket}")
        assert head.status_code == 200
        assert int(head.headers["content-length"]) == size
        assert head.content == b""
        transfer = client.get(f"/v1/transfers/{job.id}?ticket={job.ticket}")
        assert transfer.status_code == 200
        assert transfer.json()["file"]["content_length"] == size

    persisted_id = "a" * 32
    persisted_ready = backend.JOB_DIR / persisted_id / "ready"
    persisted_ready.mkdir(parents=True)
    persisted_file = persisted_ready / sample.name
    shutil.copyfile(sample, persisted_file)
    persisted = replace(
        job,
        id=persisted_id,
        request_id="persist-request",
        file_path=persisted_file,
    )
    _persist_completed_job(persisted)
    jobs.pop(persisted.id, None)
    _restore_completed_jobs()
    assert jobs[persisted.id].file_path == persisted_file.resolve()

    jobs.clear()
    active = replace(
        job,
        id="active",
        status="running",
        stage="downloading",
        file_path=None,
        content_length=None,
        finished_at=None,
    )
    old = replace(job, id="old", created_at=time.time() - 20)
    newest = replace(job, id="newest", created_at=time.time() - 10)
    jobs.update({item.id: item for item in (active, old, newest)})
    retained_jobs = backend.MAX_RETAINED_JOBS
    retained_bytes = backend.MAX_RETAINED_BYTES
    try:
        backend.MAX_RETAINED_JOBS = 1
        backend.MAX_RETAINED_BYTES = size * 10
        backend._clean_expired()
        assert "active" in jobs
        assert "old" not in jobs
        assert "newest" in jobs
    finally:
        backend.MAX_RETAINED_JOBS = retained_jobs
        backend.MAX_RETAINED_BYTES = retained_bytes
        jobs.clear()

    shutil.rmtree(root, ignore_errors=True)
    runtime = "deno" if shutil.which("deno") else "node" if shutil.which("node") else None
    print(
        "ok: URL trust, selections, decode validation, HEAD/Range, active-safe retention; "
        f"host_ejs={importlib.util.find_spec('yt_dlp_ejs') is not None}, "
        f"host_js_runtime={runtime or 'missing'}"
    )


if __name__ == "__main__":
    main()
