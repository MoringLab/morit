import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'media_provider.dart';

const _maxBackendResponseBytes = 4 * 1024 * 1024;
const _analysisCacheTtl = Duration(minutes: 10);

final class DownloadBackendException implements Exception {
  const DownloadBackendException({
    required this.code,
    required this.message,
    this.stage,
    this.engine,
    this.platform,
    this.logId,
    this.fallbacks = const [],
    this.retryable = false,
  });

  final String code;
  final String message;
  final String? stage;
  final String? engine;
  final String? platform;
  final String? logId;
  final List<String> fallbacks;
  final bool retryable;

  String get displayMessage {
    final details = [
      platform,
      engine,
      code,
      if (logId case final value?) 'log:$value',
    ].whereType<String>().where((value) => value.isNotEmpty).join(' / ');
    final primary = details.isEmpty ? message : '$message [$details]';
    return fallbacks.isEmpty
        ? primary
        : '$primary · 대체 엔진: ${fallbacks.join(', ')}';
  }

  @override
  String toString() => displayMessage;
}

final class BackendDownloadJob {
  const BackendDownloadJob({
    required this.id,
    required this.status,
    required this.stage,
    required this.progress,
    this.engine,
    this.platform,
    this.error,
    this.transferUrl,
    this.fileUrl,
    this.fileName,
    this.mimeType,
    this.kind,
    this.contentLength,
  });

  final String id;
  final String status;
  final String stage;
  final int progress;
  final String? engine;
  final String? platform;
  final DownloadBackendException? error;
  final Uri? transferUrl;
  final Uri? fileUrl;
  final String? fileName;
  final String? mimeType;
  final MediaKind? kind;
  final int? contentLength;

  bool get ready =>
      const {'ready', 'complete', 'completed'}.contains(status) &&
      fileUrl != null;
  bool get terminal => const {
    'ready',
    'complete',
    'completed',
    'failed',
    'canceled',
  }.contains(status);
}

/// Authenticated boundary to the server-side yt-dlp/FFmpeg pipeline.
///
/// The APK contains only the public endpoint. A current Supabase access token
/// authenticates analysis and job calls; it is never passed to DownloadManager.
final class DownloadBackendClient {
  DownloadBackendClient({required this.endpoint, required this.accessToken}) {
    _client.connectionTimeout = const Duration(seconds: 15);
  }

  final Uri? endpoint;
  final String? Function() accessToken;
  final HttpClient _client = HttpClient();
  final Map<Uri, ({DateTime expiresAt, MediaAnalysisResult result})>
  _analysisCache = {};
  String? _analysisCacheToken;

  bool get configured => endpoint != null;

  Future<MediaAnalysisResult> analyzeDetailed(Uri sourceUrl) async {
    final classification = classifyMediaUrl(sourceUrl);
    if (!configured) {
      return MediaAnalysisResult(
        classification: classification,
        failure: const MediaAnalysisFailure(
          MediaAnalysisFailureCode.backendUnavailable,
          '다운로드 서버가 설정되지 않았습니다. 앱 관리자에게 문의해 주세요.',
        ),
      );
    }
    final token = accessToken()?.trim();
    if (token != _analysisCacheToken) {
      _analysisCache.clear();
      _analysisCacheToken = token;
    }
    final cacheKey = sourceUrl.removeFragment();
    final cached = _analysisCache[cacheKey];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.result;
    }
    _analysisCache.remove(cacheKey);
    try {
      final json = await _jsonRequest(
        'POST',
        'v1/analyze',
        body: {'url': sourceUrl.removeFragment().toString()},
        timeout: const Duration(seconds: 45),
      );
      final analysisId =
          _nonEmpty(json['analysis_id']) ?? _nonEmpty(json['id']);
      final resolvedSource =
          Uri.tryParse(_nonEmpty(json['source_url']) ?? '') ?? sourceUrl;
      final platform =
          _nonEmpty(json['platform']) ??
          _nonEmpty(json['provider']) ??
          classification.providerLabel;
      final values = (json['selections'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      if (analysisId == null || values.isEmpty) {
        throw const DownloadBackendException(
          code: 'invalid_analysis',
          message: '다운로드 서버가 선택 가능한 미디어 정보를 반환하지 않았습니다.',
        );
      }
      final candidates = <MediaCandidate>[];
      for (final value in values) {
        final selectionId = _nonEmpty(value['id']);
        final fileName =
            _nonEmpty(value['file_name']) ?? _nonEmpty(value['filename']);
        final kind = _mediaKind(value['kind']);
        if (selectionId == null || fileName == null || kind == null) continue;
        candidates.add(
          MediaCandidate(
            url: _uri(
              'v1/selections/${Uri.encodeComponent(analysisId)}/'
              '${Uri.encodeComponent(selectionId)}',
            ),
            kind: kind,
            fileName: fileName,
            providerLabel: platform,
            mimeType: _nonEmpty(value['mime_type']),
            isPreview: value['is_preview'] == true,
            analysisId: analysisId,
            selectionId: selectionId,
            assetId: _nonEmpty(value['asset_id']) ?? selectionId,
            qualityLabel:
                _nonEmpty(value['label']) ?? _nonEmpty(value['quality']),
            sizeBytes: switch ((value['size_bytes'] as num?)?.toInt()) {
              final size? when size > 0 => size,
              _ => null,
            },
            sizeEstimated: value['size_estimated'] == true,
            recommended: value['recommended'] == true,
          ),
        );
      }
      if (candidates.isEmpty) {
        throw const DownloadBackendException(
          code: 'invalid_analysis',
          message: '다운로드 서버 응답에서 유효한 미디어 형식을 확인하지 못했습니다.',
        );
      }
      final result = MediaAnalysisResult(
        classification: classification,
        analysis: MediaAnalysis(
          sourceUrl: resolvedSource,
          providerLabel: platform,
          candidates: candidates,
          title: _nonEmpty(json['title']),
          thumbnailUrl: _optionalUri(json['thumbnail_url']),
        ),
      );
      if (_analysisCache.length >= 20) {
        _analysisCache.remove(_analysisCache.keys.first);
      }
      _analysisCache[cacheKey] = (
        expiresAt: DateTime.now().add(_analysisCacheTtl),
        result: result,
      );
      return result;
    } on DownloadBackendException catch (error) {
      return MediaAnalysisResult(
        classification: classification,
        failure: MediaAnalysisFailure(
          _failureCode(error.code),
          error.displayMessage,
        ),
      );
    } on TimeoutException {
      return MediaAnalysisResult(
        classification: classification,
        failure: const MediaAnalysisFailure(
          MediaAnalysisFailureCode.timeout,
          '플랫폼 분석 시간이 초과되었습니다. 잠시 후 다시 시도해 주세요.',
        ),
      );
    } on SocketException {
      return MediaAnalysisResult(
        classification: classification,
        failure: const MediaAnalysisFailure(
          MediaAnalysisFailureCode.backendUnavailable,
          '다운로드 서버에 연결할 수 없습니다. 네트워크를 확인해 주세요.',
        ),
      );
    } on HandshakeException {
      return MediaAnalysisResult(
        classification: classification,
        failure: const MediaAnalysisFailure(
          MediaAnalysisFailureCode.tls,
          '다운로드 서버의 보안 연결을 확인할 수 없습니다.',
        ),
      );
    } on Object {
      return MediaAnalysisResult(
        classification: classification,
        failure: const MediaAnalysisFailure(
          MediaAnalysisFailureCode.backendUnavailable,
          '다운로드 서버 응답을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.',
        ),
      );
    }
  }

  Future<BackendDownloadJob> createJob(
    MediaCandidate selection, {
    required String requestId,
  }) async {
    final analysisId = selection.analysisId;
    final selectionId = selection.selectionId;
    if (analysisId == null || selectionId == null) {
      throw const DownloadBackendException(
        code: 'invalid_selection',
        message: '선택한 형식의 서버 식별자가 없습니다. 링크를 다시 분석해 주세요.',
      );
    }
    return jobFromJson(
      await _jsonRequest(
        'POST',
        'v1/jobs',
        body: {
          'analysis_id': analysisId,
          'selection_id': selectionId,
          'request_id': requestId,
        },
        timeout: const Duration(seconds: 20),
      ),
    );
  }

  Future<BackendDownloadJob> queryJob(String id) async => jobFromJson(
    await _jsonRequest(
      'GET',
      'v1/jobs/${Uri.encodeComponent(id)}',
      timeout: const Duration(seconds: 15),
    ),
  );

  Future<void> cancelJob(String id) async {
    await _jsonRequest(
      'DELETE',
      'v1/jobs/${Uri.encodeComponent(id)}',
      timeout: const Duration(seconds: 15),
    );
  }

  BackendDownloadJob jobFromJson(Map<String, dynamic> json) {
    final id = _nonEmpty(json['id']) ?? _nonEmpty(json['job_id']);
    final status =
        _nonEmpty(json['status']) ?? _nonEmpty(json['state']) ?? 'queued';
    final rawFile = json['file'];
    final file = rawFile is Map
        ? Map<String, dynamic>.from(rawFile)
        : const <String, dynamic>{};
    final rawError = json['error'];
    final error = rawError is Map
        ? _backendError(Map<String, dynamic>.from(rawError))
        : rawError is String && rawError.trim().isNotEmpty
        ? DownloadBackendException(code: 'engine_failed', message: rawError)
        : null;
    final fileUrl = _optionalUri(file['url'] ?? json['download_url']);
    final transferUrl = _optionalUri(json['transfer_url']);
    if (id == null) {
      throw const DownloadBackendException(
        code: 'invalid_job',
        message: '다운로드 서버가 작업 ID를 반환하지 않았습니다.',
      );
    }
    if (fileUrl != null && !_sameOrigin(fileUrl, endpoint!)) {
      throw const DownloadBackendException(
        code: 'invalid_file_url',
        message: '다운로드 서버가 신뢰할 수 없는 파일 주소를 반환했습니다.',
      );
    }
    if (transferUrl != null && !_sameOrigin(transferUrl, endpoint!)) {
      throw const DownloadBackendException(
        code: 'invalid_transfer_url',
        message: '다운로드 서버가 신뢰할 수 없는 작업 주소를 반환했습니다.',
      );
    }
    final rawProgress = (json['progress'] as num?)?.toDouble() ?? 0;
    return BackendDownloadJob(
      id: id,
      status: status,
      stage: _nonEmpty(json['stage']) ?? status,
      progress: (rawProgress <= 1 ? rawProgress * 100 : rawProgress)
          .round()
          .clamp(0, 100),
      engine: _nonEmpty(json['engine']),
      platform: _nonEmpty(json['platform']),
      error: error,
      transferUrl: transferUrl,
      fileUrl: fileUrl,
      fileName: _nonEmpty(file['file_name']) ?? _nonEmpty(json['file_name']),
      mimeType: _nonEmpty(file['mime_type']) ?? _nonEmpty(json['mime_type']),
      kind: _mediaKind(file['kind'] ?? json['kind']),
      contentLength: switch ((file['content_length'] as num?)?.toInt() ??
          (json['content_length'] as num?)?.toInt()) {
        final size? when size > 0 => size,
        _ => null,
      },
    );
  }

  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
    required Duration timeout,
  }) async {
    if (!configured) {
      throw const DownloadBackendException(
        code: 'backend_unconfigured',
        message: '다운로드 서버가 설정되지 않았습니다.',
      );
    }
    final token = accessToken()?.trim();
    if (token == null || token.isEmpty) {
      throw const DownloadBackendException(
        code: 'authentication_required',
        message: '로그인 세션이 만료되었습니다. 다시 로그인해 주세요.',
      );
    }
    final request = await _client.openUrl(method, _uri(path)).timeout(timeout);
    request.followRedirects = false;
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBackendResponseBytes) {
        throw const DownloadBackendException(
          code: 'response_too_large',
          message: '다운로드 서버 응답이 허용 크기를 초과했습니다.',
        );
      }
    }
    Map<String, dynamic> json = const {};
    if (bytes.isNotEmpty) {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) json = Map<String, dynamic>.from(decoded);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = json['detail'];
      final error = json['error'];
      final payload = error is Map
          ? Map<String, dynamic>.from(error)
          : detail is Map
          ? Map<String, dynamic>.from(detail)
          : <String, dynamic>{
              'code': response.statusCode == 401
                  ? 'authentication_required'
                  : response.statusCode == 429
                  ? 'rate_limited'
                  : 'http_${response.statusCode}',
              'message': error is String
                  ? error
                  : detail is String
                  ? detail
                  : '다운로드 서버가 HTTP ${response.statusCode} 오류를 반환했습니다.',
            };
      throw _backendError(payload);
    }
    return json;
  }

  Uri _uri(String path) {
    final base = endpoint!;
    final prefix = base.path.endsWith('/')
        ? base.path
        : base.path.isEmpty
        ? '/'
        : '${base.path}/';
    return base.replace(
      path: '$prefix${path.replaceFirst(RegExp(r'^/+'), '')}',
      query: null,
      fragment: null,
    );
  }
}

DownloadBackendException _backendError(Map<String, dynamic> value) =>
    DownloadBackendException(
      code: _nonEmpty(value['code']) ?? 'backend_error',
      message: _nonEmpty(value['message']) ?? '다운로드 서버에서 알 수 없는 오류가 발생했습니다.',
      stage: _nonEmpty(value['stage']),
      engine: _nonEmpty(value['engine']),
      platform: _nonEmpty(value['platform']),
      logId: _nonEmpty(value['log_id']),
      fallbacks: _failureFallbacks(value['causes']),
      retryable: value['retryable'] == true,
    );

List<String> _failureFallbacks(Object? value) => (value as List? ?? const [])
    .whereType<Map>()
    .map(
      (cause) => [
        _nonEmpty(cause['engine']),
        _nonEmpty(cause['code']),
        if (_nonEmpty(cause['log_id']) case final logId?) 'log:$logId',
      ].whereType<String>().join(' / '),
    )
    .where((cause) => cause.isNotEmpty)
    .toList(growable: false);

String? _nonEmpty(Object? value) {
  final text = value is String ? value.trim() : '';
  return text.isEmpty ? null : text;
}

Uri? _optionalUri(Object? value) {
  final text = _nonEmpty(value);
  return text == null ? null : Uri.tryParse(text);
}

MediaKind? _mediaKind(Object? value) =>
    switch (_nonEmpty(value)?.toLowerCase()) {
      'video' => MediaKind.video,
      'audio' => MediaKind.audio,
      'photo' || 'image' => MediaKind.image,
      'file' => MediaKind.file,
      _ => null,
    };

MediaAnalysisFailureCode _failureCode(String code) {
  final value = code.toLowerCase();
  if (value.contains('auth') || value.contains('login')) {
    return MediaAnalysisFailureCode.authenticationRequired;
  }
  if (value.contains('forbidden') || value.contains('denied')) {
    return MediaAnalysisFailureCode.accessDenied;
  }
  if (value.contains('not_found') || value == 'http_404') {
    return MediaAnalysisFailureCode.notFound;
  }
  if (value.contains('rate') || value == 'http_429') {
    return MediaAnalysisFailureCode.rateLimited;
  }
  if (value.contains('unsupported')) {
    return MediaAnalysisFailureCode.unsupportedLinkFormat;
  }
  if (value.contains('no_media') || value.contains('private')) {
    return MediaAnalysisFailureCode.noPublicMedia;
  }
  if (value.contains('timeout')) return MediaAnalysisFailureCode.timeout;
  return MediaAnalysisFailureCode.backendUnavailable;
}

bool _sameOrigin(Uri value, Uri expected) =>
    value.scheme == 'https' &&
    value.userInfo.isEmpty &&
    value.host.toLowerCase() == expected.host.toLowerCase() &&
    value.port == expected.port;
