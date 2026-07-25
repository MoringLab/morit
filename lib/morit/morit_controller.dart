import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../core/app_config.dart';
import '../core/morit_pin_store.dart';
import 'data/morit_attachment_store.dart';
import 'data/morit_models.dart';
import 'media/download_backend.dart';
import 'media/media_provider.dart';
import 'platform/morit_platform.dart';

export 'data/morit_models.dart';
export 'data/morit_attachment_store.dart';
export 'media/download_backend.dart';
export 'media/media_provider.dart';

const _uuid = Uuid();

String inferKind(String? mimeType, String value) {
  final mime = mimeType?.toLowerCase() ?? '';
  if (mime.startsWith('image/')) return 'photo';
  if (mime.startsWith('video/')) return 'video';
  if (mime.isNotEmpty && mime != 'text/plain') return 'file';
  final uri = Uri.tryParse(extractWebUrl(value) ?? value.trim());
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
      ? 'link'
      : 'memo';
}

String? extractWebUrl(String value) {
  final match = RegExp(
    "https?://[^\\s<>\\\"']+",
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return null;
  final candidate = match
      .group(0)!
      .replaceFirst(RegExp(r'[\]\)},.!?;:]+$'), '');
  final uri = Uri.tryParse(candidate);
  return uri != null && {'http', 'https'}.contains(uri.scheme)
      ? candidate
      : null;
}

String safeFileName(String value) {
  final cleaned = value.replaceAll(
    RegExp(r'[^\p{L}\p{N}._-]', unicode: true),
    '_',
  );
  return cleaned.isEmpty
      ? 'download'
      : cleaned.substring(0, cleaned.length.clamp(0, 100));
}

String downloadFileName(String id, String title, Uri source, String? mimeType) {
  var name = safeFileName(title);
  final sourceName = source.pathSegments.isEmpty
      ? ''
      : source.pathSegments.last;
  final sourceMatch = RegExp(r'\.([a-zA-Z0-9]{1,10})$').firstMatch(sourceName);
  final mimeExtension = switch (mimeType?.toLowerCase()) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/avif' => 'avif',
    'video/mp4' => 'mp4',
    'video/webm' => 'webm',
    'video/quicktime' => 'mov',
    'video/ogg' => 'ogv',
    'audio/mpeg' => 'mp3',
    'audio/webm' => 'webm',
    'audio/mp4' => 'm4a',
    'audio/aac' => 'aac',
    'audio/ogg' => 'ogg',
    'audio/wav' => 'wav',
    'audio/flac' => 'flac',
    'application/pdf' => 'pdf',
    'application/zip' => 'zip',
    _ => null,
  };
  final extension = mimeExtension ?? sourceMatch?.group(1)?.toLowerCase();
  if (extension != null) {
    final nameMatch = RegExp(r'\.([a-zA-Z0-9]{1,10})$').firstMatch(name);
    final current = nameMatch?.group(1)?.toLowerCase();
    final compatible =
        current == extension ||
        mimeType?.toLowerCase() == 'image/jpeg' &&
            const {'jpg', 'jpeg'}.contains(current);
    if (!compatible) {
      if (nameMatch != null) name = name.substring(0, nameMatch.start);
      name = '$name.$extension';
    }
  }
  return '${id}_$name';
}

int nativeReminderId(String uuid) {
  final hex = uuid.replaceAll('-', '');
  return int.parse(hex.substring(0, 8), radix: 16) & 0x7FFFFFFF;
}

String displayDate(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
  return '${local.month}.${local.day}';
}

bool isTodayItem(MoritItem item) =>
    item.kind == 'memo' && !item.deleted && item.metadata['today'] == true;

bool isTodayCompleted(MoritItem item) =>
    isTodayItem(item) && item.metadata['completed_at'] is String;

String todayDayKey(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String downloadReasonMessage(int status, int reason, {bool wifiOnly = false}) {
  if (status == 1) {
    return wifiOnly ? 'Wi-Fi 또는 비종량 네트워크를 기다리고 있습니다.' : '시스템에서 시작을 준비하고 있습니다.';
  }
  if (status == 4) {
    return switch (reason) {
      1 => '네트워크 오류 후 자동 재시도 중입니다.',
      2 => '네트워크 연결을 기다리고 있습니다.',
      3 => 'Wi-Fi 연결을 기다리고 있습니다.',
      _ => '시스템에서 다운로드 재개를 기다리고 있습니다.',
    };
  }
  if (status != 16) return '';
  if (reason >= 400 && reason <= 599) return '서버가 HTTP $reason 오류를 반환했습니다.';
  return switch (reason) {
    1001 => '파일을 저장하지 못했습니다.',
    1002 => '지원하지 않는 서버 응답입니다.',
    1004 => '다운로드 중 연결이 끊겼습니다.',
    1005 => '리디렉션이 너무 많습니다.',
    1006 => '기기 저장 공간이 부족합니다.',
    1007 => '저장 장치를 찾을 수 없습니다.',
    1008 => '서버가 이어받기를 지원하지 않습니다.',
    1009 => '같은 이름의 파일이 이미 있습니다.',
    1010 => '네트워크 정책으로 다운로드가 차단됐습니다.',
    _ => '알 수 없는 다운로드 오류($reason)입니다.',
  };
}

const downloadStartTimeout = Duration(minutes: 2);
const backendPreparationTimeout = Duration(minutes: 60);

bool isDownloadStartStalled({
  required int status,
  required int bytesDownloaded,
  required DateTime lastModified,
  bool wifiOnly = false,
  DateTime? now,
}) =>
    !wifiOnly &&
    status == 1 &&
    bytesDownloaded <= 0 &&
    (now ?? DateTime.now().toUtc()).difference(lastModified.toUtc()) >=
        downloadStartTimeout;

String backendFailureMessage(DownloadBackendException error) {
  return error.displayMessage;
}

final class SharedAttachmentInput {
  const SharedAttachmentInput({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    this.mimeType,
  });

  final String path;
  final String fileName;
  final int sizeBytes;
  final String? mimeType;
}

bool supportsAttachments(String kind) => kind == 'memo' || kind == 'reminder';

String _defaultItemTitle(String kind) => switch (kind) {
  'memo' => '메모',
  'link' => '링크',
  'bookmark' => '북마크',
  'photo' => '사진',
  'video' => '영상',
  'file' => '파일',
  'reminder' => '알림',
  _ => '항목',
};

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({
    required this.supabase,
    MoritPlatform? platform,
    MediaAnalyzer? mediaAnalyzer,
    DownloadBackendClient? downloadBackend,
    MoritPinStore? pinStore,
    MoritAttachmentStore? attachmentStore,
  }) : _platform = platform ?? const MoritPlatform(),
       _mediaAnalyzer = mediaAnalyzer,
       _downloadBackend =
           downloadBackend ??
           DownloadBackendClient(
             endpoint: AppConfig.downloadApiUri,
             accessToken: () => supabase.auth.currentSession?.accessToken,
           ),
       _pinStore = pinStore ?? MoritPinStore(),
       _attachmentStore = attachmentStore ?? MoritAttachmentStore(supabase) {
    WidgetsBinding.instance.addObserver(this);
    _authSubscription = supabase.auth.onAuthStateChange.listen((event) {
      if (event.session == null) {
        unawaited(setAccessEnabled(false));
      }
    });
  }

  final SupabaseClient supabase;
  final MoritPlatform _platform;
  final MediaAnalyzer? _mediaAnalyzer;
  final DownloadBackendClient _downloadBackend;
  final MoritPinStore _pinStore;
  final MoritAttachmentStore _attachmentStore;
  late final StreamSubscription<AuthState> _authSubscription;
  List<Folder> folders = [];
  List<MoritItem> items = [];
  List<MoritAttachment> attachments = [];
  final Map<String, double> attachmentProgress = {};
  List<DownloadEntry> downloads = [];
  bool busy = false;
  bool syncing = false;
  bool _syncAgain = false;
  bool _signingOut = false;
  Completer<void>? _syncDone;
  Future<void> _saveQueue = Future.value();
  Timer? _dayRolloverTimer;
  String? message;
  String downloadMode = 'direct';
  bool notificationsEnabled = true;
  bool autoSync = true;
  MoritSettings settings = MoritSettings();
  bool _preferencesDirty = false;
  bool _pollingDownloads = false;
  Future<bool>? _notificationPermissionRequest;
  final Map<String, Object> _downloadAttempts = {};
  bool _resuming = false;
  bool _accessEnabled = false;
  int _accessRevision = 0;
  String? _loadedUserId;

  Session? get session => supabase.auth.currentSession;
  User? get user => supabase.auth.currentUser;
  List<Folder> get visibleFolders {
    final result = folders.where((folder) => !folder.deleted).toList();
    result.sort(
      settings.folderSort == 'name'
          ? (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())
          : (a, b) {
              final position = a.position.compareTo(b.position);
              return position != 0 ? position : a.id.compareTo(b.id);
            },
    );
    return result;
  }

  List<MoritItem> get visibleItems =>
      items.where((item) => !item.deleted).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  List<MoritAttachment> attachmentsForItem(String itemId) =>
      attachments
          .where(
            (value) =>
                value.itemId == itemId &&
                value.uploadState != AttachmentUploadState.deleting,
          )
          .toList()
        ..sort((a, b) {
          final position = a.position.compareTo(b.position);
          return position != 0 ? position : a.createdAt.compareTo(b.createdAt);
        });
  int get attachmentBytes => attachments
      .where((value) => value.uploadState != AttachmentUploadState.deleting)
      .fold(0, (total, value) => total + (value.sizeBytes ?? 0));
  List<MoritItem> get allFavoriteItems =>
      visibleItems.where((item) => item.favorite).toList();
  List<MoritItem> get favoriteItems =>
      allFavoriteItems.take(settings.favoriteLimit).toList();
  List<MoritItem> get allTodayItems {
    final result = items.where(isTodayItem).toList();
    result.sort(_compareToday);
    return result;
  }

  List<MoritItem> get todayItems => allTodayItems
      .where((item) => settings.showCompletedToday || !isTodayCompleted(item))
      .toList();

  int _compareToday(MoritItem a, MoritItem b) {
    if (settings.todaySort == 'newest') {
      return b.createdAt.compareTo(a.createdAt);
    }
    if (settings.todaySort == 'oldest') {
      return a.createdAt.compareTo(b.createdAt);
    }
    final position = ((a.metadata['today_position'] as num?)?.toInt() ?? 0)
        .compareTo((b.metadata['today_position'] as num?)?.toInt() ?? 0);
    return position != 0 ? position : a.createdAt.compareTo(b.createdAt);
  }

  List<Folder> childFolders(String? parentId) =>
      visibleFolders.where((folder) => folder.parentId == parentId).toList();

  List<Folder> folderPath(String? folderId) {
    final result = <Folder>[];
    final seen = <String>{};
    var currentId = folderId;
    while (currentId != null && seen.add(currentId)) {
      final folder = folders
          .where((value) => value.id == currentId && !value.deleted)
          .firstOrNull;
      if (folder == null) break;
      result.add(folder);
      currentId = folder.parentId;
    }
    return result.reversed.toList();
  }

  void showMessage(String value) {
    message = value;
    notifyListeners();
  }

  Future<Map<String, dynamic>?> getInitialShare() => _platform.initialShare();

  Future<String?> copySharedContentUri(
    String uri, {
    required int maxBytes,
    String? fileName,
  }) => _platform.copySharedContentUri(
    uri,
    maxBytes: maxBytes,
    fileName: fileName,
  );

  Future<void> setAccessEnabled(bool enabled) async {
    final currentUser = user;
    if (enabled && currentUser == null) enabled = false;
    if (_accessEnabled == enabled &&
        (!enabled || _loadedUserId == currentUser?.id)) {
      return;
    }
    _accessEnabled = enabled;
    _accessRevision++;
    if (!enabled) {
      _dayRolloverTimer?.cancel();
      final cachedUserId = _loadedUserId;
      await _clearTodayNotification();
      await _cancelAllReminders();
      await _clearDeviceDownloads();
      await _deleteOwnedLocalFiles(
        [
          ...items.map((value) => value.localPath),
          ...attachments.map((value) => value.localPath),
        ].whereType<String>(),
      );
      if (cachedUserId != null) await _clearLocalCache(cachedUserId);
      _loadedUserId = null;
      folders = [];
      items = [];
      attachments = [];
      downloads = [];
      busy = false;
      _syncAgain = false;
      notifyListeners();
      return;
    }
    await load();
  }

  Future<void> _clearDeviceDownloads() async {
    _downloadAttempts.clear();
    final owned = downloads
        .where(
          (value) =>
              value.deviceOwned &&
              {'queued', 'running', 'paused'}.contains(value.state),
        )
        .toList();
    for (final nativeId
        in owned.map((value) => value.nativeId).whereType<int>().toSet()) {
      try {
        await _platform.cancelDownload(nativeId);
      } catch (_) {}
    }
    for (final jobId
        in owned
            .where((value) => value.nativeBackendTransferOwned)
            .map((value) => value.backendJobId)
            .whereType<String>()
            .toSet()) {
      try {
        await _platform.cancelBackendTransfer(jobId);
      } catch (_) {}
    }
    for (final jobId
        in owned
            .map((value) => value.backendJobId)
            .whereType<String>()
            .toSet()) {
      try {
        await _downloadBackend.cancelJob(jobId);
      } catch (_) {}
    }
  }

  Future<void> _clearLocalCache(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = 'morit_${userId}_';
    await Future.wait(
      prefs.getKeys().where((key) => key.startsWith(prefix)).map(prefs.remove),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_resume());
  }

  Future<void> _resume() async {
    final currentUser = user;
    if (!_accessEnabled ||
        currentUser == null ||
        _resuming ||
        busy ||
        _loadedUserId != currentUser.id) {
      return;
    }
    final userId = currentUser.id;
    final accessRevision = _accessRevision;
    bool active() =>
        _accessEnabled &&
        _accessRevision == accessRevision &&
        user?.id == userId;
    _resuming = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (!active()) return;
      folders = _mergeCached(
        folders,
        _decodeList(prefs.getString(_key('folders', userId)), Folder.fromJson),
        (value) => value.id,
        (value) => value.dirty || value.deleted,
        (value) => value.updatedAt,
      );
      items = _mergeCached(
        items,
        _decodeList(prefs.getString(_key('items', userId)), MoritItem.fromJson),
        (value) => value.id,
        (value) => value.dirty || value.deleted,
        (value) => value.updatedAt,
      );
      attachments = _mergeCached(
        attachments,
        _decodeList(
          prefs.getString(_key('attachments', userId)),
          MoritAttachment.fromLocal,
        ),
        (value) => value.id,
        (value) =>
            value.uploadState != AttachmentUploadState.uploaded ||
            value.localPath != null,
        (value) => value.updatedAt,
      );
      downloads = _mergeCached(
        downloads,
        _decodeList(
          prefs.getString(_key('downloads', userId)),
          DownloadEntry.fromJson,
        ),
        (value) => value.id,
        (value) => value.dirty,
        (value) => value.updatedAt,
      );
      _normalizeDetachedDownloads();
      _normalizeLegacyMediaSources();
      _normalizeLocalFileItems(userId);
      if (!_preferencesDirty) {
        downloadMode = 'direct';
        notificationsEnabled =
            prefs.getBool(_key('notifications', userId)) ??
            notificationsEnabled;
        autoSync = prefs.getBool(_key('auto_sync', userId)) ?? autoSync;
        settings = MoritSettings.fromJson(
          _decodeMap(prefs.getString(_key('settings', userId))),
        );
        _preferencesDirty =
            prefs.getBool(_key('preferences_dirty', userId)) ?? false;
        if (settings.lockScreenPolicy == 'morit_pin' &&
            !await _pinStore.hasPin(userId)) {
          settings.lockScreenPolicy = 'device_unlock';
          _preferencesDirty = true;
        }
      }
      _scheduleDayRollover();
      final handoffKeys = _mergeHandoffs(prefs, userId);
      _normalizeLocalFileItems(userId);
      await _applyTodayActions(userId);
      _rolloverTodayItems();
      await _save(userId);
      if (!active()) return;
      await Future.wait(handoffKeys.map(prefs.remove));
      notifyListeners();
      if (autoSync) await sync();
      await pollDownloads();
      await _syncTodayNotification();
    } finally {
      _resuming = false;
    }
  }

  bool _rolloverTodayItems([DateTime? value]) {
    final now = value ?? DateTime.now();
    final day = todayDayKey(now);
    final updatedAt = now.toUtc();
    var changed = false;
    for (final item in items.where(isTodayItem)) {
      final itemDay = item.metadata['today_day'] as String?;
      if (itemDay == day) continue;
      final metadata = Map<String, dynamic>.from(item.metadata);
      if (isTodayCompleted(item) ||
          (itemDay != null && !settings.carryOverIncomplete)) {
        metadata['today'] = false;
      } else {
        metadata['today_day'] = day;
      }
      item.metadata = metadata;
      item.updatedAt = updatedAt;
      item.dirty = true;
      changed = true;
    }
    return changed;
  }

  void _scheduleDayRollover() {
    _dayRolloverTimer?.cancel();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day + 1);
    _dayRolloverTimer = Timer(next.difference(now), () async {
      if (_rolloverTodayItems()) await _changed(forceSync: true);
      _scheduleDayRollover();
    });
  }

  Future<bool> prepareForSignOut() async {
    busy = true;
    notifyListeners();
    final pendingSync = _syncDone?.future;
    if (pendingSync != null) {
      await pendingSync.timeout(const Duration(seconds: 15), onTimeout: () {});
    }
    if (!await _cancelActiveDownloadsForSignOut()) {
      busy = false;
      message = '진행 중인 다운로드를 정리하지 못해 로그아웃을 중단했습니다.';
      notifyListeners();
      return false;
    }
    if (_hasUnsyncedChanges) await sync();
    if (_hasUnsyncedChanges) {
      busy = false;
      message = '동기화하지 못한 변경이 있어 로그아웃을 중단했습니다. 연결을 확인해 주세요.';
      notifyListeners();
      return false;
    }
    _signingOut = true;
    await _clearTodayNotification();
    await _cancelAllReminders();
    return true;
  }

  Future<bool> _cancelActiveDownloadsForSignOut() async {
    final userId = user?.id;
    if (userId == null) return true;
    _downloadAttempts.clear();
    var changed = false;
    for (final entry in downloads.where(
      (value) =>
          value.deviceOwned &&
          {'queued', 'running', 'paused'}.contains(value.state),
    )) {
      final nativeId = entry.nativeId;
      if (nativeId != null) {
        try {
          await _platform.cancelDownload(nativeId);
        } catch (_) {
          if (changed) await _save(userId);
          return false;
        }
      }
      final backendJobId = entry.backendJobId;
      if (backendJobId != null) {
        if (entry.nativeBackendTransferOwned) {
          try {
            if (!await _platform.cancelBackendTransfer(backendJobId)) {
              if (changed) await _save(userId);
              return false;
            }
          } catch (_) {
            if (changed) await _save(userId);
            return false;
          }
        }
        try {
          await _downloadBackend.cancelJob(backendJobId);
        } catch (_) {
          if (changed) await _save(userId);
          return false;
        }
      }
      entry.nativeId = null;
      entry.backendJobId = null;
      entry.nativeBackendTransferOwned = false;
      entry.backendStage = null;
      entry.state = 'canceled';
      entry.error = null;
      entry.updatedAt = DateTime.now().toUtc();
      entry.dirty = true;
      changed = true;
    }
    if (changed) await _save(userId);
    return true;
  }

  bool get _hasUnsyncedChanges =>
      _preferencesDirty ||
      folders.any((value) => value.dirty || value.deleted) ||
      items.any((value) => value.dirty || value.deleted) ||
      attachments.any(
        (value) => value.uploadState != AttachmentUploadState.uploaded,
      ) ||
      downloads.any((value) => value.dirty);

  void finishSignOut() {
    _signingOut = false;
    busy = false;
    notifyListeners();
  }

  Future<void> _cancelReminderIds(Iterable<String> ids) async {
    for (final id in ids.toSet()) {
      try {
        await _platform.cancelReminder(id: nativeReminderId(id), key: id);
      } catch (_) {}
    }
  }

  Future<void> _cancelAllReminders() => _cancelReminderIds(
    items.where((value) => value.kind == 'reminder').map((value) => value.id),
  );

  Future<void> _clearTodayNotification() async {
    try {
      await _platform.clearTodayNotification();
    } catch (_) {}
  }

  Future<void> _syncTodayNotification() async {
    final userId = user?.id;
    if (!_accessEnabled || userId == null || !notificationsEnabled) {
      await _clearTodayNotification();
      return;
    }
    String bounded(String value) =>
        value.length <= 500 ? value : value.substring(0, 500);
    try {
      final posted = await _platform.setTodayTasks(
        userId: userId,
        tasks: allTodayItems
            .take(50)
            .map(
              (item) => {
                'id': item.id,
                'text': bounded(item.note.isNotEmpty ? item.note : item.title),
                'completed': isTodayCompleted(item),
                'dayKey':
                    item.metadata['today_day'] as String? ??
                    todayDayKey(DateTime.now()),
              },
            )
            .toList(),
        maxVisible: settings.todayNotificationLimit,
        showCompleted: settings.showCompletedToday,
        carryOverIncomplete: settings.carryOverIncomplete,
        lockPolicy: settings.lockScreenPolicy,
        overlayEnabled: settings.overlayEnabled,
      );
      if (allTodayItems.isNotEmpty && !posted) {
        message ??= '시스템 설정에서 오늘 할 일 알림을 허용해 주세요.';
      }
    } catch (_) {}
  }

  Future<void> _applyTodayActions(String userId) async {
    List<Map<String, dynamic>> actions;
    try {
      actions = await _platform.readTodayActions(userId);
    } catch (_) {
      return;
    }
    if (actions.isEmpty || user?.id != userId) return;
    final actionIds = <String>[];
    var changed = false;
    final uuidPattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    for (final action in actions) {
      final actionId = action['id'] as String?;
      final itemId = action['itemId'] as String?;
      final type = action['type'] as String?;
      final text = (action['text'] as String?)?.trim();
      if (actionId == null || !uuidPattern.hasMatch(actionId)) continue;
      actionIds.add(actionId);
      if (itemId == null || !uuidPattern.hasMatch(itemId)) continue;
      final createdAt = (action['createdAt'] as num?)?.toInt();
      final at = createdAt == null
          ? DateTime.now().toUtc()
          : DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true);
      if (type == 'add' &&
          text != null &&
          text.isNotEmpty &&
          text.length <= 500 &&
          !items.any((item) => item.id == itemId)) {
        items.add(
          MoritItem(
            id: itemId,
            userId: userId,
            kind: 'memo',
            title: text,
            note: '',
            metadata: {
              'today': true,
              'today_day': todayDayKey(at),
              'today_position': allTodayItems.length,
            },
            createdAt: at,
            updatedAt: at,
          ),
        );
        changed = true;
        continue;
      }
      final item = items
          .where(
            (value) =>
                value.id == itemId &&
                value.userId == userId &&
                isTodayItem(value),
          )
          .firstOrNull;
      if (item == null) continue;
      if (type == 'edit' &&
          text != null &&
          text.isNotEmpty &&
          text.length <= 500) {
        if (item.note.isNotEmpty) {
          item.note = text;
        } else {
          item.title = text;
        }
      } else if (type == 'complete') {
        item.metadata = {
          ...item.metadata,
          'today': true,
          'today_day': todayDayKey(at),
          'completed_at': at.toIso8601String(),
        };
      } else if (type == 'uncomplete') {
        item.metadata = Map<String, dynamic>.from(item.metadata)
          ..remove('completed_at');
      } else if (type == 'rollover' &&
          text != null &&
          RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
        item.metadata = {...item.metadata, 'today': true, 'today_day': text};
      } else if (type == 'expire') {
        item.metadata = {...item.metadata, 'today': false};
      } else {
        continue;
      }
      item.updatedAt = at;
      item.dirty = true;
      changed = true;
    }
    if (changed) await _save(userId);
    if (actionIds.isNotEmpty) {
      try {
        await _platform.ackTodayActions(userId, actionIds);
      } catch (_) {}
    }
  }

  Future<void> _scheduleFutureReminders() async {
    final userId = user?.id;
    if (!_accessEnabled || userId == null) return;
    final reminders = List<MoritItem>.from(
      items.where(
        (value) =>
            value.userId == userId &&
            value.kind == 'reminder' &&
            !value.deleted,
      ),
    );
    if (!notificationsEnabled) {
      await _cancelReminderIds(reminders.map((value) => value.id));
      return;
    }
    final now = DateTime.now();
    for (final item in reminders) {
      if (!_accessEnabled || user?.id != userId) return;
      final at = DateTime.tryParse(
        item.metadata['scheduled_at'] as String? ?? '',
      );
      if (at != null && at.isAfter(now)) {
        await _scheduleReminder(item);
      } else {
        await _cancelReminderIds([item.id]);
      }
    }
  }

  Future<void> load() async {
    final currentUser = user;
    if (!_accessEnabled || currentUser == null || busy) return;
    final userId = currentUser.id;
    final accessRevision = _accessRevision;
    bool active() =>
        _accessEnabled &&
        _accessRevision == accessRevision &&
        user?.id == userId;
    final isShareRoute =
        WidgetsBinding.instance.platformDispatcher.defaultRouteName == '/share';
    busy = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (!active()) return;
      folders = _decodeList(
        prefs.getString(_key('folders', userId)),
        Folder.fromJson,
      );
      items = _decodeList(
        prefs.getString(_key('items', userId)),
        MoritItem.fromJson,
      );
      downloads = _decodeList(
        prefs.getString(_key('downloads', userId)),
        DownloadEntry.fromJson,
      );
      attachments = _decodeList(
        prefs.getString(_key('attachments', userId)),
        MoritAttachment.fromLocal,
      );
      _normalizeDetachedDownloads();
      _normalizeLegacyMediaSources();
      _normalizeLocalFileItems(userId);
      downloadMode = 'direct';
      notificationsEnabled =
          prefs.getBool(_key('notifications', userId)) ?? true;
      autoSync = prefs.getBool(_key('auto_sync', userId)) ?? true;
      settings = MoritSettings.fromJson(
        _decodeMap(prefs.getString(_key('settings', userId))),
      );
      _preferencesDirty =
          prefs.getBool(_key('preferences_dirty', userId)) ?? false;
      if (settings.lockScreenPolicy == 'morit_pin' &&
          !await _pinStore.hasPin(userId)) {
        settings.lockScreenPolicy = 'device_unlock';
        _preferencesDirty = true;
      }
      final handoffKeys = isShareRoute
          ? const <String>[]
          : _mergeHandoffs(prefs, userId);
      if (handoffKeys.isNotEmpty) _normalizeLocalFileItems(userId);
      _loadedUserId = userId;
      _scheduleDayRollover();
      if (handoffKeys.isNotEmpty) {
        await _save(userId);
        if (!active()) return;
        await Future.wait(handoffKeys.map(prefs.remove));
      }
      if (!isShareRoute) {
        await _applyTodayActions(userId);
        _rolloverTodayItems();
      }
      if (!isShareRoute && autoSync) await sync();
      if (!isShareRoute) await _scheduleFutureReminders();
      if (!isShareRoute && active() && visibleFolders.isEmpty) {
        final now = DateTime.now().toUtc();
        folders.add(
          Folder(
            id: _uuid.v4(),
            userId: currentUser.id,
            name: '받은 항목',
            color: 0xFF167C6A,
            createdAt: now,
            updatedAt: now,
          ),
        );
        await _save(userId);
        if (autoSync) await sync();
      }
      if (!isShareRoute) await _syncTodayNotification();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  List<T> _decodeList<T>(
    String? source,
    T Function(Map<String, dynamic>) convert,
  ) {
    if (source == null) return [];
    try {
      return (jsonDecode(source) as List)
          .map((value) => convert(Map<String, dynamic>.from(value as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Map<String, dynamic>? _decodeMap(String? source) {
    if (source == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(source) as Map);
    } catch (_) {
      return null;
    }
  }

  void _applyRemoteSettings(Map<String, dynamic>? value) {
    final lockPolicy = settings.lockScreenPolicy;
    final overlayEnabled = settings.overlayEnabled;
    settings = MoritSettings.fromJson(value);
    settings.lockScreenPolicy = lockPolicy;
    settings.overlayEnabled = overlayEnabled;
  }

  String _key(String suffix, String userId) => 'morit_${userId}_$suffix';

  List<T> _mergeCached<T>(
    List<T> memory,
    List<T> disk,
    String Function(T value) id,
    bool Function(T value) dirty,
    DateTime Function(T value) updatedAt,
  ) {
    final merged = {for (final value in memory) id(value): value};
    for (final value in disk) {
      final current = merged[id(value)];
      if (current == null ||
          (!dirty(current) &&
              (dirty(value) || updatedAt(value).isAfter(updatedAt(current))))) {
        merged[id(value)] = value;
      }
    }
    return merged.values.toList();
  }

  void _normalizeDetachedDownloads() {
    final now = DateTime.now().toUtc();
    for (final entry in downloads.where(
      (value) =>
          value.deviceOwned &&
          value.nativeId == null &&
          value.backendJobId == null &&
          {'queued', 'running'}.contains(value.state),
    )) {
      entry.state = 'failed';
      entry.error = '이 기기의 다운로드 작업 정보가 없어 다시 시도해야 합니다.';
      entry.updatedAt = now;
      entry.dirty = true;
    }
  }

  void _normalizeLegacyMediaSources() {
    final now = DateTime.now().toUtc();
    final sourceByItemId = <String, String>{};
    for (final item in items) {
      final raw = item.metadata['source_page_url'];
      final provider = item.metadata['media_provider'];
      final metadataUri = provider is String && raw is String
          ? Uri.tryParse(raw)
          : null;
      final itemUri = Uri.tryParse(item.sourceUrl ?? '');
      final uri =
          metadataUri != null &&
              metadataUri.scheme == 'https' &&
              metadataUri.host.isNotEmpty &&
              metadataUri.userInfo.isEmpty
          ? metadataUri
          : itemUri;
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        continue;
      }
      final source = uri.toString();
      sourceByItemId[item.id] = source;
      if (metadataUri == uri && item.sourceUrl != source) {
        item.sourceUrl = source;
        item.updatedAt = now;
        item.dirty = true;
      }
    }
    for (final entry in downloads) {
      final source = sourceByItemId[entry.itemId];
      if (source != null && entry.sourceUrl != source) {
        entry.sourceUrl = source;
        entry.updatedAt = now;
        entry.dirty = true;
      }
    }
  }

  void _normalizeLocalFileItems(String userId) {
    final now = DateTime.now().toUtc();
    for (final item in items.where(
      (value) =>
          value.userId == userId &&
          {'photo', 'video', 'file'}.contains(value.kind) &&
          value.localPath != null &&
          value.storagePath == null,
    )) {
      if (attachments.any((value) => value.itemId == item.id)) continue;
      final attachmentId = _uuid.v4();
      final path = item.localPath!;
      final fileName = normalizeAttachmentFileName(
        path.split(Platform.pathSeparator).last,
      );
      attachments.add(
        MoritAttachment(
          id: attachmentId,
          userId: userId,
          itemId: item.id,
          fileName: fileName,
          mimeType: item.mimeType ?? 'application/octet-stream',
          sizeBytes: item.sizeBytes,
          storagePath: attachmentStoragePath(
            userId: userId,
            itemId: item.id,
            attachmentId: attachmentId,
            fileName: fileName,
          ),
          uploadState: AttachmentUploadState.pending,
          attemptCount: 0,
          position: 0,
          createdAt: item.createdAt,
          updatedAt: now,
          localPath: path,
        ),
      );
      item.metadata = {...item.metadata, 'legacy_kind': item.kind};
      item.kind = 'memo';
      item.localPath = null;
      item.mimeType = null;
      item.sizeBytes = null;
      item.updatedAt = now;
      item.dirty = true;
    }
  }

  List<String> _mergeHandoffs(SharedPreferences prefs, String userId) {
    final prefix = '${_key('handoff', userId)}_';
    final keys = prefs.getKeys().where((value) => value.startsWith(prefix));
    final handoffs = <MoritItem>[];
    final handoffAttachments = <MoritAttachment>[];
    final validKeys = <String>[];
    for (final key in keys) {
      try {
        final value = prefs.getString(key);
        if (value == null) continue;
        final decoded = Map<String, dynamic>.from(jsonDecode(value) as Map);
        final itemJson = decoded['item'] is Map
            ? Map<String, dynamic>.from(decoded['item'] as Map)
            : decoded;
        final item = MoritItem.fromJson(itemJson);
        if (item.userId != userId) continue;
        handoffs.add(item);
        if (decoded['attachments'] case final List<dynamic> values) {
          for (final raw in values.whereType<Map>()) {
            final attachment = MoritAttachment.fromLocal(
              Map<String, dynamic>.from(raw),
            );
            if (attachment.userId == userId &&
                attachment.itemId == item.id &&
                attachment.localPath != null &&
                attachment.storagePath.startsWith('$userId/${item.id}/')) {
              handoffAttachments.add(attachment);
            }
          }
        }
        validKeys.add(key);
      } catch (_) {}
    }
    items = _mergeCached(
      items,
      handoffs,
      (value) => value.id,
      (value) => value.dirty || value.deleted,
      (value) => value.updatedAt,
    );
    attachments = _mergeCached(
      attachments,
      handoffAttachments,
      (value) => value.id,
      (value) =>
          value.uploadState != AttachmentUploadState.uploaded ||
          value.localPath != null,
      (value) => value.updatedAt,
    );
    return validKeys;
  }

  Future<void> _saveHandoff(
    MoritItem item, [
    Iterable<MoritAttachment> itemAttachments = const [],
  ]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '${_key('handoff', item.userId)}_${item.id}',
      jsonEncode({
        'item': item.toJson(),
        'attachments': itemAttachments.map((value) => value.toLocal()).toList(),
      }),
    );
  }

  Future<void> _save([String? expectedUserId]) async {
    final userId = expectedUserId ?? user?.id;
    if (!_accessEnabled || userId == null || user?.id != userId) return;
    final folderJson = jsonEncode(
      folders.map((value) => value.toJson()).toList(),
    );
    final itemJson = jsonEncode(items.map((value) => value.toJson()).toList());
    final attachmentJson = jsonEncode(
      attachments.map((value) => value.toLocal()).toList(),
    );
    final downloadJson = jsonEncode(
      downloads.map((value) => value.toJson()).toList(),
    );
    final mode = downloadMode;
    final notifications = notificationsEnabled;
    final syncEnabled = autoSync;
    final settingsJson = jsonEncode(settings.toJson());
    final preferencesDirty = _preferencesDirty;
    _saveQueue = _saveQueue.catchError((Object _) {}).then((_) async {
      if (!_accessEnabled || user?.id != userId) return;
      final prefs = await SharedPreferences.getInstance();
      if (!_accessEnabled || user?.id != userId) return;
      await Future.wait([
        prefs.setString(_key('folders', userId), folderJson),
        prefs.setString(_key('items', userId), itemJson),
        prefs.setString(_key('attachments', userId), attachmentJson),
        prefs.setString(_key('downloads', userId), downloadJson),
        prefs.setString(_key('download_mode', userId), mode),
        prefs.setBool(_key('notifications', userId), notifications),
        prefs.setBool(_key('auto_sync', userId), syncEnabled),
        prefs.setString(_key('settings', userId), settingsJson),
        prefs.setBool(_key('preferences_dirty', userId), preferencesDirty),
      ]);
    });
    await _saveQueue;
  }

  Future<void> sync() async {
    final currentUser = user;
    if (!_accessEnabled || currentUser == null || _signingOut) return;
    if (syncing) {
      _syncAgain = true;
      return;
    }
    final userId = currentUser.id;
    bool active() => _accessEnabled && user?.id == userId;
    syncing = true;
    _syncAgain = false;
    final done = Completer<void>();
    _syncDone = done;
    notifyListeners();
    try {
      var attachmentFailures = 0;

      final dirtyFolders = folders
          .where((value) => value.dirty && !value.deleted)
          .toList();
      final folderVersions = {
        for (final value in dirtyFolders) value.id: value.updatedAt,
      };
      if (dirtyFolders.isNotEmpty) {
        await supabase
            .schema('morit')
            .from('folders')
            .upsert(dirtyFolders.map((value) => value.toRemote()).toList());
        if (!active()) return;
        for (final value in folders) {
          if (folderVersions[value.id] == value.updatedAt && !value.deleted) {
            value.dirty = false;
          }
        }
      }
      final dirtyItems = items
          .where((value) => value.dirty && !value.deleted)
          .toList();
      final itemVersions = {
        for (final value in dirtyItems) value.id: value.updatedAt,
      };
      if (dirtyItems.isNotEmpty) {
        await supabase
            .schema('morit')
            .from('items')
            .upsert(dirtyItems.map((value) => value.toRemote()).toList());
        if (!active()) return;
        final reminders = dirtyItems
            .where((value) => value.kind == 'reminder')
            .map((value) {
              return {
                'id': value.id,
                'user_id': userId,
                'item_id': value.id,
                'scheduled_at': value.metadata['scheduled_at'],
              };
            })
            .toList();
        if (reminders.isNotEmpty) {
          await supabase.schema('morit').from('reminders').upsert(reminders);
          if (!active()) return;
        }
        for (final value in items) {
          if (itemVersions[value.id] == value.updatedAt && !value.deleted) {
            value.dirty = false;
          }
        }
      }
      for (final deleting in List<MoritAttachment>.from(
        attachments.where(
          (value) => value.uploadState == AttachmentUploadState.deleting,
        ),
      )) {
        if (!active()) return;
        try {
          await _attachmentStore.delete(
            userId: userId,
            attachmentId: deleting.id,
          );
          if (!active()) return;
          if (deleting.localPath != null) {
            await _deleteOwnedLocalFiles([deleting.localPath!]);
          }
          attachments.removeWhere((value) => value.id == deleting.id);
          final item = items
              .where((value) => value.id == deleting.itemId)
              .firstOrNull;
          if (item != null && attachmentsForItem(item.id).isEmpty) {
            item.metadata = Map<String, dynamic>.from(item.metadata)
              ..remove('has_attachments');
            item.updatedAt = DateTime.now().toUtc();
            item.dirty = true;
            _syncAgain = true;
          }
        } on Object catch (error) {
          attachmentFailures++;
          message = '${deleting.fileName}: ${attachmentFailureReason(error)}';
        }
      }
      for (final pending in List<MoritAttachment>.from(
        attachments.where(shouldAutomaticallyUploadAttachment),
      )) {
        if (!active()) return;
        final file = File(pending.localPath!);
        _replaceAttachment(
          _copyAttachment(
            pending,
            state: AttachmentUploadState.uploading,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        attachmentProgress[pending.id] = 0;
        notifyListeners();
        try {
          final uploaded = await _attachmentStore.upload(
            userId: userId,
            itemId: pending.itemId,
            attachmentId: pending.id,
            file: file,
            fileName: pending.fileName,
            mimeType: pending.mimeType,
            position: pending.position,
            onProgress: (uploadedBytes, totalBytes) {
              if (!active() || totalBytes <= 0) return;
              attachmentProgress[pending.id] = uploadedBytes / totalBytes;
              notifyListeners();
            },
          );
          if (!active()) return;
          _replaceAttachment(
            _copyAttachment(
              uploaded,
              localPath: pending.localPath,
              state: AttachmentUploadState.uploaded,
            ),
          );
        } on Object catch (error) {
          if (!active()) return;
          attachmentFailures++;
          final reason = attachmentFailureReason(error);
          _replaceAttachment(
            _copyAttachment(
              pending,
              state: AttachmentUploadState.failed,
              lastError: reason,
              attemptCount: pending.attemptCount + 1,
              updatedAt: DateTime.now().toUtc(),
            ),
          );
          message = '${pending.fileName}: $reason';
        } finally {
          attachmentProgress.remove(pending.id);
          notifyListeners();
        }
      }
      final dirtyDownloads = downloads.where((value) => value.dirty).toList();
      final downloadVersions = {
        for (final value in dirtyDownloads) value.id: value.updatedAt,
      };
      if (dirtyDownloads.isNotEmpty) {
        await supabase
            .schema('morit')
            .from('downloads')
            .upsert(dirtyDownloads.map((value) => value.toRemote()).toList());
        if (!active()) return;
        for (final value in downloads) {
          if (downloadVersions[value.id] == value.updatedAt) {
            value.dirty = false;
          }
        }
      }
      for (final item in List<MoritItem>.from(
        items.where((value) => value.deleted),
      )) {
        final itemAttachments = attachments
            .where((value) => value.itemId == item.id)
            .toList();
        for (final attachment in itemAttachments) {
          await _attachmentStore.delete(
            userId: userId,
            attachmentId: attachment.id,
          );
          if (!active()) return;
          if (attachment.localPath != null) {
            await _deleteOwnedLocalFiles([attachment.localPath!]);
          }
          attachments.removeWhere((value) => value.id == attachment.id);
        }
        if (item.storagePath != null && itemAttachments.isEmpty) {
          await supabase.storage.from('morit-files').remove([
            item.storagePath!,
          ]);
          if (!active()) return;
        }
        await supabase.schema('morit').from('items').delete().eq('id', item.id);
        if (!active()) return;
        items.removeWhere((value) => value.id == item.id && value.deleted);
      }
      for (final folder in List<Folder>.from(
        folders.where((value) => value.deleted),
      )) {
        await supabase
            .schema('morit')
            .from('folders')
            .delete()
            .eq('id', folder.id);
        if (!active()) return;
        folders.removeWhere((value) => value.id == folder.id && value.deleted);
      }
      if (_preferencesDirty) {
        final mode = downloadMode;
        final notifications = notificationsEnabled;
        final syncEnabled = autoSync;
        final settingsValue = settings.toRemote();
        await supabase.schema('morit').from('preferences').upsert({
          'user_id': userId,
          'download_mode': mode,
          'notifications_enabled': notifications,
          'auto_sync': syncEnabled,
          'settings': settingsValue,
        });
        if (!active()) return;
        if (downloadMode == mode &&
            notificationsEnabled == notifications &&
            autoSync == syncEnabled &&
            jsonEncode(settings.toRemote()) == jsonEncode(settingsValue)) {
          _preferencesDirty = false;
        }
      } else {
        final preferences = await supabase
            .schema('morit')
            .from('preferences')
            .select()
            .eq('user_id', userId)
            .maybeSingle();
        if (!active()) return;
        if (_preferencesDirty) {
          _syncAgain = true;
        } else if (preferences == null) {
          await supabase.schema('morit').from('preferences').upsert({
            'user_id': userId,
            'download_mode': downloadMode,
            'notifications_enabled': notificationsEnabled,
            'auto_sync': autoSync,
            'settings': settings.toRemote(),
          });
          if (!active()) return;
        } else {
          downloadMode = 'direct';
          notificationsEnabled =
              preferences['notifications_enabled'] as bool? ?? true;
          autoSync = preferences['auto_sync'] as bool? ?? true;
          _applyRemoteSettings(
            Map<String, dynamic>.from(
              preferences['settings'] as Map? ?? const {},
            ),
          );
          _rolloverTodayItems();
        }
      }

      final localPaths = {for (final item in items) item.id: item.localPath};
      final localAttachmentPaths = {
        for (final value in attachments)
          if (value.localPath != null) value.id: value.localPath!,
      };
      final localAttachmentPathsByStorage = {
        for (final value in attachments)
          if (value.localPath != null) value.storagePath: value.localPath!,
        for (final value in items)
          if (value.storagePath != null && value.localPath != null)
            value.storagePath!: value.localPath!,
      };
      final localDownloads = {for (final value in downloads) value.id: value};
      final previousReminderIds = items
          .where((value) => value.kind == 'reminder')
          .map((value) => value.id)
          .toSet();
      final folderRows = await _fetchAllRows('folders', 'position', userId);
      final itemRows = await _fetchAllRows('items', 'updated_at', userId);
      final downloadRows = await _fetchAllRows(
        'downloads',
        'updated_at',
        userId,
      );
      List<MoritAttachment>? remoteAttachments;
      try {
        remoteAttachments = await _attachmentStore.listForUser(
          userId,
          localPathsByAttachmentId: localAttachmentPaths,
          localPathsByStoragePath: localAttachmentPathsByStorage,
        );
      } on Object catch (error) {
        attachmentFailures++;
        message = attachmentFailureReason(error);
      }
      if (!active()) return;
      final remoteFolders = folderRows
          .map(
            (value) => Folder.fromJson(
              Map<String, dynamic>.from(value as Map),
              remote: true,
            ),
          )
          .toList();
      final remoteItems = itemRows.map((value) {
        final item = MoritItem.fromJson(
          Map<String, dynamic>.from(value as Map),
          remote: true,
        );
        item.localPath = localPaths[item.id];
        return item;
      }).toList();
      final remoteDownloads = downloadRows.map((value) {
        final data = Map<String, dynamic>.from(value as Map);
        final entry = DownloadEntry.fromJson(data, remote: true);
        final local = localDownloads[entry.id];
        entry.nativeId = local?.nativeId;
        entry.localPath = local?.localPath;
        entry.saveLocation = local?.saveLocation;
        entry.fileName = local?.fileName;
        entry.mimeType = local?.mimeType;
        entry.description = local?.description;
        entry.wifiOnly = local?.wifiOnly ?? false;
        entry.deviceOwned = local?.deviceOwned ?? false;
        entry.backendJobId = local?.backendJobId;
        entry.nativeBackendTransferOwned =
            local?.nativeBackendTransferOwned ?? false;
        entry.backendStage = local?.backendStage;
        entry.backendEngine = local?.backendEngine;
        return entry;
      }).toList();
      final remoteItemIds = remoteItems.map((value) => value.id).toSet();
      final orphanPaths = items
          .where(
            (value) =>
                !value.dirty &&
                !value.deleted &&
                value.localPath != null &&
                !remoteItemIds.contains(value.id),
          )
          .map((value) => value.localPath!)
          .toList();
      var orphanAttachmentPaths = const <String>[];
      folders = _mergeRemote(
        folders,
        remoteFolders,
        (value) => value.id,
        (value) => value.dirty || value.deleted,
      );
      items = _mergeRemote(
        items,
        remoteItems,
        (value) => value.id,
        (value) => value.dirty || value.deleted,
      );
      if (remoteAttachments != null) {
        final remoteIds = remoteAttachments.map((value) => value.id).toSet();
        orphanAttachmentPaths = attachments
            .where(
              (value) =>
                  value.uploadState == AttachmentUploadState.uploaded &&
                  value.localPath != null &&
                  !remoteIds.contains(value.id),
            )
            .map((value) => value.localPath!)
            .toList();
        attachments = [
          ...remoteAttachments,
          ...attachments.where(
            (value) =>
                !remoteIds.contains(value.id) &&
                value.localPath != null &&
                value.uploadState != AttachmentUploadState.uploaded,
          ),
        ];
      }
      downloads = _mergeRemote(
        downloads,
        remoteDownloads,
        (value) => value.id,
        (value) => value.dirty,
      );
      _normalizeDetachedDownloads();
      _normalizeLegacyMediaSources();
      await _deleteOwnedLocalFiles([...orphanPaths, ...orphanAttachmentPaths]);
      final reminderIds = items
          .where((value) => value.kind == 'reminder' && !value.deleted)
          .map((value) => value.id)
          .toSet();
      await _cancelReminderIds(previousReminderIds.difference(reminderIds));
      await _scheduleFutureReminders();
      await _syncTodayNotification();
      if (attachmentFailures == 0) message = '동기화됨';
    } catch (_) {
      if (active()) message = '오프라인에 저장됨';
    } finally {
      try {
        if (active()) await _save(userId);
      } catch (_) {
        if (active()) message = '기기에 저장하지 못했습니다.';
      }
      final rerun = _syncAgain;
      _syncAgain = false;
      syncing = false;
      if (!done.isCompleted) done.complete();
      if (identical(_syncDone, done)) _syncDone = null;
      notifyListeners();
      if (rerun && user != null && !_signingOut) unawaited(sync());
    }
  }

  Future<List<Map<String, dynamic>>> _fetchAllRows(
    String table,
    String order,
    String userId,
  ) async {
    const pageSize = 500;
    final rows = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += pageSize) {
      final page = await supabase
          .schema('morit')
          .from(table)
          .select()
          .eq('user_id', userId)
          .order(order)
          .order('id')
          .range(offset, offset + pageSize - 1);
      if (user?.id != userId) throw StateError('account changed');
      final values = (page as List)
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
      rows.addAll(values);
      if (values.length < pageSize) break;
    }
    return rows;
  }

  Future<void> _deleteOwnedLocalFiles(Iterable<String> paths) async {
    if (paths.isEmpty) return;
    try {
      final value = await _platform.appFilesPath();
      if (value == null) return;
      final root = await Directory(value).resolveSymbolicLinks();
      final prefix = '$root${Platform.pathSeparator}';
      for (final path in paths.toSet()) {
        try {
          final file = File(path);
          if (!await file.exists()) continue;
          final resolved = await file.resolveSymbolicLinks();
          if (resolved.startsWith(prefix)) await file.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  List<T> _mergeRemote<T>(
    List<T> local,
    List<T> remote,
    String Function(T value) id,
    bool Function(T value) keepLocal,
  ) {
    final merged = {for (final value in remote) id(value): value};
    for (final value in local.where(keepLocal)) {
      merged[id(value)] = value;
    }
    return merged.values.toList();
  }

  MoritAttachment _copyAttachment(
    MoritAttachment value, {
    AttachmentUploadState? state,
    String? mimeType,
    String? lastError,
    String? localPath,
    int? attemptCount,
    DateTime? updatedAt,
  }) => MoritAttachment(
    id: value.id,
    userId: value.userId,
    itemId: value.itemId,
    fileName: value.fileName,
    mimeType: mimeType ?? value.mimeType,
    sizeBytes: value.sizeBytes,
    storagePath: value.storagePath,
    uploadState: state ?? value.uploadState,
    lastError: lastError,
    localPath: localPath ?? value.localPath,
    attemptCount: attemptCount ?? value.attemptCount,
    position: value.position,
    createdAt: value.createdAt,
    updatedAt: updatedAt ?? value.updatedAt,
  );

  void _replaceAttachment(MoritAttachment value) {
    final index = attachments.indexWhere((item) => item.id == value.id);
    if (index < 0) {
      attachments.add(value);
    } else {
      attachments[index] = value;
    }
  }

  Future<Folder?> saveFolder({
    Folder? folder,
    required String name,
    int? color,
    String? parentId,
    bool updateParent = false,
  }) async {
    final currentUser = user;
    final trimmed = name.trim();
    if (currentUser == null || trimmed.isEmpty || trimmed.length > 80) {
      return null;
    }
    if (parentId != null &&
        !folders.any(
          (value) =>
              value.id == parentId &&
              value.userId == currentUser.id &&
              !value.deleted,
        )) {
      return null;
    }
    final now = DateTime.now().toUtc();
    if (folder == null) {
      folder = Folder(
        id: _uuid.v4(),
        userId: currentUser.id,
        name: trimmed,
        color: color ?? 0xFF167C6A,
        parentId: parentId,
        position: childFolders(parentId).length,
        createdAt: now,
        updatedAt: now,
      );
      folders.add(folder);
    } else {
      folder = folders.where((value) => value.id == folder!.id).firstOrNull;
      if (folder == null) return null;
      final previousParentId = folder.parentId;
      folder.name = trimmed;
      folder.color = color ?? folder.color;
      if (updateParent && !canMoveFolder(folder, parentId)) return null;
      if (updateParent && folder.parentId != parentId) {
        folder.parentId = parentId;
        folder.position = childFolders(
          parentId,
        ).where((value) => value.id != folder!.id).length;
        _renumberFolders(previousParentId, now);
        _renumberFolders(parentId, now);
      }
      folder.updatedAt = now;
      folder.dirty = true;
    }
    await _changed();
    return folder;
  }

  Future<void> deleteFolder(Folder folder) async {
    final current = folders.where((value) => value.id == folder.id).firstOrNull;
    if (current == null) return;
    folder = current;
    folder.deleted = true;
    folder.dirty = true;
    folder.updatedAt = DateTime.now().toUtc();
    for (final child in folders.where(
      (value) => value.parentId == folder.id && !value.deleted,
    )) {
      child.parentId = folder.parentId;
      child.dirty = true;
      child.updatedAt = folder.updatedAt;
    }
    for (final item in items.where(
      (value) => value.folderId == folder.id && !value.deleted,
    )) {
      item.folderId = folder.parentId;
      item.dirty = true;
      item.updatedAt = folder.updatedAt;
    }
    _renumberFolders(folder.parentId, folder.updatedAt);
    await _changed();
  }

  Set<String> descendantFolderIds(String folderId) {
    final result = <String>{};
    final pending = <String>[folderId];
    while (pending.isNotEmpty) {
      final parent = pending.removeLast();
      for (final child in folders.where(
        (value) => !value.deleted && value.parentId == parent,
      )) {
        if (result.add(child.id)) pending.add(child.id);
      }
    }
    return result;
  }

  bool canMoveFolder(Folder folder, String? parentId) {
    if (folder.deleted || folder.userId != user?.id) return false;
    if (parentId == null) return true;
    if (parentId == folder.id ||
        descendantFolderIds(folder.id).contains(parentId)) {
      return false;
    }
    return folders.any(
      (value) =>
          value.id == parentId &&
          value.userId == folder.userId &&
          !value.deleted,
    );
  }

  Future<bool> moveFolder(Folder folder, String? parentId) async {
    final current = folders.where((value) => value.id == folder.id).firstOrNull;
    if (current == null || !canMoveFolder(current, parentId)) {
      message = '자기 자신이나 하위 폴더 안으로는 이동할 수 없습니다.';
      notifyListeners();
      return false;
    }
    if (current.parentId == parentId) return true;
    final previousParentId = current.parentId;
    current.parentId = parentId;
    current.position = childFolders(
      parentId,
    ).where((value) => value.id != current.id).length;
    current.updatedAt = DateTime.now().toUtc();
    current.dirty = true;
    _renumberFolders(previousParentId, current.updatedAt);
    _renumberFolders(parentId, current.updatedAt);
    await _changed();
    return true;
  }

  void _renumberFolders(String? parentId, DateTime at) {
    final siblings =
        folders
            .where((value) => !value.deleted && value.parentId == parentId)
            .toList()
          ..sort((a, b) {
            final position = a.position.compareTo(b.position);
            return position != 0 ? position : a.id.compareTo(b.id);
          });
    for (var index = 0; index < siblings.length; index++) {
      final sibling = siblings[index];
      if (sibling.position == index) continue;
      sibling.position = index;
      sibling.updatedAt = at;
      sibling.dirty = true;
    }
  }

  Future<bool> moveItemToFolder(MoritItem item, String? folderId) async {
    final current = items
        .where(
          (value) =>
              value.id == item.id && !value.deleted && value.userId == user?.id,
        )
        .firstOrNull;
    final validDestination =
        folderId == null ||
        folders.any(
          (folder) =>
              folder.id == folderId &&
              !folder.deleted &&
              folder.userId == current?.userId,
        );
    if (current == null || !validDestination) {
      message = '이동할 폴더를 찾을 수 없습니다.';
      notifyListeners();
      return false;
    }
    return updateItem(current, folderId: folderId, move: true);
  }

  Future<List<PlatformFile>> pickAttachmentFiles({
    FileType type = FileType.any,
    bool allowMultiple = true,
  }) async {
    try {
      final result = await FilePicker.pickFiles(
        type: type,
        allowMultiple: allowMultiple,
      );
      final picked = result?.files ?? const <PlatformFile>[];
      if (picked.length > 20) {
        message = '첨부 파일은 한 항목에 최대 20개까지 추가할 수 있습니다.';
        notifyListeners();
        return const [];
      }
      var total = 0;
      final seen = <String>{};
      final files = <PlatformFile>[];
      for (final file in picked) {
        if (file.path == null) {
          message = '기기에서 첨부 파일을 읽을 수 없습니다.';
          notifyListeners();
          return const [];
        }
        total += file.size;
        if (file.size > maxMoritAttachmentBytes ||
            total > maxMoritAttachmentBytes) {
          message = '첨부 파일의 총 크기는 500 MiB 이하여야 합니다.';
          notifyListeners();
          return const [];
        }
        final key = '${normalizeAttachmentFileName(file.name)}:${file.size}';
        if (seen.add(key)) files.add(file);
      }
      return files;
    } on PlatformException catch (error) {
      message = error.message ?? '파일을 가져오지 못했습니다.';
      notifyListeners();
      return const [];
    }
  }

  Future<List<MoritAttachment>?> _preparePickedAttachments(
    MoritItem item,
    List<PlatformFile> pickedFiles, {
    Iterable<MoritAttachment> existing = const [],
  }) async {
    if (pickedFiles.isEmpty) return const [];
    if (!supportsAttachments(item.kind)) {
      message = '메모와 알림에만 파일을 첨부할 수 있습니다.';
      notifyListeners();
      return null;
    }
    final currentUser = user;
    final existingList = existing.toList();
    if (currentUser == null ||
        item.userId != currentUser.id ||
        existingList.length + pickedFiles.length > 20) {
      message = '첨부 파일은 한 항목에 최대 20개까지 추가할 수 있습니다.';
      notifyListeners();
      return null;
    }
    final copiedPaths = <String>[];
    try {
      final root = await _platform.appFilesPath();
      if (root == null) {
        throw const FileSystemException('앱 저장 공간을 찾을 수 없습니다.');
      }
      final directory = Directory('$root/imports');
      await directory.create(recursive: true);
      final keys = {
        for (final value in existingList)
          '${value.fileName.toLowerCase()}:${value.sizeBytes}',
      };
      final prepared = <MoritAttachment>[];
      var total = 0;
      for (final picked in pickedFiles) {
        final sourcePath = picked.path;
        if (sourcePath == null) {
          throw const FileSystemException('첨부 파일을 읽을 수 없습니다.');
        }
        final source = File(sourcePath);
        final size = await source.length();
        total += size;
        if (size != picked.size ||
            size > maxMoritAttachmentBytes ||
            total > maxMoritAttachmentBytes) {
          throw const FileSystemException('첨부 파일의 크기가 올바르지 않습니다.');
        }
        final fileName = normalizeAttachmentFileName(picked.name);
        if (!keys.add('${fileName.toLowerCase()}:$size')) continue;
        final attachmentId = _uuid.v4();
        final target =
            '${directory.path}/${attachmentId}_${safeFileName(fileName)}';
        await source.copy(target);
        copiedPaths.add(target);
        final now = DateTime.now().toUtc();
        prepared.add(
          MoritAttachment(
            id: attachmentId,
            userId: currentUser.id,
            itemId: item.id,
            fileName: fileName,
            mimeType: _mimeFor(picked.extension),
            sizeBytes: size,
            storagePath: attachmentStoragePath(
              userId: currentUser.id,
              itemId: item.id,
              attachmentId: attachmentId,
              fileName: fileName,
            ),
            uploadState: AttachmentUploadState.pending,
            attemptCount: 0,
            position: existingList.length + prepared.length,
            createdAt: now,
            updatedAt: now,
            localPath: target,
          ),
        );
      }
      return prepared;
    } on Object catch (error) {
      await _deleteOwnedLocalFiles(copiedPaths);
      message = error is FileSystemException
          ? error.message
          : '첨부 파일을 복사하지 못했습니다. 저장 공간을 확인해 주세요.';
      notifyListeners();
      return null;
    }
  }

  Future<MoritItem?> addItem({
    required String kind,
    required String title,
    String note = '',
    String? folderId,
    String? sourceUrl,
    String? localPath,
    String? mimeType,
    int? sizeBytes,
    Map<String, dynamic>? metadata,
    List<PlatformFile> pickedFiles = const [],
  }) async {
    final currentUser = user;
    if (currentUser == null ||
        (title.trim().isEmpty &&
            note.trim().isEmpty &&
            sourceUrl == null &&
            localPath == null &&
            pickedFiles.isEmpty)) {
      return null;
    }
    final now = DateTime.now().toUtc();
    final item = MoritItem(
      id: _uuid.v4(),
      userId: currentUser.id,
      kind: kind,
      title: title.trim().isEmpty ? _defaultItemTitle(kind) : title.trim(),
      note: note.trim(),
      folderId: folderId,
      sourceUrl: sourceUrl,
      localPath: localPath,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      metadata: metadata,
      createdAt: now,
      updatedAt: now,
    );
    final prepared = await _preparePickedAttachments(item, pickedFiles);
    if (prepared == null) return null;
    if (prepared.isNotEmpty) {
      item.metadata = {...item.metadata, 'has_attachments': true};
    }
    items.add(item);
    attachments.addAll(prepared);
    final isShareRoute =
        WidgetsBinding.instance.platformDispatcher.defaultRouteName == '/share';
    if (isShareRoute) {
      await _saveHandoff(item, prepared);
      notifyListeners();
    } else {
      await _changed(forceSync: prepared.isNotEmpty || isTodayItem(item));
    }
    if (!isShareRoute && kind == 'reminder') {
      await _scheduleReminder(item);
    }
    return item;
  }

  Future<MoritItem?> addSharedAttachments({
    required String title,
    required String note,
    required List<SharedAttachmentInput> files,
    String? folderId,
  }) async {
    final currentUser = user;
    if (currentUser == null || files.isEmpty || files.length > 20) return null;
    final appFiles = await _platform.appFilesPath();
    if (appFiles == null) {
      throw const FileSystemException('앱 저장 공간을 찾을 수 없습니다.');
    }
    final root = await Directory(appFiles).resolveSymbolicLinks();
    final prefix = '$root${Platform.pathSeparator}';
    final resolvedFiles =
        <({File file, String fileName, String mimeType, int sizeBytes})>[];
    var totalBytes = 0;
    for (final input in files) {
      final file = File(input.path);
      if (!await file.exists()) {
        throw const FileSystemException('공유 파일을 찾을 수 없습니다.');
      }
      final resolved = await file.resolveSymbolicLinks();
      if (!resolved.startsWith(prefix)) {
        throw const FileSystemException('앱 소유 경로가 아닌 파일입니다.');
      }
      final size = await file.length();
      if (size != input.sizeBytes || size > maxMoritAttachmentBytes) {
        throw const FileSystemException('공유 파일 크기가 올바르지 않습니다.');
      }
      totalBytes += size;
      if (totalBytes > maxMoritAttachmentBytes) {
        throw const FileSystemException('공유 파일의 총 크기가 500 MiB를 초과합니다.');
      }
      final fileName = normalizeAttachmentFileName(input.fileName);
      final extension = fileName.contains('.')
          ? fileName.split('.').last
          : null;
      final suppliedMime = input.mimeType?.trim().toLowerCase();
      final mime =
          suppliedMime != null &&
              RegExp(
                r'^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$',
              ).hasMatch(suppliedMime)
          ? suppliedMime
          : _mimeFor(extension);
      resolvedFiles.add((
        file: file,
        fileName: fileName,
        mimeType: mime,
        sizeBytes: size,
      ));
    }
    final now = DateTime.now().toUtc();
    final item = MoritItem(
      id: _uuid.v4(),
      userId: currentUser.id,
      kind: 'memo',
      title: title.trim().isEmpty ? '첨부 메모' : title.trim(),
      note: note.trim(),
      folderId: folderId,
      metadata: const {'has_attachments': true},
      createdAt: now,
      updatedAt: now,
    );
    final createdAttachments = <MoritAttachment>[];
    for (var index = 0; index < resolvedFiles.length; index++) {
      final input = resolvedFiles[index];
      final attachmentId = _uuid.v4();
      createdAttachments.add(
        MoritAttachment(
          id: attachmentId,
          userId: currentUser.id,
          itemId: item.id,
          fileName: input.fileName,
          mimeType: input.mimeType,
          sizeBytes: input.sizeBytes,
          storagePath: attachmentStoragePath(
            userId: currentUser.id,
            itemId: item.id,
            attachmentId: attachmentId,
            fileName: input.fileName,
          ),
          uploadState: AttachmentUploadState.pending,
          attemptCount: 0,
          position: index,
          createdAt: now,
          updatedAt: now,
          localPath: input.file.path,
        ),
      );
    }
    items.add(item);
    attachments.addAll(createdAttachments);
    final isShareRoute =
        WidgetsBinding.instance.platformDispatcher.defaultRouteName == '/share';
    if (isShareRoute) {
      await _saveHandoff(item, createdAttachments);
      notifyListeners();
    } else {
      await _changed(forceSync: true);
    }
    return item;
  }

  Future<MoritAttachment?> attachFile(MoritItem item, FileType type) async {
    if (!supportsAttachments(item.kind)) return null;
    final existingIds = attachmentsForItem(
      item.id,
    ).map((value) => value.id).toSet();
    final files = await pickAttachmentFiles(type: type, allowMultiple: false);
    if (files.isEmpty) return null;
    if (!await updateItem(item, pickedFiles: files)) return null;
    return attachmentsForItem(
      item.id,
    ).where((value) => !existingIds.contains(value.id)).firstOrNull;
  }

  String _mimeFor(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'avif':
        return 'image/avif';
      case 'mp4':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mov':
        return 'video/quicktime';
      case 'ogv':
        return 'video/ogg';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'flac':
        return 'audio/flac';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }

  Future<bool> updateItem(
    MoritItem item, {
    String? title,
    String? note,
    String? folderId,
    bool move = false,
    bool? favorite,
    String? sourceUrl,
    Map<String, dynamic>? metadata,
    List<PlatformFile> pickedFiles = const [],
    Set<String> removedAttachmentIds = const {},
  }) async {
    final current = items.where((value) => value.id == item.id).firstOrNull;
    if (current == null || current.deleted) return false;
    item = current;
    final currentAttachments = attachmentsForItem(item.id);
    final ownedIds = currentAttachments.map((value) => value.id).toSet();
    if (!ownedIds.containsAll(removedAttachmentIds)) {
      message = '삭제할 첨부 파일 정보를 다시 확인해 주세요.';
      notifyListeners();
      return false;
    }
    final kept = currentAttachments
        .where((value) => !removedAttachmentIds.contains(value.id))
        .toList();
    final prepared = await _preparePickedAttachments(
      item,
      pickedFiles,
      existing: kept,
    );
    if (prepared == null) return false;
    if (title != null) item.title = title.trim();
    if (note != null) item.note = note.trim();
    if (move) item.folderId = folderId;
    if (favorite != null) item.favorite = favorite;
    if (sourceUrl != null) item.sourceUrl = sourceUrl;
    final nextMetadata = Map<String, dynamic>.from(metadata ?? item.metadata);
    if (kept.isNotEmpty || prepared.isNotEmpty) {
      nextMetadata['has_attachments'] = true;
    } else {
      nextMetadata.remove('has_attachments');
    }
    item.metadata = nextMetadata;
    final localDeletes = <String>[];
    for (final attachment in currentAttachments.where(
      (value) => removedAttachmentIds.contains(value.id),
    )) {
      if (attachment.uploadState == AttachmentUploadState.pending &&
          attachment.attemptCount == 0) {
        attachments.removeWhere((value) => value.id == attachment.id);
        if (attachment.localPath != null) {
          localDeletes.add(attachment.localPath!);
        }
      } else {
        _replaceAttachment(
          _copyAttachment(
            attachment,
            state: AttachmentUploadState.deleting,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
      }
    }
    attachments.addAll(prepared);
    item.updatedAt = DateTime.now().toUtc();
    item.dirty = true;
    await _deleteOwnedLocalFiles(localDeletes);
    await _changed(
      forceSync:
          isTodayItem(item) ||
          pickedFiles.isNotEmpty ||
          removedAttachmentIds.isNotEmpty,
    );
    if (item.kind == 'reminder') {
      await _cancelReminderIds([item.id]);
      await _scheduleReminder(item);
    }
    return true;
  }

  Future<void> setToday(MoritItem item, bool enabled) async {
    final current = items.where((value) => value.id == item.id).firstOrNull;
    if (current == null || current.deleted || current.kind != 'memo') return;
    if (enabled) {
      try {
        notificationsEnabled = await _platform.requestNotificationPermission();
      } catch (_) {
        notificationsEnabled = false;
      }
      _preferencesDirty = true;
      if (!notificationsEnabled) {
        message = '오늘 할 일은 저장했지만 알림 권한이 꺼져 있습니다.';
      }
    }
    final metadata = Map<String, dynamic>.from(current.metadata);
    if (enabled) {
      metadata['today'] = true;
      metadata.remove('completed_at');
      metadata['today_day'] = todayDayKey(DateTime.now());
      metadata['today_position'] = allTodayItems.length;
    } else {
      metadata.remove('today');
      metadata.remove('completed_at');
      metadata.remove('today_day');
      metadata.remove('today_position');
    }
    current.metadata = metadata;
    current.updatedAt = DateTime.now().toUtc();
    current.dirty = true;
    await _changed(forceSync: true);
  }

  Future<MoritItem?> addToday(
    String text, {
    List<PlatformFile> pickedFiles = const [],
  }) async {
    final currentUser = user;
    final value = text.trim();
    if (currentUser == null || value.isEmpty || value.length > 500) return null;
    try {
      notificationsEnabled = await _platform.requestNotificationPermission();
    } catch (_) {
      notificationsEnabled = false;
    }
    _preferencesDirty = true;
    if (!notificationsEnabled) {
      message = '할 일은 저장했지만 알림 권한이 꺼져 있습니다.';
    }
    final item = await addItem(
      kind: 'memo',
      title: value,
      pickedFiles: pickedFiles,
      metadata: {
        'today': true,
        'today_day': todayDayKey(DateTime.now()),
        'today_position': allTodayItems.length,
      },
    );
    return item;
  }

  Future<bool> updateTodayText(
    MoritItem item,
    String text, {
    List<PlatformFile> pickedFiles = const [],
    Set<String> removedAttachmentIds = const {},
  }) async {
    final current = items.where((value) => value.id == item.id).firstOrNull;
    final value = text.trim();
    if (current == null ||
        !isTodayItem(current) ||
        value.isEmpty ||
        value.length > 500) {
      return false;
    }
    return updateItem(
      current,
      title: current.note.isEmpty ? value : null,
      note: current.note.isNotEmpty ? value : null,
      pickedFiles: pickedFiles,
      removedAttachmentIds: removedAttachmentIds,
    );
  }

  Future<void> completeToday(MoritItem item) async {
    final current = items.where((value) => value.id == item.id).firstOrNull;
    if (current == null || !isTodayItem(current)) return;
    final now = DateTime.now().toUtc();
    current.metadata = {
      ...current.metadata,
      'today': true,
      'today_day': todayDayKey(now),
      'completed_at': now.toIso8601String(),
    };
    current.updatedAt = now;
    current.dirty = true;
    await _changed(forceSync: true);
  }

  Future<void> setTodayCompleted(MoritItem item, bool completed) async {
    final current = items.where((value) => value.id == item.id).firstOrNull;
    if (current == null || !isTodayItem(current)) return;
    if (completed) return completeToday(current);
    current.metadata = Map<String, dynamic>.from(current.metadata)
      ..remove('completed_at');
    current.updatedAt = DateTime.now().toUtc();
    current.dirty = true;
    await _changed(forceSync: true);
  }

  Future<void> reorderToday(int oldIndex, int newIndex) async {
    final ordered = todayItems;
    if (oldIndex < 0 || oldIndex >= ordered.length) return;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex < 0 || newIndex >= ordered.length) return;
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex, moved);
    final visibleIds = ordered.map((item) => item.id).toSet();
    ordered.addAll(
      allTodayItems.where((item) => !visibleIds.contains(item.id)),
    );
    if (settings.todaySort != 'manual') {
      settings.todaySort = 'manual';
      _preferencesDirty = true;
    }
    final now = DateTime.now().toUtc();
    for (var index = 0; index < ordered.length; index++) {
      final item = ordered[index];
      if (item.metadata['today_position'] == index) continue;
      item.metadata = {...item.metadata, 'today_position': index};
      item.updatedAt = now;
      item.dirty = true;
    }
    await _changed(forceSync: true);
  }

  Future<void> deleteItem(MoritItem item) async {
    final current = items.where((value) => value.id == item.id).firstOrNull;
    if (current == null || current.deleted) return;
    item = current;
    item.deleted = true;
    item.dirty = true;
    item.updatedAt = DateTime.now().toUtc();
    await _cancelReminderIds([item.id]);
    final localPaths = [
      item.localPath,
      ...attachmentsForItem(item.id).map((value) => value.localPath),
    ].whereType<String>().toList();
    if (localPaths.isNotEmpty) {
      await _deleteOwnedLocalFiles(localPaths);
      item.localPath = null;
    }
    await _changed(forceSync: isTodayItem(item));
  }

  Future<void> _scheduleReminder(MoritItem item) async {
    final itemId = item.id;
    final userId = item.userId;
    if (user?.id != userId ||
        !notificationsEnabled ||
        !items.any(
          (value) =>
              value.id == itemId && value.kind == 'reminder' && !value.deleted,
        )) {
      return;
    }
    try {
      final granted = await _platform.requestNotificationPermission();
      if (!granted) {
        notificationsEnabled = false;
        _preferencesDirty = true;
        message = '알림 권한을 허용하면 예약 알림을 받을 수 있어요.';
        await _save();
        notifyListeners();
        if (autoSync) unawaited(sync());
        return;
      }
      final current = items
          .where(
            (value) =>
                value.id == itemId &&
                value.userId == userId &&
                value.kind == 'reminder' &&
                !value.deleted,
          )
          .firstOrNull;
      final at = DateTime.tryParse(
        current?.metadata['scheduled_at'] as String? ?? '',
      );
      if (current == null ||
          user?.id != userId ||
          at == null ||
          !at.isAfter(DateTime.now())) {
        return;
      }
      final result = await _platform.scheduleReminder(
        id: nativeReminderId(current.id),
        key: current.id,
        title: current.title,
        body: current.note,
        atMillis: at.millisecondsSinceEpoch,
      );
      final stillCurrent =
          user?.id == userId &&
          items.any(
            (value) =>
                value.id == itemId &&
                value.kind == 'reminder' &&
                !value.deleted,
          );
      if (!stillCurrent) {
        await _cancelReminderIds([itemId]);
        return;
      }
      if (result?['scheduled'] != true) {
        message = '시스템 설정에서 Morit 알림을 허용해 주세요.';
        notifyListeners();
      }
    } on PlatformException catch (error) {
      message = error.message ?? '알림 권한을 확인해 주세요.';
      notifyListeners();
    }
  }

  Future<MediaAnalysis?> analyzeMediaUrl(Uri uri) async {
    return (await analyzeMediaUrlDetailed(uri))?.analysis;
  }

  Future<MediaAnalysisResult?> analyzeMediaUrlDetailed(Uri uri) async {
    if (!_accessEnabled ||
        user == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty) {
      return null;
    }
    final injectedAnalyzer = _mediaAnalyzer;
    return injectedAnalyzer != null
        ? injectedAnalyzer.analyzeDetailed(uri)
        : _downloadBackend.analyzeDetailed(uri);
  }

  Future<MediaAnalysis?> analyzeItemMedia(MoritItem item) async {
    final currentUser = user;
    final uri = Uri.tryParse(item.sourceUrl ?? '');
    if (!_accessEnabled ||
        currentUser == null ||
        item.userId != currentUser.id ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty) {
      message = '다운로드 가능한 웹 주소가 없습니다.';
      notifyListeners();
      return null;
    }
    message = '저장 가능한 미디어를 분석하고 있습니다.';
    notifyListeners();
    final result = await analyzeMediaUrlDetailed(uri);
    final analysis = result?.analysis;
    if (analysis == null || analysis.candidates.isEmpty) {
      message = result?.failure?.message ?? '페이지가 공개한 다운로드 가능한 미디어를 찾지 못했습니다.';
      notifyListeners();
      return null;
    }
    message = null;
    notifyListeners();
    return analysis;
  }

  Future<void> downloadCandidate(
    MoritItem item,
    MediaCandidate candidate,
  ) async {
    final currentUser = user;
    final source = Uri.tryParse(item.sourceUrl ?? '');
    if (!_accessEnabled ||
        currentUser == null ||
        item.userId != currentUser.id ||
        source == null) {
      return;
    }
    await _enqueueDownloadCandidate(
      sourceUrl: source,
      title: item.title,
      description: item.note,
      itemId: item.id,
      candidate: candidate,
    );
  }

  Future<void> downloadCandidateFromSource({
    required Uri sourceUrl,
    required String title,
    String description = '',
    required MediaCandidate candidate,
  }) => _enqueueDownloadCandidate(
    sourceUrl: sourceUrl,
    title: title,
    description: description,
    candidate: candidate,
  );

  Future<void> _enqueueDownloadCandidate({
    required Uri sourceUrl,
    required String title,
    required MediaCandidate candidate,
    String description = '',
    String? itemId,
  }) async {
    final currentUser = user;
    if (!_accessEnabled ||
        currentUser == null ||
        sourceUrl.scheme != 'https' ||
        sourceUrl.host.isEmpty ||
        sourceUrl.userInfo.isNotEmpty ||
        candidate.url.scheme != 'https' ||
        candidate.url.host.isEmpty ||
        candidate.url.userInfo.isNotEmpty) {
      return;
    }
    if (notificationsEnabled) {
      try {
        final granted = await _requestDownloadNotificationPermission();
        if (!granted) {
          notificationsEnabled = false;
          _preferencesDirty = true;
          message = '다운로드는 시작하지만 알림 권한이 없어 진행 알림은 표시되지 않습니다.';
        }
      } catch (_) {
        notificationsEnabled = false;
        _preferencesDirty = true;
        message = '다운로드는 시작하지만 진행 알림 상태를 확인하지 못했습니다.';
      }
    }
    final userId = currentUser.id;
    final now = DateTime.now().toUtc();
    final entry = DownloadEntry(
      id: _uuid.v4(),
      userId: userId,
      itemId: itemId,
      sourceUrl: sourceUrl.removeFragment().toString(),
      title: title.trim().isEmpty ? candidate.fileName : title.trim(),
      mode: candidate.isBackendSelection ? 'proxy' : 'direct',
      quality: candidate.qualityLabel ?? 'original',
      fileName: candidate.fileName,
      mimeType: candidate.mimeType,
      description: description.trim(),
      backendAssetId: candidate.assetId,
      createdAt: now,
      updatedAt: now,
    );
    downloads.insert(0, entry);
    await _startDownload(entry, candidate);
  }

  Future<bool> _requestDownloadNotificationPermission() {
    final pending = _notificationPermissionRequest;
    if (pending != null) return pending;
    late final Future<bool> request;
    request = _platform.requestNotificationPermission().whenComplete(() {
      if (identical(_notificationPermissionRequest, request)) {
        _notificationPermissionRequest = null;
      }
    });
    _notificationPermissionRequest = request;
    return request;
  }

  Future<void> _startDownload(DownloadEntry entry, MediaCandidate candidate) {
    final attempt = Object();
    _downloadAttempts[entry.id] = attempt;
    return candidate.isBackendSelection
        ? _startBackendDownload(entry, candidate, attempt)
        : _startNativeDownload(entry, candidate, attempt: attempt);
  }

  bool _isCurrentDownloadAttempt(DownloadEntry entry, Object attempt) =>
      identical(_downloadAttempts[entry.id], attempt) &&
      identical(
        downloads.where((value) => value.id == entry.id).firstOrNull,
        entry,
      );

  Future<void> _startBackendDownload(
    DownloadEntry entry,
    MediaCandidate candidate,
    Object attempt,
  ) async {
    final userId = user?.id;
    if (!_accessEnabled || userId == null || entry.userId != userId) return;
    final previousJobId = entry.backendJobId;
    if (previousJobId != null) {
      if (entry.nativeBackendTransferOwned) {
        try {
          await _platform.cancelBackendTransfer(previousJobId);
        } catch (_) {}
      }
      try {
        await _downloadBackend.cancelJob(previousJobId);
      } catch (_) {}
    }
    entry
      ..state = 'queued'
      ..progress = 0
      ..nativeId = null
      ..localPath = null
      ..saveLocation = null
      ..backendJobId = null
      ..nativeBackendTransferOwned = false
      ..backendStage = 'queued'
      ..backendEngine = null
      ..error = null
      ..updatedAt = DateTime.now().toUtc()
      ..dirty = true;
    await _changed();
    try {
      final job = await _downloadBackend.createJob(
        candidate,
        requestId: entry.id,
      );
      if (user?.id != userId ||
          !_isCurrentDownloadAttempt(entry, attempt) ||
          entry.state != 'queued') {
        try {
          await _downloadBackend.cancelJob(job.id);
        } catch (_) {}
        return;
      }
      entry
        ..backendJobId = job.id
        ..backendStage = job.stage
        ..backendEngine = job.engine;
      if (job.ready) {
        await _startReadyBackendFile(entry, job, attempt: attempt);
        return;
      }
      if (job.status == 'failed') {
        _downloadAttempts.remove(entry.id);
        entry
          ..state = 'failed'
          ..error = job.error == null
              ? '서버에서 다운로드 파일을 만들지 못했습니다.'
              : backendFailureMessage(job.error!);
      } else if (job.status == 'canceled') {
        _downloadAttempts.remove(entry.id);
        entry.state = 'canceled';
      } else {
        entry
          ..state = job.status == 'queued' ? 'queued' : 'running'
          ..progress = (job.progress * 85 ~/ 100).clamp(0, 84);
        final transferUrl = job.transferUrl;
        if (transferUrl != null) {
          var scheduled = false;
          try {
            scheduled = await _platform.scheduleBackendTransfer(
              statusUrl: transferUrl,
              backendJobId: job.id,
              title: entry.title,
              description: entry.description,
              wifiOnly: settings.downloadWifiOnly,
            );
          } catch (_) {
            // API < 29 and older native builds keep the Dart polling fallback.
          }
          if (user?.id != userId ||
              !_isCurrentDownloadAttempt(entry, attempt) ||
              !{'queued', 'running'}.contains(entry.state)) {
            if (scheduled) {
              try {
                await _platform.cancelBackendTransfer(job.id);
              } catch (_) {}
            }
            try {
              await _downloadBackend.cancelJob(job.id);
            } catch (_) {}
            return;
          }
          entry
            ..nativeBackendTransferOwned = scheduled
            ..wifiOnly = settings.downloadWifiOnly;
          if (scheduled) _downloadAttempts.remove(entry.id);
        }
      }
    } on DownloadBackendException catch (error) {
      _downloadAttempts.remove(entry.id);
      entry
        ..state = 'failed'
        ..backendJobId = null
        ..error = backendFailureMessage(error);
    } on TimeoutException {
      _downloadAttempts.remove(entry.id);
      entry
        ..state = 'failed'
        ..backendJobId = null
        ..error = '다운로드 서버가 작업을 시작하는 데 너무 오래 걸렸습니다.';
    } on Object {
      _downloadAttempts.remove(entry.id);
      entry
        ..state = 'failed'
        ..backendJobId = null
        ..error = '다운로드 서버에 작업을 요청하지 못했습니다.';
    }
    entry
      ..updatedAt = DateTime.now().toUtc()
      ..dirty = true;
    await _changed();
    final jobId = entry.backendJobId;
    if (jobId != null &&
        !entry.nativeBackendTransferOwned &&
        {'queued', 'running'}.contains(entry.state)) {
      await _waitForBackendDeviceQueue(entry.id, jobId);
    }
  }

  Future<void> _startReadyBackendFile(
    DownloadEntry entry,
    BackendDownloadJob job, {
    Object? attempt,
  }) async {
    if (!{'queued', 'running'}.contains(entry.state)) return;
    final currentAttempt = attempt ?? _downloadAttempts[entry.id] ?? Object();
    _downloadAttempts[entry.id] = currentAttempt;
    if (!_isCurrentDownloadAttempt(entry, currentAttempt)) return;
    if (entry.nativeBackendTransferOwned ||
        entry.nativeId != null ||
        {'device_queuing', 'device_download'}.contains(entry.backendStage)) {
      return;
    }
    entry.backendStage = 'device_queuing';
    final fileUrl = job.fileUrl;
    final fileName = job.fileName;
    final kind = job.kind;
    if (fileUrl == null || fileName == null || kind == null) {
      entry
        ..state = 'failed'
        ..error = '서버가 완료 파일의 주소·이름·형식을 모두 반환하지 않았습니다.'
        ..updatedAt = DateTime.now().toUtc()
        ..dirty = true;
      await _changed();
      return;
    }
    await _startNativeDownload(
      entry,
      MediaCandidate(
        url: fileUrl,
        kind: kind,
        fileName: fileName,
        providerLabel: job.platform ?? entry.backendEngine ?? 'Morit backend',
        mimeType: job.mimeType,
      ),
      preflight: false,
      attempt: currentAttempt,
      expectedContentLength: job.contentLength,
    );
  }

  Future<void> _waitForBackendDeviceQueue(String entryId, String jobId) async {
    final deadline = DateTime.now().add(backendPreparationTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final current = downloads
          .where((value) => value.id == entryId)
          .firstOrNull;
      if (current == null ||
          current.backendJobId != jobId ||
          current.nativeId != null ||
          !{'queued', 'running'}.contains(current.state)) {
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      await pollDownloads();
    }
    final current = downloads
        .where(
          (value) =>
              value.id == entryId &&
              value.backendJobId == jobId &&
              value.nativeId == null &&
              {'queued', 'running'}.contains(value.state),
        )
        .firstOrNull;
    if (current == null) return;
    try {
      await _downloadBackend.cancelJob(jobId);
    } catch (_) {}
    current
      ..backendJobId = null
      ..nativeBackendTransferOwned = false
      ..backendStage = null
      ..state = 'failed'
      ..error = '서버가 60분 안에 완료 파일을 준비하지 못해 작업을 중단했습니다.'
      ..updatedAt = DateTime.now().toUtc()
      ..dirty = true;
    _downloadAttempts.remove(entryId);
    await _changed();
  }

  Future<void> _startNativeDownload(
    DownloadEntry entry,
    MediaCandidate candidate, {
    bool preflight = true,
    Object? attempt,
    int? expectedContentLength,
  }) async {
    final currentAttempt = attempt ?? Object();
    if (attempt == null) _downloadAttempts[entry.id] = currentAttempt;
    if (!_isCurrentDownloadAttempt(entry, currentAttempt)) return;
    final userId = user?.id;
    if (!_accessEnabled || userId == null || entry.userId != userId) return;
    final uri = candidate.url;
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      _downloadAttempts.remove(entry.id);
      entry.state = 'failed';
      entry.error = '다운로드 주소가 올바르지 않습니다.';
      entry.updatedAt = DateTime.now().toUtc();
      entry.dirty = true;
      await _changed();
      return;
    }
    final previousNativeId = entry.nativeId;
    if (previousNativeId != null) {
      try {
        await _platform.cancelDownload(previousNativeId);
      } catch (_) {
        entry.state = 'failed';
        entry.error = '기존 다운로드 작업을 정리하지 못해 다시 시작하지 않았습니다.';
        entry.updatedAt = DateTime.now().toUtc();
        entry.dirty = true;
        await _changed();
        return;
      }
    }
    final checked = preflight
        ? await validateMediaCandidateForDownload(candidate)
        : (candidate: candidate, failure: null);
    if (user?.id != userId) return;
    if (checked.failure case final failure?) {
      _downloadAttempts.remove(entry.id);
      entry.state = 'failed';
      entry.nativeId = null;
      entry.error = failure.message;
      entry.updatedAt = DateTime.now().toUtc();
      entry.dirty = true;
      await _changed();
      return;
    }
    final resolvedCandidate = checked.candidate!;
    final downloadUri = resolvedCandidate.url;
    entry.state = 'queued';
    entry.progress = entry.mode == 'proxy' ? 85 : 0;
    entry.nativeId = null;
    entry.nativeBackendTransferOwned = false;
    entry.localPath = null;
    entry.saveLocation = null;
    entry.deviceOwned = true;
    entry.wifiOnly = settings.downloadWifiOnly;
    entry.fileName = resolvedCandidate.fileName;
    entry.mimeType = resolvedCandidate.mimeType;
    entry.backendStage = entry.mode == 'proxy' ? 'device_download' : null;
    entry.error = null;
    try {
      final job = await _platform.enqueueDownload(
        url: downloadUri,
        fileName: downloadFileName(
          entry.id,
          resolvedCandidate.fileName,
          downloadUri,
          resolvedCandidate.mimeType,
        ),
        mediaKind: resolvedCandidate.kind.name,
        mimeType: resolvedCandidate.mimeType,
        title: entry.title,
        description: entry.description,
        expectedContentLength: expectedContentLength,
        wifiOnly: entry.wifiOnly,
        headers: {
          for (final header in resolvedCandidate.headers.entries)
            if ({'referer', 'user-agent'}.contains(header.key.toLowerCase()) &&
                header.value.length <= 1000 &&
                !header.value.contains('\n') &&
                !header.value.contains('\r'))
              header.key: header.value,
        },
      );
      if (user?.id != userId ||
          !_isCurrentDownloadAttempt(entry, currentAttempt) ||
          entry.state != 'queued') {
        if (job != null) {
          try {
            await _platform.cancelDownload(job.id);
          } catch (_) {}
        }
        return;
      }
      if (job == null) throw PlatformException(code: 'enqueue_failed');
      entry.nativeId = job.id;
      entry.saveLocation = job.saveLocation;
      entry.state = 'queued';
      _downloadAttempts.remove(entry.id);
    } on PlatformException catch (error) {
      _downloadAttempts.remove(entry.id);
      entry.state = 'failed';
      entry.error = error.message ?? '다운로드를 시작하지 못했습니다.';
    } on Object {
      _downloadAttempts.remove(entry.id);
      entry.state = 'failed';
      entry.error = '다운로드를 시작하지 못했습니다.';
    }
    entry.updatedAt = DateTime.now().toUtc();
    entry.dirty = true;
    await _changed();
  }

  Future<void> _restartDownload(DownloadEntry entry) async {
    final source = Uri.tryParse(entry.sourceUrl);
    if (source == null ||
        source.scheme != 'https' ||
        source.host.isEmpty ||
        source.userInfo.isNotEmpty) {
      entry.state = 'failed';
      entry.error = '원본 링크가 올바르지 않아 다시 분석할 수 없습니다.';
      entry.updatedAt = DateTime.now().toUtc();
      entry.dirty = true;
      await _changed();
      return;
    }
    final analysis = await analyzeMediaUrl(source);
    final candidates = analysis?.candidates ?? const <MediaCandidate>[];
    final candidate = candidates
        .where(
          (value) =>
              (entry.backendAssetId != null
                  ? value.assetId == entry.backendAssetId
                  : value.fileName == entry.fileName &&
                        (entry.mimeType == null ||
                            value.mimeType == entry.mimeType)) &&
              (entry.quality == 'original' ||
                  value.qualityLabel == entry.quality),
        )
        .firstOrNull;
    if (candidate == null) {
      entry.state = 'failed';
      entry.error = '원본 링크에서 다운로드 파일을 다시 찾지 못했습니다.';
      entry.updatedAt = DateTime.now().toUtc();
      entry.dirty = true;
      await _changed();
      return;
    }
    await _startDownload(entry, candidate);
  }

  Future<({bool changed, String? error})> _attachCompletedDownload(
    DownloadEntry entry,
  ) async {
    final itemId = entry.itemId;
    if (itemId == null) return (changed: false, error: null);
    final item = items
        .where(
          (value) =>
              value.id == itemId &&
              value.userId == entry.userId &&
              !value.deleted &&
              supportsAttachments(value.kind),
        )
        .firstOrNull;
    if (item == null) return (changed: false, error: null);
    String? temporarySharedPath;
    try {
      final rawPath = entry.localPath;
      final uri = rawPath == null ? null : Uri.tryParse(rawPath);
      final path = switch (uri?.scheme) {
        'file' => uri!.toFilePath(),
        'content' => temporarySharedPath = await _platform.copySharedContentUri(
          rawPath!,
          maxBytes: maxMoritAttachmentBytes,
          fileName: entry.fileName,
        ),
        '' => rawPath,
        _ => null,
      };
      if (path == null) {
        return (
          changed: false,
          error: '다운로드는 완료됐지만 공개 파일 URI를 읽을 수 없어 첨부 복사에 실패했습니다.',
        );
      }
      final file = File(path);
      if (!await file.exists()) {
        return (
          changed: false,
          error: '다운로드는 완료됐지만 저장된 파일을 찾지 못해 첨부 복사에 실패했습니다.',
        );
      }
      final size = await file.length();
      final fileName = entry.fileName?.trim().isNotEmpty == true
          ? entry.fileName!
          : file.uri.pathSegments.last;
      final existing = attachmentsForItem(item.id);
      if (existing.any(
        (value) =>
            value.fileName.toLowerCase() == fileName.toLowerCase() &&
            value.sizeBytes == size,
      )) {
        return (changed: false, error: null);
      }
      final prepared = await _preparePickedAttachments(item, [
        PlatformFile(name: fileName, size: size, path: path),
      ], existing: existing);
      if (prepared == null) {
        return (
          changed: false,
          error: '다운로드는 완료됐지만 첨부 복사에 실패했습니다. ${message ?? '앱 저장 공간을 확인해 주세요.'}',
        );
      }
      if (prepared.isEmpty) return (changed: false, error: null);
      attachments.addAll(
        prepared.map(
          (value) => entry.mimeType == null
              ? value
              : _copyAttachment(value, mimeType: entry.mimeType),
        ),
      );
      item.metadata = {...item.metadata, 'has_attachments': true};
      item.updatedAt = DateTime.now().toUtc();
      item.dirty = true;
      return (changed: true, error: null);
    } on Object {
      return (
        changed: false,
        error: '다운로드는 완료됐지만 첨부 복사에 실패했습니다. 앱 저장 공간을 확인해 주세요.',
      );
    } finally {
      final path = temporarySharedPath;
      if (path != null) {
        try {
          await _platform.deleteOwnedFile(path);
        } catch (_) {}
      }
    }
  }

  Future<void> pollDownloads() async {
    final userId = user?.id;
    if (!_accessEnabled || userId == null || _pollingDownloads) return;
    final pendingBackend = downloads
        .where(
          (value) =>
              value.backendJobId != null &&
              value.nativeId == null &&
              {'queued', 'running'}.contains(value.state),
        )
        .map((value) => (id: value.id, jobId: value.backendJobId!))
        .toList();
    final pendingNative = downloads
        .where(
          (value) =>
              value.nativeId != null &&
              {'queued', 'running', 'paused'}.contains(value.state),
        )
        .map((value) => (id: value.id, nativeId: value.nativeId!))
        .toList();
    if (pendingBackend.isEmpty && pendingNative.isEmpty) return;
    _pollingDownloads = true;
    var changed = false;
    var syncRequired = false;
    var attachmentSyncRequired = false;
    try {
      for (final pendingEntry in pendingBackend) {
        final entry = downloads
            .where((value) => value.id == pendingEntry.id)
            .firstOrNull;
        if (entry == null ||
            entry.backendJobId != pendingEntry.jobId ||
            entry.nativeId != null) {
          continue;
        }
        final previous = (
          state: entry.state,
          progress: entry.progress,
          error: entry.error,
          stage: entry.backendStage,
          engine: entry.backendEngine,
          nativeId: entry.nativeId,
          nativeBackendTransferOwned: entry.nativeBackendTransferOwned,
        );
        try {
          if (entry.nativeBackendTransferOwned) {
            final native = await _platform.queryBackendTransfer(
              pendingEntry.jobId,
            );
            if (native == null) {
              entry.nativeBackendTransferOwned = false;
            } else {
              final nativeId = (native['nativeId'] as num?)?.toInt();
              final nativeStatus = native['status'] as String? ?? 'waiting';
              final nativeProgress =
                  (native['progress'] as num?)?.toInt().clamp(0, 100) ?? 0;
              entry
                ..backendStage =
                    native['stage'] as String? ?? entry.backendStage
                ..error = native['error'] as String?;
              if (nativeId != null) {
                entry
                  ..nativeId = nativeId
                  ..saveLocation =
                      native['saveLocation'] as String? ?? entry.saveLocation
                  ..nativeBackendTransferOwned = false
                  ..backendStage = 'device_download'
                  ..state = 'queued'
                  ..progress = 85;
                _downloadAttempts.remove(entry.id);
                pendingNative.add((id: entry.id, nativeId: nativeId));
              } else {
                entry
                  ..state = switch (nativeStatus) {
                    'failed' => 'failed',
                    'canceled' => 'canceled',
                    'scheduled' || 'waiting' || 'queued' => 'queued',
                    _ => 'running',
                  }
                  ..progress = (nativeProgress * 85 ~/ 100).clamp(0, 84);
                if ({'failed', 'canceled'}.contains(entry.state)) {
                  entry.nativeBackendTransferOwned = false;
                  _downloadAttempts.remove(entry.id);
                }
              }
            }
          }
          if (!entry.nativeBackendTransferOwned &&
              entry.nativeId == null &&
              {'queued', 'running'}.contains(entry.state)) {
            final job = await _downloadBackend.queryJob(pendingEntry.jobId);
            if (user?.id != userId ||
                entry.backendJobId != pendingEntry.jobId ||
                entry.nativeId != null ||
                entry.nativeBackendTransferOwned) {
              continue;
            }
            entry
              ..backendStage = job.stage
              ..backendEngine = job.engine ?? entry.backendEngine;
            if (job.ready) {
              await _startReadyBackendFile(entry, job);
              continue;
            }
            entry
              ..state = switch (job.status) {
                'failed' => 'failed',
                'canceled' => 'canceled',
                'queued' => 'queued',
                _ => 'running',
              }
              ..progress = (job.progress * 85 ~/ 100).clamp(0, 84)
              ..error = job.error == null
                  ? null
                  : backendFailureMessage(job.error!);
          }
        } on PlatformException {
          // Native ownership remains authoritative after a transient channel error.
        } on DownloadBackendException catch (error) {
          if (!error.retryable) entry.state = 'failed';
          entry.error = backendFailureMessage(error);
        } on TimeoutException {
          // The server job keeps running; a later poll can recover its state.
        } on SocketException {
          // The server job keeps running; a later poll can recover its state.
        }
        final current = (
          state: entry.state,
          progress: entry.progress,
          error: entry.error,
          stage: entry.backendStage,
          engine: entry.backendEngine,
          nativeId: entry.nativeId,
          nativeBackendTransferOwned: entry.nativeBackendTransferOwned,
        );
        if (current != previous) {
          entry.updatedAt = DateTime.now().toUtc();
          if (current.state != previous.state ||
              {'failed', 'canceled'}.contains(current.state)) {
            entry.dirty = true;
            syncRequired = true;
          }
          changed = true;
        }
      }
      for (final pendingEntry in pendingNative) {
        try {
          final raw = await _platform.queryDownload(pendingEntry.nativeId);
          if (user?.id != userId) return;
          final entry = downloads
              .where((value) => value.id == pendingEntry.id)
              .firstOrNull;
          if (entry == null ||
              entry.nativeId != pendingEntry.nativeId ||
              !{'queued', 'running', 'paused'}.contains(entry.state)) {
            continue;
          }
          final previous = (
            state: entry.state,
            progress: entry.progress,
            localPath: entry.localPath,
            saveLocation: entry.saveLocation,
            error: entry.error,
            nativeId: entry.nativeId,
          );
          if (raw == null) {
            entry.state = 'failed';
            entry.nativeId = null;
            entry.error = '다운로드 기록을 기기에서 찾을 수 없습니다.';
          } else {
            final status = (raw['status'] as num?)?.toInt();
            final reason = (raw['reason'] as num?)?.toInt() ?? 0;
            final downloaded = (raw['bytesDownloaded'] as num?)?.toInt() ?? 0;
            final total = (raw['totalBytes'] as num?)?.toInt() ?? -1;
            final modifiedMillis =
                (raw['lastModifiedMillis'] as num?)?.toInt() ?? 0;
            final lastModified = modifiedMillis > 0
                ? DateTime.fromMillisecondsSinceEpoch(
                    modifiedMillis,
                    isUtc: true,
                  )
                : entry.updatedAt;
            if (status != null &&
                isDownloadStartStalled(
                  status: status,
                  bytesDownloaded: downloaded,
                  lastModified: lastModified,
                  wifiOnly: entry.wifiOnly,
                )) {
              try {
                await _platform.cancelDownload(pendingEntry.nativeId);
              } catch (_) {}
              if (user?.id != userId ||
                  entry.nativeId != pendingEntry.nativeId) {
                continue;
              }
              entry.state = 'failed';
              entry.nativeId = null;
              entry.error =
                  '시스템 다운로드가 2분 동안 시작되지 않아 중단했습니다. 네트워크를 확인한 뒤 재시도해 주세요.';
            } else {
              if (total > 0) {
                final deviceProgress = (downloaded * 100 ~/ total).clamp(
                  0,
                  100,
                );
                entry.progress = entry.mode == 'proxy'
                    ? 85 + deviceProgress * 15 ~/ 100
                    : deviceProgress;
              }
              entry.state = switch (status) {
                1 => 'queued',
                2 => 'running',
                4 => 'paused',
                8 => 'completed',
                16 => 'failed',
                _ => entry.state,
              };
              if (entry.state == 'completed') entry.progress = 100;
              entry.localPath = raw['localUri'] as String? ?? entry.localPath;
              entry.saveLocation =
                  raw['saveLocation'] as String? ?? entry.saveLocation;
              final nativeError = (raw['errorMessage'] as String?)?.trim();
              final detail = downloadReasonMessage(
                status ?? 0,
                reason,
                wifiOnly: entry.wifiOnly,
              );
              entry.error = nativeError?.isNotEmpty == true
                  ? nativeError
                  : detail.isEmpty
                  ? null
                  : detail;
              if (entry.state == 'completed' && previous.state != 'completed') {
                final attachment = await _attachCompletedDownload(entry);
                if (attachment.error != null) entry.error = attachment.error;
                if (attachment.changed) {
                  changed = true;
                  syncRequired = true;
                  attachmentSyncRequired = true;
                }
              }
            }
          }
          final current = (
            state: entry.state,
            progress: entry.progress,
            localPath: entry.localPath,
            saveLocation: entry.saveLocation,
            error: entry.error,
            nativeId: entry.nativeId,
          );
          if (current != previous) {
            entry.updatedAt = DateTime.now().toUtc();
            final stateChanged = current.state != previous.state;
            final terminal = {
              'completed',
              'failed',
              'canceled',
            }.contains(current.state);
            if (stateChanged || terminal) {
              entry.dirty = true;
              syncRequired = true;
            }
            changed = true;
          }
        } on PlatformException {
          // A transient MethodChannel/query failure does not stop the native job.
        } on Object {
          // Keep polling; retrying here could enqueue the same download twice.
        }
      }
      if (changed) {
        await _save(userId);
        notifyListeners();
        if (attachmentSyncRequired || syncRequired && autoSync) {
          unawaited(sync());
        }
      }
    } finally {
      _pollingDownloads = false;
    }
  }

  Future<void> cancelDownload(DownloadEntry entry) async {
    final entryId = entry.id;
    _downloadAttempts.remove(entryId);
    final current = downloads.where((value) => value.id == entryId).firstOrNull;
    if (current == null || !current.deviceOwned) return;
    final nativeId = current.nativeId;
    if (nativeId != null) {
      try {
        await _platform.cancelDownload(nativeId);
      } catch (_) {
        showMessage('시스템 다운로드를 취소하지 못했습니다. 잠시 후 다시 시도해 주세요.');
        return;
      }
    }
    final backendJobId = current.backendJobId;
    final nativeBackendTransferOwned = current.nativeBackendTransferOwned;
    var backendCancelFailed = false;
    if (backendJobId != null) {
      if (nativeBackendTransferOwned) {
        try {
          if (!await _platform.cancelBackendTransfer(backendJobId)) {
            showMessage('백그라운드 다운로드를 취소하지 못했습니다. 잠시 후 다시 시도해 주세요.');
            return;
          }
        } catch (_) {
          showMessage('백그라운드 다운로드를 취소하지 못했습니다. 잠시 후 다시 시도해 주세요.');
          return;
        }
      }
      try {
        await _downloadBackend.cancelJob(backendJobId);
      } catch (_) {
        backendCancelFailed = true;
      }
    }
    final latest = downloads.where((value) => value.id == entryId).firstOrNull;
    if (latest == null || latest.backendJobId != backendJobId) {
      return;
    }
    entry = latest;
    final racedNativeId = entry.nativeId;
    if (racedNativeId != null && racedNativeId != nativeId) {
      try {
        await _platform.cancelDownload(racedNativeId);
      } catch (_) {}
    }
    if (backendCancelFailed) {
      entry
        ..nativeId = null
        ..nativeBackendTransferOwned = false
        ..state = 'failed'
        ..error = '기기 다운로드는 중단했지만 서버 작업 취소를 확인하지 못했습니다.'
        ..updatedAt = DateTime.now().toUtc()
        ..dirty = true;
      await _changed();
      return;
    }
    entry.nativeId = null;
    entry.backendJobId = null;
    entry.nativeBackendTransferOwned = false;
    entry.backendStage = null;
    entry.state = 'canceled';
    entry.error = null;
    entry.updatedAt = DateTime.now().toUtc();
    entry.dirty = true;
    await _changed();
  }

  Future<void> pauseDownload(DownloadEntry entry) async {
    _downloadAttempts.remove(entry.id);
    final current = downloads
        .where((value) => value.id == entry.id)
        .firstOrNull;
    if (current == null ||
        !current.deviceOwned ||
        !{'queued', 'running'}.contains(current.state)) {
      return;
    }
    final nativeId = current.nativeId;
    if (nativeId != null) {
      try {
        await _platform.cancelDownload(nativeId);
      } catch (_) {
        showMessage('시스템 다운로드를 일시 중지하지 못했습니다.');
        return;
      }
    }
    final backendJobId = current.backendJobId;
    if (backendJobId != null) {
      if (current.nativeBackendTransferOwned) {
        try {
          if (!await _platform.cancelBackendTransfer(backendJobId)) {
            showMessage('백그라운드 다운로드를 일시 중지하지 못했습니다.');
            return;
          }
        } catch (_) {
          showMessage('백그라운드 다운로드를 일시 중지하지 못했습니다.');
          return;
        }
      }
      try {
        await _downloadBackend.cancelJob(backendJobId);
      } catch (_) {
        current
          ..nativeId = null
          ..nativeBackendTransferOwned = false
          ..state = 'failed'
          ..error = '기기 다운로드는 중단했지만 서버 작업 일시 중지를 확인하지 못했습니다.'
          ..updatedAt = DateTime.now().toUtc()
          ..dirty = true;
        await _changed();
        return;
      }
    }
    current.nativeId = null;
    current.backendJobId = null;
    current.nativeBackendTransferOwned = false;
    current.backendStage = null;
    current.state = 'paused';
    current.progress = 0;
    // ponytail: DownloadManager has no public byte-resume API; resume restarts.
    current.error = '일시 중지됨 · 재개하면 처음부터 다시 시작합니다.';
    current.updatedAt = DateTime.now().toUtc();
    current.dirty = true;
    await _changed();
  }

  Future<void> resumeDownload(DownloadEntry entry) async {
    final current = downloads
        .where((value) => value.id == entry.id)
        .firstOrNull;
    if (current == null || !current.deviceOwned || current.state != 'paused') {
      return;
    }
    await _restartDownload(current);
  }

  Future<void> retryDownload(DownloadEntry entry) async {
    final current = downloads
        .where((value) => value.id == entry.id)
        .firstOrNull;
    if (current == null ||
        !current.deviceOwned ||
        !{'failed', 'canceled'}.contains(current.state)) {
      return;
    }
    await _restartDownload(current);
  }

  Future<void> openDownload(DownloadEntry entry) async {
    try {
      final nativeId = entry.nativeId;
      if (nativeId != null &&
          await _platform.openDownload(nativeId, mimeType: entry.mimeType)) {
        return;
      }
      final value = entry.localPath;
      if (value == null) {
        showMessage('다운로드 파일을 기기에서 찾을 수 없습니다.');
        return;
      }
      final uri = Uri.tryParse(value);
      final path = uri?.scheme == 'file' ? uri!.toFilePath() : value;
      final opened = await _platform.openFile(path, mimeType: entry.mimeType);
      if (!opened) showMessage('이 파일을 열 수 있는 앱이 없습니다.');
    } on PlatformException catch (error) {
      showMessage(error.message ?? '다운로드 파일을 열지 못했습니다.');
    }
  }

  Future<bool> openItemContent(MoritItem item) async {
    final currentUser = user;
    if (currentUser == null || item.userId != currentUser.id || item.deleted) {
      return false;
    }
    try {
      final source = Uri.tryParse(item.sourceUrl ?? '');
      if (source != null &&
          source.host.isNotEmpty &&
          {'http', 'https'}.contains(source.scheme) &&
          await canLaunchUrl(source)) {
        return launchUrl(source, mode: LaunchMode.externalApplication);
      }

      final localPath = item.localPath;
      if (localPath != null && await File(localPath).exists()) {
        if (await _platform.openFile(localPath, mimeType: item.mimeType)) {
          return true;
        }
        showMessage('이 파일을 열 수 있는 앱이 없습니다.');
      }

      final storagePath = item.storagePath;
      if (storagePath != null) {
        if (!storagePath.startsWith('${currentUser.id}/')) {
          showMessage('계정 소유 경로가 아닌 파일은 열 수 없습니다.');
          return false;
        }
        final signed = await supabase.storage
            .from('morit-files')
            .createSignedUrl(storagePath, 3600);
        final uri = Uri.tryParse(signed);
        if (uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            await canLaunchUrl(uri)) {
          return launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        showMessage('파일 주소를 안전하게 열 수 없습니다.');
      }
    } on PlatformException catch (error) {
      showMessage(error.message ?? '파일을 열지 못했습니다.');
    } on Object {
      showMessage('파일을 내려받지 못했습니다. 연결을 확인해 주세요.');
    }
    return false;
  }

  Future<bool> openAttachment(MoritAttachment attachment) async {
    final currentUser = user;
    if (currentUser == null ||
        attachment.userId != currentUser.id ||
        !attachment.storagePath.startsWith(
          '${currentUser.id}/${attachment.itemId}/',
        )) {
      return false;
    }
    try {
      final localPath = attachment.localPath;
      if (localPath != null && await File(localPath).exists()) {
        return _platform.openFile(localPath, mimeType: attachment.mimeType);
      }
      if (attachment.uploadState != AttachmentUploadState.uploaded) {
        showMessage(attachment.lastError ?? '첨부 파일 업로드가 아직 완료되지 않았습니다.');
        return false;
      }
      final signed = await supabase.storage
          .from(moritFilesBucket)
          .createSignedUrl(attachment.storagePath, 3600);
      final uri = Uri.tryParse(signed);
      if (uri != null && uri.scheme == 'https' && await canLaunchUrl(uri)) {
        return launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } on Object catch (error) {
      showMessage(attachmentFailureReason(error));
    }
    return false;
  }

  Future<void> retryAttachment(MoritAttachment attachment) async {
    if (attachment.userId != user?.id || attachment.localPath == null) return;
    _replaceAttachment(
      _copyAttachment(
        attachment,
        state: AttachmentUploadState.pending,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    await _save();
    notifyListeners();
    unawaited(sync());
  }

  Future<void> deleteAttachment(MoritAttachment attachment) async {
    final userId = user?.id;
    if (userId == null || attachment.userId != userId) return;
    final current = attachments
        .where((value) => value.id == attachment.id)
        .firstOrNull;
    if (current == null) return;
    if (current.uploadState == AttachmentUploadState.pending &&
        current.attemptCount == 0) {
      attachments.removeWhere((value) => value.id == current.id);
      if (current.localPath != null) {
        await _deleteOwnedLocalFiles([current.localPath!]);
      }
      final item = items
          .where((value) => value.id == current.itemId)
          .firstOrNull;
      if (item != null && attachmentsForItem(item.id).isEmpty) {
        item.metadata = {...item.metadata}..remove('has_attachments');
        item.updatedAt = DateTime.now().toUtc();
        item.dirty = true;
      }
      await _changed(forceSync: item != null && isTodayItem(item));
      return;
    }
    _replaceAttachment(
      _copyAttachment(
        current,
        state: AttachmentUploadState.deleting,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    await _save(userId);
    notifyListeners();
    unawaited(sync());
  }

  Future<void> setPreferences({
    String? mode,
    bool? notifications,
    bool? syncEnabled,
  }) async {
    if (mode != null) downloadMode = 'direct';
    if (notifications != null) {
      if (notifications) {
        try {
          notificationsEnabled = await _platform
              .requestNotificationPermission();
        } catch (_) {
          notificationsEnabled = false;
        }
        if (!notificationsEnabled) {
          message = '시스템 설정에서 Morit 알림을 허용해 주세요.';
        }
      } else {
        notificationsEnabled = false;
      }
      if (notificationsEnabled) {
        await _scheduleFutureReminders();
      } else {
        await _cancelAllReminders();
      }
    }
    if (syncEnabled != null) autoSync = syncEnabled;
    _preferencesDirty = true;
    await _changed();
    if (!autoSync) unawaited(sync());
  }

  Future<bool> hasTodayPin() async {
    final userId = user?.id;
    return userId != null && await _pinStore.hasPin(userId);
  }

  Future<bool> verifyTodayPin(String pin) async {
    final userId = user?.id;
    return userId != null && await _pinStore.verify(userId, pin);
  }

  Future<void> setTodayPin(String pin) async {
    final userId = user?.id;
    if (userId == null) return;
    await _pinStore.setPin(userId, pin);
  }

  Future<void> clearTodayPin() async {
    final userId = user?.id;
    if (userId == null) return;
    await _pinStore.clear(userId);
    if (settings.lockScreenPolicy == 'morit_pin') {
      settings.lockScreenPolicy = 'device_unlock';
      _preferencesDirty = true;
      await _changed(forceSync: true);
    } else {
      notifyListeners();
    }
  }

  Future<bool> setBehaviorSettings({
    bool? carryOverIncomplete,
    bool? showCompletedToday,
    String? todaySort,
    int? todayNotificationLimit,
    String? lockScreenPolicy,
    bool? animationsEnabled,
    String? completionStyle,
    bool? showFavorites,
    int? favoriteLimit,
    String? folderSort,
    bool? compactUi,
    bool? overlayEnabled,
    bool? downloadWifiOnly,
  }) async {
    if (todaySort != null &&
        !{'manual', 'newest', 'oldest'}.contains(todaySort)) {
      return false;
    }
    if (lockScreenPolicy != null &&
        !{
          'device_unlock',
          'allow_locked',
          'morit_pin',
        }.contains(lockScreenPolicy)) {
      return false;
    }
    if (lockScreenPolicy == 'morit_pin' && !await hasTodayPin()) {
      message = '먼저 Morit 전용 PIN을 설정해 주세요.';
      notifyListeners();
      return false;
    }
    if (completionStyle != null &&
        !{'marker', 'strike', 'dim'}.contains(completionStyle)) {
      return false;
    }
    if (folderSort != null && !{'manual', 'name'}.contains(folderSort)) {
      return false;
    }
    if (carryOverIncomplete != null) {
      settings.carryOverIncomplete = carryOverIncomplete;
    }
    if (showCompletedToday != null) {
      settings.showCompletedToday = showCompletedToday;
    }
    if (todaySort != null) settings.todaySort = todaySort;
    if (todayNotificationLimit != null) {
      settings.todayNotificationLimit = todayNotificationLimit
          .clamp(1, 8)
          .toInt();
    }
    if (lockScreenPolicy != null) {
      settings.lockScreenPolicy = lockScreenPolicy;
    }
    if (animationsEnabled != null) {
      settings.animationsEnabled = animationsEnabled;
    }
    if (completionStyle != null) {
      settings.completionStyle = completionStyle;
    }
    if (showFavorites != null) settings.showFavorites = showFavorites;
    if (favoriteLimit != null) {
      settings.favoriteLimit = favoriteLimit.clamp(1, 8).toInt();
    }
    if (folderSort != null) settings.folderSort = folderSort;
    if (compactUi != null) settings.compactUi = compactUi;
    if (overlayEnabled != null) settings.overlayEnabled = overlayEnabled;
    if (downloadWifiOnly != null) {
      settings.downloadWifiOnly = downloadWifiOnly;
    }
    _preferencesDirty = true;
    _rolloverTodayItems();
    await _changed(forceSync: true);
    return true;
  }

  Future<void> _changed({bool forceSync = false}) async {
    await _save();
    await _syncTodayNotification();
    notifyListeners();
    if (forceSync || autoSync) unawaited(sync());
  }

  @override
  void dispose() {
    _dayRolloverTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription.cancel();
    super.dispose();
  }
}
