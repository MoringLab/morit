import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:morit/morit/data/morit_attachment_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const userId = '11111111-1111-4111-8111-111111111111';
  const itemId = '22222222-2222-4222-8222-222222222222';
  const attachmentId = '33333333-3333-4333-8333-333333333333';

  test('attachment path is owner scoped, ASCII-only, and traversal safe', () {
    final path = attachmentStoragePath(
      userId: userId,
      itemId: itemId,
      attachmentId: attachmentId,
      fileName: '../../민감한 사진?.jpg',
    );

    expect(path, startsWith('$userId/$itemId/$attachmentId/'));
    expect(path.split('/'), hasLength(4));
    expect(path.split('/').last, 'file.jpg');
    expect(path, matches(RegExp(r'^[a-zA-Z0-9._/-]+$')));
    expect(
      isAttachmentStoragePathSafe(
        path: path,
        userId: userId,
        itemId: itemId,
        attachmentId: attachmentId,
      ),
      isTrue,
    );
    expect(
      isAttachmentStoragePathSafe(
        path: '$userId/$itemId/$attachmentId/한글.jpg',
        userId: userId,
        itemId: itemId,
        attachmentId: attachmentId,
      ),
      isFalse,
    );
    expect(normalizeAttachmentFileName('민감한 사진?.jpg'), '민감한_사진_.jpg');
    expect(attachmentObjectName('문서.한글확장자'), 'file');
    expect(
      () => attachmentStoragePath(
        userId: '../owner',
        itemId: itemId,
        attachmentId: attachmentId,
        fileName: 'a.jpg',
      ),
      throwsFormatException,
    );
  });

  test('remote attachment data never contains a device-local path', () {
    final attachment = MoritAttachment(
      id: attachmentId,
      userId: userId,
      itemId: itemId,
      fileName: 'photo.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 42,
      storagePath: '$userId/$itemId/$attachmentId/photo.jpg',
      uploadState: AttachmentUploadState.uploaded,
      attemptCount: 1,
      position: 0,
      createdAt: DateTime.utc(2026, 7, 23),
      updatedAt: DateTime.utc(2026, 7, 23),
      localPath: r'C:\private\photo.jpg',
    );

    final remote = attachment.toRemote();
    expect(remote, isNot(contains('local_path')));
    expect(attachment.toLocal()['local_path'], r'C:\private\photo.jpg');
    expect(
      MoritAttachment.fromRemote(remote).uploadState,
      same(AttachmentUploadState.uploaded),
    );
  });

  test('automatic upload retries only pending or stale work', () {
    MoritAttachment attachment(AttachmentUploadState state, DateTime updated) =>
        MoritAttachment(
          id: attachmentId,
          userId: userId,
          itemId: itemId,
          fileName: 'photo.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 42,
          storagePath: '$userId/$itemId/$attachmentId/file.jpg',
          uploadState: state,
          attemptCount: 1,
          position: 0,
          createdAt: updated,
          updatedAt: updated,
          localPath: r'C:\private\photo.jpg',
        );

    final now = DateTime.utc(2026, 7, 23, 12);
    expect(
      shouldAutomaticallyUploadAttachment(
        attachment(AttachmentUploadState.pending, now),
        now: now,
      ),
      isTrue,
    );
    expect(
      shouldAutomaticallyUploadAttachment(
        attachment(AttachmentUploadState.failed, now),
        now: now,
      ),
      isFalse,
    );
    expect(
      shouldAutomaticallyUploadAttachment(
        attachment(
          AttachmentUploadState.uploading,
          now.subtract(staleAttachmentUploadAfter),
        ),
        now: now,
      ),
      isTrue,
    );
  });

  test('storage and database failures become actionable safe messages', () {
    expect(
      attachmentFailureReason(
        const StorageException('raw server detail', statusCode: '403'),
      ),
      contains('권한'),
    );
    expect(
      attachmentFailureReason(
        const StorageException(
          'raw server detail',
          error: 'InvalidKey',
          statusCode: '400',
        ),
      ),
      contains('안전한 저장 경로'),
    );
    expect(
      attachmentFailureReason(
        const StorageException(
          'raw server detail',
          error: 'EntityTooLarge',
          statusCode: '413',
        ),
      ),
      contains('서버에서 허용한 최대 크기'),
    );
    expect(
      attachmentFailureReason(
        const PostgrestException(message: 'raw detail', code: '23503'),
      ),
      contains('항목이 아직 동기화'),
    );
    expect(
      attachmentFailureReason(
        const PostgrestException(message: 'secret=must-not-leak'),
      ),
      isNot(contains('must-not-leak')),
    );
  });

  test('large files use 6 MiB resumable chunks and report progress', () async {
    final directory = await Directory.systemTemp.createTemp('morit-tus-');
    final file = File('${directory.path}/large.bin');
    final size = moritResumableChunkBytes + 7;
    final writer = await file.open(mode: FileMode.write);
    await writer.setPosition(size - 1);
    await writer.writeByte(1);
    await writer.close();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var offset = 0;
    var patchCount = 0;
    String? metadata;
    server.listen((request) async {
      if (request.method == 'POST') {
        metadata = request.headers.value('upload-metadata');
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.created
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://${server.address.address}:${server.port}/upload/1',
          )
          ..headers.set('upload-offset', '0');
        await request.response.close();
        return;
      }
      if (request.method == 'PATCH') {
        patchCount++;
        final received = await request.fold<int>(
          0,
          (total, bytes) => total + bytes.length,
        );
        offset += received;
        request.response
          ..statusCode = patchCount == 1
              ? HttpStatus.internalServerError
              : HttpStatus.noContent
          ..headers.set('upload-offset', '$offset');
        await request.response.close();
        return;
      }
      if (request.method == 'HEAD') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('upload-offset', '$offset');
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final progress = <int>[];
    try {
      await uploadMoritFileResumable(
        endpoint: Uri.parse(
          'http://${server.address.address}:${server.port}/storage/v1/'
          'upload/resumable',
        ),
        accessToken: 'test-token',
        file: file,
        storagePath: '$userId/$itemId/$attachmentId/large.bin',
        mimeType: 'application/octet-stream',
        onProgress: (uploaded, _) => progress.add(uploaded),
      );
      expect(patchCount, 2);
      expect(offset, size);
      expect(progress.last, size);
      expect(metadata, contains('bucketName '));
      expect(metadata, contains('objectName '));
    } finally {
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test(
    'migration is lossless, idempotent, and removes anon profile access',
    () {
      final sql = File(
        'supabase/migrations/'
        '202607230008_harden_attachments_and_profiles.sql',
      ).readAsStringSync();

      expect(sql, contains('on conflict (storage_path) do nothing'));
      expect(sql, contains("metadata -> 'legacy_kind'"));
      expect(sql, contains("kind = 'memo'"));
      expect(sql, contains('item.storage_path'));
      expect(sql, isNot(contains('local_path')));
      expect(sql, contains('items_capture_legacy_attachment'));
      expect(
        sql,
        contains(
          'revoke all privileges on table public.profiles from public, anon',
        ),
      );
    },
  );

  test('reminder attachment migration keeps the item ownership trigger', () {
    final sql = File(
      'supabase/migrations/202607230010_allow_reminder_attachments.sql',
    ).readAsStringSync();
    expect(sql, contains("item.kind in ('memo', 'reminder')"));
    expect(sql, contains('item.user_id = new.user_id'));
    expect(sql, contains('revoke all on function'));
  });

  test('shared Storage policies cannot bypass the Morit bucket gate', () {
    final sql = File(
      'supabase/migrations/202607230011_scope_shared_storage_policies.sql',
    ).readAsStringSync();
    expect(sql, contains("bucket_id = 'post-attachments'"));
    expect(sql, contains('"Allow user to delete their own files"'));
    expect(sql, contains('"Allow user to update their own files"'));
  });
}
