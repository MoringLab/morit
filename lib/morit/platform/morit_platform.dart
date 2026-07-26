import 'package:flutter/services.dart';

/// Typed boundary between shared Flutter code and Android platform features.
///
/// Keeping raw method-channel names here prevents screens and data logic from
/// depending on Kotlin implementation details. An iOS implementation can use
/// the same Dart-facing contract later.
final class MoritPlatform {
  const MoritPlatform();

  static const _native = MethodChannel('com.luverse.morit/native');
  static const _share = MethodChannel('com.luverse.morit/share');
  static const _todayOverlay = MethodChannel('com.luverse.morit/today_overlay');

  void setNavigationHandlers({
    void Function()? openDownloads,
    void Function(String route)? openToday,
  }) {
    _native.setMethodCallHandler(
      openDownloads == null && openToday == null
          ? null
          : (call) async {
              if (call.method == 'openDownloads') {
                openDownloads?.call();
                return;
              }
              if (call.method == 'openToday') {
                final value = Map<String, dynamic>.from(
                  call.arguments as Map? ?? const {},
                );
                final action = value['action'] as String? ?? 'list';
                final itemId = value['itemId'] as String?;
                openToday?.call(
                  '/today-overlay/$action${itemId == null ? '' : '/$itemId'}',
                );
                return;
              }
              throw MissingPluginException(
                'Unknown native event: ${call.method}',
              );
            },
    );
  }

  void setOpenDownloadsHandler(void Function()? handler) =>
      setNavigationHandlers(openDownloads: handler);

  Future<Map<String, dynamic>?> initialTodayOverlay() =>
      _todayOverlay.invokeMapMethod<String, dynamic>('getInitialTodayOverlay');

  Future<bool> requestTodayDeviceUnlock() async =>
      await _todayOverlay.invokeMethod<bool>('requestDeviceUnlock') ?? false;

  Future<void> closeTodayOverlay() =>
      _todayOverlay.invokeMethod<void>('closeTodayOverlay');

  void setTodayOverlayHandler(
    void Function(Map<String, dynamic> value)? handler,
  ) {
    _todayOverlay.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method == 'todayOverlayChanged' ||
                  call.method == 'todayOverlayAuthorizationChanged') {
                handler(
                  Map<String, dynamic>.from(call.arguments as Map? ?? const {}),
                );
                return;
              }
              throw MissingPluginException(
                'Unknown today overlay event: ${call.method}',
              );
            },
    );
  }

  Future<Map<String, dynamic>?> initialShare() =>
      _share.invokeMapMethod<String, dynamic>('getInitialShare');

  Future<String?> appFilesPath() =>
      _native.invokeMethod<String>('getAppFilesPath');

  Future<bool> deleteOwnedFile(String path) async =>
      await _native.invokeMethod<bool>('deleteOwnedFile', {'path': path}) ??
      false;

  Future<String?> copySharedContentUri(
    String uri, {
    required int maxBytes,
    String? fileName,
  }) => _native.invokeMethod<String>('copyContentUriToAppFiles', {
    'uri': uri,
    'maxBytes': maxBytes,
    'fileName': ?fileName,
  });

  Future<bool> requestNotificationPermission() async =>
      await _native.invokeMethod<bool>('requestNotificationPermission') ??
      false;

  Future<Map<String, dynamic>?> scheduleReminder({
    required int id,
    required String key,
    required String title,
    required String body,
    required int atMillis,
  }) => _native.invokeMapMethod<String, dynamic>('scheduleReminder', {
    'id': id,
    'key': key,
    'title': title,
    'body': body,
    'atMillis': atMillis,
  });

  Future<void> cancelReminder({required int id, required String key}) =>
      _native.invokeMethod<void>('cancelReminder', {'id': id, 'key': key});

  Future<({int id, String saveLocation})?> enqueueDownload({
    required String taskId,
    required Uri url,
    required String fileName,
    required String title,
    required String mediaKind,
    String? description,
    String? mimeType,
    int? expectedContentLength,
    bool wifiOnly = false,
    Map<String, String> headers = const {},
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,100}$').hasMatch(taskId)) {
      throw ArgumentError.value(taskId, 'taskId', 'must be an opaque task ID');
    }
    if (url.toString().length > 8192 ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      throw ArgumentError.value(url, 'url', 'must be an HTTPS URL');
    }
    if (expectedContentLength != null &&
        (expectedContentLength <= 0 ||
            expectedContentLength > 0x7fffffffffffffff)) {
      throw ArgumentError.value(
        expectedContentLength,
        'expectedContentLength',
        'must be positive',
      );
    }
    for (final header in headers.entries) {
      if (!{'referer', 'user-agent'}.contains(header.key.toLowerCase()) ||
          header.value.length > 1000 ||
          header.key.contains('\n') ||
          header.key.contains('\r') ||
          header.value.contains('\n') ||
          header.value.contains('\r')) {
        throw ArgumentError.value(headers, 'headers', 'contains unsafe values');
      }
    }
    final value = await _native
        .invokeMapMethod<String, dynamic>('enqueueDownload', {
          'taskId': taskId,
          'url': url.toString(),
          'fileName': fileName,
          'mediaKind': mediaKind,
          'mimeType': mimeType,
          'title': title,
          'description': description,
          'expectedContentLength': ?expectedContentLength,
          'wifiOnly': wifiOnly,
          'headers': headers,
        });
    if (value == null) return null;
    final id = (value['id'] as num?)?.toInt();
    final saveLocation = value['saveLocation'] as String?;
    if (id == null || saveLocation == null || saveLocation.isEmpty) {
      throw PlatformException(
        code: 'invalid_native_response',
        message: '다운로드 저장 위치를 확인하지 못했습니다.',
      );
    }
    return (id: id, saveLocation: saveLocation);
  }

  Future<void> cancelDownload(int id) =>
      _native.invokeMethod<void>('cancelDownload', {'id': id});

  Future<Map<String, dynamic>?> queryDownload(int id) =>
      _native.invokeMapMethod<String, dynamic>('queryDownload', {'id': id});

  Future<int?> queryDownloadTask(String taskId) =>
      _native.invokeMethod<int>('queryDownloadTask', {'taskId': taskId});

  Future<bool> scheduleBackendTransfer({
    required Uri statusUrl,
    required String backendJobId,
    required String title,
    String? description,
    bool wifiOnly = false,
  }) async {
    final normalizedJobId = _backendJobId(backendJobId);
    final statusValue = statusUrl.toString();
    if (statusValue.length > 8192 ||
        statusUrl.scheme != 'https' ||
        statusUrl.host.isEmpty ||
        statusUrl.userInfo.isNotEmpty ||
        statusUrl.hasFragment ||
        !RegExp(
          r'[A-Za-z0-9_-]{43,}',
        ).hasMatch('${statusUrl.path}?${statusUrl.query}')) {
      throw ArgumentError.value(
        statusUrl,
        'statusUrl',
        'must be an opaque-ticket HTTPS URL',
      );
    }
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
      throw ArgumentError.value(title, 'title', 'must be 1-200 characters');
    }
    final normalizedDescription = description?.trim();
    if (normalizedDescription != null && normalizedDescription.length > 500) {
      throw ArgumentError.value(
        description,
        'description',
        'must be at most 500 characters',
      );
    }
    return await _native.invokeMethod<bool>('scheduleBackendTransfer', {
          'statusUrl': statusValue,
          'backendJobId': normalizedJobId,
          'title': normalizedTitle,
          'description': normalizedDescription,
          'wifiOnly': wifiOnly,
        }) ??
        false;
  }

  Future<Map<String, dynamic>?> queryBackendTransfer(String backendJobId) =>
      _native.invokeMapMethod<String, dynamic>('queryBackendTransfer', {
        'backendJobId': _backendJobId(backendJobId),
      });

  Future<bool> cancelBackendTransfer(String backendJobId) async =>
      await _native.invokeMethod<bool>('cancelBackendTransfer', {
        'backendJobId': _backendJobId(backendJobId),
      }) ??
      false;

  Future<bool> openDownload(int id, {String? mimeType}) async =>
      await _native.invokeMethod<bool>('openDownload', {
        'id': id,
        'mimeType': mimeType ?? '*/*',
      }) ??
      false;

  Future<bool> setTodayTasks({
    required String userId,
    required List<Map<String, dynamic>> tasks,
    int maxVisible = 5,
    bool showCompleted = true,
    bool carryOverIncomplete = true,
    String lockPolicy = 'device_unlock',
    bool overlayEnabled = true,
  }) async =>
      await _native.invokeMethod<bool>('setTodayTasks', {
        'userId': userId,
        'tasks': tasks,
        'maxVisible': maxVisible.clamp(1, 8),
        'showCompleted': showCompleted,
        'carryOverIncomplete': carryOverIncomplete,
        'lockPolicy': lockPolicy,
        'overlayEnabled': overlayEnabled,
      }) ??
      false;

  Future<List<Map<String, dynamic>>> readTodayActions(String userId) async {
    final value = await _native.invokeListMethod<dynamic>('readTodayActions', {
      'userId': userId,
    });
    return (value ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> ackTodayActions(String userId, Iterable<String> ids) =>
      _native.invokeMethod<void>('ackTodayActions', {
        'userId': userId,
        'ids': ids.toList(),
      });

  Future<void> clearTodayNotification() =>
      _native.invokeMethod<void>('clearTodayNotification');

  Future<bool> openFile(String path, {String? mimeType}) async =>
      await _native.invokeMethod<bool>('openFile', {
        'path': path,
        'mimeType': mimeType ?? '*/*',
      }) ??
      false;

  static String _backendJobId(String value) {
    final normalized = value.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{8,100}$').hasMatch(normalized)) {
      throw ArgumentError.value(value, 'backendJobId', 'has an invalid format');
    }
    return normalized;
  }
}
