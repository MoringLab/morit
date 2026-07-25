import 'package:flutter_test/flutter_test.dart';
import 'package:morit/morit/media/media_provider.dart';

void main() {
  test('classifies every supported platform without lookalike hosts', () {
    const cases = {
      'https://youtu.be/abc': 'YouTube',
      'https://instagram.com/p/abc': 'Instagram',
      'https://fb.watch/abc': 'Facebook',
      'https://threads.com/@morit/post/abc': 'Threads',
      'https://vm.tiktok.com/abc': 'TikTok',
      'https://x.com/morit/status/123': 'X (Twitter)',
      'https://bsky.app/profile/morit.test/post/abc': 'Bluesky',
      'https://redd.it/abc': 'Reddit',
      'https://pin.it/abc': 'Pinterest',
      'https://snapchat.com/spotlight/abc': 'Snapchat',
      'https://lnkd.in/abc': 'LinkedIn',
      'https://tumblr.com/morit/123': 'Tumblr',
      'https://clips.twitch.tv/abc': 'Twitch',
      'https://vimeo.com/123': 'Vimeo',
      'https://dai.ly/abc': 'Dailymotion',
      'https://cdn.discordapp.com/attachments/a/b/file.png': 'Discord',
      'https://t.me/morit/123': 'Telegram',
      'https://story.kakao.com/morit/abc': 'KakaoStory',
      'https://cafe.naver.com/morit/123': 'Naver Cafe',
      'https://blog.naver.com/morit/123': 'Naver Blog',
      'https://band.us/band/123/post/456': 'Naver Band',
      'https://line.me/R/msg/text/': 'LINE',
      'https://medium.com/@morit/post-abc': 'Medium',
      'https://morit.substack.com/p/post': 'Substack',
      'https://morit.wordpress.com/post': 'WordPress',
      'https://behance.net/gallery/123/project': 'Behance',
      'https://flic.kr/p/abc': 'Flickr',
      'https://i.imgur.com/file.jpg': 'Imgur',
      'https://on.soundcloud.com/abc': 'SoundCloud',
    };

    for (final entry in cases.entries) {
      expect(
        mediaPlatformFor(Uri.parse(entry.key))?.label,
        entry.value,
        reason: entry.key,
      );
    }
    expect(
      mediaPlatformFor(Uri.parse('https://youtube.com.evil.example/watch')),
      isNull,
    );
  });

  test('classifies direct, short, post, generic, and unsupported formats', () {
    expect(
      classifyMediaUrl(
        Uri.parse('https://cdn.discordapp.com/attachments/a/b/file.mp4'),
      ).format,
      MediaLinkFormat.directMedia,
    );
    expect(
      classifyMediaUrl(Uri.parse('https://youtu.be/abc')).format,
      MediaLinkFormat.shortLink,
    );
    expect(
      classifyMediaUrl(Uri.parse('https://x.com/morit/status/123')).format,
      MediaLinkFormat.post,
    );
    expect(
      classifyMediaUrl(Uri.parse('https://example.com/article')).format,
      MediaLinkFormat.page,
    );
    final unsupported = classifyMediaUrl(
      Uri.parse('https://instagram.com/accounts/login'),
    );
    expect(unsupported.format, MediaLinkFormat.unsupported);
    expect(unsupported.recognized, isFalse);
  });

  test(
    'detailed analysis reports actionable failure without network access',
    () async {
      final analyzer = MediaAnalyzer(
        registry: MediaProviderRegistry([_EmptyProvider()]),
      );

      final insecure = await analyzer.analyzeDetailed(
        Uri.parse('http://example.com/video'),
      );
      expect(insecure.failure?.code, MediaAnalysisFailureCode.insecureUrl);

      final unsupported = await analyzer.analyzeDetailed(
        Uri.parse('https://instagram.com/accounts/login'),
      );
      expect(
        unsupported.failure?.code,
        MediaAnalysisFailureCode.unsupportedLinkFormat,
      );

      final noMedia = await analyzer.analyzeDetailed(
        Uri.parse('https://example.com/article'),
      );
      expect(noMedia.failure?.code, MediaAnalysisFailureCode.noPublicMedia);
      expect(
        await analyzer.analyze(Uri.parse('https://example.com/article')),
        isNull,
      );
    },
  );

  test('extracts relative HTML media and deduplicates URLs', () {
    final candidates = extractMediaCandidatesFromHtml('''
      <meta property="og:video" content="/media/clip.mp4">
      <meta property="og:video:url" content="https://example.com/media/clip.mp4">
      <meta property="og:image" content="//example.com/poster.webp">
      <source src="/audio/theme.mp3" type="audio/mpeg">
      <script type="application/ld+json">
        {
          "@type":"VideoObject",
          "url":"/watch/other",
          "contentUrl":"/media/other.mp4"
        }
      </script>
      ''', Uri.parse('https://example.com/watch/1'));

    expect(candidates.map((value) => value.url.toString()), [
      'https://example.com/media/clip.mp4',
      'https://example.com/audio/theme.mp3',
      'https://example.com/media/other.mp4',
    ]);
    expect(candidates.first.kind, MediaKind.video);
    expect(candidates[1].mimeType, 'audio/mpeg');
    expect(candidates.every((value) => !value.isPreview), isTrue);
    expect(
      candidates.every(
        (value) =>
            value.headers['Referer'] == 'https://example.com/watch/1' &&
            value.headers['User-Agent']?.contains('Morit/1.5') == true,
      ),
      isTrue,
    );
  });

  test('rejects non-HTTPS page and candidate URLs', () {
    expect(
      extractMediaCandidatesFromHtml(
        '<meta property="og:video" content="https://example.com/video.mp4">',
        Uri.parse('http://example.com/page'),
      ),
      isEmpty,
    );

    final candidates = extractMediaCandidatesFromHtml('''
      <meta property="og:video" content="http://example.com/video.mp4">
      <meta property="og:image" content="javascript:alert(1)">
      <meta property="og:image" content="https://127.0.0.1/private.jpg">
      <source src="https://cdn.example.com/photo.jpg">
      ''', Uri.parse('https://example.com/page'));

    expect(candidates, hasLength(1));
    expect(
      candidates.single.url,
      Uri.parse('https://cdn.example.com/photo.jpg'),
    );
    expect(candidates.single.kind, MediaKind.image);
  });

  test('rejects HTML players and streaming manifests as files', () {
    final candidates = extractMediaCandidatesFromHtml('''
      <meta property="og:video" content="/embed/player">
      <meta property="og:video:type" content="text/html">
      <source src="/stream/master.m3u8" type="application/vnd.apple.mpegurl">
      <source src="/media/clip.mp4" type="video/mp4">
      ''', Uri.parse('https://example.com/watch/1'));

    expect(candidates, hasLength(1));
    expect(
      candidates.single.url.toString(),
      'https://example.com/media/clip.mp4',
    );
    expect(
      extractMediaCandidatesFromHtml(
        '<meta property="og:image" content="/thumbnail.jpg">',
        Uri.parse('https://example.com/watch/1'),
      ),
      isEmpty,
    );
  });

  test('extracts only Bluesky full-size gallery images', () {
    final candidates = extractBlueskyMediaCandidates({
      'thread': {
        'post': {
          'embed': {
            'items': [
              {
                'thumb': 'https://cdn.bsky.app/thumb/one.jpg',
                'fullsize': 'https://cdn.bsky.app/full/one.jpg',
              },
              {
                'thumbnail': 'https://cdn.bsky.app/thumb/two.jpg',
                'fullsize': 'https://cdn.bsky.app/full/two.jpg',
              },
            ],
            'external': {'fullsize': 'https://ads.example.com/card.jpg'},
          },
        },
      },
    }, Uri.parse('https://bsky.app/profile/example.com/post/abc123'));

    expect(candidates.map((candidate) => candidate.url.toString()), [
      'https://cdn.bsky.app/full/one.jpg',
      'https://cdn.bsky.app/full/two.jpg',
    ]);
    expect(candidates.every((candidate) => !candidate.isPreview), isTrue);
  });

  test('extracts carousel media and ignores UI image noise', () {
    final candidates = extractMediaCandidatesFromHtml('''
      <meta property="og:image" content="/photos/cover.jpg">
      <img src="/ui/logo.png" width="48" height="48">
      <img srcset="/photos/story-small.webp 320w, /photos/story.webp 1280w">
      <script type="application/ld+json">
        {
          "@type": "ImageGallery",
          "image": [
            {"@type":"ImageObject","contentUrl":"/photos/one.jpg"},
            {"@type":"ImageObject","url":"/photos/two.webp"}
          ],
          "thumbnailUrl": "/photos/thumbnail.jpg"
        }
      </script>
      <script id="__NEXT_DATA__" type="application/json">
        {
          "carousel_media": [
            {
              "image_versions2": {
                "candidates": [
                  {"url":"/photos/three-small.jpg","width":320,"height":320},
                  {"url":"/photos/three.jpg","width":1080,"height":1080}
                ]
              }
            },
            {
              "video_info": {
                "variants": [
                  {"url":"/clips/four.mp4","content_type":"video/mp4"}
                ]
              }
            }
          ],
          "profile_image_url_https": "/ui/avatar.jpg",
          "tracking_pixel": "/ui/pixel.gif"
        }
      </script>
      ''', Uri.parse('https://example.com/post/1'));

    expect(candidates.map((value) => value.url.toString()), [
      'https://example.com/photos/story.webp',
      'https://example.com/photos/one.jpg',
      'https://example.com/photos/two.webp',
      'https://example.com/photos/three.jpg',
      'https://example.com/clips/four.mp4',
    ]);
    expect(
      candidates.map((value) => value.kind),
      containsAll([MediaKind.image, MediaKind.video]),
    );
  });

  test('keeps post media while removing previews, ads, and UI assets', () {
    final candidates = extractMediaCandidatesFromHtml('''
      <meta property="og:image" content="/preview/poster.jpg">
      <img class="profile avatar" src="/photos/profile.jpg" width="640" height="640">
      <img src="https://doubleclick.net/ads/campaign.jpg" width="1200" height="800">
      <script type="application/json">
        {
          "advertisement": {"image_url": "/ads/sponsored.jpg"},
          "adaptiveFormats": [{"url": "/stream/video-only.mp4", "mimeType": "video/mp4"}],
          "video": {
            "playAddr": {"urlList": ["/posts/actual.mp4"]}
          },
          "poster": {"url": "/preview/video-poster.jpg"}
        }
      </script>
      ''', Uri.parse('https://example.com/post/1'));

    expect(candidates.map((value) => value.url.toString()), [
      'https://example.com/posts/actual.mp4',
    ]);
    expect(candidates.single.kind, MediaKind.video);
  });

  test('rejects Vimeo and X page/profile assets but keeps post media CDNs', () {
    final vimeo = extractMediaCandidatesFromHtml('''
      <script type="application/json">
        {
          "video": {"url": "https://vimeo.com/286898202"},
          "image": {"url": "https://vimeo.com/techuser"},
          "images": [
            {"url": "https://i.vimeocdn.com/portrait/123_300x300.jpg"}
          ]
        }
      </script>
      ''', Uri.parse('https://vimeo.com/286898202'));
    expect(vimeo, isEmpty);

    final x = extractMediaCandidatesFromHtml('''
      <img src="https://pbs.twimg.com/profile_images/1/avatar_normal.jpg" width="400" height="400">
      <img src="https://abs.twimg.com/x-web/client-web/tap-hand.png" width="400" height="400">
      <img src="https://pbs.twimg.com/media/POST_IMAGE.jpg" width="1200" height="800">
      <video src="https://video.twimg.com/tweet_video/POST_VIDEO.mp4"></video>
      ''', Uri.parse('https://x.com/jack/status/20'));
    expect(x, hasLength(2));
    expect(
      x.map((candidate) => candidate.url.toString()),
      containsAll([
        'https://pbs.twimg.com/media/POST_IMAGE.jpg',
        'https://video.twimg.com/tweet_video/POST_VIDEO.mp4',
      ]),
    );

    final progressive = extractMediaCandidatesFromHtml(
      '<video src="https://player.vimeo.com/progressive_redirect/playback/1/file.mp4"></video>',
      Uri.parse('https://vimeo.com/286898202'),
    );
    expect(progressive, hasLength(1));
  });

  test('validates response bytes and repairs MIME and extension', () {
    final image = MediaCandidate(
      url: Uri.parse('https://cdn.example.com/photo.jpg'),
      kind: MediaKind.image,
      fileName: 'photo.jpg',
      providerLabel: 'Test',
      mimeType: 'image/jpeg',
    );

    final invalid = validateMediaResponse(
      image,
      responseUrl: image.url,
      statusCode: 200,
      contentType: 'image/jpeg',
      contentLength: 32,
      firstBytes: '<!doctype html><title>Denied</title>'.codeUnits,
    );
    expect(
      invalid.failure?.code,
      MediaAnalysisFailureCode.invalidMediaResponse,
    );

    final repaired = validateMediaResponse(
      image,
      responseUrl: image.url,
      statusCode: 200,
      contentType: 'text/plain',
      contentLength: 128,
      firstBytes: const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    ).candidate!;
    expect(repaired.mimeType, 'image/png');
    expect(repaired.fileName, 'photo.png');

    final adaptive = validateMediaResponse(
      image,
      responseUrl: Uri.parse('https://cdn.example.com/manifest'),
      statusCode: 200,
      contentType: 'text/plain',
      contentLength: 32,
      firstBytes: '#EXTM3U'.codeUnits,
    );
    expect(
      adaptive.failure?.code,
      MediaAnalysisFailureCode.adaptiveStreamUnsupported,
    );
  });

  test('gives different URLs stable unique file names', () {
    final candidates = extractMediaCandidatesFromHtml('''
      <img src="https://cdn.example.com/image.jpg?v=1" width="1000" height="1000">
      <img src="https://cdn.example.com/image.jpg?v=2" width="1000" height="1000">
      <img src="https://cdn.example.com/image_2.jpg" width="1000" height="1000">
      ''', Uri.parse('https://example.com/post/1'));

    expect(candidates.map((value) => value.fileName), [
      'image.jpg',
      'image_2.jpg',
      'image_2_2.jpg',
    ]);
  });
}

final class _EmptyProvider implements MediaProvider {
  @override
  bool supports(Uri url) => true;

  @override
  Future<MediaAnalysis?> analyze(Uri url) async => null;
}
