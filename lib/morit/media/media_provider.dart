import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _requestTimeout = Duration(seconds: 12);
const _maxPageBytes = 2 * 1024 * 1024;
const _maxStructuredDepth = 32;
const _maxRawCandidates = 100;
const _browserUserAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36 Morit/1.5';
const _pageAccept =
    'text/html,application/xhtml+xml,image/avif,image/webp,'
    'image/*,video/*,audio/*,*/*;q=0.8';

enum MediaKind { video, audio, image, file }

final class MediaCandidate {
  const MediaCandidate({
    required this.url,
    required this.kind,
    required this.fileName,
    required this.providerLabel,
    this.mimeType,
    this.headers = const {},
    this.isPreview = false,
    this.analysisId,
    this.selectionId,
    this.assetId,
    this.qualityLabel,
    this.sizeBytes,
    this.recommended = false,
  });

  final Uri url;
  final MediaKind kind;
  final String fileName;
  final String providerLabel;
  final String? mimeType;
  final Map<String, String> headers;
  final bool isPreview;
  final String? analysisId;
  final String? selectionId;
  final String? assetId;
  final String? qualityLabel;
  final int? sizeBytes;
  final bool recommended;

  bool get isBackendSelection =>
      analysisId?.isNotEmpty == true && selectionId?.isNotEmpty == true;
}

final class MediaAnalysis {
  const MediaAnalysis({
    required this.sourceUrl,
    required this.providerLabel,
    required this.candidates,
    this.title,
    this.thumbnailUrl,
  });

  final Uri sourceUrl;
  final String providerLabel;
  final List<MediaCandidate> candidates;
  final String? title;
  final Uri? thumbnailUrl;
}

enum MediaLinkFormat { directMedia, shortLink, post, page, unsupported }

final class MediaPlatformDescriptor {
  const MediaPlatformDescriptor({
    required this.id,
    required this.label,
    required this.hosts,
    this.shortHosts = const [],
    this.postPathPatterns = const [r'^/.+'],
    this.accessNote,
  });

  final String id;
  final String label;
  final List<String> hosts;
  final List<String> shortHosts;
  final List<String> postPathPatterns;

  /// Explains a platform limitation without claiming that every public link is
  /// restricted.
  final String? accessNote;

  bool matchesHost(String host) =>
      hosts.any((domain) => _hostMatches(host, domain));

  bool isShortHost(String host) =>
      shortHosts.any((domain) => _hostMatches(host, domain));

  bool recognizesPath(String path) => postPathPatterns.any(
    (pattern) => RegExp(pattern, caseSensitive: false).hasMatch(path),
  );
}

const defaultMediaPlatforms = <MediaPlatformDescriptor>[
  MediaPlatformDescriptor(
    id: 'youtube',
    label: 'YouTube',
    hosts: ['youtube.com', 'youtu.be'],
    shortHosts: ['youtu.be'],
    postPathPatterns: [r'^/watch/?$', r'^/(?:shorts|live|embed)/[^/]+/?$'],
    accessNote: '비공개·연령 제한·DRM 콘텐츠는 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'instagram',
    label: 'Instagram',
    hosts: ['instagram.com'],
    postPathPatterns: [r'^/(?:p|reel|reels|tv)/[^/]+/?$'],
    accessNote: '비공개 계정이나 로그인 전용 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'facebook',
    label: 'Facebook',
    hosts: ['facebook.com', 'fb.watch'],
    shortHosts: ['fb.watch'],
    postPathPatterns: [
      r'^/(?:watch|reel|share|videos?)(?:/|$)',
      r'^/[^/]+/(?:videos|posts)/',
    ],
    accessNote: '로그인 전용·친구 공개 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'threads',
    label: 'Threads',
    hosts: ['threads.com', 'threads.net'],
    postPathPatterns: [r'^/@[^/]+/post/[^/]+/?$'],
    accessNote: '비공개 계정 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'tiktok',
    label: 'TikTok',
    hosts: ['tiktok.com'],
    shortHosts: ['vm.tiktok.com', 'vt.tiktok.com'],
    postPathPatterns: [r'^/@[^/]+/video/[^/]+/?$', r'^/t/[^/]+/?$'],
    accessNote: '비공개·연령 제한 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'x',
    label: 'X (Twitter)',
    hosts: ['x.com', 'twitter.com'],
    postPathPatterns: [r'^/(?:[^/]+|i)/status/\d+/?$'],
    accessNote: '보호 계정이나 로그인 전용 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'bluesky',
    label: 'Bluesky',
    hosts: ['bsky.app'],
    postPathPatterns: [r'^/profile/[^/]+/post/[^/]+/?$'],
  ),
  MediaPlatformDescriptor(
    id: 'reddit',
    label: 'Reddit',
    hosts: ['reddit.com', 'redd.it'],
    shortHosts: ['redd.it'],
    postPathPatterns: [
      r'^/(?:r/[^/]+/)?comments/[^/]+(?:/|$)',
      r'^/r/[^/]+/s/[^/]+/?$',
    ],
    accessNote: '비공개 커뮤니티나 로그인 전용 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'pinterest',
    label: 'Pinterest',
    hosts: ['pinterest.com', 'pin.it'],
    shortHosts: ['pin.it'],
    postPathPatterns: [r'^/pin/[^/]+/?$'],
  ),
  MediaPlatformDescriptor(
    id: 'snapchat',
    label: 'Snapchat',
    hosts: ['snapchat.com'],
    postPathPatterns: [r'^/(?:spotlight|t|p)/[^/]+(?:/|$)'],
    accessNote: '친구 공개·로그인 전용 콘텐츠는 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'linkedin',
    label: 'LinkedIn',
    hosts: ['linkedin.com', 'lnkd.in'],
    shortHosts: ['lnkd.in'],
    postPathPatterns: [r'^/(?:posts|feed/update)/.+'],
    accessNote: '로그인 또는 조직 권한이 필요한 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'tumblr',
    label: 'Tumblr',
    hosts: ['tumblr.com'],
    postPathPatterns: [r'^/(?:post/)?\d+(?:/|$)', r'^/[^/]+/\d+(?:/|$)'],
  ),
  MediaPlatformDescriptor(
    id: 'twitch',
    label: 'Twitch',
    hosts: ['twitch.tv'],
    postPathPatterns: [
      r'^/videos/\d+/?$',
      r'^/[^/]+/clip/[^/]+/?$',
      r'^/[^/]+/?$',
    ],
    accessNote: '구독자 전용·삭제된 VOD나 DRM 스트림은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'vimeo',
    label: 'Vimeo',
    hosts: ['vimeo.com'],
    postPathPatterns: [r'^/(?:.*?/)?\d+/?$'],
    accessNote: '비밀번호·DRM 보호 영상은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'dailymotion',
    label: 'Dailymotion',
    hosts: ['dailymotion.com', 'dai.ly'],
    shortHosts: ['dai.ly'],
    postPathPatterns: [r'^/video/[^/]+/?$'],
  ),
  MediaPlatformDescriptor(
    id: 'discord',
    label: 'Discord',
    hosts: [
      'discord.com',
      'discord.gg',
      'discordapp.com',
      'cdn.discordapp.com',
      'media.discordapp.net',
    ],
    shortHosts: ['discord.gg'],
    postPathPatterns: [r'^/channels/\d+/\d+/\d+/?$', r'^/attachments/.+'],
    accessNote: '채널 권한이나 로그인이 필요한 메시지는 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'telegram',
    label: 'Telegram',
    hosts: ['t.me', 'telegram.me'],
    postPathPatterns: [r'^/(?:s/)?[^/]+/\d+/?$'],
    accessNote: '비공개 채널이나 초대 전용 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'kakaostory',
    label: 'KakaoStory',
    hosts: ['story.kakao.com'],
    accessNote: '친구 공개·로그인 전용 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'naver_cafe',
    label: 'Naver Cafe',
    hosts: ['cafe.naver.com'],
    accessNote: '카페 가입 또는 로그인이 필요한 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'naver_blog',
    label: 'Naver Blog',
    hosts: ['blog.naver.com'],
  ),
  MediaPlatformDescriptor(
    id: 'naver_band',
    label: 'Naver Band',
    hosts: ['band.us'],
    postPathPatterns: [r'^/band/\d+/post/\d+/?$'],
    accessNote: '밴드 가입 또는 로그인이 필요한 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'line',
    label: 'LINE',
    hosts: ['line.me'],
    accessNote: '앱 전용·로그인 전용 콘텐츠는 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(id: 'medium', label: 'Medium', hosts: ['medium.com']),
  MediaPlatformDescriptor(
    id: 'substack',
    label: 'Substack',
    hosts: ['substack.com'],
    postPathPatterns: [r'^/p/[^/]+/?$'],
    accessNote: '유료 구독자 전용 게시물은 분석할 수 없습니다.',
  ),
  MediaPlatformDescriptor(
    id: 'wordpress',
    label: 'WordPress',
    hosts: ['wordpress.com', 'wp.me'],
    shortHosts: ['wp.me'],
  ),
  MediaPlatformDescriptor(
    id: 'behance',
    label: 'Behance',
    hosts: ['behance.net'],
    postPathPatterns: [r'^/gallery/\d+/.+'],
  ),
  MediaPlatformDescriptor(
    id: 'flickr',
    label: 'Flickr',
    hosts: ['flickr.com', 'flic.kr'],
    shortHosts: ['flic.kr'],
    postPathPatterns: [r'^/photos/[^/]+/[^/]+/?$'],
  ),
  MediaPlatformDescriptor(
    id: 'imgur',
    label: 'Imgur',
    hosts: ['imgur.com'],
    postPathPatterns: [r'^/(?:gallery|a)/[^/]+/?$', r'^/[^/]+/?$'],
  ),
  MediaPlatformDescriptor(
    id: 'soundcloud',
    label: 'SoundCloud',
    hosts: ['soundcloud.com', 'snd.sc'],
    shortHosts: ['on.soundcloud.com', 'snd.sc'],
    postPathPatterns: [r'^/[^/]+/[^/]+/?$'],
    accessNote: '비공개·지역 제한·다운로드 제한 트랙은 분석할 수 없습니다.',
  ),
];

MediaPlatformDescriptor? mediaPlatformFor(
  Uri url, {
  Iterable<MediaPlatformDescriptor> platforms = defaultMediaPlatforms,
}) {
  final host = url.host.toLowerCase();
  return platforms.where((platform) => platform.matchesHost(host)).firstOrNull;
}

MediaLinkClassification classifyMediaUrl(
  Uri url, {
  Iterable<MediaPlatformDescriptor> platforms = defaultMediaPlatforms,
}) {
  final platform = mediaPlatformFor(url, platforms: platforms);
  if (url.host.isEmpty || url.userInfo.isNotEmpty) {
    return MediaLinkClassification(
      url: url,
      platform: platform,
      format: MediaLinkFormat.unsupported,
      recognized: false,
      note: '호스트가 없거나 사용자 정보가 포함된 주소는 지원하지 않습니다.',
    );
  }
  if (_mimeFromUrl(url) != null) {
    return MediaLinkClassification(
      url: url,
      platform: platform,
      format: MediaLinkFormat.directMedia,
      recognized: true,
    );
  }
  if (platform == null) {
    return MediaLinkClassification(
      url: url,
      format: MediaLinkFormat.page,
      recognized: true,
      note: '공개 표준 메타데이터가 있는 웹 페이지만 분석합니다.',
    );
  }
  final host = url.host.toLowerCase();
  if (platform.isShortHost(host)) {
    return MediaLinkClassification(
      url: url,
      platform: platform,
      format: MediaLinkFormat.shortLink,
      recognized: url.pathSegments.isNotEmpty,
      note: platform.accessNote,
    );
  }
  final recognized = platform.recognizesPath(url.path);
  return MediaLinkClassification(
    url: url,
    platform: platform,
    format: recognized ? MediaLinkFormat.post : MediaLinkFormat.unsupported,
    recognized: recognized,
    note: recognized
        ? platform.accessNote
        : '${platform.label} 게시물 주소 형식이 아닙니다.',
  );
}

final class MediaLinkClassification {
  const MediaLinkClassification({
    required this.url,
    required this.format,
    required this.recognized,
    this.platform,
    this.note,
  });

  final Uri url;
  final MediaPlatformDescriptor? platform;
  final MediaLinkFormat format;
  final bool recognized;
  final String? note;

  String get providerLabel => platform?.label ?? 'Web page';
}

enum MediaAnalysisFailureCode {
  invalidUrl,
  insecureUrl,
  unsupportedLinkFormat,
  authenticationRequired,
  accessDenied,
  notFound,
  rateLimited,
  remoteServer,
  timeout,
  tls,
  network,
  adaptiveStreamUnsupported,
  invalidMediaResponse,
  noPublicMedia,
  backendUnavailable,
}

final class MediaAnalysisFailure {
  const MediaAnalysisFailure(this.code, this.message);

  final MediaAnalysisFailureCode code;
  final String message;
}

final class MediaAnalysisResult {
  const MediaAnalysisResult({
    required this.classification,
    this.analysis,
    this.failure,
  }) : assert((analysis == null) != (failure == null));

  final MediaLinkClassification classification;
  final MediaAnalysis? analysis;
  final MediaAnalysisFailure? failure;

  bool get isSuccess => analysis != null;
}

abstract interface class MediaProvider {
  bool supports(Uri url);

  Future<MediaAnalysis?> analyze(Uri url);
}

final class MediaProviderRegistry {
  MediaProviderRegistry(
    Iterable<MediaProvider> providers, {
    Iterable<MediaPlatformDescriptor> platforms = defaultMediaPlatforms,
  }) : providers = List.unmodifiable(providers),
       platforms = List.unmodifiable(platforms);

  factory MediaProviderRegistry.defaults() => MediaProviderRegistry([
    BlueskyMediaProvider(),
    DirectMediaProvider(),
    PageMediaProvider(),
  ]);

  final List<MediaProvider> providers;
  final List<MediaPlatformDescriptor> platforms;

  MediaLinkClassification classify(Uri url) =>
      classifyMediaUrl(url, platforms: platforms);
}

final class MediaAnalyzer {
  MediaAnalyzer({MediaProviderRegistry? registry})
    : registry = registry ?? MediaProviderRegistry.defaults();

  final MediaProviderRegistry registry;

  Future<MediaAnalysis?> analyze(Uri url) async =>
      (await analyzeDetailed(url)).analysis;

  Future<MediaAnalysisResult> analyzeDetailed(Uri url) async {
    final classification = registry.classify(url);
    if (url.scheme.toLowerCase() != 'https') {
      return MediaAnalysisResult(
        classification: classification,
        failure: const MediaAnalysisFailure(
          MediaAnalysisFailureCode.insecureUrl,
          'HTTPS 링크만 분석할 수 있습니다.',
        ),
      );
    }
    if (!_isHttps(url)) {
      return MediaAnalysisResult(
        classification: classification,
        failure: const MediaAnalysisFailure(
          MediaAnalysisFailureCode.invalidUrl,
          '공개 인터넷 주소가 아니거나 올바르지 않은 링크입니다.',
        ),
      );
    }
    for (final provider in registry.providers) {
      if (!provider.supports(url)) continue;
      try {
        final result = await provider.analyze(url);
        if (result != null && result.candidates.isNotEmpty) {
          return MediaAnalysisResult(
            classification: classification,
            analysis: result,
          );
        }
      } on _MediaProviderFailure catch (error) {
        return MediaAnalysisResult(
          classification: classification,
          failure: error.failure,
        );
      }
    }
    if (!classification.recognized) {
      return MediaAnalysisResult(
        classification: classification,
        failure: MediaAnalysisFailure(
          MediaAnalysisFailureCode.unsupportedLinkFormat,
          '${classification.providerLabel} 링크이지만 지원하는 게시물 주소 형식이 아닙니다.',
        ),
      );
    }
    return MediaAnalysisResult(
      classification: classification,
      failure: const MediaAnalysisFailure(
        MediaAnalysisFailureCode.noPublicMedia,
        '공개 게시물일 수 있지만 페이지 응답에서 직접 저장 가능한 원본 미디어 URL을 확인하지 못했습니다.',
      ),
    );
  }
}

final class DirectMediaProvider implements MediaProvider {
  @override
  bool supports(Uri url) => _isHttps(url);

  @override
  Future<MediaAnalysis?> analyze(Uri url) async {
    if (!supports(url)) return null;
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      return await _head(client, url).timeout(_requestTimeout);
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<MediaAnalysis?> _head(HttpClient client, Uri sourceUrl) async {
    final opened = await _openPublicUrl(client, 'HEAD', sourceUrl);
    final response = opened.response;
    final finalUrl = opened.url;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final mimeType =
        _normalizedMime(response.headers.contentType?.mimeType) ??
        _mimeFromUrl(finalUrl);
    final dispositionName = _contentDispositionFileName(
      response.headers.value('content-disposition'),
    );
    if (!_looksLikeDownloadResponse(finalUrl, mimeType, dispositionName)) {
      return null;
    }
    final providerLabel = providerLabelFor(sourceUrl, fallback: 'Direct file');
    final candidate = _candidate(
      finalUrl,
      providerLabel: providerLabel,
      mimeType: mimeType,
      preferredName: dispositionName,
      headers: const {'User-Agent': _browserUserAgent},
    );
    if (candidate == null) return null;
    return MediaAnalysis(
      sourceUrl: sourceUrl,
      providerLabel: providerLabel,
      candidates: [candidate],
    );
  }
}

final class BlueskyMediaProvider implements MediaProvider {
  @override
  bool supports(Uri url) =>
      _hostMatches(url.host.toLowerCase(), 'bsky.app') &&
      _blueskyPostParts(url) != null;

  @override
  Future<MediaAnalysis?> analyze(Uri url) async {
    final parts = _blueskyPostParts(url);
    if (parts == null) return null;
    final apiUrl = Uri.https(
      'public.api.bsky.app',
      '/xrpc/app.bsky.feed.getPostThread',
      {
        'uri': 'at://${parts.handle}/app.bsky.feed.post/${parts.rkey}',
        'depth': '0',
      },
    );
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final opened = await _openPublicUrl(
        client,
        'GET',
        apiUrl,
      ).timeout(_requestTimeout);
      if (opened.response.statusCode < 200 ||
          opened.response.statusCode >= 300) {
        throw _MediaProviderFailure(
          _failureForStatus(opened.response.statusCode),
        );
      }
      final bytes = <int>[];
      await for (final chunk in opened.response) {
        final remaining = _maxPageBytes - bytes.length;
        if (remaining <= 0) break;
        bytes.addAll(chunk.length <= remaining ? chunk : chunk.take(remaining));
        if (chunk.length >= remaining) break;
      }
      final json = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      final candidates = extractBlueskyMediaCandidates(json, url);
      if (candidates.isNotEmpty) {
        return MediaAnalysis(
          sourceUrl: url,
          providerLabel: 'Bluesky',
          candidates: candidates,
        );
      }
      if (_containsBlueskyPlaylist(json)) {
        throw const _MediaProviderFailure(_adaptiveStreamFailure);
      }
      return null;
    } on _MediaProviderFailure {
      rethrow;
    } on TimeoutException {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.timeout,
          'Bluesky 공개 게시물 응답 시간이 초과되었습니다.',
        ),
      );
    } on HandshakeException {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.tls,
          'Bluesky 공개 API의 보안 연결을 확인할 수 없습니다.',
        ),
      );
    } on Object {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.network,
          'Bluesky 공개 게시물 정보를 읽지 못했습니다.',
        ),
      );
    } finally {
      client.close(force: true);
    }
  }
}

({String handle, String rkey})? _blueskyPostParts(Uri url) {
  final parts = url.pathSegments;
  if (!_isHttps(url) ||
      !_hostMatches(url.host.toLowerCase(), 'bsky.app') ||
      parts.length != 4 ||
      parts[0] != 'profile' ||
      parts[2] != 'post' ||
      !RegExp(r'^[a-zA-Z0-9._:%-]{1,255}$').hasMatch(parts[1]) ||
      !RegExp(r'^[a-zA-Z0-9._~-]{1,128}$').hasMatch(parts[3])) {
    return null;
  }
  return (handle: parts[1], rkey: parts[3]);
}

bool _containsBlueskyPlaylist(Object? value) {
  if (value is List) return value.any(_containsBlueskyPlaylist);
  if (value is! Map) return false;
  return value.entries.any(
    (entry) =>
        _normalizedJsonKey(entry.key) == 'playlist' &&
            entry.value is String &&
            (entry.value as String).isNotEmpty ||
        _containsBlueskyPlaylist(entry.value),
  );
}

List<MediaCandidate> extractBlueskyMediaCandidates(
  Object? response,
  Uri sourceUrl,
) {
  if (_blueskyPostParts(sourceUrl) == null || response is! Map) return const [];
  final thread = response['thread'];
  final post = thread is Map ? thread['post'] : null;
  final embed = post is Map ? post['embed'] : null;
  if (embed is! Map && embed is! List) return const [];

  final urls = <String>[];
  void collect(Object? value) {
    if (value is List) {
      for (final child in value) {
        collect(child);
      }
      return;
    }
    if (value is! Map) return;
    for (final entry in value.entries) {
      final key = _normalizedJsonKey(entry.key);
      if (key == 'external' || _isStructuredNoiseKey(key)) continue;
      if (key == 'fullsize' && entry.value is String) {
        urls.add(entry.value as String);
      } else {
        collect(entry.value);
      }
    }
  }

  collect(embed);
  final result = <MediaCandidate>[];
  final seen = <Uri>{};
  final names = <String>{};
  for (final value in urls) {
    final url = _resolveHttps(sourceUrl, value);
    if (url == null || !seen.add(url)) continue;
    final candidate = _candidate(
      url,
      providerLabel: 'Bluesky',
      kind: MediaKind.image,
      headers: {
        'Referer': sourceUrl.toString(),
        'User-Agent': _browserUserAgent,
      },
    );
    if (candidate == null) continue;
    result.add(
      MediaCandidate(
        url: candidate.url,
        kind: candidate.kind,
        fileName: _uniqueFileName(candidate.fileName, names),
        providerLabel: candidate.providerLabel,
        mimeType: candidate.mimeType,
        headers: candidate.headers,
      ),
    );
  }
  return List.unmodifiable(result.take(20));
}

final class PageMediaProvider implements MediaProvider {
  @override
  bool supports(Uri url) => _isHttps(url);

  @override
  Future<MediaAnalysis?> analyze(Uri url) async {
    if (!supports(url)) return null;
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      return await _get(client, url).timeout(_requestTimeout);
    } on _MediaProviderFailure {
      rethrow;
    } on TimeoutException {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.timeout,
          '페이지 응답 시간이 초과되었습니다. 잠시 후 다시 시도해 주세요.',
        ),
      );
    } on HandshakeException {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.tls,
          '페이지의 보안 연결을 확인할 수 없습니다.',
        ),
      );
    } on SocketException {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.network,
          '페이지에 연결할 수 없습니다. 네트워크와 주소를 확인해 주세요.',
        ),
      );
    } on HttpException {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.network,
          '페이지 응답을 읽지 못했습니다.',
        ),
      );
    } on FormatException {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.noPublicMedia,
          '페이지가 너무 크거나 공개 미디어 메타데이터 형식이 올바르지 않습니다.',
        ),
      );
    } on Object {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.network,
          '페이지 분석 중 통신 오류가 발생했습니다.',
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<MediaAnalysis?> _get(HttpClient client, Uri sourceUrl) async {
    final opened = await _openPublicUrl(client, 'GET', sourceUrl);
    final response = opened.response;
    final finalUrl = opened.url;
    final mimeType = _normalizedMime(response.headers.contentType?.mimeType);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _MediaProviderFailure(_failureForStatus(response.statusCode));
    }
    if (_isAdaptiveStream(finalUrl, mimeType)) {
      throw const _MediaProviderFailure(_adaptiveStreamFailure);
    }

    final dispositionName = _contentDispositionFileName(
      response.headers.value('content-disposition'),
    );
    if (_looksLikeDownloadResponse(finalUrl, mimeType, dispositionName)) {
      final providerLabel = providerLabelFor(
        sourceUrl,
        fallback: 'Direct file',
      );
      final candidate = _candidate(
        finalUrl,
        providerLabel: providerLabel,
        mimeType: mimeType,
        preferredName: dispositionName,
        headers: const {'User-Agent': _browserUserAgent},
      );
      if (candidate == null) return null;
      final sample = await response.expand((chunk) => chunk).take(512).toList();
      final checked = validateMediaResponse(
        candidate,
        responseUrl: finalUrl,
        statusCode: response.statusCode,
        contentType: mimeType,
        contentDisposition: response.headers.value('content-disposition'),
        contentLength: response.contentLength,
        firstBytes: sample,
      );
      if (checked.failure case final failure?) {
        throw _MediaProviderFailure(failure);
      }
      return MediaAnalysis(
        sourceUrl: sourceUrl,
        providerLabel: providerLabel,
        candidates: [checked.candidate!],
      );
    }

    final bytes = <int>[];
    await for (final chunk in response) {
      final remaining = _maxPageBytes - bytes.length;
      if (remaining <= 0) break;
      bytes.addAll(chunk.length <= remaining ? chunk : chunk.take(remaining));
      if (chunk.length >= remaining) break;
    }
    final html = utf8.decode(bytes, allowMalformed: true);
    final providerLabel = providerLabelFor(sourceUrl, fallback: 'Web page');
    final candidates = extractMediaCandidatesFromHtml(
      html,
      finalUrl,
      providerLabel: providerLabel,
    );
    if (candidates.isEmpty) {
      if (_containsAdaptiveStreamReference(html)) {
        throw const _MediaProviderFailure(_adaptiveStreamFailure);
      }
      return null;
    }
    return MediaAnalysis(
      sourceUrl: sourceUrl,
      providerLabel: providerLabel,
      candidates: candidates,
    );
  }
}

final class _MediaProviderFailure implements Exception {
  const _MediaProviderFailure(this.failure);

  final MediaAnalysisFailure failure;
}

const _adaptiveStreamFailure = MediaAnalysisFailure(
  MediaAnalysisFailureCode.adaptiveStreamUnsupported,
  '이 페이지는 HLS/DASH 적응형 스트림만 제공합니다. 단일 파일 주소가 없어 직접 저장할 수 없습니다.',
);

MediaAnalysisFailure _failureForStatus(int statusCode) => switch (statusCode) {
  401 => const MediaAnalysisFailure(
    MediaAnalysisFailureCode.authenticationRequired,
    '로그인이 필요한 링크입니다.',
  ),
  403 || 451 => const MediaAnalysisFailure(
    MediaAnalysisFailureCode.accessDenied,
    '페이지 접근이 거부되었습니다. 공개 범위나 지역 제한을 확인해 주세요.',
  ),
  404 || 410 => const MediaAnalysisFailure(
    MediaAnalysisFailureCode.notFound,
    '게시물이 삭제되었거나 주소가 만료되었습니다.',
  ),
  429 => const MediaAnalysisFailure(
    MediaAnalysisFailureCode.rateLimited,
    '플랫폼이 요청을 일시적으로 제한했습니다. 잠시 후 다시 시도해 주세요.',
  ),
  >= 500 => const MediaAnalysisFailure(
    MediaAnalysisFailureCode.remoteServer,
    '플랫폼 서버가 일시적으로 응답하지 않습니다.',
  ),
  _ => MediaAnalysisFailure(
    MediaAnalysisFailureCode.accessDenied,
    '페이지가 HTTP $statusCode 응답을 반환해 분석할 수 없습니다.',
  ),
};

String providerLabelFor(Uri url, {required String fallback}) {
  return mediaPlatformFor(url)?.label ?? fallback;
}

Future<({MediaCandidate? candidate, MediaAnalysisFailure? failure})>
validateMediaCandidateForDownload(MediaCandidate candidate) async {
  final client = HttpClient()..connectionTimeout = _requestTimeout;
  try {
    final opened = await _openPublicUrl(
      client,
      'GET',
      candidate.url,
      requestHeaders: candidate.headers,
    ).timeout(_requestTimeout);
    final response = opened.response;
    final sample = await response
        .expand((chunk) => chunk)
        .take(512)
        .toList()
        .timeout(_requestTimeout);
    return validateMediaResponse(
      candidate,
      responseUrl: opened.url,
      statusCode: response.statusCode,
      contentType: response.headers.contentType?.mimeType,
      contentDisposition: response.headers.value('content-disposition'),
      contentLength: response.contentLength,
      firstBytes: sample,
    );
  } on _MediaProviderFailure catch (error) {
    return (candidate: null, failure: error.failure);
  } on TimeoutException {
    return (
      candidate: null,
      failure: const MediaAnalysisFailure(
        MediaAnalysisFailureCode.timeout,
        '다운로드 파일 응답 시간이 초과되었습니다. 다시 시도해 주세요.',
      ),
    );
  } on HandshakeException {
    return (
      candidate: null,
      failure: const MediaAnalysisFailure(
        MediaAnalysisFailureCode.tls,
        '다운로드 파일의 보안 연결을 확인할 수 없습니다.',
      ),
    );
  } on SocketException {
    return (
      candidate: null,
      failure: const MediaAnalysisFailure(
        MediaAnalysisFailureCode.network,
        '다운로드 파일에 연결할 수 없습니다. 네트워크를 확인해 주세요.',
      ),
    );
  } on HttpException {
    return (
      candidate: null,
      failure: const MediaAnalysisFailure(
        MediaAnalysisFailureCode.network,
        '다운로드 파일에 연결할 수 없습니다. 네트워크를 확인해 주세요.',
      ),
    );
  } on Object {
    return (
      candidate: null,
      failure: const MediaAnalysisFailure(
        MediaAnalysisFailureCode.network,
        '다운로드 파일을 확인하는 중 통신 오류가 발생했습니다.',
      ),
    );
  } finally {
    client.close(force: true);
  }
}

({MediaCandidate? candidate, MediaAnalysisFailure? failure})
validateMediaResponse(
  MediaCandidate candidate, {
  required Uri responseUrl,
  required int statusCode,
  String? contentType,
  String? contentDisposition,
  int? contentLength,
  List<int> firstBytes = const [],
}) {
  if (statusCode < 200 || statusCode >= 300) {
    return (candidate: null, failure: _failureForStatus(statusCode));
  }
  if (contentLength == 0 || firstBytes.isEmpty) {
    return (
      candidate: null,
      failure: const MediaAnalysisFailure(
        MediaAnalysisFailureCode.invalidMediaResponse,
        '다운로드 주소가 비어 있는 파일을 반환했습니다.',
      ),
    );
  }

  final headerMime = _normalizedMime(contentType);
  if (_isAdaptiveStream(responseUrl, headerMime) ||
      _looksLikeAdaptiveManifest(firstBytes)) {
    return (candidate: null, failure: _adaptiveStreamFailure);
  }
  final sniffedMime = _sniffMediaMime(firstBytes, candidate.kind);
  if (_looksLikeMarkup(firstBytes) ||
      _isNonFileResponseMime(headerMime) && sniffedMime == null) {
    return (
      candidate: null,
      failure: const MediaAnalysisFailure(
        MediaAnalysisFailureCode.invalidMediaResponse,
        '다운로드 주소가 미디어 파일 대신 HTML 또는 오류 응답을 반환했습니다.',
      ),
    );
  }

  final dispositionName = _contentDispositionFileName(contentDisposition);
  final namedMime =
      _mimeFromValue(dispositionName ?? '') ??
      _mimeFromUrl(responseUrl) ??
      _mimeFromValue(candidate.fileName);
  final effectiveMime =
      sniffedMime ?? _usableResponseMime(headerMime) ?? namedMime;
  final resolvedKind = _kindFromMimeOrUrl(
    effectiveMime,
    dispositionName ?? responseUrl.path,
  );
  if (candidate.kind != MediaKind.file && resolvedKind == MediaKind.file) {
    return (
      candidate: null,
      failure: const MediaAnalysisFailure(
        MediaAnalysisFailureCode.invalidMediaResponse,
        '응답 헤더와 파일 내용에서 유효한 미디어 형식을 확인하지 못했습니다.',
      ),
    );
  }
  if (!_looksLikeDownloadResponse(
    responseUrl,
    effectiveMime,
    dispositionName,
  )) {
    return (
      candidate: null,
      failure: const MediaAnalysisFailure(
        MediaAnalysisFailureCode.invalidMediaResponse,
        '응답이 다운로드 가능한 파일 형식이 아닙니다.',
      ),
    );
  }

  return (
    candidate: MediaCandidate(
      url: responseUrl.removeFragment(),
      kind: resolvedKind,
      fileName: _safeFileName(
        dispositionName ?? candidate.fileName,
        responseUrl,
        effectiveMime,
        resolvedKind,
      ),
      providerLabel: candidate.providerLabel,
      mimeType: effectiveMime,
      headers: candidate.headers,
      isPreview: candidate.isPreview && resolvedKind == MediaKind.image,
    ),
    failure: null,
  );
}

/// Extracts media URLs explicitly published in page metadata.
///
/// This does not execute scripts, decode signatures, or bypass DRM.
List<MediaCandidate> extractMediaCandidatesFromHtml(
  String html,
  Uri pageUrl, {
  String? providerLabel,
}) {
  if (!_isHttps(pageUrl)) return const [];
  final label =
      providerLabel ?? providerLabelFor(pageUrl, fallback: 'Web page');
  final raw = <_RawCandidate>[];

  // ponytail: regex covers metadata/source tags, not malformed DOM; use a real
  // HTML parser only when pages outside this metadata contract require it.
  final metaValues = <String, List<String>>{};
  for (final match in RegExp(
    r'<meta\b[^>]*>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html)) {
    final attributes = _attributes(match.group(0)!);
    final key = (attributes['property'] ?? attributes['name'])
        ?.trim()
        .toLowerCase();
    final content = attributes['content']?.trim();
    if (key != null &&
        key.isNotEmpty &&
        content != null &&
        content.isNotEmpty) {
      metaValues.putIfAbsent(key, () => []).add(content);
    }
  }

  void addMeta(
    Iterable<String> keys,
    MediaKind kind, {
    Iterable<String> mimeKeys = const [],
    bool isPreview = false,
  }) {
    final mimeType = mimeKeys
        .expand((key) => metaValues[key] ?? const <String>[])
        .map(_normalizedMime)
        .whereType<String>()
        .firstOrNull;
    for (final key in keys) {
      for (final value in metaValues[key] ?? const <String>[]) {
        raw.add(
          _RawCandidate(value, kind, mimeType, null, isPreview: isPreview),
        );
      }
    }
  }

  addMeta(
    const ['og:video', 'og:video:url', 'og:video:secure_url'],
    MediaKind.video,
    mimeKeys: const ['og:video:type'],
  );
  addMeta(
    const ['og:audio', 'og:audio:url', 'og:audio:secure_url'],
    MediaKind.audio,
    mimeKeys: const ['og:audio:type'],
  );
  addMeta(
    const [
      'og:image',
      'og:image:url',
      'og:image:secure_url',
      'twitter:image',
      'twitter:image:src',
    ],
    MediaKind.image,
    isPreview: true,
  );
  addMeta(
    const ['twitter:player:stream'],
    MediaKind.video,
    mimeKeys: const ['twitter:player:stream:content_type'],
  );

  for (final match in RegExp(
    r'<source\b[^>]*>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html)) {
    final attributes = _attributes(match.group(0)!);
    final value =
        attributes['src']?.trim() ?? _largestSrcsetValue(attributes['srcset']);
    if (value == null || value.isEmpty) continue;
    final mimeType = _normalizedMime(attributes['type']);
    raw.add(
      _RawCandidate(value, _kindFromMimeOrUrl(mimeType, value), mimeType, null),
    );
  }

  for (final match in RegExp(
    r'<(?:video|audio)\b[^>]*>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html)) {
    final tag = match.group(0)!;
    final attributes = _attributes(tag);
    final value = attributes['src']?.trim();
    if (value == null || value.isEmpty) continue;
    final mimeType = _normalizedMime(attributes['type']);
    final kind = tag.toLowerCase().startsWith('<video')
        ? MediaKind.video
        : MediaKind.audio;
    raw.add(_RawCandidate(value, kind, mimeType, null));
  }

  for (final match in RegExp(
    r'<img\b[^>]*>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html)) {
    final attributes = _attributes(match.group(0)!);
    final value =
        attributes['data-original']?.trim() ??
        attributes['data-full']?.trim() ??
        attributes['data-src']?.trim() ??
        _largestSrcsetValue(attributes['data-srcset']) ??
        _largestSrcsetValue(attributes['srcset']) ??
        attributes['src']?.trim();
    if (value == null ||
        value.isEmpty ||
        !_isLikelyContentImage(attributes, value)) {
      continue;
    }
    raw.add(_RawCandidate(value, MediaKind.image, _mimeFromValue(value), null));
  }

  for (final match in RegExp(
    r'<script\b([^>]*)>([\s\S]*?)</script\s*>',
    caseSensitive: false,
  ).allMatches(html)) {
    final attributes = _attributes('<script ${match.group(1) ?? ''}>');
    final type = attributes['type']?.trim().toLowerCase();
    final isJsonLd = type == 'application/ld+json';
    final isJson =
        isJsonLd ||
        type == 'application/json' ||
        type?.endsWith('+json') == true;
    if (!isJson) continue;
    try {
      _collectStructuredMedia(
        jsonDecode(_decodeHtml(match.group(2)!.trim())),
        raw,
        jsonLd: isJsonLd,
      );
    } on FormatException {
      // Invalid embedded JSON is unrelated to otherwise valid page metadata.
    }
  }

  final result = <MediaCandidate>[];
  final seen = <String>{};
  final usedFileNames = <String>{};
  for (final value in raw) {
    final resolved = _resolveHttps(pageUrl, value.url);
    if (resolved == null ||
        _isObviousNonContentImage(resolved, value.kind) ||
        !seen.add(resolved.toString())) {
      continue;
    }
    var candidate = _candidate(
      resolved,
      providerLabel: label,
      kind: value.kind,
      mimeType: value.mimeType,
      preferredName: value.fileName,
      isPreview: value.isPreview,
      headers: {'Referer': pageUrl.toString(), 'User-Agent': _browserUserAgent},
    );
    if (candidate != null) {
      final uniqueName = _uniqueFileName(candidate.fileName, usedFileNames);
      if (uniqueName != candidate.fileName) {
        candidate = MediaCandidate(
          url: candidate.url,
          kind: candidate.kind,
          fileName: uniqueName,
          providerLabel: candidate.providerLabel,
          mimeType: candidate.mimeType,
          headers: candidate.headers,
          isPreview: candidate.isPreview,
        );
      }
      result.add(candidate);
    }
  }
  return List.unmodifiable(
    result.where((candidate) => !candidate.isPreview).take(20),
  );
}

final class _RawCandidate {
  const _RawCandidate(
    this.url,
    this.kind,
    this.mimeType,
    this.fileName, {
    this.isPreview = false,
  });

  final String url;
  final MediaKind kind;
  final String? mimeType;
  final String? fileName;
  final bool isPreview;
}

void _collectStructuredMedia(
  Object? value,
  List<_RawCandidate> output, {
  required bool jsonLd,
  MediaKind? inheritedKind,
  String? containerKey,
  int depth = 0,
}) {
  if (depth > _maxStructuredDepth || output.length >= _maxRawCandidates) {
    return;
  }
  if (value is List) {
    final bestVariant =
        inheritedKind == MediaKind.image &&
            const {
              'candidates',
              'displayresources',
              'resolutions',
            }.contains(containerKey)
        ? _largestImageVariant(value)
        : null;
    for (final child in bestVariant == null ? value : [bestVariant]) {
      _collectStructuredMedia(
        child,
        output,
        jsonLd: jsonLd,
        inheritedKind: inheritedKind,
        containerKey: containerKey,
        depth: depth + 1,
      );
    }
    return;
  }
  if (value is! Map) return;
  final map = Map<String, Object?>.fromEntries(
    value.entries.map(
      (entry) => MapEntry(_normalizedJsonKey(entry.key), entry.value),
    ),
  );
  final mimeType = _normalizedMime(
    (map['encodingformat'] ?? map['contenttype'] ?? map['mimetype'])
        ?.toString(),
  );
  final nodeKind =
      _kindFromType(map['@type'] ?? map['type'], concreteOnly: jsonLd) ??
      (mimeType == null ? null : _kindFromMimeOrUrl(mimeType, ''));
  final contextualKind = nodeKind ?? inheritedKind;
  final fileName = (map['filename'] ?? map['name'] ?? map['title'])?.toString();

  for (final entry in map.entries) {
    if (_isStructuredNoiseKey(entry.key) ||
        jsonLd &&
            entry.key == 'url' &&
            _stringValues(map['contenturl']).isNotEmpty) {
      continue;
    }
    final kind = _kindForStructuredUrlKey(
      entry.key,
      jsonLd: jsonLd,
      contextualKind: contextualKind,
    );
    if (kind == null) continue;
    for (final url in _stringValues(entry.value)) {
      if (url.trim().isEmpty) continue;
      final resolvedKind = kind == MediaKind.file
          ? _kindFromMimeOrUrl(mimeType, url)
          : kind;
      output.add(_RawCandidate(url, resolvedKind, mimeType, fileName));
      if (output.length >= _maxRawCandidates) return;
    }
  }

  for (final entry in map.entries) {
    final child = entry.value;
    if (child is! List && child is! Map || _isStructuredNoiseKey(entry.key)) {
      continue;
    }
    _collectStructuredMedia(
      child,
      output,
      jsonLd: jsonLd,
      inheritedKind: _kindForStructuredContainer(entry.key) ?? contextualKind,
      containerKey: entry.key,
      depth: depth + 1,
    );
  }
}

String _normalizedJsonKey(Object? value) =>
    value.toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9@]'), '');

MediaKind? _kindFromType(Object? value, {required bool concreteOnly}) {
  final type = value?.toString().toLowerCase() ?? '';
  if (type.contains(concreteOnly ? 'videoobject' : 'video')) {
    return MediaKind.video;
  }
  if (type.contains(concreteOnly ? 'audioobject' : 'audio')) {
    return MediaKind.audio;
  }
  if (type.contains(concreteOnly ? 'imageobject' : 'image') ||
      type.contains(concreteOnly ? 'photoobject' : 'photo')) {
    return MediaKind.image;
  }
  return null;
}

MediaKind? _kindForStructuredUrlKey(
  String key, {
  required bool jsonLd,
  required MediaKind? contextualKind,
}) => switch (key) {
  'videourl' ||
  'videosrc' ||
  'playableurl' ||
  'playableurlqualityhd' ||
  'playbackurl' ||
  'playurl' ||
  'playaddr' ||
  'downloadaddr' ||
  'fallbackurl' ||
  'browsernativehdurl' ||
  'browsernativesdurl' ||
  'hdsrc' ||
  'sdsrc' => MediaKind.video,
  'audiourl' || 'audiosrc' => MediaKind.audio,
  'imageurl' ||
  'imageurlhttps' ||
  'imagesrc' ||
  'displayurl' ||
  'originalimageurl' ||
  'mediaurlhttps' => MediaKind.image,
  'image' => MediaKind.image,
  'video' => MediaKind.video,
  'audio' => MediaKind.audio,
  'contenturl' ||
  'downloadurl' ||
  'mediaurl' => contextualKind ?? MediaKind.file,
  'url' ||
  'src' ||
  'urllist' when jsonLd || contextualKind != null => contextualKind,
  _ => null,
};

MediaKind? _kindForStructuredContainer(String key) => switch (key) {
  'image' ||
  'images' ||
  'imageobject' ||
  'imageversions2' ||
  'displayresources' ||
  'resolutions' => MediaKind.image,
  'video' ||
  'videos' ||
  'videoobject' ||
  'videoinfo' ||
  'videoversions' ||
  'redditvideo' ||
  'bitrateinfo' ||
  'playaddr' ||
  'downloadaddr' => MediaKind.video,
  'audio' || 'audios' || 'audioobject' => MediaKind.audio,
  _ => null,
};

bool _isStructuredNoiseKey(String key) => const {
  'ad',
  'ads',
  'adaptiveformats',
  'advertisement',
  'advertisements',
  'analytics',
  'animatedcover',
  'avatar',
  'avatars',
  'badge',
  'badges',
  'emoji',
  'emojis',
  'external',
  'favicon',
  'cover',
  'coverimage',
  'covers',
  'dynamiccover',
  'iconimage',
  'icon',
  'icons',
  'logo',
  'logos',
  'linkpreview',
  'origincover',
  'poster',
  'posterimage',
  'posterurl',
  'preview',
  'previewimage',
  'profileimage',
  'profileimages',
  'profileimageurl',
  'profileimageurlhttps',
  'sprite',
  'sprites',
  'sponsor',
  'sponsored',
  'thumbnail',
  'thumbnails',
  'thumbnailurl',
  'trackingpixel',
  'watermark',
}.contains(key);

Iterable<String> _stringValues(Object? value) sync* {
  if (value is String) {
    yield value;
    return;
  }
  if (value is List) {
    for (final child in value) {
      if (child is String) yield child;
    }
  }
}

Object? _largestImageVariant(List<Object?> values) {
  Object? best;
  num bestArea = -1;
  for (final value in values) {
    if (value is! Map) continue;
    final map = Map<String, Object?>.fromEntries(
      value.entries.map(
        (entry) => MapEntry(_normalizedJsonKey(entry.key), entry.value),
      ),
    );
    if ((map['url'] ?? map['src'] ?? map['imageurl']) is! String) continue;
    final width = map['width'];
    final height = map['height'];
    final area = width is num && height is num ? width * height : 0;
    if (best == null || area > bestArea) {
      best = value;
      bestArea = area;
    }
  }
  return best;
}

String? _largestSrcsetValue(String? value) {
  if (value == null) return null;
  String? best;
  num bestSize = -1;
  for (final part in value.split(',')) {
    final fields = part.trim().split(RegExp(r'\s+'));
    if (fields.isEmpty || fields.first.isEmpty) continue;
    final descriptor = fields.length > 1 ? fields.last.toLowerCase() : '';
    final size = descriptor.endsWith('w') || descriptor.endsWith('x')
        ? num.tryParse(descriptor.substring(0, descriptor.length - 1)) ?? 0
        : 0;
    if (best == null || size > bestSize) {
      best = fields.first;
      bestSize = size;
    }
  }
  return best;
}

bool _isLikelyContentImage(Map<String, String> attributes, String value) {
  final mimeType = _mimeFromValue(value);
  if (mimeType?.startsWith('image/') != true) return false;
  final width = num.tryParse(attributes['width'] ?? '');
  final height = num.tryParse(attributes['height'] ?? '');
  if (width != null && height != null && width <= 96 && height <= 96) {
    return false;
  }
  final semantics = [
    attributes['id'],
    attributes['class'],
    attributes['role'],
    attributes['alt'],
    attributes['aria-label'],
  ].whereType<String>().join('/');
  return !_containsNonContentImageToken(value) &&
      !_containsNonContentImageToken(semantics);
}

String? _mimeFromValue(String value) {
  final uri = Uri.tryParse(_decodeHtml(value.trim()));
  return uri == null ? null : _mimeFromUrl(uri);
}

bool _isObviousNonContentImage(Uri url, MediaKind kind) =>
    kind == MediaKind.image &&
    (_containsNonContentImageToken(url.toString()) ||
        _isPlatformUiImage(url) ||
        const {
          'doubleclick.net',
          'googlesyndication.com',
          'google-analytics.com',
        }.any((host) => _hostMatches(url.host.toLowerCase(), host)));

bool _containsNonContentImageToken(String value) => RegExp(
  r'(?:^|[/_.?=&\s-])(?:ad|ads|advert|advertisement|analytics|avatar|badge|'
  r'beacon|emoji|favicon|gravatar|icon|logo|pixel|placeholder|poster|preview|'
  r'reaction|spacer|sprite|thumb|thumbnail|tracker|tracking)'
  r'(?:$|[/_.?=&\s-])',
  caseSensitive: false,
).hasMatch(value);

bool _isPlatformUiImage(Uri url) {
  final host = url.host.toLowerCase();
  final path = url.path.toLowerCase();
  if (host == 'abs.twimg.com') return true;
  if (host == 'pbs.twimg.com') {
    return path.startsWith('/profile_images/') ||
        path.startsWith('/profile_banners/') ||
        path.startsWith('/card_img/');
  }
  return host == 'i.vimeocdn.com' && path.startsWith('/portrait/');
}

String _uniqueFileName(String fileName, Set<String> used) {
  if (used.add(fileName.toLowerCase())) return fileName;
  final extension = _extension(fileName);
  final base = extension.isEmpty
      ? fileName
      : fileName.substring(0, fileName.length - extension.length - 1);
  for (var index = 2; ; index++) {
    final candidate = extension.isEmpty
        ? '${base}_$index'
        : '${base}_$index.$extension';
    if (used.add(candidate.toLowerCase())) return candidate;
  }
}

Map<String, String> _attributes(String tag) {
  final result = <String, String>{};
  final pattern = RegExp(
    r'''([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))''',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(tag)) {
    result[match.group(1)!.toLowerCase()] = _decodeHtml(
      match.group(2) ?? match.group(3) ?? match.group(4) ?? '',
    );
  }
  return result;
}

String _decodeHtml(String value) => value.replaceAllMapped(
  RegExp(
    r'&(?:#(\d+)|#x([0-9a-f]+)|amp|quot|apos|lt|gt);',
    caseSensitive: false,
  ),
  (match) {
    final decimal = match.group(1);
    final hex = match.group(2);
    if (decimal != null || hex != null) {
      final codePoint = int.tryParse(
        decimal ?? hex!,
        radix: hex == null ? 10 : 16,
      );
      if (codePoint != null && codePoint <= 0x10ffff) {
        return String.fromCharCode(codePoint);
      }
    }
    return switch (match.group(0)!.toLowerCase()) {
      '&amp;' => '&',
      '&quot;' => '"',
      '&apos;' => "'",
      '&lt;' => '<',
      '&gt;' => '>',
      _ => match.group(0)!,
    };
  },
);

MediaCandidate? _candidate(
  Uri url, {
  required String providerLabel,
  String? mimeType,
  MediaKind? kind,
  String? preferredName,
  Map<String, String> headers = const {},
  bool isPreview = false,
}) {
  if (!_isHttps(url) || _isLikelyPlayerPage(url)) return null;
  final normalizedMime = _normalizedMime(mimeType) ?? _mimeFromUrl(url);
  if ((normalizedMime != null &&
          (_isHtml(normalizedMime) || _isStreamingManifest(normalizedMime))) ||
      {'m3u8', 'mpd'}.contains(_extension(url.path))) {
    return null;
  }
  final resolvedKind = kind ?? _kindFromMimeOrUrl(normalizedMime, url.path);
  return MediaCandidate(
    url: url.removeFragment(),
    kind: resolvedKind,
    fileName: _safeFileName(preferredName, url, normalizedMime, resolvedKind),
    providerLabel: providerLabel,
    mimeType: normalizedMime,
    headers: Map.unmodifiable(headers),
    isPreview: isPreview,
  );
}

bool _isLikelyPlayerPage(Uri url) {
  if (_mimeFromUrl(url) != null) return false;
  final host = url.host.toLowerCase();
  final path = url.path.toLowerCase();
  if (_hostMatches(host, 'vimeo.com')) return true;
  return (_hostMatches(host, 'youtube.com') ||
              _hostMatches(host, 'youtube-nocookie.com')) &&
          path.startsWith('/embed/') ||
      host == 'player.vimeo.com' && path.startsWith('/video/') ||
      _hostMatches(host, 'facebook.com') && path.startsWith('/plugins/video') ||
      _hostMatches(host, 'tiktok.com') && path.startsWith('/player/') ||
      RegExp(r'/(?:embed|player)(?:/|$)').hasMatch(path);
}

Uri? _resolveHttps(Uri base, String value) {
  try {
    final resolved = base.resolve(_decodeHtml(value.trim())).removeFragment();
    return _isHttps(resolved) ? resolved : null;
  } on FormatException {
    return null;
  }
}

bool _isHttps(Uri url) {
  if (url.scheme.toLowerCase() != 'https' ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty) {
    return false;
  }
  final host = url.host.toLowerCase();
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    return false;
  }
  final address = InternetAddress.tryParse(host);
  return address == null || _isPublicAddress(address.rawAddress);
}

bool _isPublicAddress(List<int> bytes) {
  if (bytes.length == 4) {
    final a = bytes[0];
    final b = bytes[1];
    return a != 0 &&
        a != 10 &&
        a != 127 &&
        !(a == 100 && b >= 64 && b <= 127) &&
        !(a == 169 && b == 254) &&
        !(a == 172 && b >= 16 && b <= 31) &&
        !(a == 192 && b == 168) &&
        a < 224;
  }
  if (bytes.length != 16) return false;
  final unspecified = bytes.every((value) => value == 0);
  final loopback =
      bytes.take(15).every((value) => value == 0) && bytes.last == 1;
  final uniqueLocal = bytes[0] & 0xfe == 0xfc;
  final linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80;
  final multicast = bytes[0] == 0xff;
  final ipv4Mapped =
      bytes.take(10).every((value) => value == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  return !unspecified &&
      !loopback &&
      !uniqueLocal &&
      !linkLocal &&
      !multicast &&
      (!ipv4Mapped || _isPublicAddress(bytes.sublist(12)));
}

bool _hostMatches(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

bool _isHtml(String mimeType) =>
    mimeType == 'text/html' || mimeType == 'application/xhtml+xml';

bool _isNonFileResponseMime(String? mimeType) =>
    mimeType != null &&
    (_isHtml(mimeType) ||
        mimeType.startsWith('text/') ||
        mimeType == 'application/json' ||
        mimeType.endsWith('+json') ||
        mimeType == 'application/xml' ||
        mimeType.endsWith('+xml'));

String? _usableResponseMime(String? mimeType) =>
    mimeType == null ||
        mimeType == 'application/octet-stream' ||
        mimeType == 'binary/octet-stream'
    ? null
    : mimeType;

bool _looksLikeMarkup(List<int> bytes) {
  final prefix = ascii
      .decode(bytes.take(128).toList(), allowInvalid: true)
      .trimLeft()
      .toLowerCase();
  return prefix.startsWith('<!doctype') ||
      prefix.startsWith('<html') ||
      prefix.startsWith('<head') ||
      prefix.startsWith('<body') ||
      prefix.startsWith('<?xml') ||
      prefix.startsWith('{') ||
      prefix.startsWith('[');
}

bool _looksLikeAdaptiveManifest(List<int> bytes) {
  final prefix = ascii
      .decode(bytes.take(512).toList(), allowInvalid: true)
      .trimLeft()
      .toLowerCase();
  return prefix.startsWith('#extm3u') ||
      prefix.startsWith('<mpd') ||
      prefix.startsWith('<?xml') && prefix.contains('<mpd');
}

String? _sniffMediaMime(List<int> bytes, MediaKind expectedKind) {
  bool startsWith(List<int> signature) =>
      bytes.length >= signature.length &&
      Iterable<int>.generate(
        signature.length,
      ).every((index) => bytes[index] == signature[index]);
  if (startsWith(const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (startsWith(const [0x89, 0x50, 0x4e, 0x47])) return 'image/png';
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (startsWith(const [0x25, 0x50, 0x44, 0x46])) return 'application/pdf';
  if (startsWith(const [0x50, 0x4b, 0x03, 0x04])) return 'application/zip';
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF') {
    final type = ascii.decode(bytes.sublist(8, 12), allowInvalid: true);
    if (type == 'WEBP') return 'image/webp';
    if (type == 'WAVE') return 'audio/wav';
  }
  if (startsWith(const [0x1a, 0x45, 0xdf, 0xa3])) {
    return expectedKind == MediaKind.audio ? 'audio/webm' : 'video/webm';
  }
  if (startsWith(const [0x4f, 0x67, 0x67, 0x53])) {
    return expectedKind == MediaKind.video ? 'video/ogg' : 'audio/ogg';
  }
  if (startsWith(const [0x66, 0x4c, 0x61, 0x43])) return 'audio/flac';
  if (bytes.length >= 2 && bytes[0] == 0xff && (bytes[1] & 0xf6) == 0xf0) {
    return 'audio/aac';
  }
  if (startsWith(const [0x49, 0x44, 0x33]) ||
      bytes.length >= 2 &&
          bytes[0] == 0xff &&
          (bytes[1] & 0xe0) == 0xe0 &&
          expectedKind == MediaKind.audio) {
    return 'audio/mpeg';
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp') {
    final brand = ascii.decode(bytes.sublist(8, 12), allowInvalid: true);
    if (const {'avif', 'avis'}.contains(brand)) return 'image/avif';
    if (brand.startsWith('qt')) return 'video/quicktime';
    if (brand.startsWith('M4A') || brand.startsWith('M4B')) {
      return 'audio/mp4';
    }
    return expectedKind == MediaKind.audio ? 'audio/mp4' : 'video/mp4';
  }
  return null;
}

bool _isStreamingManifest(String mimeType) =>
    mimeType == 'application/vnd.apple.mpegurl' ||
    mimeType == 'application/x-mpegurl' ||
    mimeType == 'application/dash+xml';

bool _isAdaptiveStream(Uri url, String? mimeType) =>
    mimeType != null && _isStreamingManifest(mimeType) ||
    const {'m3u8', 'mpd'}.contains(_extension(url.path));

bool _containsAdaptiveStreamReference(String html) => RegExp(
  r'''(?:adaptiveFormats|(?:hls|dash)ManifestUrl|application/(?:vnd\.apple\.mpegurl|x-mpegurl|dash\+xml)|["'\s=](?:https?:)?[^"'\s<>]+?\.(?:m3u8|mpd)(?:[?"'\s<>]|$))''',
  caseSensitive: false,
).hasMatch(html);

bool _looksLikeDownloadResponse(
  Uri url,
  String? mimeType,
  String? dispositionName,
) {
  final extension = _extension(url.path);
  if (mimeType != null &&
          (_isHtml(mimeType) || _isStreamingManifest(mimeType)) ||
      const {'m3u8', 'mpd'}.contains(extension)) {
    return false;
  }
  if (mimeType?.startsWith('video/') == true ||
      mimeType?.startsWith('audio/') == true ||
      mimeType?.startsWith('image/') == true ||
      const {'application/pdf', 'application/zip'}.contains(mimeType)) {
    return true;
  }
  if (dispositionName != null && dispositionName.trim().isNotEmpty) {
    return true;
  }
  return extension.isNotEmpty &&
      !const {'asp', 'aspx', 'htm', 'html', 'jsp', 'php'}.contains(extension);
}

void _setPublicPageHeaders(HttpClientRequest request) {
  request.headers
    ..set(HttpHeaders.userAgentHeader, _browserUserAgent)
    ..set(HttpHeaders.acceptHeader, _pageAccept)
    ..set(HttpHeaders.acceptLanguageHeader, 'ko-KR,ko;q=0.9,en;q=0.8');
}

Future<({HttpClientResponse response, Uri url})> _openPublicUrl(
  HttpClient client,
  String method,
  Uri sourceUrl, {
  Map<String, String> requestHeaders = const {},
}) async {
  var current = sourceUrl;
  for (var redirectCount = 0; ; redirectCount++) {
    if (!_isHttps(current)) {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.invalidUrl,
          '리디렉션된 주소가 공개 HTTPS 주소가 아닙니다.',
        ),
      );
    }
    final request = await client.openUrl(method, current);
    request.followRedirects = false;
    _setPublicPageHeaders(request);
    for (final header in requestHeaders.entries) {
      if ({'referer', 'user-agent'}.contains(header.key.toLowerCase()) &&
          header.value.length <= 1000 &&
          !header.value.contains('\n') &&
          !header.value.contains('\r')) {
        request.headers.set(header.key, header.value);
      }
    }
    final response = await request.close();
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (!const {
          HttpStatus.movedPermanently,
          HttpStatus.found,
          HttpStatus.seeOther,
          HttpStatus.temporaryRedirect,
          HttpStatus.permanentRedirect,
        }.contains(response.statusCode) ||
        location == null ||
        location.trim().isEmpty) {
      return (response: response, url: current);
    }
    if (redirectCount >= 5) {
      await response.drain<void>();
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.network,
          '페이지가 너무 많이 리디렉션되어 분석을 중단했습니다.',
        ),
      );
    }
    Uri next;
    try {
      next = current.resolve(location.trim()).removeFragment();
    } on FormatException {
      await response.drain<void>();
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.invalidUrl,
          '페이지의 리디렉션 주소가 올바르지 않습니다.',
        ),
      );
    }
    await response.drain<void>();
    if (!_isHttps(next)) {
      throw const _MediaProviderFailure(
        MediaAnalysisFailure(
          MediaAnalysisFailureCode.invalidUrl,
          '리디렉션된 주소가 공개 HTTPS 주소가 아닙니다.',
        ),
      );
    }
    current = next;
  }
}

String? _normalizedMime(String? value) {
  final normalized = value?.split(';').first.trim().toLowerCase();
  return normalized == null || !normalized.contains('/') ? null : normalized;
}

MediaKind _kindFromMimeOrUrl(String? mimeType, String value) {
  if (mimeType?.startsWith('video/') == true) return MediaKind.video;
  if (mimeType?.startsWith('audio/') == true) return MediaKind.audio;
  if (mimeType?.startsWith('image/') == true) return MediaKind.image;
  final extension = _extension(Uri.tryParse(value)?.path ?? value);
  if (const {'mp4', 'webm', 'mov', 'm4v', 'ogv'}.contains(extension)) {
    return MediaKind.video;
  }
  if (const {'mp3', 'm4a', 'aac', 'ogg', 'wav', 'flac'}.contains(extension)) {
    return MediaKind.audio;
  }
  if (const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif'}.contains(extension)) {
    return MediaKind.image;
  }
  return MediaKind.file;
}

String? _mimeFromUrl(Uri url) => switch (_extension(url.path)) {
  'mp4' => 'video/mp4',
  'webm' => 'video/webm',
  'mov' => 'video/quicktime',
  'm4v' => 'video/x-m4v',
  'ogv' => 'video/ogg',
  'mp3' => 'audio/mpeg',
  'm4a' => 'audio/mp4',
  'aac' => 'audio/aac',
  'ogg' => 'audio/ogg',
  'wav' => 'audio/wav',
  'flac' => 'audio/flac',
  'jpg' || 'jpeg' => 'image/jpeg',
  'png' => 'image/png',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'avif' => 'image/avif',
  _ => null,
};

String _safeFileName(
  String? preferredName,
  Uri url,
  String? mimeType,
  MediaKind kind,
) {
  var name = preferredName?.trim();
  if (name == null || name.isEmpty) {
    final segment = url.pathSegments.lastOrNull;
    if (segment != null && segment.isNotEmpty) {
      try {
        name = Uri.decodeComponent(segment);
      } on FormatException {
        name = segment;
      }
    }
  }
  name = (name == null || name.isEmpty ? kind.name : name)
      .replaceAll(RegExp(r'[\x00-\x1f\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  if (name.isEmpty) name = kind.name;
  if (name.length > 120) name = name.substring(0, 120);
  final extension = _extensionForMime(mimeType);
  if (extension != null) {
    final currentExtension = _extension(name);
    if (currentExtension.isEmpty) {
      name = '$name.$extension';
    } else if (!_extensionMatchesMime(currentExtension, mimeType!)) {
      name =
          '${name.substring(0, name.length - currentExtension.length)}'
          '$extension';
    }
  }
  return name;
}

bool _extensionMatchesMime(String extension, String mimeType) =>
    switch (mimeType) {
      'image/jpeg' => const {'jpg', 'jpeg'}.contains(extension),
      'video/mp4' => const {'mp4', 'm4v'}.contains(extension),
      _ => extension == _extensionForMime(mimeType),
    };

String _extension(String value) {
  final dot = value.lastIndexOf('.');
  if (dot < 0 || dot == value.length - 1) return '';
  final valueAfterDot = value.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{1,10}$').hasMatch(valueAfterDot)
      ? valueAfterDot
      : '';
}

String? _extensionForMime(String? mimeType) => switch (mimeType) {
  'video/mp4' => 'mp4',
  'video/webm' => 'webm',
  'video/quicktime' => 'mov',
  'video/x-m4v' => 'm4v',
  'video/ogg' => 'ogv',
  'audio/mpeg' => 'mp3',
  'audio/webm' => 'webm',
  'audio/mp4' => 'm4a',
  'audio/aac' => 'aac',
  'audio/ogg' => 'ogg',
  'audio/wav' => 'wav',
  'audio/flac' => 'flac',
  'image/jpeg' => 'jpg',
  'image/png' => 'png',
  'image/gif' => 'gif',
  'image/webp' => 'webp',
  'image/avif' => 'avif',
  'application/pdf' => 'pdf',
  'application/zip' => 'zip',
  _ => null,
};

String? _contentDispositionFileName(String? value) {
  if (value == null) return null;
  final encoded = RegExp(
    r"""filename\*\s*=\s*(?:UTF-8'')?([^;\s]+)""",
    caseSensitive: false,
  ).firstMatch(value)?.group(1);
  if (encoded != null) {
    try {
      return Uri.decodeComponent(encoded.replaceAll('"', ''));
    } on FormatException {
      return encoded;
    }
  }
  return RegExp(
    r'''filename\s*=\s*(?:"([^"]+)"|'([^']+)'|([^;\s]+))''',
    caseSensitive: false,
  ).firstMatch(value)?.groups([1, 2, 3]).whereType<String>().firstOrNull;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;

  T? get lastOrNull => isEmpty ? null : last;
}
