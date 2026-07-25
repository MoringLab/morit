class MoritSettings {
  MoritSettings({
    this.carryOverIncomplete = true,
    this.showCompletedToday = true,
    this.todaySort = 'manual',
    this.todayNotificationLimit = 5,
    this.lockScreenPolicy = 'device_unlock',
    this.animationsEnabled = true,
    this.completionStyle = 'marker',
    this.showFavorites = true,
    this.favoriteLimit = 4,
    this.folderSort = 'manual',
    this.compactUi = false,
    this.overlayEnabled = true,
    this.downloadWifiOnly = false,
  });

  bool carryOverIncomplete;
  bool showCompletedToday;
  String todaySort;
  int todayNotificationLimit;
  String lockScreenPolicy;
  bool animationsEnabled;
  String completionStyle;
  bool showFavorites;
  int favoriteLimit;
  String folderSort;
  bool compactUi;
  bool overlayEnabled;
  bool downloadWifiOnly;

  factory MoritSettings.fromJson(Map<String, dynamic>? json) {
    final value = json ?? const <String, dynamic>{};
    final todaySort = value['today_sort'];
    final lockPolicy = value['lock_screen_policy'];
    final completionStyle = value['completion_style'];
    final folderSort = value['folder_sort'];
    return MoritSettings(
      carryOverIncomplete: value['carry_over_incomplete'] as bool? ?? true,
      showCompletedToday: value['show_completed_today'] as bool? ?? true,
      todaySort: {'manual', 'newest', 'oldest'}.contains(todaySort)
          ? todaySort as String
          : 'manual',
      todayNotificationLimit:
          ((value['today_notification_limit'] as num?)?.toInt() ?? 5)
              .clamp(1, 8)
              .toInt(),
      lockScreenPolicy:
          {'device_unlock', 'allow_locked', 'morit_pin'}.contains(lockPolicy)
          ? lockPolicy as String
          : 'device_unlock',
      animationsEnabled: value['animations_enabled'] as bool? ?? true,
      completionStyle: {'marker', 'strike', 'dim'}.contains(completionStyle)
          ? completionStyle as String
          : 'marker',
      showFavorites: value['show_favorites'] as bool? ?? true,
      favoriteLimit: ((value['favorite_limit'] as num?)?.toInt() ?? 4)
          .clamp(1, 8)
          .toInt(),
      folderSort: {'manual', 'name'}.contains(folderSort)
          ? folderSort as String
          : 'manual',
      compactUi: value['compact_ui'] as bool? ?? false,
      overlayEnabled: value['overlay_enabled'] as bool? ?? true,
      downloadWifiOnly: value['download_wifi_only'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'carry_over_incomplete': carryOverIncomplete,
    'show_completed_today': showCompletedToday,
    'today_sort': todaySort,
    'today_notification_limit': todayNotificationLimit,
    'lock_screen_policy': lockScreenPolicy,
    'animations_enabled': animationsEnabled,
    'completion_style': completionStyle,
    'show_favorites': showFavorites,
    'favorite_limit': favoriteLimit,
    'folder_sort': folderSort,
    'compact_ui': compactUi,
    'overlay_enabled': overlayEnabled,
    'download_wifi_only': downloadWifiOnly,
  };

  Map<String, dynamic> toRemote() => Map<String, dynamic>.from(toJson())
    ..remove('lock_screen_policy')
    ..remove('overlay_enabled');
}

class Folder {
  Folder({
    required this.id,
    required this.userId,
    required this.name,
    required this.color,
    required this.createdAt,
    required this.updatedAt,
    this.parentId,
    this.position = 0,
    this.dirty = true,
    this.deleted = false,
  });

  final String id;
  final String userId;
  String name;
  int color;
  String? parentId;
  int position;
  DateTime createdAt;
  DateTime updatedAt;
  bool dirty;
  bool deleted;

  factory Folder.fromJson(Map<String, dynamic> json, {bool remote = false}) =>
      Folder(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        name: json['name'] as String,
        color: (json['color'] as num?)?.toInt() ?? 0xFF167C6A,
        parentId: json['parent_id'] as String?,
        position: (json['position'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
        dirty: remote ? false : json['dirty'] as bool? ?? false,
        deleted: remote ? false : json['deleted'] as bool? ?? false,
      );

  Map<String, dynamic> toRemote() => {
    'id': id,
    'user_id': userId,
    'name': name,
    'color': color,
    'parent_id': parentId,
    'position': position,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toJson() => {
    ...toRemote(),
    'dirty': dirty,
    'deleted': deleted,
  };
}

class MoritItem {
  MoritItem({
    required this.id,
    required this.userId,
    required this.kind,
    required this.title,
    required this.note,
    required this.createdAt,
    required this.updatedAt,
    this.folderId,
    this.sourceUrl,
    this.storagePath,
    this.localPath,
    this.mimeType,
    this.sizeBytes,
    Map<String, dynamic>? metadata,
    this.favorite = false,
    this.dirty = true,
    this.deleted = false,
  }) : metadata = metadata ?? {};

  final String id;
  final String userId;
  String kind;
  String title;
  String note;
  String? folderId;
  String? sourceUrl;
  String? storagePath;
  String? localPath;
  String? mimeType;
  int? sizeBytes;
  Map<String, dynamic> metadata;
  bool favorite;
  DateTime createdAt;
  DateTime updatedAt;
  bool dirty;
  bool deleted;

  factory MoritItem.fromJson(
    Map<String, dynamic> json, {
    bool remote = false,
  }) => MoritItem(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    kind: json['kind'] as String,
    title: json['title'] as String? ?? '',
    note: json['note'] as String? ?? '',
    folderId: json['folder_id'] as String?,
    sourceUrl: json['source_url'] as String?,
    storagePath: json['storage_path'] as String?,
    localPath: remote ? null : json['local_path'] as String?,
    mimeType: json['mime_type'] as String?,
    sizeBytes: (json['size_bytes'] as num?)?.toInt(),
    metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? const {}),
    favorite: json['is_favorite'] as bool? ?? false,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    dirty: remote ? false : json['dirty'] as bool? ?? false,
    deleted: remote ? false : json['deleted'] as bool? ?? false,
  );

  Map<String, dynamic> toRemote() => {
    'id': id,
    'user_id': userId,
    'folder_id': folderId,
    'kind': kind,
    'title': title,
    'note': note,
    'source_url': sourceUrl,
    'storage_path': storagePath,
    'mime_type': mimeType,
    'size_bytes': sizeBytes,
    'metadata': metadata,
    'is_favorite': favorite,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toJson() => {
    ...toRemote(),
    'local_path': localPath,
    'dirty': dirty,
    'deleted': deleted,
  };
}

class DownloadEntry {
  DownloadEntry({
    required this.id,
    required this.userId,
    required this.sourceUrl,
    required this.title,
    required this.mode,
    required this.createdAt,
    required this.updatedAt,
    this.quality = 'original',
    this.itemId,
    this.state = 'queued',
    this.progress = 0,
    this.nativeId,
    this.localPath,
    this.saveLocation,
    this.fileName,
    this.mimeType,
    this.sizeBytes,
    this.description,
    this.error,
    this.wifiOnly = false,
    this.deviceOwned = true,
    this.backendJobId,
    this.nativeBackendTransferOwned = false,
    this.backendStage,
    this.backendEngine,
    this.backendAssetId,
    this.dirty = true,
  });

  final String id;
  final String userId;
  String sourceUrl;
  final String title;
  final String mode;
  final String quality;
  final String? itemId;
  String state;
  int progress;
  int? nativeId;
  String? localPath;
  String? saveLocation;
  String? fileName;
  String? mimeType;
  int? sizeBytes;
  String? description;
  String? error;
  bool wifiOnly;
  bool deviceOwned;
  String? backendJobId;
  bool nativeBackendTransferOwned;
  String? backendStage;
  String? backendEngine;
  String? backendAssetId;
  DateTime createdAt;
  DateTime updatedAt;
  bool dirty;

  factory DownloadEntry.fromJson(
    Map<String, dynamic> json, {
    bool remote = false,
  }) => DownloadEntry(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    sourceUrl: json['source_url'] as String,
    title: json['title'] as String? ?? '다운로드',
    mode: json['mode'] as String? ?? 'auto',
    quality: json['quality'] as String? ?? 'original',
    itemId: json['item_id'] as String?,
    state: json['state'] as String? ?? 'queued',
    progress: (json['progress'] as num?)?.toInt() ?? 0,
    nativeId: remote ? null : (json['native_id'] as num?)?.toInt(),
    localPath: remote ? null : json['local_path'] as String?,
    saveLocation: remote ? null : json['save_location'] as String?,
    fileName: remote ? null : json['file_name'] as String?,
    mimeType: remote ? null : json['mime_type'] as String?,
    sizeBytes: remote ? null : (json['size_bytes'] as num?)?.toInt(),
    description: remote ? null : json['description'] as String?,
    error: json['error'] as String?,
    wifiOnly: remote ? false : json['wifi_only'] as bool? ?? false,
    deviceOwned: remote
        ? false
        : json['device_owned'] as bool? ??
              (json['native_id'] != null ||
                  json['local_path'] != null ||
                  json['dirty'] == true),
    backendJobId: remote ? null : json['backend_job_id'] as String?,
    nativeBackendTransferOwned: remote
        ? false
        : json['native_backend_transfer_owned'] as bool? ?? false,
    backendStage: remote ? null : json['backend_stage'] as String?,
    backendEngine: remote ? null : json['backend_engine'] as String?,
    backendAssetId: remote ? null : json['backend_asset_id'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    dirty: remote ? false : json['dirty'] as bool? ?? false,
  );

  Map<String, dynamic> toRemote() => {
    'id': id,
    'user_id': userId,
    'item_id': itemId,
    'source_url': sourceUrl,
    'title': title,
    'mode': mode,
    'quality': quality,
    'state': state,
    'progress': progress,
    'error': error,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toJson() => {
    ...toRemote(),
    'title': title,
    'native_id': nativeId,
    'local_path': localPath,
    'save_location': saveLocation,
    'file_name': fileName,
    'mime_type': mimeType,
    'size_bytes': sizeBytes,
    'description': description,
    'wifi_only': wifiOnly,
    'device_owned': deviceOwned,
    'backend_job_id': backendJobId,
    'native_backend_transfer_owned': nativeBackendTransferOwned,
    'backend_stage': backendStage,
    'backend_engine': backendEngine,
    'backend_asset_id': backendAssetId,
    'dirty': dirty,
  };
}
