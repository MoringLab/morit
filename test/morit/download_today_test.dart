import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morit/morit/morit_controller.dart';
import 'package:morit/morit/platform/morit_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final createdAt = DateTime.utc(2026, 7, 23, 1, 2, 3);

  DownloadEntry download() => DownloadEntry(
    id: 'download-1',
    userId: 'user-1',
    itemId: 'item-1',
    sourceUrl: 'https://cdn.example.com/video.mp4',
    title: '영상',
    mode: 'video',
    quality: '1080p',
    state: 'running',
    progress: 42,
    nativeId: 73,
    localPath: '/private/video.mp4',
    saveLocation: 'Movies/Morit',
    fileName: 'video.mp4',
    mimeType: 'video/mp4',
    sizeBytes: 1048576,
    description: '나중에 보기',
    wifiOnly: true,
    backendJobId: 'job-1',
    nativeBackendTransferOwned: true,
    backendStage: 'merging',
    backendEngine: 'yt-dlp',
    backendAssetId: 'asset-1',
    createdAt: createdAt,
    updatedAt: createdAt.add(const Duration(minutes: 1)),
  );

  MoritItem memo({
    String kind = 'memo',
    bool deleted = false,
    Map<String, dynamic>? metadata,
  }) => MoritItem(
    id: 'item-1',
    userId: 'user-1',
    kind: kind,
    title: '할 일',
    note: '',
    metadata: metadata,
    deleted: deleted,
    createdAt: createdAt,
    updatedAt: createdAt,
  );

  test('DownloadEntry local JSON preserves native download metadata', () {
    final restored = DownloadEntry.fromJson(download().toJson());

    expect(restored.fileName, 'video.mp4');
    expect(restored.mimeType, 'video/mp4');
    expect(restored.sizeBytes, 1048576);
    expect(restored.description, '나중에 보기');
    expect(restored.deviceOwned, isTrue);
    expect(restored.nativeId, 73);
    expect(restored.localPath, '/private/video.mp4');
    expect(restored.saveLocation, 'Movies/Morit');
    expect(restored.wifiOnly, isTrue);
    expect(restored.quality, '1080p');
    expect(restored.backendJobId, 'job-1');
    expect(restored.nativeBackendTransferOwned, isTrue);
    expect(restored.backendStage, 'merging');
    expect(restored.backendEngine, 'yt-dlp');
    expect(restored.backendAssetId, 'asset-1');
    expect(restored.deleted, isFalse);

    final deleted = download()..deleted = true;
    expect(DownloadEntry.fromJson(deleted.toJson()).deleted, isTrue);
  });

  test('DownloadEntry remote JSON excludes device-only fields', () {
    final remote = download().toRemote();

    for (final key in const [
      'native_id',
      'local_path',
      'save_location',
      'file_name',
      'mime_type',
      'size_bytes',
      'description',
      'wifi_only',
      'headers',
      'device_owned',
      'backend_job_id',
      'native_backend_transfer_owned',
      'backend_stage',
      'backend_engine',
      'backend_asset_id',
      'dirty',
      'deleted',
    ]) {
      expect(remote, isNot(contains(key)), reason: '$key must stay local');
    }
    expect(remote['quality'], '1080p');
    expect(DownloadEntry.fromJson(remote, remote: true).deviceOwned, isFalse);
  });

  test('an active server handoff is not treated as a detached download', () {
    final entry = download()
      ..state = 'queued'
      ..nativeId = null
      ..backendJobId = null
      ..deviceOwned = true;

    expect(isDetachedDownload(entry, hasActiveAttempt: true), isFalse);
    expect(isDetachedDownload(entry, hasActiveAttempt: false), isTrue);
  });

  test('download reason messages cover pending, paused and failures', () {
    expect(downloadReasonMessage(1, 0), '시스템에서 시작을 준비하고 있습니다.');
    expect(
      downloadReasonMessage(1, 0, wifiOnly: true),
      'Wi-Fi 또는 비종량 네트워크를 기다리고 있습니다.',
    );
    expect(downloadReasonMessage(4, 1), '네트워크 오류 후 자동 재시도 중입니다.');
    expect(downloadReasonMessage(4, 2), '네트워크 연결을 기다리고 있습니다.');
    expect(downloadReasonMessage(4, 3), 'Wi-Fi 연결을 기다리고 있습니다.');
    expect(downloadReasonMessage(4, 99), '시스템에서 다운로드 재개를 기다리고 있습니다.');
    expect(downloadReasonMessage(16, 404), '서버가 HTTP 404 오류를 반환했습니다.');
    expect(downloadReasonMessage(16, 1006), '기기 저장 공간이 부족합니다.');
    expect(downloadReasonMessage(16, 9999), '알 수 없는 다운로드 오류(9999)입니다.');
    expect(downloadReasonMessage(2, 0), isEmpty);
  });

  test('download file name trusts validated MIME over a stale URL suffix', () {
    expect(
      downloadFileName(
        'id',
        'photo.jpg',
        Uri.parse('https://cdn.example.com/stale.jpg'),
        'image/png',
      ),
      'id_photo.png',
    );
    expect(
      downloadFileName(
        'id',
        'track',
        Uri.parse('https://cdn.example.com/content'),
        'audio/mp4',
      ),
      'id_track.m4a',
    );
  });

  test(
    'pending native jobs stop being treated as active after two minutes',
    () {
      final lastModified = DateTime.utc(2026, 7, 23, 1);

      expect(
        isDownloadStartStalled(
          status: 1,
          bytesDownloaded: 0,
          lastModified: lastModified,
          now: lastModified.add(downloadStartTimeout),
        ),
        isTrue,
      );
      expect(
        isDownloadStartStalled(
          status: 1,
          bytesDownloaded: 1,
          lastModified: lastModified,
          now: lastModified.add(const Duration(hours: 1)),
        ),
        isFalse,
      );
      expect(
        isDownloadStartStalled(
          status: 2,
          bytesDownloaded: 0,
          lastModified: lastModified,
          now: lastModified.add(const Duration(hours: 1)),
        ),
        isFalse,
      );
      expect(
        isDownloadStartStalled(
          status: 1,
          bytesDownloaded: 0,
          lastModified: lastModified,
          wifiOnly: true,
          now: lastModified.add(const Duration(hours: 1)),
        ),
        isFalse,
      );
    },
  );

  test('today membership keeps completed memos until rollover', () {
    expect(isTodayItem(memo(metadata: {'today': true})), isTrue);
    final completed = memo(
      metadata: {'today': true, 'completed_at': '2026-07-23T01:02:03Z'},
    );
    expect(isTodayItem(completed), isTrue);
    expect(isTodayCompleted(completed), isTrue);
    expect(
      isTodayItem(memo(deleted: true, metadata: {'today': true})),
      isFalse,
    );
    expect(isTodayItem(memo(kind: 'link', metadata: {'today': true})), isFalse);
    expect(isTodayItem(memo(metadata: {'today': false})), isFalse);
  });

  test(
    'platform serializes download and today notification arguments',
    () async {
      const channel = MethodChannel('com.luverse.morit/native');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'enqueueDownload' => {'id': 73, 'saveLocation': 'Movies/Morit'},
              'setTodayTasks' => true,
              'deleteOwnedFile' => true,
              'readTodayActions' => [
                {
                  'id': 'action-1',
                  'userId': 'user-1',
                  'itemId': 'item-1',
                  'type': 'complete',
                  'createdAt': 1784768523000,
                },
              ],
              _ => null,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      const platform = MoritPlatform();
      final job = await platform.enqueueDownload(
        url: Uri.parse('https://cdn.example.com/video.mp4'),
        fileName: 'video.mp4',
        title: '영상',
        mediaKind: 'video',
        description: '나중에 보기',
        mimeType: 'video/mp4',
        expectedContentLength: 1048576,
        wifiOnly: true,
        headers: const {'Referer': 'https://example.com/watch/1'},
      );
      final todayPosted = await platform.setTodayTasks(
        userId: 'user-1',
        tasks: const [
          {
            'id': 'item-1',
            'text': '장보기',
            'completed': true,
            'dayKey': '2026-07-23',
          },
        ],
        maxVisible: 8,
        showCompleted: false,
        carryOverIncomplete: false,
        lockPolicy: 'morit_pin',
        overlayEnabled: false,
      );
      final actions = await platform.readTodayActions('user-1');
      await platform.ackTodayActions('user-1', ['action-1']);
      await platform.clearTodayNotification();

      expect(job?.id, 73);
      expect(job?.saveLocation, 'Movies/Morit');
      expect(todayPosted, isTrue);
      expect(calls[0].method, 'enqueueDownload');
      expect(calls[0].arguments, {
        'url': 'https://cdn.example.com/video.mp4',
        'fileName': 'video.mp4',
        'mediaKind': 'video',
        'mimeType': 'video/mp4',
        'title': '영상',
        'description': '나중에 보기',
        'expectedContentLength': 1048576,
        'wifiOnly': true,
        'headers': {'Referer': 'https://example.com/watch/1'},
      });
      expect(calls[1], isA<MethodCall>());
      expect(calls[1].method, 'setTodayTasks');
      expect(calls[1].arguments, {
        'userId': 'user-1',
        'tasks': [
          {
            'id': 'item-1',
            'text': '장보기',
            'completed': true,
            'dayKey': '2026-07-23',
          },
        ],
        'maxVisible': 8,
        'showCompleted': false,
        'carryOverIncomplete': false,
        'lockPolicy': 'morit_pin',
        'overlayEnabled': false,
      });
      expect(actions.single['type'], 'complete');
      expect(calls[3].arguments, {
        'userId': 'user-1',
        'ids': ['action-1'],
      });
      expect(calls[4].method, 'clearTodayNotification');
    },
  );

  test('platform rejects credential-bearing download headers', () async {
    const platform = MoritPlatform();

    await expectLater(
      platform.enqueueDownload(
        url: Uri.parse('https://cdn.example.com/video.mp4'),
        fileName: 'video.mp4',
        title: '영상',
        mediaKind: 'video',
        headers: const {'Authorization': 'Bearer secret'},
      ),
      throwsArgumentError,
    );
  });

  test('platform rejects a non-positive expected content length', () async {
    await expectLater(
      const MoritPlatform().enqueueDownload(
        url: Uri.parse('https://cdn.example.com/video.mp4'),
        fileName: 'video.mp4',
        title: '영상',
        mediaKind: 'video',
        expectedContentLength: 0,
      ),
      throwsArgumentError,
    );
  });

  test('platform serializes native backend transfer ownership calls', () async {
    const channel = MethodChannel('com.luverse.morit/native');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'scheduleBackendTransfer' => true,
            'queryBackendTransfer' => {
              'status': 'device_queued',
              'nativeId': 91,
              'saveLocation': 'Movies/Morit',
            },
            'cancelBackendTransfer' => true,
            _ => null,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    const platform = MoritPlatform();
    final scheduled = await platform.scheduleBackendTransfer(
      statusUrl: Uri.parse(
        'https://download.example.com/v1/transfers/'
        '0123456789abcdef0123456789abcdef?ticket='
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ',
      ),
      backendJobId: '0123456789abcdef0123456789abcdef',
      title: '영상',
      description: '나중에 보기',
      wifiOnly: true,
    );
    final status = await platform.queryBackendTransfer(
      '0123456789abcdef0123456789abcdef',
    );
    final canceled = await platform.cancelBackendTransfer(
      '0123456789abcdef0123456789abcdef',
    );

    expect(scheduled, isTrue);
    expect(status?['nativeId'], 91);
    expect(canceled, isTrue);
    expect(calls[0].method, 'scheduleBackendTransfer');
    expect(calls[0].arguments, {
      'statusUrl':
          'https://download.example.com/v1/transfers/'
          '0123456789abcdef0123456789abcdef?ticket='
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ',
      'backendJobId': '0123456789abcdef0123456789abcdef',
      'title': '영상',
      'description': '나중에 보기',
      'wifiOnly': true,
    });
    expect(calls[1].method, 'queryBackendTransfer');
    expect(calls[2].method, 'cancelBackendTransfer');
  });

  test('platform copies content URI with bounded size and file name', () async {
    const channel = MethodChannel('com.luverse.morit/native');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return '/app/shared/share-1.jpg';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final path = await const MoritPlatform().copySharedContentUri(
      'content://downloads/public/73',
      maxBytes: 1024,
      fileName: 'photo.jpg',
    );

    expect(path, '/app/shared/share-1.jpg');
    expect(received?.method, 'copyContentUriToAppFiles');
    expect(received?.arguments, {
      'uri': 'content://downloads/public/73',
      'maxBytes': 1024,
      'fileName': 'photo.jpg',
    });
  });

  test('platform opens completed downloads by native id', () async {
    const channel = MethodChannel('com.luverse.morit/native');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    expect(
      await const MoritPlatform().openDownload(73, mimeType: 'video/mp4'),
      isTrue,
    );
    expect(received?.method, 'openDownload');
    expect(received?.arguments, {'id': 73, 'mimeType': 'video/mp4'});
  });
}
