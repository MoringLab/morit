import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morit/main.dart' show DownloadsPage;
import 'package:morit/morit/morit_controller.dart';
import 'package:morit/morit/today/today_overlay.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

AppController testController() => AppController(
  supabase: SupabaseClient(
    'https://example.supabase.co',
    'test-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  ),
);

DownloadEntry downloadEntry({
  required String id,
  required String sourceUrl,
  String state = 'completed',
  bool deviceOwned = true,
}) {
  final now = DateTime.utc(2026, 7, 26, 1);
  return DownloadEntry(
    id: id,
    userId: 'user',
    sourceUrl: sourceUrl,
    title: id,
    mode: 'proxy',
    state: state,
    localPath: deviceOwned ? '/storage/emulated/0/Download/$id.mp4' : null,
    deviceOwned: deviceOwned,
    createdAt: now.add(Duration(minutes: int.parse(id.split('-').last))),
    updatedAt: now,
  );
}

void main() {
  test(
    'shared content is classified without mistaking plain text for a link',
    () {
      expect(inferKind('text/plain', 'https://example.com/a'), 'link');
      expect(inferKind('text/plain', '설명 https://example.com/a.'), 'link');
      expect(
        extractWebUrl('설명 https://example.com/a.'),
        'https://example.com/a',
      );
      expect(inferKind('text/plain', 'buy milk'), 'memo');
      expect(inferKind('image/jpeg', 'content://photo/1'), 'photo');
      expect(inferKind('video/mp4', 'content://video/1'), 'video');
      expect(inferKind('application/pdf', 'content://file/1'), 'file');
    },
  );

  test('download filenames are bounded and filesystem-safe', () {
    expect(safeFileName('a/b:c?.pdf'), 'a_b_c_.pdf');
    expect(safeFileName('x' * 150).length, 100);
  });

  test('UUID reminder IDs are stable and fit Android request codes', () {
    expect(
      nativeReminderId('ffffffff-ffff-ffff-ffff-ffffffffffff'),
      2147483647,
    );
    expect(nativeReminderId('00000001-0000-0000-0000-000000000000'), 1);
  });

  test('attachments are limited to memo-backed item types', () {
    expect(supportsAttachments('memo'), isTrue);
    expect(supportsAttachments('reminder'), isTrue);
    expect(supportsAttachments('link'), isFalse);
    expect(supportsAttachments('photo'), isFalse);
  });

  testWidgets('completed marker covers every visible text line', (
    tester,
  ) async {
    final controller = testController();
    addTearDown(controller.dispose);
    final now = DateTime.now().toUtc();
    final item = MoritItem(
      id: 'item',
      userId: 'user',
      kind: 'memo',
      title: '두 줄 이상으로 표시되는 긴 오늘 할 일 제목입니다',
      note: '',
      metadata: {'today': true, 'completed_at': now.toIso8601String()},
      createdAt: now,
      updatedAt: now,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: TodayTaskRow(
              item: item,
              controller: controller,
              allowFolderDrag: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final marker = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .where((painter) => painter.runtimeType.toString() == '_MarkerPainter')
        .single;
    expect((marker as dynamic).rects.length, greaterThan(2));
  });

  testWidgets('today overlay never exposes tasks without a policy payload', (
    tester,
  ) async {
    const channel = MethodChannel('com.luverse.morit/today_overlay');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final controller = testController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: TodayOverlayPage(
          controller: controller,
          route: '/today-overlay/list',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('잠금화면 정책을 확인하지 못했습니다'), findsOneWidget);
    expect(find.text('오늘 할 일'), findsNothing);
  });

  test(
    'history deletion keeps the downloaded file and skips active work',
    () async {
      final controller = testController();
      addTearDown(controller.dispose);
      final completed = downloadEntry(
        id: 'download-1',
        sourceUrl: 'https://youtu.be/public',
      );
      final active = downloadEntry(
        id: 'download-2',
        sourceUrl: 'https://threads.com/@morit/post/public',
        state: 'running',
      );
      controller.downloads = [completed, active];

      expect(await controller.deleteDownloadRecords([completed, active]), 1);
      expect(completed.deleted, isTrue);
      expect(completed.localPath, contains('/Download/download-1.mp4'));
      expect(controller.visibleDownloads, [active]);
      expect(await controller.deleteDownloadRecords([active]), 0);
    },
  );

  testWidgets('download tabs only show platforms that have history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = testController();
    addTearDown(controller.dispose);
    controller.downloads = [
      downloadEntry(
        id: 'download-1',
        sourceUrl: 'https://youtube.com/watch?v=one',
      ),
      downloadEntry(id: 'download-2', sourceUrl: 'https://youtu.be/two'),
      downloadEntry(
        id: 'download-3',
        sourceUrl: 'https://threads.com/@morit/post/three',
      ),
      downloadEntry(
        id: 'download-4',
        sourceUrl: 'https://unknown.example/media/four',
      ),
      downloadEntry(
        id: 'download-5',
        sourceUrl: 'https://instagram.com/p/active',
        state: 'running',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DownloadsPage(controller: controller)),
      ),
    );
    await tester.pump();

    expect(find.text('전체 4'), findsOneWidget);
    expect(find.text('YouTube 2'), findsOneWidget);
    expect(find.text('Threads 1'), findsOneWidget);
    expect(find.text('기타 1'), findsOneWidget);
    expect(find.textContaining('Instagram '), findsNothing);

    await tester.tap(find.text('선택'));
    await tester.pump();
    expect(find.byType(Checkbox), findsNWidgets(4));
    await tester.tap(find.byTooltip('선택 취소'));
    await tester.pump();

    await tester.tap(find.text('YouTube 2'));
    await tester.pump();
    expect(find.text('download-1'), findsOneWidget);
    expect(find.text('download-2'), findsOneWidget);
    expect(find.text('download-3'), findsNothing);
    expect(find.text('download-4'), findsNothing);
    expect(find.text('download-5'), findsOneWidget);

    await tester.longPress(find.text('download-1'));
    await tester.pump();
    await tester.tap(find.text('download-2'));
    await tester.pump();
    expect(find.text('2개 선택'), findsOneWidget);

    await tester.tap(find.byTooltip('선택한 기록 삭제'));
    await tester.pump();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    await tester.tap(find.descendant(of: dialog, matching: find.text('취소')));
    await tester.pump();
    expect(find.text('download-1'), findsOneWidget);

    await tester.tap(find.byTooltip('선택한 기록 삭제'));
    await tester.pump();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('삭제')),
    );
    await tester.pump();
    expect(find.text('YouTube 2'), findsNothing);
    expect(find.text('전체 2'), findsOneWidget);

    await tester.tap(find.byTooltip('전체 기록 삭제'));
    await tester.pump();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('삭제')),
    );
    await tester.pump();
    expect(find.text('완료된 다운로드 기록이 여기에 표시돼요.'), findsOneWidget);
    expect(find.text('download-5'), findsOneWidget);
  });

  testWidgets('remote history cannot open and stale selection is normalized', (
    tester,
  ) async {
    final controller = testController();
    addTearDown(controller.dispose);
    final remote = downloadEntry(
      id: 'download-1',
      sourceUrl: 'https://youtu.be/remote',
      deviceOwned: false,
    );
    final threads = downloadEntry(
      id: 'download-2',
      sourceUrl: 'https://threads.com/@morit/post/local',
    );
    controller.downloads = [remote, threads];

    Widget app() => MaterialApp(
      home: Scaffold(body: DownloadsPage(controller: controller)),
    );

    await tester.pumpWidget(app());
    await tester.tap(find.text('YouTube 1'));
    await tester.pump();
    expect(find.text('YouTube · 다른 기기에서 완료 · 크기 확인 불가'), findsOneWidget);
    final row = tester.widget<InkWell>(
      find.ancestor(
        of: find.text('download-1'),
        matching: find.byType(InkWell),
      ),
    );
    expect(row.onTap, isNull);

    await tester.longPress(find.text('download-1'));
    await tester.pump();
    expect(find.text('1개 선택'), findsOneWidget);

    controller.downloads = [threads];
    await tester.pumpWidget(app());
    expect(find.text('기록'), findsOneWidget);
    expect(find.text('download-2'), findsOneWidget);

    controller.downloads = [
      threads,
      downloadEntry(
        id: 'download-3',
        sourceUrl: 'https://youtube.com/watch?v=new',
      ),
    ];
    await tester.pumpWidget(app());
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '전체 2'))
          .selected,
      isTrue,
    );
    expect(find.text('download-2'), findsOneWidget);
    expect(find.text('download-3'), findsOneWidget);
  });
}
