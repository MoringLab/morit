import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

const moritFilesBucket = 'morit-files';
const maxMoritAttachmentBytes = 500 * 1024 * 1024;
// Compatibility for existing UI/cache code while attachments move to this
// module. New code should use maxMoritAttachmentBytes.
const maxSyncedFileBytes = maxMoritAttachmentBytes;
const moritResumableChunkBytes = 6 * 1024 * 1024;
const staleAttachmentUploadAfter = Duration(minutes: 15);

enum AttachmentUploadState { pending, uploading, uploaded, failed, deleting }

class MoritAttachment {
  const MoritAttachment({
    required this.id,
    required this.userId,
    required this.itemId,
    required this.fileName,
    required this.mimeType,
    required this.storagePath,
    required this.uploadState,
    required this.attemptCount,
    required this.position,
    required this.createdAt,
    required this.updatedAt,
    this.sizeBytes,
    this.lastError,
    this.localPath,
  });

  final String id;
  final String userId;
  final String itemId;
  final String fileName;
  final String mimeType;
  final int? sizeBytes;
  final String storagePath;
  final AttachmentUploadState uploadState;
  final String? lastError;
  final String? localPath;
  final int attemptCount;
  final int position;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory MoritAttachment.fromRemote(
    Map<String, dynamic> json, {
    String? localPath,
  }) {
    return MoritAttachment(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      itemId: json['item_id'] as String,
      fileName: json['file_name'] as String,
      mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
      storagePath: json['storage_path'] as String,
      uploadState: AttachmentUploadState.values.byName(
        json['upload_state'] as String? ?? 'pending',
      ),
      lastError: json['last_error'] as String?,
      localPath: localPath,
      attemptCount: (json['attempt_count'] as num?)?.toInt() ?? 0,
      position: (json['position'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  factory MoritAttachment.fromLocal(Map<String, dynamic> json) =>
      MoritAttachment.fromRemote(
        json,
        localPath: json['local_path'] as String?,
      );

  Map<String, dynamic> toRemote() => {
    'id': id,
    'user_id': userId,
    'item_id': itemId,
    'file_name': fileName,
    'mime_type': mimeType,
    'size_bytes': sizeBytes,
    'storage_path': storagePath,
    'upload_state': uploadState.name,
    'last_error': lastError,
    'attempt_count': attemptCount,
    'position': position,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toLocal() => {...toRemote(), 'local_path': localPath};
}

bool shouldAutomaticallyUploadAttachment(
  MoritAttachment attachment, {
  DateTime? now,
}) {
  if (attachment.localPath == null) return false;
  if (attachment.uploadState == AttachmentUploadState.pending) return true;
  return attachment.uploadState == AttachmentUploadState.uploading &&
      (now ?? DateTime.now().toUtc()).difference(attachment.updatedAt) >=
          staleAttachmentUploadAfter;
}

class AttachmentUploadException implements Exception {
  const AttachmentUploadException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

String normalizeAttachmentFileName(String value) {
  final cleaned = value.trim().replaceAll(
    RegExp(r'[^\p{L}\p{N}._-]', unicode: true),
    '_',
  );
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'attachment';
  return cleaned.substring(0, cleaned.length.clamp(0, 100));
}

String attachmentObjectName(String fileName) {
  final displayName = normalizeAttachmentFileName(fileName);
  final dot = displayName.lastIndexOf('.');
  if (dot <= 0 || dot == displayName.length - 1) return 'file';
  final extension = displayName
      .substring(dot + 1)
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]'), '');
  if (extension.isEmpty) return 'file';
  return 'file.${extension.substring(0, extension.length.clamp(0, 12))}';
}

String attachmentStoragePath({
  required String userId,
  required String itemId,
  required String attachmentId,
  required String fileName,
}) {
  for (final id in [userId, itemId, attachmentId]) {
    if (!Uuid.isValidUUIDFormat(fromString: id)) {
      throw const FormatException('첨부 파일 식별자가 올바르지 않습니다.');
    }
  }
  return '$userId/$itemId/$attachmentId/'
      '${attachmentObjectName(fileName)}';
}

bool isAttachmentStoragePathSafe({
  required String path,
  required String userId,
  required String itemId,
  required String attachmentId,
}) {
  final parts = path.split('/');
  return parts.length == 4 &&
      parts[0] == userId &&
      parts[1] == itemId &&
      parts[2] == attachmentId &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(parts[3]);
}

String attachmentFailureReason(Object error) {
  if (error is AttachmentUploadException) return error.message;
  if (error is StorageException) {
    final storageCode = (error.error ?? '').toLowerCase().replaceAll(
      RegExp('[^a-z0-9]'),
      '',
    );
    if (storageCode == 'invalidkey') {
      return '파일 이름을 안전한 저장 경로로 만들지 못했습니다. 앱을 업데이트한 뒤 다시 시도해 주세요.';
    }
    if (storageCode == 'invalidmimetype') {
      return '파일 형식 정보가 올바르지 않습니다. 다른 파일을 선택하거나 다시 시도해 주세요.';
    }
    if (storageCode == 'invalidrequest' ||
        storageCode == 'missingparameter' ||
        storageCode == 'missingcontentlength') {
      return '파일 업로드 요청 형식이 올바르지 않습니다. 앱을 업데이트한 뒤 다시 시도해 주세요.';
    }
    if (storageCode == 'entitytoolarge') {
      return '파일이 서버에서 허용한 최대 크기를 초과했습니다.';
    }
    if (storageCode == 'nosuchbucket') {
      return '파일 저장소 구성이 없습니다. 관리자 확인이 필요합니다.';
    }
    if (storageCode == 'accessdenied' || storageCode == 'invalidjwt') {
      return '파일 저장 권한이 없습니다. 다시 로그인해 주세요.';
    }
    if (storageCode == 'slowdown') {
      return '업로드 요청이 많아 잠시 제한되었습니다. 잠시 후 다시 시도해 주세요.';
    }
    return switch (error.statusCode) {
      '401' || '403' => '파일 저장 권한이 없습니다. 다시 로그인해 주세요.',
      '400' => '파일 이름·형식 또는 업로드 요청이 저장소 규칙에 맞지 않습니다.',
      '404' => '파일 저장소 구성이 없습니다. 앱 업데이트 또는 관리자 확인이 필요합니다.',
      '409' => '같은 파일 경로가 이미 사용 중입니다. 다시 시도해 주세요.',
      '413' => '파일이 서버에서 허용한 최대 크기를 초과했습니다.',
      '429' => '업로드 요청이 많아 잠시 제한되었습니다. 잠시 후 다시 시도해 주세요.',
      _ => '파일 저장소에 업로드하지 못했습니다. 네트워크를 확인해 다시 시도해 주세요.',
    };
  }
  if (error is PostgrestException) {
    return switch (error.code) {
      '42501' => '첨부 파일 데이터 저장 권한이 없습니다. 다시 로그인해 주세요.',
      '23503' => '항목이 아직 동기화되지 않았습니다. 저장 후 다시 시도해 주세요.',
      '23505' => '같은 첨부 파일이 이미 등록되어 있습니다.',
      '23514' => '첨부 파일 정보가 허용 범위를 벗어났습니다.',
      '42P01' || 'PGRST205' => '첨부 파일 데이터베이스 구성이 필요합니다.',
      _ => '첨부 파일 정보를 저장하지 못했습니다. 다시 시도해 주세요.',
    };
  }
  if (error is FileSystemException) {
    return '기기의 파일을 읽을 수 없습니다. 파일 권한과 저장 공간을 확인해 주세요.';
  }
  if (error is SocketException) {
    return '네트워크에 연결할 수 없습니다. 연결 후 다시 시도해 주세요.';
  }
  return '첨부 파일을 저장하지 못했습니다. 다시 시도해 주세요.';
}

Future<void> uploadMoritFileResumable({
  required Uri endpoint,
  required String accessToken,
  required File file,
  required String storagePath,
  required String mimeType,
  void Function(int uploadedBytes, int totalBytes)? onProgress,
  HttpClient? httpClient,
}) async {
  final loopback =
      endpoint.scheme == 'http' &&
      {'localhost', '127.0.0.1', '::1'}.contains(endpoint.host);
  if ((endpoint.scheme != 'https' && !loopback) ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.host.isEmpty ||
      accessToken.isEmpty ||
      accessToken.contains(RegExp(r'[\r\n]'))) {
    throw const AttachmentUploadException(
      'invalid_resumable_endpoint',
      '안전한 대용량 업로드 연결을 만들 수 없습니다.',
    );
  }
  final size = await file.length();
  final client = httpClient ?? HttpClient();
  try {
    final create = await client.postUrl(endpoint);
    create.followRedirects = false;
    create.contentLength = 0;
    _setTusHeaders(create, accessToken);
    create.headers
      ..set('Upload-Length', '$size')
      ..set(
        'Upload-Metadata',
        _tusMetadata({
          'bucketName': moritFilesBucket,
          'objectName': storagePath,
          'contentType': mimeType,
          'cacheControl': '3600',
        }),
      )
      ..set('x-upsert', 'true');
    final created = await create.close();
    if (created.statusCode != HttpStatus.created) {
      throw await _storageResponseException(
        created,
        'Resumable upload creation failed',
      );
    }
    await created.drain<void>();
    final location = created.headers.value(HttpHeaders.locationHeader);
    final offsetHeader = created.headers.value('upload-offset');
    final uploadUri = location == null ? null : endpoint.resolve(location);
    if (uploadUri == null ||
        uploadUri.scheme != endpoint.scheme ||
        uploadUri.host != endpoint.host ||
        uploadUri.port != endpoint.port) {
      throw const AttachmentUploadException(
        'invalid_upload_location',
        '대용량 업로드 주소가 안전하지 않습니다.',
      );
    }
    var offset = int.tryParse(offsetHeader ?? '') ?? 0;
    if (offset < 0 || offset > size) {
      throw const AttachmentUploadException(
        'invalid_upload_offset',
        '대용량 업로드 위치가 올바르지 않습니다.',
      );
    }
    onProgress?.call(offset, size);

    while (offset < size) {
      final end = math.min(offset + moritResumableChunkBytes, size);
      Object? lastError;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final patch = await client.patchUrl(uploadUri);
          patch.followRedirects = false;
          patch.contentLength = end - offset;
          _setTusHeaders(patch, accessToken);
          patch.headers
            ..set('Upload-Offset', '$offset')
            ..contentType = ContentType('application', 'offset+octet-stream');
          await patch.addStream(file.openRead(offset, end));
          final response = await patch.close();
          if (response.statusCode != HttpStatus.noContent) {
            throw await _storageResponseException(
              response,
              'Resumable upload chunk failed',
            );
          }
          await response.drain<void>();
          final next = int.tryParse(
            response.headers.value('upload-offset') ?? '',
          );
          if (next == null || next <= offset || next > size) {
            throw const AttachmentUploadException(
              'invalid_upload_offset',
              '대용량 업로드 응답이 올바르지 않습니다.',
            );
          }
          offset = next;
          onProgress?.call(offset, size);
          lastError = null;
          break;
        } on Object catch (error) {
          lastError = error;
          if (attempt == 2) break;
          try {
            final recovered = await _tusOffset(
              client,
              uploadUri,
              accessToken,
              size,
            );
            if (recovered > offset) {
              offset = recovered;
              onProgress?.call(offset, size);
              lastError = null;
              break;
            }
          } on Object {
            // Retry the same chunk; the final attempt reports a safe error.
          }
        }
      }
      if (lastError != null) throw lastError;
    }
  } finally {
    if (httpClient == null) client.close(force: true);
  }
}

void _setTusHeaders(HttpClientRequest request, String accessToken) {
  request.headers
    ..set('Tus-Resumable', '1.0.0')
    ..set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
}

Future<StorageException> _storageResponseException(
  HttpClientResponse response,
  String fallbackMessage,
) async {
  try {
    final body = await utf8.decoder.bind(response).join();
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final data = Map<String, dynamic>.from(decoded);
      return StorageException(
        data['message']?.toString() ?? fallbackMessage,
        error: (data['code'] ?? data['error'])?.toString(),
        statusCode: data['statusCode']?.toString() ?? '${response.statusCode}',
      );
    }
  } on Object {
    // The HTTP status is still enough to provide a safe, actionable message.
  }
  return StorageException(
    fallbackMessage,
    statusCode: '${response.statusCode}',
  );
}

String _tusMetadata(Map<String, String> values) => values.entries
    .map((entry) => '${entry.key} ${base64.encode(utf8.encode(entry.value))}')
    .join(',');

Future<int> _tusOffset(
  HttpClient client,
  Uri uploadUri,
  String accessToken,
  int size,
) async {
  final head = await client.headUrl(uploadUri);
  head.followRedirects = false;
  _setTusHeaders(head, accessToken);
  final response = await head.close();
  if (response.statusCode != HttpStatus.ok &&
      response.statusCode != HttpStatus.noContent) {
    throw await _storageResponseException(
      response,
      'Resumable upload status failed',
    );
  }
  await response.drain<void>();
  final offset = int.tryParse(response.headers.value('upload-offset') ?? '');
  if (offset == null || offset < 0 || offset > size) {
    throw const AttachmentUploadException(
      'invalid_upload_offset',
      '대용량 업로드 위치가 올바르지 않습니다.',
    );
  }
  return offset;
}

class MoritAttachmentStore {
  const MoritAttachmentStore(this._client);

  final SupabaseClient _client;

  Future<List<MoritAttachment>> listForUser(
    String userId, {
    Map<String, String> localPathsByAttachmentId = const {},
    Map<String, String> localPathsByStoragePath = const {},
  }) async {
    _requireUser(userId);
    const pageSize = 500;
    final attachments = <MoritAttachment>[];
    for (var offset = 0; ; offset += pageSize) {
      final rows = await _client
          .schema('morit')
          .from('attachments')
          .select()
          .eq('user_id', userId)
          .order('position')
          .order('created_at')
          .order('id')
          .range(offset, offset + pageSize - 1);
      final page = (rows as List).map((value) {
        final data = Map<String, dynamic>.from(value as Map);
        return MoritAttachment.fromRemote(
          data,
          localPath:
              localPathsByAttachmentId[data['id'] as String] ??
              localPathsByStoragePath[data['storage_path'] as String],
        );
      }).toList();
      attachments.addAll(page);
      if (page.length < pageSize) return attachments;
    }
  }

  Future<MoritAttachment> upload({
    required String userId,
    required String itemId,
    required String attachmentId,
    required File file,
    required String fileName,
    String? mimeType,
    int position = 0,
    void Function(int uploadedBytes, int totalBytes)? onProgress,
  }) async {
    _requireUser(userId);
    var path = attachmentStoragePath(
      userId: userId,
      itemId: itemId,
      attachmentId: attachmentId,
      fileName: fileName,
    );
    if (position < 0) {
      throw const FormatException('첨부 파일 순서는 0 이상이어야 합니다.');
    }
    if (!await file.exists()) {
      throw const AttachmentUploadException(
        'file_missing',
        '기기의 첨부 파일을 찾을 수 없습니다.',
      );
    }
    final size = await file.length();
    if (size > maxMoritAttachmentBytes) {
      throw const AttachmentUploadException(
        'file_too_large',
        '첨부 파일은 500 MiB 이하여야 합니다.',
      );
    }
    final contentType = _contentType(mimeType);
    final existing = await _client
        .schema('morit')
        .from('attachments')
        .select()
        .eq('id', attachmentId)
        .eq('user_id', userId)
        .maybeSingle();
    if (existing != null) {
      final attachment = MoritAttachment.fromRemote(existing);
      if (attachment.itemId != itemId ||
          !attachment.storagePath.startsWith('$userId/$itemId/')) {
        throw const AttachmentUploadException(
          'attachment_conflict',
          '첨부 파일 식별자가 다른 파일에 이미 사용 중입니다.',
        );
      }
      if (attachment.uploadState == AttachmentUploadState.uploaded) {
        return attachment;
      }
      if (isAttachmentStoragePathSafe(
        path: attachment.storagePath,
        userId: userId,
        itemId: itemId,
        attachmentId: attachmentId,
      )) {
        path = attachment.storagePath;
      }
      if (attachment.uploadState == AttachmentUploadState.uploading &&
          DateTime.now().toUtc().difference(attachment.updatedAt) <
              staleAttachmentUploadAfter) {
        throw const AttachmentUploadException(
          'upload_in_progress',
          '이 첨부 파일은 이미 업로드 중입니다.',
        );
      }
      // ponytail: a 15-minute lease is enough for the serialized client sync;
      // replace it with a server lease only if concurrent writers are added.
      if (attachment.uploadState == AttachmentUploadState.deleting) {
        throw const AttachmentUploadException(
          'delete_in_progress',
          '이 첨부 파일은 삭제 중입니다.',
        );
      }
    }

    final now = DateTime.now().toUtc();
    final attempt = existing == null
        ? 1
        : ((existing['attempt_count'] as num?)?.toInt() ?? 0) + 1;
    final attachment = MoritAttachment(
      id: attachmentId,
      userId: userId,
      itemId: itemId,
      fileName: normalizeAttachmentFileName(fileName),
      mimeType: contentType,
      sizeBytes: size,
      storagePath: path,
      uploadState: AttachmentUploadState.uploading,
      attemptCount: attempt,
      position: position,
      createdAt: existing == null
          ? now
          : DateTime.parse(existing['created_at'] as String),
      updatedAt: now,
      localPath: file.path,
    );

    try {
      await _client
          .schema('morit')
          .from('attachments')
          .upsert(attachment.toRemote(), onConflict: 'id');
    } on Object catch (error) {
      throw AttachmentUploadException(
        'metadata_start_failed',
        attachmentFailureReason(error),
      );
    }

    try {
      if (size > moritResumableChunkBytes) {
        final token = _client.auth.currentSession?.accessToken;
        if (token == null) {
          throw const AttachmentUploadException(
            'authentication_required',
            '첨부 파일을 저장하려면 다시 로그인해 주세요.',
          );
        }
        final storageUrl = _client.storage.url.replaceFirst(RegExp(r'/$'), '');
        await uploadMoritFileResumable(
          endpoint: Uri.parse('$storageUrl/upload/resumable'),
          accessToken: token,
          file: file,
          storagePath: path,
          mimeType: contentType,
          onProgress: onProgress,
        );
      } else {
        await _client.storage
            .from(moritFilesBucket)
            .upload(
              path,
              file,
              fileOptions: FileOptions(upsert: true, contentType: contentType),
              retryAttempts: 2,
            );
        onProgress?.call(size, size);
      }
    } on Object catch (error) {
      await _compensateFailedUpload(attachmentId, userId, path, error);
      throw AttachmentUploadException(
        'storage_upload_failed',
        attachmentFailureReason(error),
      );
    }

    try {
      final finalized = await _client
          .schema('morit')
          .from('attachments')
          .update({
            'upload_state': AttachmentUploadState.uploaded.name,
            'last_error': null,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', attachmentId)
          .eq('user_id', userId)
          .select('id')
          .maybeSingle();
      if (finalized == null) {
        throw const AttachmentUploadException(
          'metadata_missing',
          '업로드 중 첨부 파일 정보가 삭제되었습니다.',
        );
      }
    } on Object catch (error) {
      await _compensateFailedUpload(attachmentId, userId, path, error);
      throw AttachmentUploadException(
        'metadata_finalize_failed',
        attachmentFailureReason(error),
      );
    }

    return MoritAttachment(
      id: attachment.id,
      userId: attachment.userId,
      itemId: attachment.itemId,
      fileName: attachment.fileName,
      mimeType: attachment.mimeType,
      sizeBytes: attachment.sizeBytes,
      storagePath: attachment.storagePath,
      uploadState: AttachmentUploadState.uploaded,
      attemptCount: attachment.attemptCount,
      position: attachment.position,
      createdAt: attachment.createdAt,
      updatedAt: DateTime.now().toUtc(),
      localPath: file.path,
    );
  }

  Future<void> delete({
    required String userId,
    required String attachmentId,
  }) async {
    _requireUser(userId);
    final row = await _client
        .schema('morit')
        .from('attachments')
        .select()
        .eq('id', attachmentId)
        .eq('user_id', userId)
        .maybeSingle();
    if (row == null) return;
    final attachment = MoritAttachment.fromRemote(row);
    if (!attachment.storagePath.startsWith('$userId/')) {
      throw const AttachmentUploadException(
        'invalid_owner_path',
        '계정 소유 경로가 아닌 첨부 파일은 삭제할 수 없습니다.',
      );
    }
    await _client
        .schema('morit')
        .from('attachments')
        .update({
          'upload_state': AttachmentUploadState.deleting.name,
          'last_error': null,
        })
        .eq('id', attachmentId)
        .eq('user_id', userId);
    try {
      await _client.storage.from(moritFilesBucket).remove([
        attachment.storagePath,
      ]);
      await _client
          .schema('morit')
          .from('attachments')
          .delete()
          .eq('id', attachmentId)
          .eq('user_id', userId);
    } on Object catch (error) {
      await _markFailed(attachmentId, userId, error);
      throw AttachmentUploadException(
        'attachment_delete_failed',
        attachmentFailureReason(error),
      );
    }
  }

  Future<void> _compensateFailedUpload(
    String attachmentId,
    String userId,
    String path,
    Object error,
  ) async {
    try {
      await _client.storage.from(moritFilesBucket).remove([path]);
    } on Object {
      // Preserve the upload failure: cleanup is best-effort compensation.
    }
    await _markFailed(attachmentId, userId, error);
  }

  Future<void> _markFailed(
    String attachmentId,
    String userId,
    Object error,
  ) async {
    try {
      await _client
          .schema('morit')
          .from('attachments')
          .update({
            'upload_state': AttachmentUploadState.failed.name,
            'last_error': attachmentFailureReason(error),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', attachmentId)
          .eq('user_id', userId);
    } on Object {
      // The original operation is the actionable failure; never mask it.
    }
  }

  void _requireUser(String userId) {
    if (!Uuid.isValidUUIDFormat(fromString: userId) ||
        _client.auth.currentUser?.id != userId) {
      throw const AttachmentUploadException(
        'authentication_required',
        '첨부 파일을 저장하려면 다시 로그인해 주세요.',
      );
    }
  }

  String _contentType(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null ||
        normalized.length > 255 ||
        !normalized.contains('/') ||
        normalized.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return 'application/octet-stream';
    }
    return normalized;
  }
}
