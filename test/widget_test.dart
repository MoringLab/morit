import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
