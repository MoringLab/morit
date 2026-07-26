import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth/moring_auth.dart';
import 'core/app_config.dart';
import 'core/secure_supabase_storage.dart';
import 'morit/folder_drop_tree.dart';
import 'morit/media/media_selection.dart';
import 'morit/morit_controller.dart';
import 'morit/platform/morit_platform.dart';
import 'morit/today/today_overlay.dart';

abstract final class _MoritUi {
  static const pageHorizontal = 22.0;
  static const sectionGap = 24.0;
  static const radius = 18.0;
  static const tileHeight = 64.0;
  static const border = Color(0xFFE2E9E7);
  static const paper = Color(0xFFFBFDFC);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppConfig.validate();
  final authStorage = SecureSupabaseStorage(projectUrl: AppConfig.supabaseUrl);
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabasePublishableKey,
    debug: false,
    authOptions: FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
      localStorage: authStorage,
      pkceAsyncStorage: authStorage,
    ),
  );
  runApp(const MoritApp());
}

String _kindLabel(String kind) => switch (kind) {
  'memo' => '메모',
  'today' => '오늘 할 일',
  'link' => '링크',
  'bookmark' => '북마크',
  'photo' => '사진',
  'video' => '영상',
  'file' => '파일',
  'reminder' => '알림',
  _ => '항목',
};

IconData _kindIcon(String kind) => switch (kind) {
  'memo' => Icons.notes_rounded,
  'today' => Icons.today_rounded,
  'link' => Icons.link_rounded,
  'bookmark' => Icons.bookmark_outline_rounded,
  'photo' => Icons.image_outlined,
  'video' => Icons.play_circle_outline_rounded,
  'file' => Icons.description_outlined,
  'reminder' => Icons.notifications_none_rounded,
  _ => Icons.layers_outlined,
};

String? _dragSourceFolder(AppController controller, FolderDragData data) {
  if (data.type == 'item') {
    return controller.items
        .where((value) => value.id == data.id && !value.deleted)
        .firstOrNull
        ?.folderId;
  }
  if (data.type == 'folder') {
    return controller.folders
        .where((value) => value.id == data.id && !value.deleted)
        .firstOrNull
        ?.parentId;
  }
  return null;
}

bool _canDropDragged(
  AppController controller,
  FolderDragData data,
  String? folderId,
) {
  final folderIds = controller.visibleFolders.map((value) => value.id).toSet();
  if (data.type == 'item') {
    final item = controller.items
        .where((value) => value.id == data.id && !value.deleted)
        .firstOrNull;
    return item != null &&
        canDropInFolder(
          data: data,
          sourceFolderId: item.folderId,
          destinationFolderId: folderId,
          folderIds: folderIds,
        );
  }
  if (data.type == 'folder') {
    final folder = controller.folders
        .where((value) => value.id == data.id && !value.deleted)
        .firstOrNull;
    return folder != null &&
        canDropInFolder(
          data: data,
          sourceFolderId: folder.parentId,
          destinationFolderId: folderId,
          folderIds: folderIds,
          blockedFolderIds: {
            folder.id,
            ...controller.descendantFolderIds(folder.id),
          },
        );
  }
  return false;
}

Future<bool> _moveDragged(
  AppController controller,
  FolderDragData data,
  String? folderId,
) async {
  if (data.type == 'item') {
    final item = controller.items
        .where((value) => value.id == data.id)
        .firstOrNull;
    return item != null && await controller.moveItemToFolder(item, folderId);
  }
  if (data.type == 'folder') {
    final folder = controller.folders
        .where((value) => value.id == data.id)
        .firstOrNull;
    return folder != null && await controller.moveFolder(folder, folderId);
  }
  return false;
}

class MoritApp extends StatefulWidget {
  const MoritApp({super.key});

  @override
  State<MoritApp> createState() => _MoritAppState();
}

class _MoritAppState extends State<MoritApp> {
  static const platform = MoritPlatform();
  final navigatorKey = GlobalKey<NavigatorState>();
  final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  late final SupabaseClient client = Supabase.instance.client;
  late final AppController controller = AppController(supabase: client);
  late final MoringAuthController authController = MoringAuthController(
    client: client,
    config: MoringAuthConfig(
      appName: 'Morit',
      redirectUri: AppConfig.authRedirectUri,
      profilesSchema: 'public',
      profilesTable: 'profiles',
      privacyPolicyUrl: Uri.parse(
        'https://www.notion.so/Moring-5e8639fe55c2405ab2756c785ebc8704',
      ),
      termsOfServiceUrl: Uri.parse(
        'https://www.notion.so/Moring-250bb23c8f7d40c2845f89755ac6c445',
      ),
    ),
  );
  int openDownloadsRequest = 0;

  @override
  void initState() {
    super.initState();
    platform.setNavigationHandlers(
      openDownloads: () {
        if (mounted) setState(() => openDownloadsRequest++);
      },
      openToday: _openTodayRoute,
    );
    authController.addListener(_syncDataAccess);
    _syncDataAccess();
  }

  void _syncDataAccess() {
    unawaited(controller.setAccessEnabled(authController.state.isReady));
  }

  void _openTodayRoute(String route) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = navigatorKey.currentContext;
      if (!mounted ||
          context == null ||
          !authController.state.isReady ||
          controller.busy) {
        return;
      }
      final segments = Uri.tryParse(route)?.pathSegments ?? const <String>[];
      final action = segments.length > 1 ? segments[1] : 'list';
      final itemId = segments.length > 2 ? segments[2] : null;
      if (action == 'toggle' && itemId != null) {
        final item = controller.allTodayItems
            .where((value) => value.id == itemId)
            .firstOrNull;
        if (item != null) {
          await controller.setTodayCompleted(item, !isTodayCompleted(item));
        }
        return;
      }
      if (!context.mounted) return;
      await showTodayTasksModal(
        context,
        controller,
        startAdding: action == 'add',
        initialEditId: action == 'edit' ? itemId : null,
      );
    });
  }

  Future<void> _signOut() async {
    if (!await controller.prepareForSignOut()) return;
    try {
      await authController.signOut();
    } finally {
      controller.finishSignOut();
    }
  }

  Future<void> _dropDragged(
    FolderDragData data,
    String? destinationFolderId,
  ) async {
    if (!_canDropDragged(controller, data, destinationFolderId)) return;
    final sourceFolderId = _dragSourceFolder(controller, data);
    final destinationLabel = destinationFolderId == null
        ? '루트'
        : controller
              .folderPath(destinationFolderId)
              .map((folder) => folder.name)
              .join(' / ');
    final moved = await _moveDragged(controller, data, destinationFolderId);
    if (!moved) return;
    final messenger = scaffoldMessengerKey.currentState;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$destinationLabel(으)로 이동했습니다.'),
          action: SnackBarAction(
            label: '실행 취소',
            onPressed: () {
              unawaited(_moveDragged(controller, data, sourceFolderId));
            },
          ),
        ),
      );
  }

  @override
  void dispose() {
    platform.setNavigationHandlers();
    authController.removeListener(_syncDataAccess);
    authController.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF17211F);
    const seed = Color(0xFF00A884);
    final route = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    return MaterialApp(
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: 'Morit',
      debugShowCheckedModeBanner: false,
      builder: (context, child) => ValueListenableBuilder<FolderDragData?>(
        valueListenable: activeFolderDrag,
        child: child,
        builder: (context, data, child) {
          if (data == null || !data.showTree) return child!;
          final sourceFolderId = _dragSourceFolder(controller, data);
          return Stack(
            fit: StackFit.expand,
            children: [
              child!,
              FolderDropTree(
                data: data,
                folders: controller.visibleFolders,
                initiallyExpanded: sourceFolderId == null
                    ? const {}
                    : controller
                          .folderPath(sourceFolderId)
                          .map((folder) => folder.id)
                          .toSet(),
                canDrop: (folderId) =>
                    _canDropDragged(controller, data, folderId),
                pathLabel: (folderId) => folderId == null
                    ? '루트'
                    : [
                        '루트',
                        ...controller
                            .folderPath(folderId)
                            .map((folder) => folder.name),
                      ].join(' / '),
                onDrop: (folderId) {
                  unawaited(_dropDragged(data, folderId));
                },
              ),
            ],
          );
        },
      ),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          surface: const Color(0xFFF7F8FA),
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8FA),
        fontFamilyFallback: const ['Noto Sans KR', 'sans-serif'],
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        ),
        cardTheme: CardThemeData(
          margin: EdgeInsets.zero,
          color: _MoritUi.paper,
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_MoritUi.radius),
            side: const BorderSide(color: _MoritUi.border),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFEEF1F0),
          space: 1,
          thickness: 1,
        ),
        listTileTheme: const ListTileThemeData(
          minVerticalPadding: 8,
          iconColor: Color(0xFF4E5A57),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_MoritUi.radius),
            borderSide: const BorderSide(color: _MoritUi.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_MoritUi.radius),
            borderSide: const BorderSide(color: _MoritUi.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_MoritUi.radius),
            borderSide: const BorderSide(color: seed, width: 1.6),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_MoritUi.radius),
            borderSide: const BorderSide(color: Color(0xFFEEF1F0)),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_MoritUi.radius),
            borderSide: const BorderSide(color: Color(0xFFE5484D)),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_MoritUi.radius),
            borderSide: const BorderSide(color: Color(0xFFE5484D), width: 1.6),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(64, 50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_MoritUi.radius),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(64, 50),
            foregroundColor: ink,
            side: const BorderSide(color: Color(0xFFD8E1DE)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_MoritUi.radius),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_MoritUi.radius),
            ),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFFFBFDFC),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_MoritUi.radius),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          showDragHandle: true,
          backgroundColor: Color(0xFFFBFDFC),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(_MoritUi.radius),
            ),
          ),
          constraints: BoxConstraints(
            minWidth: double.infinity,
            maxWidth: double.infinity,
          ),
        ),
      ),
      home: MoringAuthGate(
        controller: authController,
        loading: const _LoadingPage(),
        child: route == '/share'
            ? ShareCapturePage(controller: controller)
            : route.startsWith('/today-overlay')
            ? AnimatedBuilder(
                animation: controller,
                builder: (context, _) => controller.busy
                    ? const _LoadingPage()
                    : TodayOverlayPage(controller: controller, route: route),
              )
            : AnimatedBuilder(
                animation: controller,
                builder: (context, _) => controller.busy
                    ? const _LoadingPage()
                    : Shell(
                        controller: controller,
                        onSignOut: _signOut,
                        initialIndex:
                            route == '/downloads' || openDownloadsRequest > 0
                            ? 2
                            : 0,
                        downloadsRequestRevision: openDownloadsRequest,
                      ),
              ),
      ),
    );
  }
}

class _LoadingPage extends StatelessWidget {
  const _LoadingPage();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.controller,
    required this.onSignOut,
    this.initialIndex = 0,
    this.downloadsRequestRevision = 0,
  });
  final AppController controller;
  final Future<void> Function() onSignOut;
  final int initialIndex;
  final int downloadsRequestRevision;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late int index;
  String? selectedFolderId;
  int libraryRequest = 0;
  String? lastNotice;

  @override
  void initState() {
    super.initState();
    index = widget.initialIndex;
    widget.controller.addListener(_showControllerNotice);
  }

  @override
  void didUpdateWidget(covariant Shell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.downloadsRequestRevision != widget.downloadsRequestRevision) {
      index = 2;
    } else if (oldWidget.initialIndex != widget.initialIndex) {
      index = widget.initialIndex;
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_showControllerNotice);
      widget.controller.addListener(_showControllerNotice);
    }
  }

  void _showControllerNotice() {
    final value = widget.controller.message;
    if (!mounted || value == null || value == lastNotice || value == '동기화됨') {
      return;
    }
    lastNotice = value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(value)));
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_showControllerNotice);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(
        controller: widget.controller,
        openLibrary: (folderId) => setState(() {
          selectedFolderId = folderId;
          libraryRequest++;
          index = 1;
        }),
      ),
      LibraryPage(
        controller: widget.controller,
        selectedFolderId: selectedFolderId,
        requestRevision: libraryRequest,
        onFolderChanged: (value) => selectedFolderId = value,
      ),
      DownloadsPage(controller: widget.controller),
      SettingsPage(controller: widget.controller, onSignOut: widget.onSignOut),
    ];
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      floatingActionButton: index < 2
          ? FloatingActionButton.extended(
              onPressed: () => showComposeSheet(
                context,
                widget.controller,
                initialFolderId: index == 1 ? selectedFolderId : null,
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('저장'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: '홈',
          ),
          NavigationDestination(icon: Icon(Icons.search_rounded), label: '찾기'),
          NavigationDestination(
            icon: Icon(Icons.downloading_outlined),
            label: '다운로드',
          ),
          NavigationDestination(icon: Icon(Icons.tune_rounded), label: '설정'),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.openLibrary,
  });
  final AppController controller;
  final ValueChanged<String?> openLibrary;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final quickNote = TextEditingController();
  final quickNoteFocus = FocusNode();
  bool savingQuickNote = false;

  Future<void> _saveQuickNote([String? submitted]) async {
    final value = (submitted ?? quickNote.text).trim();
    if (value.isEmpty || savingQuickNote) return;
    setState(() => savingQuickNote = true);
    final kind = inferKind(null, value);
    try {
      final saved = await widget.controller.addItem(
        kind: kind,
        title: kind == 'link' ? value : '빠른 메모',
        note: kind == 'memo' ? value : '',
        sourceUrl: kind == 'link' ? extractWebUrl(value) : null,
        folderId: null,
      );
      if (mounted && saved != null) {
        quickNote.clear();
        quickNoteFocus.unfocus();
      }
    } finally {
      if (mounted) setState(() => savingQuickNote = false);
    }
  }

  Future<void> _pasteQuickNote() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final value = data?.text?.trim();
    if (!mounted || value == null || value.isEmpty) return;
    quickNote
      ..text = value
      ..selection = TextSelection.collapsed(offset: value.length);
    quickNoteFocus.requestFocus();
    setState(() {});
  }

  @override
  void dispose() {
    quickNote.dispose();
    quickNoteFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.controller.visibleItems.take(6).toList();
    final today = widget.controller.todayItems;
    final homeToday = today.take(3).toList();
    final favorites = widget.controller.favoriteItems;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: widget.controller.sync,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                _MoritUi.pageHorizontal,
                18,
                _MoritUi.pageHorizontal,
                110,
              ),
              sliver: SliverList.list(
                children: [
                  Row(
                    children: [
                      Image.asset(
                        'docs/app_logo_transparent.png',
                        width: 40,
                        height: 40,
                        fit: BoxFit.contain,
                        cacheWidth: 80,
                        cacheHeight: 80,
                        semanticLabel: 'Morit 앱 로고',
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          'Morit',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: const Color(0xFF167C6A),
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: () => widget.openLibrary(null),
                        tooltip: '항목 찾기',
                        icon: const Icon(Icons.search_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: _MoritUi.sectionGap),
                  const _SectionTitle(title: '빠른 저장'),
                  const SizedBox(height: 8),
                  Material(
                    color: const Color(0xFFF2F4F6),
                    borderRadius: BorderRadius.circular(_MoritUi.radius),
                    clipBehavior: Clip.antiAlias,
                    child: Container(
                      constraints: const BoxConstraints(
                        minHeight: _MoritUi.tileHeight,
                      ),
                      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.add_rounded,
                            size: 24,
                            color: Color(0xFF008F72),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: quickNote,
                              focusNode: quickNoteFocus,
                              maxLines: 1,
                              textInputAction: TextInputAction.done,
                              onChanged: (_) => setState(() {}),
                              onSubmitted: _saveQuickNote,
                              decoration: const InputDecoration(
                                hintText: '메모나 링크를 바로 저장',
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _pasteQuickNote,
                            tooltip: '클립보드 붙여넣기',
                            icon: const Icon(
                              Icons.content_paste_rounded,
                              size: 20,
                            ),
                          ),
                          IconButton.filled(
                            onPressed:
                                quickNote.text.trim().isEmpty || savingQuickNote
                                ? null
                                : _saveQuickNote,
                            tooltip: '빠른 저장',
                            icon: savingQuickNote
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.arrow_upward_rounded,
                                    size: 20,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: _MoritUi.sectionGap),
                  _SectionTitle(
                    title: '오늘 할 일',
                    count: widget.controller.allTodayItems.length,
                    action: '모두 보기',
                    onTap: () =>
                        showTodayTasksModal(context, widget.controller),
                  ),
                  const SizedBox(height: 8),
                  Material(
                    color: const Color(0xFFF2F4F6),
                    borderRadius: BorderRadius.circular(_MoritUi.radius),
                    clipBehavior: Clip.antiAlias,
                    child: today.isEmpty
                        ? ListTile(
                            minTileHeight: _MoritUi.tileHeight,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                            leading: const Icon(
                              Icons.check_circle_outline_rounded,
                              size: 24,
                              color: Color(0xFF6B7684),
                            ),
                            title: const Text(
                              '오늘 할 일을 추가해 보세요',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            trailing: IconButton(
                              tooltip: '오늘 할 일 추가',
                              onPressed: () => showTodayTasksModal(
                                context,
                                widget.controller,
                                startAdding: true,
                              ),
                              color: const Color(0xFF008F72),
                              icon: const Icon(Icons.add_rounded, size: 22),
                            ),
                            onTap: () => showTodayTasksModal(
                              context,
                              widget.controller,
                              startAdding: true,
                            ),
                          )
                        : Column(
                            children: [
                              for (
                                var index = 0;
                                index < homeToday.length;
                                index++
                              ) ...[
                                if (index > 0)
                                  const Divider(
                                    color: Color(0xFFE5E8EB),
                                    indent: 52,
                                    endIndent: 12,
                                  ),
                                SizedBox(
                                  height: _MoritUi.tileHeight,
                                  child: TodayTaskRow(
                                    item: homeToday[index],
                                    controller: widget.controller,
                                    dense: true,
                                    onEdit: () => showTodayTasksModal(
                                      context,
                                      widget.controller,
                                      initialEditId: homeToday[index].id,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                  ),
                  const SizedBox(height: _MoritUi.sectionGap),
                  if (widget.controller.settings.showFavorites &&
                      favorites.isNotEmpty) ...[
                    _SectionTitle(
                      title: '즐겨찾기',
                      action: '${widget.controller.allFavoriteItems.length}개',
                      onTap: () => _showFavorites(context, widget.controller),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      color: const Color(0xFFFFF8D6),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (
                            var index = 0;
                            index < favorites.length;
                            index++
                          ) ...[
                            if (index > 0)
                              const Divider(indent: 64, endIndent: 12),
                            ItemTile(
                              item: favorites[index],
                              controller: widget.controller,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: _MoritUi.sectionGap),
                  ],
                  _SectionTitle(
                    title: '폴더',
                    action: '새 폴더',
                    onTap: () => showFolderDialog(context, widget.controller),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 92,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.controller.childFolders(null).length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 10),
                      itemBuilder: (context, index) {
                        final folder = widget.controller.childFolders(
                          null,
                        )[index];
                        final count = widget.controller.visibleItems
                            .where((item) => item.folderId == folder.id)
                            .length;
                        return _FolderCard(
                          folder: folder,
                          count: count,
                          controller: widget.controller,
                          onOpen: () => widget.openLibrary(folder.id),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: _MoritUi.sectionGap),
                  _SectionTitle(
                    title: '최근 항목',
                    action: '전체 보기',
                    onTap: () => widget.openLibrary(null),
                  ),
                  const SizedBox(height: 8),
                  if (items.isEmpty)
                    const _EmptyState(
                      icon: Icons.inbox_outlined,
                      title: '아직 저장한 항목이 없어요',
                      body: '빠른 저장이나 아래 저장 버튼으로 시작해 보세요.',
                    )
                  else
                    Column(
                      children: [
                        for (var index = 0; index < items.length; index++) ...[
                          if (index > 0)
                            const Divider(indent: 64, endIndent: 12),
                          ItemTile(
                            item: items[index],
                            controller: widget.controller,
                          ),
                        ],
                      ],
                    ),
                  if (widget.controller.message != null) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          widget.controller.syncing
                              ? Icons.sync_rounded
                              : Icons.cloud_done_outlined,
                          size: 16,
                          color: const Color(0xFF66736F),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            widget.controller.syncing
                                ? '동기화 중'
                                : widget.controller.message!,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF66736F),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.folder,
    required this.count,
    required this.controller,
    required this.onOpen,
    this.showFolderTreeOnDrag = false,
  });

  final Folder folder;
  final int count;
  final AppController controller;
  final VoidCallback onOpen;
  final bool showFolderTreeOnDrag;

  Future<void> accept(FolderDragData data) async {
    await _moveDragged(controller, data, folder.id);
  }

  Widget card(BuildContext context, {bool highlighted = false}) => InkWell(
    borderRadius: BorderRadius.circular(_MoritUi.radius),
    onTap: onOpen,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 145,
      padding: const EdgeInsets.fromLTRB(15, 9, 8, 12),
      decoration: BoxDecoration(
        color: Color(folder.color).withValues(alpha: highlighted ? 0.20 : 0.10),
        borderRadius: BorderRadius.circular(_MoritUi.radius),
        border: highlighted
            ? Border.all(color: Color(folder.color), width: 2)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_rounded, color: Color(folder.color)),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '폴더 메뉴',
                onPressed: () => showFolderMenu(context, controller, folder),
                icon: const Icon(Icons.more_horiz_rounded, size: 19),
              ),
            ],
          ),
          const Spacer(),
          Text(
            folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            '$count개',
            style: const TextStyle(color: Color(0xFF6F7B78), fontSize: 12),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final data = (
      type: 'folder',
      id: folder.id,
      showTree: showFolderTreeOnDrag,
    );
    return LongPressDraggable<FolderDragData>(
      data: data,
      onDragStarted: () => activeFolderDrag.value = data,
      onDragEnd: (_) {
        if (activeFolderDrag.value == data) activeFolderDrag.value = null;
      },
      feedback: Material(
        color: Colors.transparent,
        child: card(context, highlighted: true),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card(context)),
      child: DragTarget<FolderDragData>(
        onWillAcceptWithDetails: (details) =>
            _canDropDragged(controller, details.data, folder.id),
        onAcceptWithDetails: (details) => accept(details.data),
        builder: (context, candidates, _) =>
            card(context, highlighted: candidates.isNotEmpty),
      ),
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.controller,
    required this.selectedFolderId,
    required this.requestRevision,
    required this.onFolderChanged,
  });
  final AppController controller;
  final String? selectedFolderId;
  final int requestRevision;
  final ValueChanged<String?> onFolderChanged;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final search = TextEditingController();
  String? folderId;
  String sort = 'newest';

  @override
  void initState() {
    super.initState();
    folderId = widget.selectedFolderId;
  }

  @override
  void didUpdateWidget(covariant LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.requestRevision != oldWidget.requestRevision) {
      folderId = widget.selectedFolderId;
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void _changeFolder(String? value) {
    setState(() => folderId = value);
    widget.onFolderChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    if (folderId != null &&
        !widget.controller.visibleFolders.any(
          (folder) => folder.id == folderId,
        )) {
      folderId = null;
      widget.onFolderChanged(null);
    }
    var result = widget.controller.visibleItems.where((item) {
      final query = search.text.trim().toLowerCase();
      final matchesText =
          query.isEmpty ||
          '${item.title} ${item.note} ${item.sourceUrl ?? ''}'
              .toLowerCase()
              .contains(query);
      return matchesText && item.folderId == folderId;
    }).toList();
    if (sort == 'oldest') result = result.reversed.toList();
    if (sort == 'title') {
      result.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    }
    final currentFolder = folderId == null
        ? null
        : widget.controller.visibleFolders
              .where((folder) => folder.id == folderId)
              .firstOrNull;
    final parentPath = currentFolder == null
        ? const <Folder>[]
        : widget.controller.folderPath(currentFolder.parentId);
    final children = widget.controller.childFolders(folderId);
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DragTarget<FolderDragData>(
                  onWillAcceptWithDetails: (details) => _canDropDragged(
                    widget.controller,
                    details.data,
                    currentFolder?.id,
                  ),
                  onAcceptWithDetails: (details) => _moveDragged(
                    widget.controller,
                    details.data,
                    currentFolder?.id,
                  ),
                  builder: (context, candidates, _) => AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: candidates.isEmpty
                          ? Colors.transparent
                          : const Color(0xFF00A884).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        if (currentFolder != null)
                          IconButton(
                            tooltip: '상위 폴더',
                            onPressed: () =>
                                _changeFolder(currentFolder.parentId),
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                        Expanded(
                          child: Text(
                            candidates.isEmpty
                                ? currentFolder?.name ?? '찾기'
                                : currentFolder == null
                                ? '폴더 밖으로 이동'
                                : '${currentFolder.name}(으)로 이동',
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (parentPath.isNotEmpty)
                          PopupMenuButton<String>(
                            tooltip: '상위 경로',
                            icon: const Icon(Icons.account_tree_outlined),
                            onSelected: (value) =>
                                _changeFolder(value.isEmpty ? null : value),
                            itemBuilder: (context) => [
                              const PopupMenuItem(value: '', child: Text('루트')),
                              ...parentPath.map(
                                (folder) => PopupMenuItem(
                                  value: folder.id,
                                  child: Text(
                                    widget.controller
                                        .folderPath(folder.id)
                                        .map((value) => value.name)
                                        .join(' / '),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        IconButton(
                          tooltip: currentFolder == null ? '새 폴더' : '하위 폴더 만들기',
                          onPressed: () => showFolderDialog(
                            context,
                            widget.controller,
                            initialParentId: currentFolder?.id,
                          ),
                          icon: const Icon(Icons.create_new_folder_outlined),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: '제목, 메모, 링크 검색',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        initialValue: folderId,
                        decoration: const InputDecoration(
                          labelText: '폴더',
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('루트'),
                          ),
                          ...widget.controller.visibleFolders.map(
                            (folder) => DropdownMenuItem(
                              value: folder.id,
                              child: Text(
                                widget.controller
                                    .folderPath(folder.id)
                                    .map((value) => value.name)
                                    .join(' / '),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: _changeFolder,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: sort,
                        decoration: const InputDecoration(
                          labelText: '정렬',
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'newest', child: Text('최신순')),
                          DropdownMenuItem(
                            value: 'oldest',
                            child: Text('오래된순'),
                          ),
                          DropdownMenuItem(value: 'title', child: Text('이름순')),
                        ],
                        onChanged: (value) =>
                            setState(() => sort = value ?? 'newest'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (children.isNotEmpty)
            SizedBox(
              height: 104,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 6,
                ),
                scrollDirection: Axis.horizontal,
                itemCount: children.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final folder = children[index];
                  final count = widget.controller.visibleItems
                      .where((item) => item.folderId == folder.id)
                      .length;
                  return _FolderCard(
                    folder: folder,
                    count: count,
                    controller: widget.controller,
                    onOpen: () => _changeFolder(folder.id),
                    showFolderTreeOnDrag: folderId != null,
                  );
                },
              ),
            ),
          Expanded(
            child: result.isEmpty
                ? const _EmptyState(
                    icon: Icons.search_off_rounded,
                    title: '찾은 항목이 없어요',
                    body: '검색어나 폴더를 바꿔 보세요.',
                  )
                : RefreshIndicator(
                    onRefresh: widget.controller.sync,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 110),
                      itemCount: result.length,
                      itemBuilder: (context, index) => ItemTile(
                        item: result[index],
                        controller: widget.controller,
                        showFolderTreeOnDrag: folderId != null,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.item,
    required this.controller,
    this.showFolderTreeOnDrag = false,
  });
  final MoritItem item;
  final AppController controller;
  final bool showFolderTreeOnDrag;

  @override
  Widget build(BuildContext context) {
    final tile = ListTile(
      visualDensity: controller.settings.compactUi
          ? VisualDensity.compact
          : VisualDensity.standard,
      contentPadding: EdgeInsets.symmetric(
        horizontal: 8,
        vertical: controller.settings.compactUi ? 0 : 4,
      ),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: item.favorite
              ? const Color(0xFFFFDE59).withValues(alpha: 0.38)
              : const Color(0xFF00A884).withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          item.favorite ? Icons.star_rounded : _kindIcon(item.kind),
          color: item.favorite
              ? const Color(0xFFB7791F)
              : const Color(0xFF008F72),
        ),
      ),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        item.note.isNotEmpty
            ? item.note
            : item.sourceUrl ?? _kindLabel(item.kind),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFF6F7B78)),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            displayDate(item.updatedAt),
            style: const TextStyle(color: Color(0xFF87918F), fontSize: 12),
          ),
          PopupMenuButton<String>(
            onSelected: (value) =>
                handleItemAction(context, controller, item, value),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'favorite',
                child: Text(item.favorite ? '즐겨찾기 해제' : '즐겨찾기'),
              ),
              if (item.kind == 'memo')
                PopupMenuItem(
                  value: 'today',
                  child: Text(isTodayItem(item) ? '오늘 할 일에서 제거' : '오늘 할 일에 추가'),
                ),
              const PopupMenuItem(value: 'edit', child: Text('수정')),
              const PopupMenuItem(value: 'move', child: Text('폴더 이동')),
              if (item.sourceUrl != null)
                const PopupMenuItem(value: 'download', child: Text('다운로드')),
              const PopupMenuItem(value: 'delete', child: Text('삭제')),
            ],
          ),
        ],
      ),
      onTap: () => openItem(context, controller, item),
    );
    final data = (type: 'item', id: item.id, showTree: showFolderTreeOnDrag);
    return LongPressDraggable<FolderDragData>(
      data: data,
      onDragStarted: () => activeFolderDrag.value = data,
      onDragEnd: (_) {
        if (activeFolderDrag.value == data) activeFolderDrag.value = null;
      },
      feedback: Material(
        color: Colors.white,
        elevation: 8,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(width: 280, child: tile),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
    );
  }
}

Future<void> _showFavorites(BuildContext context, AppController controller) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.82,
          child: Column(
            children: [
              ListTile(
                title: const Text(
                  '즐겨찾기',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                trailing: const Icon(
                  Icons.star_rounded,
                  color: Color(0xFFE3A008),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                  itemCount: controller.allFavoriteItems.length,
                  itemBuilder: (context, index) => ItemTile(
                    item: controller.allFavoriteItems[index],
                    controller: controller,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('취소'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

Future<void> openItem(
  BuildContext context,
  AppController controller,
  MoritItem item,
) async {
  if (controller.attachmentsForItem(item.id).isEmpty &&
      await controller.openItemContent(item)) {
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _ItemDetailsSheet(controller: controller, item: item),
  );
}

class _ItemDetailsSheet extends StatelessWidget {
  const _ItemDetailsSheet({required this.controller, required this.item});

  final AppController controller;
  final MoritItem item;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final attachments = controller.attachmentsForItem(item.id);
      final scheduledAt = DateTime.tryParse(
        item.metadata['scheduled_at'] as String? ?? '',
      );
      return Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          8,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 28,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.75,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '상세',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Icon(
                  _kindIcon(item.kind),
                  size: 30,
                  color: const Color(0xFF167C6A),
                ),
                const SizedBox(height: 16),
                Text(
                  item.title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                if (item.note.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(item.note),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Icon(
                      Icons.schedule_outlined,
                      size: 18,
                      color: Color(0xFF8B95A1),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '생성 ${_dateTimeLabel(context, item.createdAt)}',
                      style: const TextStyle(
                        color: Color(0xFF6B7684),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                if (item.kind == 'reminder') ...[
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      const Icon(
                        Icons.notifications_active_outlined,
                        size: 18,
                        color: Color(0xFF8B95A1),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          scheduledAt == null
                              ? '알림 예정 시간 정보 없음'
                              : '알림 예정 ${_dateTimeLabel(context, scheduledAt)}',
                          style: const TextStyle(
                            color: Color(0xFF6B7684),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (attachments.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const Text(
                    '첨부 파일',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  for (final attachment in attachments)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.attach_file_rounded),
                      title: Text(
                        attachment.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            attachment.lastError ??
                                _attachmentStateLabel(attachment.uploadState),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (controller.attachmentProgress[attachment.id]
                              case final progress?)
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: LinearProgressIndicator(value: progress),
                            ),
                        ],
                      ),
                      onTap: () => controller.openAttachment(attachment),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) async {
                          if (value == 'open') {
                            await controller.openAttachment(attachment);
                          } else if (value == 'retry') {
                            await controller.retryAttachment(attachment);
                          } else if (value == 'delete') {
                            await controller.deleteAttachment(attachment);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(value: 'open', child: Text('열기')),
                          if (attachment.uploadState ==
                              AttachmentUploadState.failed)
                            const PopupMenuItem(
                              value: 'retry',
                              child: Text('업로드 다시 시도'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('첨부 삭제'),
                          ),
                        ],
                      ),
                    ),
                ],
                if (supportsAttachments(item.kind)) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => controller.attachFile(item, FileType.any),
                    icon: const Icon(Icons.attach_file_rounded),
                    label: const Text('첨부 추가'),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('취소'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

String _dateTimeLabel(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatMediumDate(local)} '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true)}';
}

String _attachmentStateLabel(AttachmentUploadState state) => switch (state) {
  AttachmentUploadState.pending => '업로드 대기 중',
  AttachmentUploadState.uploading => '업로드 중',
  AttachmentUploadState.uploaded => '동기화됨',
  AttachmentUploadState.failed => '업로드 실패',
  AttachmentUploadState.deleting => '삭제 중',
};

String _fileSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _mediaSizeLabel(int? bytes, {bool estimated = false}) =>
    bytes == null || bytes <= 0
    ? '크기 확인 중'
    : '${estimated ? '약 ' : ''}${_fileSizeLabel(bytes)}';

Future<void> _pickInto(
  AppController controller,
  List<PlatformFile> staged,
  StateSetter setState,
) async {
  final picked = await controller.pickAttachmentFiles();
  if (picked.isEmpty) return;
  final merged = <PlatformFile>[];
  final keys = <String>{};
  for (final file in [...staged, ...picked]) {
    final key = '${normalizeAttachmentFileName(file.name)}:${file.size}';
    if (keys.add(key)) merged.add(file);
  }
  if (merged.length > 20 ||
      merged.fold<int>(0, (sum, file) => sum + file.size) >
          maxMoritAttachmentBytes) {
    controller.showMessage('첨부 파일은 최대 20개, 총 500 MiB까지 추가할 수 있습니다.');
    return;
  }
  setState(() {
    staged
      ..clear()
      ..addAll(merged);
  });
}

class _AttachmentEditor extends StatelessWidget {
  const _AttachmentEditor({
    required this.controller,
    required this.staged,
    required this.removedIds,
    required this.onAdd,
    required this.onRemoveStaged,
    required this.onRemoveExisting,
    this.item,
  });

  final AppController controller;
  final MoritItem? item;
  final List<PlatformFile> staged;
  final Set<String> removedIds;
  final VoidCallback onAdd;
  final ValueChanged<PlatformFile> onRemoveStaged;
  final ValueChanged<MoritAttachment> onRemoveExisting;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final existing = item == null
          ? const <MoritAttachment>[]
          : controller
                .attachmentsForItem(item!.id)
                .where((value) => !removedIds.contains(value.id))
                .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '첨부 파일',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              OutlinedButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.attach_file_rounded, size: 18),
                label: const Text('추가'),
              ),
            ],
          ),
          if (existing.isEmpty && staged.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 2, bottom: 8),
              child: Text(
                '사진, 영상, 문서를 한 번에 여러 개 선택할 수 있어요.',
                style: TextStyle(color: Color(0xFF6B7684)),
              ),
            ),
          for (final attachment in existing)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(
                attachment.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_fileSizeLabel(attachment.sizeBytes ?? 0)} · '
                '${attachment.lastError ?? _attachmentStateLabel(attachment.uploadState)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => controller.openAttachment(attachment),
              trailing: PopupMenuButton<String>(
                onSelected: (value) async {
                  if (value == 'open') {
                    await controller.openAttachment(attachment);
                  } else if (value == 'retry') {
                    await controller.retryAttachment(attachment);
                  } else {
                    onRemoveExisting(attachment);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'open', child: Text('열기')),
                  if (attachment.uploadState == AttachmentUploadState.failed)
                    const PopupMenuItem(
                      value: 'retry',
                      child: Text('업로드 다시 시도'),
                    ),
                  const PopupMenuItem(value: 'delete', child: Text('삭제')),
                ],
              ),
            ),
          for (final file in staged)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.upload_file_rounded),
              title: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('${_fileSizeLabel(file.size)} · 저장 시 업로드'),
              trailing: IconButton(
                tooltip: '첨부에서 제거',
                onPressed: () => onRemoveStaged(file),
                icon: const Icon(Icons.remove_circle_outline_rounded),
              ),
            ),
        ],
      );
    },
  );
}

class _SheetActions extends StatelessWidget {
  const _SheetActions({required this.onCancel, required this.onSave});

  final VoidCallback onCancel;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: OutlinedButton(onPressed: onCancel, child: const Text('취소')),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: FilledButton(onPressed: onSave, child: const Text('저장')),
      ),
    ],
  );
}

Future<void> handleItemAction(
  BuildContext context,
  AppController controller,
  MoritItem item,
  String action,
) async {
  switch (action) {
    case 'favorite':
      await controller.updateItem(item, favorite: !item.favorite);
    case 'today':
      await controller.setToday(item, !isTodayItem(item));
    case 'edit':
      if (!context.mounted) return;
      await showEditItemSheet(context, controller, item);
    case 'move':
      if (!context.mounted) return;
      await showMoveSheet(context, controller, item);
    case 'download':
      if (!context.mounted) return;
      await showDownloadOptions(context, controller, item);
    case 'delete':
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('항목을 삭제할까요?'),
          content: const Text('동기화된 모든 기기에서도 삭제됩니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제'),
            ),
          ],
        ),
      );
      if (confirmed == true) await controller.deleteItem(item);
  }
}

Future<void> showDownloadOptions(
  BuildContext context,
  AppController controller,
  MoritItem item,
) async {
  final analysis = await controller.analyzeItemMedia(item);
  if (analysis == null || !context.mounted) return;
  final selected = await showDownloadCandidatePicker(context, analysis);
  if (selected == null || !context.mounted) return;
  _startMediaDownloadsInBackground(
    context,
    selected,
    (candidate) => controller.downloadCandidate(item, candidate),
  );
}

void _startMediaDownloadsInBackground(
  BuildContext context,
  List<MediaCandidate> candidates,
  Future<void> Function(MediaCandidate) start,
) {
  Future<void> run() async {
    try {
      await startMediaDownloads(candidates, start);
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('일부 다운로드를 시작하지 못했어요. 다운로드 기록을 확인해 주세요.')),
      );
    }
  }

  unawaited(run());
}

Future<List<MediaCandidate>?> showDownloadCandidatePicker(
  BuildContext context,
  MediaAnalysis analysis,
) async {
  var selectedUrls = initialMediaSelection(analysis.candidates);
  final groups = mediaCandidateGroups(analysis.candidates);
  return showModalBottomSheet<List<MediaCandidate>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) {
        final selectedCandidates = selectedMediaCandidates(
          analysis.candidates,
          selectedUrls,
        );
        final height =
            (220.0 +
                    groups.fold<double>(
                      0,
                      (height, group) => height + (group.length > 1 ? 142 : 82),
                    ))
                .clamp(320.0, MediaQuery.sizeOf(context).height * 0.82)
                .toDouble();
        return SafeArea(
          child: SizedBox(
            height: height,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    _MoritUi.pageHorizontal,
                    0,
                    _MoritUi.pageHorizontal,
                    14,
                  ),
                  child: Text(
                    '${analysis.providerLabel}에서 다운로드할 항목',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _MoritUi.pageHorizontal,
                    ),
                    children: [
                      _MediaCandidatePicker(
                        candidates: analysis.candidates,
                        selectedUrls: selectedUrls,
                        onChanged: (value) =>
                            setSheetState(() => selectedUrls = value),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    _MoritUi.pageHorizontal,
                    16,
                    _MoritUi.pageHorizontal,
                    24,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('취소'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: selectedCandidates.isEmpty
                              ? null
                              : () =>
                                    Navigator.pop(context, selectedCandidates),
                          icon: const Icon(Icons.download_rounded),
                          label: Text('${selectedCandidates.length}개 다운로드'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

String _mediaKindLabel(MediaKind kind) => switch (kind) {
  MediaKind.video => '영상',
  MediaKind.audio => '오디오',
  MediaKind.image => '사진',
  MediaKind.file => '파일',
};

IconData _mediaKindIcon(MediaKind kind) => switch (kind) {
  MediaKind.video => Icons.movie_outlined,
  MediaKind.audio => Icons.audio_file_outlined,
  MediaKind.image => Icons.image_outlined,
  MediaKind.file => Icons.description_outlined,
};

class _MediaCandidatePicker extends StatelessWidget {
  const _MediaCandidatePicker({
    required this.candidates,
    required this.selectedUrls,
    required this.onChanged,
  });

  final List<MediaCandidate> candidates;
  final Set<Uri> selectedUrls;
  final ValueChanged<Set<Uri>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final group in mediaCandidateGroups(candidates))
          _asset(context, group),
      ],
    );
  }

  Widget _asset(BuildContext context, List<MediaCandidate> group) {
    final selected =
        group.where((value) => selectedUrls.contains(value.url)).firstOrNull ??
        group.where((value) => value.recommended).firstOrNull ??
        group.first;
    final checked = group.any((value) => selectedUrls.contains(value.url));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: checked
            ? const Color(0xFF167C6A).withValues(alpha: 0.07)
            : const Color(0xFFF4F7F6),
        borderRadius: BorderRadius.circular(_MoritUi.radius),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            CheckboxListTile(
              value: checked,
              controlAffinity: ListTileControlAffinity.leading,
              secondary: Icon(_mediaKindIcon(selected.kind)),
              title: Text(
                selected.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_mediaKindLabel(selected.kind)}'
                '${group.length == 1 && selected.qualityLabel != null ? ' · ${selected.qualityLabel}' : ''}'
                ' · ${_mediaSizeLabel(selected.sizeBytes, estimated: selected.sizeEstimated)}'
                ' · ${selected.mimeType ?? '형식 미확인'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onChanged: (_) => onChanged(
                toggleMediaSelection(candidates, selectedUrls, selected),
              ),
            ),
            if (group.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(58, 0, 16, 14),
                child: DropdownButtonFormField<Uri>(
                  key: ValueKey(selected.url),
                  initialValue: selected.url,
                  decoration: const InputDecoration(
                    labelText: '품질',
                    isDense: true,
                  ),
                  items: [
                    for (final quality in group)
                      DropdownMenuItem(
                        value: quality.url,
                        child: Text(
                          '${quality.qualityLabel ?? '원본'} · ${_mediaSizeLabel(quality.sizeBytes, estimated: quality.sizeEstimated)}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (url) {
                    final quality = group
                        .where((value) => value.url == url)
                        .firstOrNull;
                    if (quality != null && quality.url != selected.url) {
                      onChanged(
                        toggleMediaSelection(candidates, selectedUrls, quality),
                      );
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.controller});
  final AppController controller;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  Timer? timer;
  final url = TextEditingController();
  bool analyzing = false;
  bool selectingHistory = false;
  String platformFilter = 'all';
  final selectedHistoryIds = <String>{};

  @override
  void initState() {
    super.initState();
    widget.controller.pollDownloads();
    timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => widget.controller.pollDownloads(),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    url.dispose();
    super.dispose();
  }

  Future<void> pasteUrl() async {
    final value = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (value == null || value.isEmpty || !mounted) return;
    setState(() => url.text = extractWebUrl(value) ?? value);
  }

  Future<void> analyzeUrl() async {
    if (analyzing) return;
    final value = extractWebUrl(url.text) ?? url.text.trim();
    final source = Uri.tryParse(value);
    if (source == null ||
        source.scheme != 'https' ||
        source.host.isEmpty ||
        source.userInfo.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('분석할 올바른 HTTPS 링크를 입력해 주세요.')),
      );
      return;
    }
    setState(() => analyzing = true);
    try {
      final result = await widget.controller.analyzeMediaUrlDetailed(source);
      if (!mounted) return;
      final analysis = result?.analysis;
      if (analysis == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result?.failure?.message ?? '링크를 분석하지 못했습니다.'),
          ),
        );
        return;
      }
      final selected = await showDownloadCandidatePicker(context, analysis);
      if (selected == null || !mounted) return;
      _startMediaDownloadsInBackground(
        context,
        selected,
        (candidate) => widget.controller.downloadCandidateFromSource(
          sourceUrl: analysis.sourceUrl,
          title: analysis.title ?? candidate.fileName,
          candidate: candidate,
        ),
      );
    } finally {
      if (mounted) setState(() => analyzing = false);
    }
  }

  String _platformId(DownloadEntry entry) {
    final source = Uri.tryParse(entry.sourceUrl);
    return source == null ? 'other' : mediaPlatformFor(source)?.id ?? 'other';
  }

  Future<void> _deleteHistory(
    List<DownloadEntry> entries, {
    required bool all,
  }) async {
    if (entries.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(all ? '전체 기록을 삭제할까요?' : '다운로드 기록을 삭제할까요?'),
        content: Text(
          all
              ? '이 기기와 현재 서버에서 ${entries.length}개의 기록을 삭제합니다. 기기에 저장된 파일은 유지됩니다.'
              : '이 기기와 현재 서버에서 기록을 삭제합니다. 기기에 저장된 파일은 유지됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final deleted = await widget.controller.deleteDownloadRecords(entries);
    if (!mounted || deleted == 0) return;
    setState(() {
      selectedHistoryIds.removeAll(entries.map((value) => value.id));
      selectingHistory = false;
      final remaining = widget.controller.visibleDownloads
          .where(
            (value) =>
                {'completed', 'failed', 'canceled'}.contains(value.state) &&
                _platformId(value) == platformFilter,
          )
          .isNotEmpty;
      if (!remaining) platformFilter = 'all';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$deleted개의 기록을 삭제했어요. 저장된 파일은 유지됩니다.')),
    );
  }

  void _toggleHistorySelection(DownloadEntry entry) {
    setState(() {
      selectingHistory = true;
      if (!selectedHistoryIds.add(entry.id)) {
        selectedHistoryIds.remove(entry.id);
      }
      if (selectedHistoryIds.isEmpty) selectingHistory = false;
    });
  }

  Widget _downloadRow(DownloadEntry entry, {required bool history}) {
    final active = {'queued', 'running', 'paused'}.contains(entry.state);
    final controllable = entry.deviceOwned;
    final canOpen =
        entry.state == 'completed' &&
        entry.deviceOwned &&
        (entry.nativeId != null || entry.localPath != null);
    final selected = selectedHistoryIds.contains(entry.id);
    final platformLabel =
        mediaPlatformFor(Uri.tryParse(entry.sourceUrl) ?? Uri())?.label ?? '기타';
    final row = InkWell(
      borderRadius: BorderRadius.circular(14),
      onLongPress: history ? () => _toggleHistorySelection(entry) : null,
      onTap: history && selectingHistory
          ? () => _toggleHistorySelection(entry)
          : canOpen
          ? () => widget.controller.openDownload(entry)
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            if (history && selectingHistory)
              Checkbox(
                value: selected,
                onChanged: (_) => _toggleHistorySelection(entry),
              )
            else
              Icon(
                entry.state == 'completed'
                    ? Icons.check_circle_rounded
                    : entry.state == 'failed'
                    ? Icons.error_outline_rounded
                    : entry.state == 'canceled'
                    ? Icons.cancel_outlined
                    : Icons.downloading_rounded,
                color: entry.state == 'failed'
                    ? const Color(0xFFC33C36)
                    : entry.state == 'canceled'
                    ? const Color(0xFF66736F)
                    : const Color(0xFF167C6A),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (active) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: entry.progress > 0 ? entry.progress / 100 : null,
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ],
                  const SizedBox(height: 5),
                  Text(
                    history
                        ? '$platformLabel · ${_downloadStatus(entry, active)}'
                        : _downloadStatus(entry, active),
                    style: const TextStyle(
                      color: Color(0xFF66736F),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (history && !selectingHistory)
              PopupMenuButton<String>(
                tooltip: '기록 메뉴',
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (action) {
                  if (action == 'retry') {
                    unawaited(widget.controller.retryDownload(entry));
                  } else {
                    unawaited(_deleteHistory([entry], all: false));
                  }
                },
                itemBuilder: (context) => [
                  if (controllable &&
                      {'failed', 'canceled'}.contains(entry.state))
                    const PopupMenuItem(
                      value: 'retry',
                      child: ListTile(
                        leading: Icon(Icons.refresh_rounded),
                        title: Text('다시 시도'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete_outline_rounded),
                      title: Text('기록 삭제'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            if (!history &&
                controllable &&
                {'queued', 'running'}.contains(entry.state)) ...[
              IconButton(
                onPressed: () => widget.controller.pauseDownload(entry),
                icon: const Icon(Icons.pause_rounded),
                tooltip: '일시 중지',
              ),
              IconButton(
                onPressed: () => widget.controller.cancelDownload(entry),
                icon: const Icon(Icons.close_rounded),
                tooltip: '다운로드 취소',
              ),
            ] else if (!history && controllable && entry.state == 'paused') ...[
              IconButton(
                onPressed: () => widget.controller.resumeDownload(entry),
                icon: const Icon(Icons.play_arrow_rounded),
                tooltip: '다시 시작',
              ),
              IconButton(
                onPressed: () => widget.controller.cancelDownload(entry),
                icon: const Icon(Icons.close_rounded),
                tooltip: '다운로드 취소',
              ),
            ],
          ],
        ),
      ),
    );
    if (!history || !selectingHistory) return row;
    return Semantics(
      checked: selected,
      button: true,
      label:
          '${entry.title}, $platformLabel, ${_downloadStatus(entry, active)}',
      onTap: () => _toggleHistorySelection(entry),
      child: ExcludeSemantics(child: row),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.controller.visibleDownloads;
    final active = visible
        .where((value) => {'queued', 'running', 'paused'}.contains(value.state))
        .toList();
    final history = visible
        .where(
          (value) => {'completed', 'failed', 'canceled'}.contains(value.state),
        )
        .toList();
    final hadSelection = selectedHistoryIds.isNotEmpty;
    selectedHistoryIds.retainAll(history.map((entry) => entry.id));
    if (selectingHistory && hadSelection && selectedHistoryIds.isEmpty) {
      selectingHistory = false;
    }
    final platformCounts = <String, int>{};
    for (final entry in history) {
      final id = _platformId(entry);
      platformCounts[id] = (platformCounts[id] ?? 0) + 1;
    }
    final filters = <(String, String)>[
      ('all', '전체'),
      for (final platform in defaultMediaPlatforms)
        if (platformCounts.containsKey(platform.id))
          (platform.id, platform.label),
      if (platformCounts.containsKey('other')) ('other', '기타'),
    ];
    if (platformFilter != 'all' &&
        !platformCounts.containsKey(platformFilter)) {
      platformFilter = 'all';
    }
    final effectiveFilter = platformFilter;
    final filteredHistory = effectiveFilter == 'all'
        ? history
        : history
              .where((entry) => _platformId(entry) == effectiveFilter)
              .toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '다운로드',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 5),
            const Text(
              '링크를 분석하고 품질을 선택해 기기에 저장해요.',
              style: TextStyle(color: Color(0xFF66736F)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: url,
              enabled: !analyzing,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              onSubmitted: (_) => analyzeUrl(),
              decoration: InputDecoration(
                hintText: 'YouTube, Instagram, X 등의 URL',
                prefixIcon: const Icon(Icons.link_rounded),
                suffixIcon: IconButton(
                  onPressed: analyzing ? null : pasteUrl,
                  tooltip: '붙여넣기',
                  icon: const Icon(Icons.content_paste_rounded),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: analyzing ? null : analyzeUrl,
                icon: analyzing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.manage_search_rounded),
                label: Text(analyzing ? '처리 중' : '분석'),
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: visible.isEmpty
                  ? const _EmptyState(
                      icon: Icons.downloading_outlined,
                      title: '다운로드 기록이 없어요',
                      body: '위에 링크를 붙여넣고 원하는 품질을 선택해 보세요.',
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 28),
                      children: [
                        if (active.isNotEmpty) ...[
                          Row(
                            children: [
                              Text(
                                '진행 중',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(width: 7),
                              Text(
                                '${active.length}',
                                style: const TextStyle(
                                  color: Color(0xFF66736F),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          for (
                            var index = 0;
                            index < active.length;
                            index++
                          ) ...[
                            _downloadRow(active[index], history: false),
                            if (index != active.length - 1)
                              const Divider(height: 1),
                          ],
                          const SizedBox(height: 24),
                        ],
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                selectingHistory
                                    ? '${selectedHistoryIds.length}개 선택'
                                    : '기록',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            if (selectingHistory) ...[
                              IconButton(
                                onPressed: () => setState(() {
                                  selectingHistory = false;
                                  selectedHistoryIds.clear();
                                }),
                                icon: const Icon(Icons.close_rounded),
                                tooltip: '선택 취소',
                              ),
                              IconButton.filledTonal(
                                onPressed: selectedHistoryIds.isEmpty
                                    ? null
                                    : () => _deleteHistory(
                                        history
                                            .where(
                                              (entry) => selectedHistoryIds
                                                  .contains(entry.id),
                                            )
                                            .toList(),
                                        all: false,
                                      ),
                                icon: const Icon(Icons.delete_outline_rounded),
                                tooltip: '선택한 기록 삭제',
                              ),
                            ] else if (history.isNotEmpty) ...[
                              TextButton(
                                onPressed: () =>
                                    setState(() => selectingHistory = true),
                                child: const Text('선택'),
                              ),
                              IconButton(
                                onPressed: () =>
                                    _deleteHistory(history, all: true),
                                icon: const Icon(Icons.delete_sweep_outlined),
                                tooltip: '전체 기록 삭제',
                              ),
                            ],
                          ],
                        ),
                        if (history.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 34),
                            child: Center(
                              child: Text(
                                '완료된 다운로드 기록이 여기에 표시돼요.',
                                style: TextStyle(color: Color(0xFF66736F)),
                              ),
                            ),
                          )
                        else ...[
                          const SizedBox(height: 8),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final filter in filters) ...[
                                  ChoiceChip(
                                    selected: effectiveFilter == filter.$1,
                                    label: Text(
                                      '${filter.$2} ${filter.$1 == 'all' ? history.length : platformCounts[filter.$1]}',
                                    ),
                                    onSelected: (_) => setState(() {
                                      platformFilter = filter.$1;
                                      selectingHistory = false;
                                      selectedHistoryIds.clear();
                                    }),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (
                            var index = 0;
                            index < filteredHistory.length;
                            index++
                          ) ...[
                            _downloadRow(filteredHistory[index], history: true),
                            if (index != filteredHistory.length - 1)
                              const Divider(height: 1),
                          ],
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

String _downloadLabel(DownloadEntry entry) {
  if (!entry.deviceOwned) {
    if (entry.state == 'completed') return '다른 기기에서 완료';
    if ({'queued', 'running', 'paused'}.contains(entry.state)) {
      return '다른 기기의 다운로드';
    }
  }
  return switch (entry.state) {
    'queued' => '대기 중',
    'running' => '다운로드 중',
    'paused' => '일시 중지',
    'completed' => '완료',
    'failed' => '실패',
    'canceled' => '취소됨',
    _ => entry.state,
  };
}

String _downloadStatus(DownloadEntry entry, bool active) {
  final backendStatus =
      active && entry.backendJobId != null && entry.nativeId == null
      ? switch (entry.backendStage) {
          'queued' => '서버 작업 대기 중',
          'analyzing' => '원본 분석 중',
          'downloading' => '원본 다운로드 중',
          'merging' => '영상과 오디오 병합 중',
          'processing' => '영상과 오디오 병합 중',
          'converting' => '형식 변환 중',
          'validating' => '완료 파일 검증 중',
          'verifying' => '완료 파일 검증 중',
          _ => '서버에서 파일 준비 중',
        }
      : null;
  final status =
      (!entry.deviceOwned && active
          ? _downloadLabel(entry)
          : entry.error ?? backendStatus) ??
      '${_downloadLabel(entry)}${entry.progress > 0 && active ? ' · ${entry.progress}%' : ''}';
  final withProgress =
      backendStatus != null && entry.error == null && entry.progress > 0
      ? '$status · ${entry.progress}%'
      : status;
  final size = entry.sizeBytes;
  final withSize = size != null && size > 0
      ? '$withProgress · ${_fileSizeLabel(size)}'
      : active
      ? '$withProgress · 크기 계산 중'
      : withProgress;
  final location = entry.saveLocation;
  return location == null ||
          !{'queued', 'running', 'paused', 'completed'}.contains(entry.state)
      ? withSize
      : '$withSize · 저장 위치: 내 파일 > $location';
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.onSignOut,
  });
  final AppController controller;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    final bytes =
        controller.visibleItems.fold<int>(
          0,
          (total, item) => total + (item.sizeBytes ?? 0),
        ) +
        controller.attachmentBytes;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 40),
        children: [
          Text(
            '설정',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 20),
          _SettingsGroup(
            title: '계정',
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(controller.user?.email ?? ''),
                subtitle: const Text('Moring 계정'),
              ),
              ListTile(
                leading: const Icon(Icons.manage_accounts_outlined),
                title: const Text('계정 관리'),
                subtitle: const Text('프로필과 계정 보안 설정'),
                trailing: const Icon(Icons.open_in_new_rounded, size: 19),
                onTap: () => launchUrl(
                  Uri.parse('https://account.moring.co/my'),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('저장 공간'),
                trailing: Text(_fileSize(bytes)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsGroup(
            title: '오늘 할 일과 알림',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.notifications_none_rounded),
                title: const Text('알림'),
                value: controller.notificationsEnabled,
                onChanged: (value) =>
                    controller.setPreferences(notifications: value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.picture_in_picture_alt_rounded),
                title: const Text('빠른 목록 오버레이'),
                subtitle: const Text('알림에서 중앙 목록 창 열기'),
                value: settings.overlayEnabled,
                onChanged: (value) =>
                    controller.setBehaviorSettings(overlayEnabled: value),
              ),
              ListTile(
                leading: const Icon(Icons.lock_clock_outlined),
                title: const Text('잠금화면 편집'),
                subtitle: Text(_lockPolicyLabel(settings.lockScreenPolicy)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _selectLockPolicy(context, controller),
              ),
              ListTile(
                leading: const Icon(Icons.pin_outlined),
                title: const Text('Morit 전용 PIN'),
                subtitle: const Text('4~6자리 · 이 기기의 보안 저장소에만 저장'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _configureTodayPin(context, controller),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.event_repeat_rounded),
                title: const Text('미완료 항목 이월'),
                subtitle: const Text('날짜가 바뀌면 다음 날로 넘김'),
                value: settings.carryOverIncomplete,
                onChanged: (value) =>
                    controller.setBehaviorSettings(carryOverIncomplete: value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.task_alt_rounded),
                title: const Text('당일 완료 항목 표시'),
                value: settings.showCompletedToday,
                onChanged: (value) =>
                    controller.setBehaviorSettings(showCompletedToday: value),
              ),
              ListTile(
                leading: const Icon(Icons.sort_rounded),
                title: const Text('할 일 정렬'),
                subtitle: Text(_todaySortLabel(settings.todaySort)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final selected = await _chooseSetting(
                    context,
                    title: '할 일 정렬',
                    current: settings.todaySort,
                    values: const {
                      'manual': '직접 정렬',
                      'newest': '최신순',
                      'oldest': '오래된순',
                    },
                  );
                  if (selected != null) {
                    await controller.setBehaviorSettings(todaySort: selected);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.format_list_numbered_rounded),
                title: const Text('알림 노출 개수'),
                subtitle: Text('${settings.todayNotificationLimit}개'),
                trailing: DropdownButton<int>(
                  value: settings.todayNotificationLimit,
                  underline: const SizedBox.shrink(),
                  items: const [3, 5, 8]
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text('$value'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      controller.setBehaviorSettings(
                        todayNotificationLimit: value,
                      );
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsGroup(
            title: '화면과 정리',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.animation_rounded),
                title: const Text('애니메이션'),
                value: settings.animationsEnabled,
                onChanged: (value) =>
                    controller.setBehaviorSettings(animationsEnabled: value),
              ),
              ListTile(
                leading: const Icon(Icons.border_color_outlined),
                title: const Text('완료 표시'),
                subtitle: Text(_completionStyleLabel(settings.completionStyle)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final selected = await _chooseSetting(
                    context,
                    title: '완료 표시',
                    current: settings.completionStyle,
                    values: const {
                      'marker': '노란 형광펜 + 취소선',
                      'strike': '취소선',
                      'dim': '흐리게',
                    },
                  );
                  if (selected != null) {
                    await controller.setBehaviorSettings(
                      completionStyle: selected,
                    );
                  }
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.star_outline_rounded),
                title: const Text('홈 즐겨찾기 영역'),
                value: settings.showFavorites,
                onChanged: (value) =>
                    controller.setBehaviorSettings(showFavorites: value),
              ),
              if (settings.showFavorites)
                ListTile(
                  leading: const Icon(Icons.format_list_numbered_rounded),
                  title: const Text('홈 즐겨찾기 개수'),
                  subtitle: Text('${settings.favoriteLimit}개'),
                  trailing: DropdownButton<int>(
                    value: settings.favoriteLimit,
                    underline: const SizedBox.shrink(),
                    items: const [3, 4, 6, 8]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('$value'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        controller.setBehaviorSettings(favoriteLimit: value);
                      }
                    },
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.folder_copy_outlined),
                title: const Text('폴더 정렬'),
                subtitle: Text(
                  settings.folderSort == 'name' ? '이름순' : '추가한 순서',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final selected = await _chooseSetting(
                    context,
                    title: '폴더 정렬',
                    current: settings.folderSort,
                    values: const {'manual': '추가한 순서', 'name': '이름순'},
                  );
                  if (selected != null) {
                    await controller.setBehaviorSettings(folderSort: selected);
                  }
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.density_medium_rounded),
                title: const Text('간결한 화면 밀도'),
                value: settings.compactUi,
                onChanged: (value) =>
                    controller.setBehaviorSettings(compactUi: value),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsGroup(
            title: '저장과 동기화',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.wifi_rounded),
                title: const Text('Wi-Fi에서만 다운로드'),
                subtitle: const Text('새 다운로드부터 적용'),
                value: settings.downloadWifiOnly,
                onChanged: (value) =>
                    controller.setBehaviorSettings(downloadWifiOnly: value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.sync_rounded),
                title: const Text('자동 동기화'),
                subtitle: const Text('오프라인 변경을 연결 시 반영'),
                value: controller.autoSync,
                onChanged: (value) =>
                    controller.setPreferences(syncEnabled: value),
              ),
              ListTile(
                leading: const Icon(Icons.cloud_sync_outlined),
                title: const Text('지금 동기화'),
                trailing: controller.syncing
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right_rounded),
                onTap: controller.syncing ? null : controller.sync,
              ),
              const ListTile(
                leading: Icon(Icons.https_outlined),
                title: Text('공개 HTTPS 다운로드'),
                subtitle: Text('인증 정보와 DRM 콘텐츠는 전달하지 않음'),
              ),
            ],
          ),
          const SizedBox(height: 22),
          OutlinedButton.icon(
            onPressed: controller.busy ? null : onSignOut,
            icon: const Icon(Icons.logout_rounded),
            label: const Text('로그아웃'),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text(
              'Morit 1.3.0',
              style: TextStyle(color: Color(0xFF87918F), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

String _lockPolicyLabel(String value) => switch (value) {
  'allow_locked' => '잠금 해제 없이 허용',
  'morit_pin' => 'Morit 전용 PIN 확인',
  _ => '기기 잠금 해제 후만 수정',
};

String _todaySortLabel(String value) => switch (value) {
  'newest' => '최신순',
  'oldest' => '오래된순',
  _ => '직접 정렬',
};

String _completionStyleLabel(String value) => switch (value) {
  'strike' => '취소선',
  'dim' => '흐리게',
  _ => '노란 형광펜 + 취소선',
};

Future<String?> _chooseSetting(
  BuildContext context, {
  required String title,
  required String current,
  required Map<String, String> values,
}) => showModalBottomSheet<String>(
  context: context,
  builder: (context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        for (final entry in values.entries)
          ListTile(
            title: Text(entry.value),
            trailing: entry.key == current
                ? const Icon(Icons.check_rounded)
                : null,
            onTap: () => Navigator.pop(context, entry.key),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
          ),
        ),
      ],
    ),
  ),
);

Future<void> _selectLockPolicy(
  BuildContext context,
  AppController controller,
) async {
  final selected = await _chooseSetting(
    context,
    title: '잠금화면 편집',
    current: controller.settings.lockScreenPolicy,
    values: const {
      'device_unlock': '기기 잠금 해제 후만 수정',
      'allow_locked': '잠금 해제 없이 허용',
      'morit_pin': 'Morit 전용 PIN 확인',
    },
  );
  if (selected == null || !context.mounted) return;
  if (selected == 'morit_pin' &&
      !await controller.hasTodayPin() &&
      context.mounted &&
      !await _configureTodayPin(context, controller)) {
    return;
  }
  await controller.setBehaviorSettings(lockScreenPolicy: selected);
}

Future<bool> _configureTodayPin(
  BuildContext context,
  AppController controller,
) async {
  final hasPin = await controller.hasTodayPin();
  if (!context.mounted) return false;
  final pin = TextEditingController();
  final confirmation = TextEditingController();
  var error = '';
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Morit 전용 PIN 설정'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pin,
              autofocus: true,
              obscureText: true,
              maxLength: 6,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: '4~6자리 PIN'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: confirmation,
              obscureText: true,
              maxLength: 6,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'PIN 다시 입력',
                errorText: error.isEmpty ? null : error,
              ),
            ),
          ],
        ),
        actions: [
          if (hasPin)
            TextButton(
              onPressed: () async {
                await controller.clearTodayPin();
                if (context.mounted) Navigator.pop(context, false);
              },
              child: const Text('PIN 삭제'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () async {
              if (!RegExp(r'^\d{4,6}$').hasMatch(pin.text)) {
                setState(() => error = '4~6자리 숫자를 입력하세요.');
                return;
              }
              if (pin.text != confirmation.text) {
                setState(() => error = 'PIN이 서로 다릅니다.');
                return;
              }
              await controller.setTodayPin(pin.text);
              if (context.mounted) Navigator.pop(context, true);
            },
            child: const Text('저장'),
          ),
        ],
      ),
    ),
  );
  pin.dispose();
  confirmation.dispose();
  return saved == true;
}

String _fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFF66736F),
            ),
          ),
        ),
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(_MoritUi.radius),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    );
  }
}

class ShareCapturePage extends StatefulWidget {
  const ShareCapturePage({super.key, required this.controller});
  final AppController controller;

  @override
  State<ShareCapturePage> createState() => _ShareCapturePageState();
}

class _ShareCapturePageState extends State<ShareCapturePage> {
  final title = TextEditingController();
  final note = TextEditingController();
  Map<String, dynamic>? payload;
  MediaAnalysis? mediaAnalysis;
  MediaAnalysisFailure? mediaFailure;
  Set<Uri> selectedMediaUrls = const {};
  bool mediaAnalysisAttempted = false;
  String? folderId;
  String kind = 'memo';
  bool saving = false;
  bool handingOffDownload = false;
  bool analyzingMedia = false;

  @override
  void initState() {
    super.initState();
    loadShare();
  }

  Future<void> loadShare() async {
    try {
      final value = await widget.controller.getInitialShare();
      payload = value;
      final text = value?['text'] as String? ?? '';
      final mime = value?['mimeType'] as String?;
      final uris = (value?['uris'] as List?)?.cast<String>() ?? const [];
      kind = inferKind(mime, text.isNotEmpty ? text : uris.firstOrNull ?? '');
      final sharedUrl = extractWebUrl(text);
      title.text =
          value?['subject'] as String? ??
          (kind == 'link' && sharedUrl != null
              ? sharedUrl
              : text.length > 80
              ? '${text.substring(0, 80)}…'
              : text);
      if (kind == 'memo' ||
          uris.isNotEmpty ||
          (kind == 'link' && sharedUrl != text.trim())) {
        note.text = text;
      }
      folderId = widget.controller.visibleFolders.firstOrNull?.id;
      final pageUri = Uri.tryParse(sharedUrl ?? '');
      analyzingMedia =
          kind == 'link' &&
          pageUri != null &&
          pageUri.scheme == 'https' &&
          pageUri.host.isNotEmpty;
      if (analyzingMedia && mounted) setState(() {});
      if (analyzingMedia) {
        mediaAnalysisAttempted = true;
        final result = await widget.controller.analyzeMediaUrlDetailed(
          pageUri!,
        );
        mediaAnalysis = result?.analysis;
        mediaFailure = result?.failure;
        selectedMediaUrls = initialMediaSelection(
          mediaAnalysis?.candidates ?? const [],
        );
      }
    } catch (_) {
      payload ??= const {};
    } finally {
      analyzingMedia = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    title.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> save({bool download = false}) async {
    if (widget.controller.session == null || saving) return;
    setState(() {
      saving = true;
      handingOffDownload = download;
    });
    final text = payload?['text'] as String? ?? '';
    final uris = (payload?['uris'] as List?)?.cast<String>() ?? const [];
    final fileKind = {'photo', 'video', 'file'}.contains(kind);
    final copiedPaths = <String>[];
    try {
      final selectedMedia = selectedMediaCandidates(
        mediaAnalysis?.candidates ?? const [],
        selectedMediaUrls,
      );
      final sourcePage = mediaAnalysis?.sourceUrl;
      if (download) {
        if (sourcePage == null || selectedMedia.isEmpty) {
          throw const FormatException('다운로드할 미디어를 선택해 주세요.');
        }
        await startMediaDownloads(
          selectedMedia,
          (candidate) => widget.controller.downloadCandidateFromSource(
            sourceUrl: sourcePage,
            title: title.text.trim().isEmpty
                ? candidate.fileName
                : title.text.trim(),
            description: note.text.trim(),
            candidate: candidate,
          ),
        );
        if (mounted) SystemNavigator.pop();
        return;
      }
      if (fileKind) {
        if (uris.isEmpty) throw const FormatException('공유된 파일이 없습니다.');
        if (uris.length > 20) {
          throw const FormatException('한 번에 최대 20개 파일까지 저장할 수 있어요.');
        }
        final metadataByUri = <String, Map<String, dynamic>>{
          for (final value
              in (payload?['files'] as List? ?? const []).whereType<Map>())
            if (value['uri'] is String)
              value['uri'] as String: Map<String, dynamic>.from(value),
        };
        var remainingBytes = maxMoritAttachmentBytes;
        final sharedFiles = <SharedAttachmentInput>[];
        for (final rawUri in uris) {
          final uri = Uri.tryParse(rawUri);
          if (uri?.scheme != 'content') {
            throw const FormatException('이 앱에서 읽을 수 없는 공유 파일입니다.');
          }
          final path = await widget.controller.copySharedContentUri(
            rawUri,
            maxBytes: remainingBytes,
          );
          if (path == null) throw const FileSystemException('파일 복사 실패');
          copiedPaths.add(path);
          final size = await File(path).length();
          remainingBytes -= size;
          if (remainingBytes < 0) {
            throw const FileSystemException('공유 파일의 총 크기가 500 MiB를 초과합니다.');
          }
          final metadata = metadataByUri[rawUri];
          sharedFiles.add(
            SharedAttachmentInput(
              path: path,
              fileName:
                  metadata?['fileName'] as String? ??
                  path.split(Platform.pathSeparator).last,
              mimeType:
                  metadata?['mimeType'] as String? ??
                  payload?['mimeType'] as String?,
              sizeBytes: size,
            ),
          );
        }
        final baseTitle = title.text.trim().isEmpty
            ? _kindLabel(kind)
            : title.text.trim();
        final item = await widget.controller.addSharedAttachments(
          title: baseTitle,
          note: note.text,
          folderId: folderId,
          files: sharedFiles,
        );
        if (item == null) {
          throw const FileSystemException('공유 메모를 저장하지 못했습니다.');
        }
      } else {
        final media = selectedMedia;
        final primaryMedia = media.firstOrNull;
        final sourcePageUrl =
            mediaAnalysis?.sourceUrl.toString() ??
            (kind == 'link' ? extractWebUrl(text) : null);
        final item = await widget.controller.addItem(
          kind: media.isEmpty ? kind : 'memo',
          title: title.text.trim().isEmpty
              ? media.length == 1
                    ? primaryMedia!.fileName
                    : _kindLabel(kind)
              : title.text,
          note: note.text,
          folderId: folderId,
          sourceUrl: sourcePageUrl,
          mimeType: media.length == 1
              ? primaryMedia!.mimeType
              : payload?['mimeType'] as String?,
          metadata: media.isEmpty
              ? null
              : {
                  'source_page_url': sourcePageUrl,
                  'media_provider': primaryMedia!.providerLabel,
                },
        );
        if (item != null) {
          await startMediaDownloads(
            media,
            (candidate) => widget.controller.downloadCandidate(item, candidate),
          );
        }
      }
      if (mounted) SystemNavigator.pop();
    } on Object catch (error) {
      for (final path in copiedPaths) {
        try {
          if (!widget.controller.items.any(
                (item) => item.localPath == path && !item.deleted,
              ) &&
              !widget.controller.attachments.any(
                (attachment) => attachment.localPath == path,
              )) {
            await File(path).delete();
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        saving = false;
        handingOffDownload = false;
      });
      final message = error is PlatformException
          ? error.message
          : error is FormatException
          ? error.message
          : null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message ?? (download ? '다운로드를 시작하지 못했습니다.' : '공유 항목을 저장하지 못했습니다.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: handingOffDownload
            ? const SizedBox.shrink()
            : Align(
                alignment: Alignment.bottomCenter,
                child: Material(
                  color: const Color(0xFFFBFDFC),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(_MoritUi.radius),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
                    child: payload == null || widget.controller.busy
                        ? const SizedBox(
                            height: 260,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : widget.controller.session == null
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.lock_outline_rounded, size: 42),
                              const SizedBox(height: 14),
                              Text(
                                'Morit 로그인이 필요해요',
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 8),
                              const Text('앱에서 먼저 로그인한 뒤 다시 공유해 주세요.'),
                              const SizedBox(height: 20),
                              FilledButton(
                                onPressed: SystemNavigator.pop,
                                child: const Text('확인'),
                              ),
                            ],
                          )
                        : SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Image.asset(
                                      'docs/app_logo_transparent.png',
                                      width: 44,
                                      height: 44,
                                      fit: BoxFit.contain,
                                      semanticLabel: 'Morit 앱 로고',
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        'Morit에 저장',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                if (analyzingMedia) ...[
                                  const LinearProgressIndicator(),
                                  const SizedBox(height: 8),
                                  Text(
                                    '저장 가능한 형식을 확인하는 중…',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                if (mediaAnalysis case final analysis?) ...[
                                  Text(
                                    '${analysis.providerLabel} 페이지가 공개한 저장 항목',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 8),
                                  _MediaCandidatePicker(
                                    candidates: analysis.candidates,
                                    selectedUrls: selectedMediaUrls,
                                    onChanged: (value) => setState(
                                      () => selectedMediaUrls = value,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                ] else if (mediaAnalysisAttempted &&
                                    !analyzingMedia) ...[
                                  Text(
                                    '${mediaFailure?.message ?? '이 페이지에서 공개된 다운로드 파일을 찾지 못했어요.'} 링크 자체는 저장할 수 있습니다.',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                if ((payload?['uris'] as List?)?.isNotEmpty ==
                                    true) ...[
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: const Color(0xFFE2E9E7),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          _kindIcon(kind),
                                          color: const Color(0xFF167C6A),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            '${(payload!['uris'] as List).length}개 파일 · ${payload?['mimeType'] ?? '형식 정보 없음'}',
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                ],
                                TextField(
                                  controller: title,
                                  decoration: const InputDecoration(
                                    labelText: '제목',
                                  ),
                                ),
                                const SizedBox(height: 10),
                                DropdownButtonFormField<String?>(
                                  initialValue: folderId,
                                  decoration: const InputDecoration(
                                    labelText: '폴더',
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                      value: null,
                                      child: Text('폴더 없음'),
                                    ),
                                    ...widget.controller.visibleFolders.map(
                                      (folder) => DropdownMenuItem(
                                        value: folder.id,
                                        child: Text(
                                          widget.controller
                                              .folderPath(folder.id)
                                              .map((value) => value.name)
                                              .join(' / '),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: (value) =>
                                      setState(() => folderId = value),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: note,
                                  minLines: 2,
                                  maxLines: 4,
                                  decoration: const InputDecoration(
                                    labelText: '메모 추가',
                                  ),
                                ),
                                const SizedBox(height: 16),
                                if (selectedMediaUrls.isNotEmpty)
                                  Column(
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: OutlinedButton.icon(
                                              onPressed: saving ? null : save,
                                              icon: const Icon(
                                                Icons.bookmark_add_outlined,
                                              ),
                                              label: const Text('저장'),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: FilledButton.icon(
                                              onPressed: saving
                                                  ? null
                                                  : () => save(download: true),
                                              icon: const Icon(
                                                Icons.download_rounded,
                                              ),
                                              label: Text(
                                                '${selectedMediaUrls.length}개 다운로드',
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      SizedBox(
                                        width: double.infinity,
                                        child: OutlinedButton(
                                          onPressed: saving
                                              ? null
                                              : SystemNavigator.pop,
                                          child: const Text('취소'),
                                        ),
                                      ),
                                    ],
                                  )
                                else
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: saving
                                              ? null
                                              : SystemNavigator.pop,
                                          child: const Text('취소'),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: FilledButton.icon(
                                          onPressed: saving ? null : save,
                                          icon: const Icon(
                                            Icons.bookmark_add_outlined,
                                          ),
                                          label: Text(saving ? '저장 중' : '저장'),
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
      ),
    );
  }
}

Future<void> showComposeSheet(
  BuildContext context,
  AppController controller, {
  String? initialFolderId,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '무엇을 저장할까요?',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _ActionTile(icon: Icons.notes_rounded, title: '메모', value: 'memo'),
            _ActionTile(
              icon: Icons.today_rounded,
              title: '오늘 할 일',
              value: 'today',
            ),
            _ActionTile(
              icon: Icons.link_rounded,
              title: '링크 · 북마크',
              value: 'link',
            ),
            _ActionTile(
              icon: Icons.notifications_active_outlined,
              title: '알림',
              value: 'reminder',
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  await showItemEditor(
    context,
    controller,
    action,
    initialFolderId: initialFolderId,
  );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.value,
  });
  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: const Color(0xFF167C6A)),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => Navigator.pop(context, value),
  );
}

Future<void> showItemEditor(
  BuildContext context,
  AppController controller,
  String kind, {
  String? initialFolderId,
}) async {
  final title = TextEditingController();
  final note = TextEditingController();
  final pickedFiles = <PlatformFile>[];
  String? folderId =
      controller.visibleFolders.any((folder) => folder.id == initialFolderId)
      ? initialFolderId
      : null;
  DateTime reminderAt = DateTime.now().add(const Duration(hours: 1));
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Padding(
        padding: EdgeInsets.fromLTRB(
          22,
          4,
          22,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_kindLabel(kind)} 저장',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: title,
                autofocus: true,
                keyboardType: kind == 'link'
                    ? TextInputType.url
                    : TextInputType.text,
                decoration: InputDecoration(
                  labelText: kind == 'link' ? '웹 주소' : '제목',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: note,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(labelText: '메모'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                initialValue: folderId,
                decoration: const InputDecoration(labelText: '폴더'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('폴더 없음')),
                  ...controller.visibleFolders.map(
                    (folder) => DropdownMenuItem(
                      value: folder.id,
                      child: Text(
                        controller
                            .folderPath(folder.id)
                            .map((value) => value.name)
                            .join(' / '),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => folderId = value),
              ),
              if ({'memo', 'today', 'reminder'}.contains(kind)) ...[
                const SizedBox(height: 16),
                _AttachmentEditor(
                  controller: controller,
                  staged: pickedFiles,
                  removedIds: const {},
                  onAdd: () => _pickInto(controller, pickedFiles, setState),
                  onRemoveStaged: (file) =>
                      setState(() => pickedFiles.remove(file)),
                  onRemoveExisting: (_) {},
                ),
              ],
              if (kind == 'reminder') ...[
                const SizedBox(height: 10),
                ListTile(
                  tileColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  leading: const Icon(Icons.schedule_rounded),
                  title: const Text('알림 예정 시간'),
                  subtitle: Text(
                    '${reminderAt.year}.${reminderAt.month}.${reminderAt.day} ${reminderAt.hour.toString().padLeft(2, '0')}:${reminderAt.minute.toString().padLeft(2, '0')} · 시스템 상황에 따라 늦어질 수 있음',
                  ),
                  onTap: () async {
                    final date = await showDatePicker(
                      context: context,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                      initialDate: reminderAt,
                    );
                    if (date == null || !context.mounted) return;
                    final time = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(reminderAt),
                    );
                    if (time == null) return;
                    setState(
                      () => reminderAt = DateTime(
                        date.year,
                        date.month,
                        date.day,
                        time.hour,
                        time.minute,
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 16),
              _SheetActions(
                onCancel: () => Navigator.pop(context),
                onSave: () async {
                  final value = title.text.trim();
                  if (value.isEmpty) return;
                  final link = kind == 'link' ? Uri.tryParse(value) : null;
                  if (kind == 'link' &&
                      (link == null ||
                          !{'http', 'https'}.contains(link.scheme))) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('http 또는 https 웹 주소를 입력해 주세요.'),
                      ),
                    );
                    return;
                  }
                  if (kind == 'reminder') {
                    if (!reminderAt.isAfter(DateTime.now())) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('현재보다 뒤의 시간을 선택해 주세요.')),
                      );
                      return;
                    }
                    if (!controller.notificationsEnabled) {
                      await controller.setPreferences(notifications: true);
                      if (!controller.notificationsEnabled) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('알림 권한을 허용해야 예약할 수 있어요.'),
                            ),
                          );
                        }
                        return;
                      }
                    }
                  }
                  final item = await controller.addItem(
                    kind: kind == 'today' ? 'memo' : kind,
                    title: kind == 'link'
                        ? (note.text.trim().isEmpty ? value : note.text.trim())
                        : value,
                    note: kind == 'link' ? '' : note.text,
                    sourceUrl: kind == 'link' ? value : null,
                    folderId: folderId,
                    metadata: kind == 'reminder'
                        ? {'scheduled_at': reminderAt.toUtc().toIso8601String()}
                        : null,
                    pickedFiles: pickedFiles,
                  );
                  if (item == null) return;
                  if (kind == 'today') {
                    await controller.setToday(item, true);
                  }
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
  title.dispose();
  note.dispose();
}

Future<void> showEditItemSheet(
  BuildContext context,
  AppController controller,
  MoritItem item,
) async {
  final title = TextEditingController(text: item.title);
  final note = TextEditingController(text: item.note);
  final sourceUrl = TextEditingController(text: item.sourceUrl ?? '');
  final pickedFiles = <PlatformFile>[];
  final removedAttachmentIds = <String>{};
  final parsedReminderAt = DateTime.tryParse(
    item.metadata['scheduled_at'] as String? ?? '',
  )?.toLocal();
  final initialToday = isTodayItem(item);
  var today = initialToday;
  var reminderAt =
      parsedReminderAt != null && parsedReminderAt.isAfter(DateTime.now())
      ? parsedReminderAt
      : DateTime.now().add(const Duration(hours: 1));
  var folderId =
      controller.visibleFolders.any((folder) => folder.id == item.folderId)
      ? item.folderId
      : null;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Padding(
        padding: EdgeInsets.fromLTRB(
          22,
          4,
          22,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '항목 수정',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: title,
                autofocus: true,
                maxLength: 200,
                decoration: const InputDecoration(labelText: '제목'),
              ),
              if (item.kind == 'link') ...[
                const SizedBox(height: 10),
                TextField(
                  controller: sourceUrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: '웹 주소'),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: note,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(labelText: '메모'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                initialValue: folderId,
                decoration: const InputDecoration(labelText: '폴더'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('폴더 없음')),
                  ...controller.visibleFolders.map(
                    (folder) => DropdownMenuItem(
                      value: folder.id,
                      child: Text(
                        controller
                            .folderPath(folder.id)
                            .map((value) => value.name)
                            .join(' / '),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => folderId = value),
              ),
              if (item.kind == 'memo') ...[
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('오늘 할 일'),
                  subtitle: const Text('알림에서 바로 추가·수정·완료할 수 있어요.'),
                  value: today,
                  onChanged: (value) => setState(() => today = value),
                ),
              ],
              if (supportsAttachments(item.kind)) ...[
                const SizedBox(height: 16),
                _AttachmentEditor(
                  controller: controller,
                  item: item,
                  staged: pickedFiles,
                  removedIds: removedAttachmentIds,
                  onAdd: () => _pickInto(controller, pickedFiles, setState),
                  onRemoveStaged: (file) =>
                      setState(() => pickedFiles.remove(file)),
                  onRemoveExisting: (attachment) =>
                      setState(() => removedAttachmentIds.add(attachment.id)),
                ),
              ],
              if (item.kind == 'reminder') ...[
                const SizedBox(height: 10),
                ListTile(
                  tileColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  leading: const Icon(Icons.schedule_rounded),
                  title: const Text('알림 예정 시간'),
                  subtitle: Text(
                    '${reminderAt.year}.${reminderAt.month}.${reminderAt.day} ${reminderAt.hour.toString().padLeft(2, '0')}:${reminderAt.minute.toString().padLeft(2, '0')}',
                  ),
                  onTap: () async {
                    final date = await showDatePicker(
                      context: context,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                      initialDate: reminderAt,
                    );
                    if (date == null || !context.mounted) return;
                    final time = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(reminderAt),
                    );
                    if (time == null) return;
                    setState(
                      () => reminderAt = DateTime(
                        date.year,
                        date.month,
                        date.day,
                        time.hour,
                        time.minute,
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 16),
              _SheetActions(
                onCancel: () => Navigator.pop(context),
                onSave: () async {
                  if (title.text.trim().isEmpty) return;
                  final link = Uri.tryParse(sourceUrl.text.trim());
                  if (item.kind == 'link' &&
                      (link == null ||
                          !{'http', 'https'}.contains(link.scheme))) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('http 또는 https 웹 주소를 입력해 주세요.'),
                      ),
                    );
                    return;
                  }
                  if (item.kind == 'reminder' &&
                      !reminderAt.isAfter(DateTime.now())) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('현재보다 뒤의 시간을 선택해 주세요.')),
                    );
                    return;
                  }
                  final saved = await controller.updateItem(
                    item,
                    title: title.text,
                    note: note.text,
                    folderId: folderId,
                    move: true,
                    sourceUrl: item.kind == 'link'
                        ? sourceUrl.text.trim()
                        : null,
                    metadata: item.kind == 'reminder'
                        ? {
                            ...item.metadata,
                            'scheduled_at': reminderAt
                                .toUtc()
                                .toIso8601String(),
                          }
                        : null,
                    pickedFiles: pickedFiles,
                    removedAttachmentIds: removedAttachmentIds,
                  );
                  if (!saved) return;
                  if (today != initialToday) {
                    await controller.setToday(item, today);
                  }
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
  title.dispose();
  note.dispose();
  sourceUrl.dispose();
}

Future<void> showMoveSheet(
  BuildContext context,
  AppController controller,
  MoritItem item,
) async {
  final selected = await showModalBottomSheet<String?>(
    context: context,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text(
                '이동할 폴더',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              title: const Text('폴더 없음'),
              onTap: () => Navigator.pop(context, ''),
            ),
            ...controller.visibleFolders.map(
              (folder) => ListTile(
                leading: Icon(Icons.folder_rounded, color: Color(folder.color)),
                title: Text(
                  controller
                      .folderPath(folder.id)
                      .map((value) => value.name)
                      .join(' / '),
                ),
                trailing: item.folderId == folder.id
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(context, folder.id),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('취소'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (selected != null) {
    await controller.updateItem(
      item,
      folderId: selected.isEmpty ? null : selected,
      move: true,
    );
  }
}

Future<int?> showColorPickerDialog(
  BuildContext context,
  int initialColor,
) async {
  var hsv = HSVColor.fromColor(Color(initialColor));
  return showDialog<int>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('폴더 색상'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 72,
                decoration: BoxDecoration(
                  color: hsv.toColor(),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              const SizedBox(height: 18),
              Text('색상 ${hsv.hue.round()}°'),
              Slider(
                value: hsv.hue,
                min: 0,
                max: 360,
                divisions: 360,
                label: '${hsv.hue.round()}°',
                onChanged: (value) => setState(() => hsv = hsv.withHue(value)),
              ),
              Text('채도 ${(hsv.saturation * 100).round()}%'),
              Slider(
                value: hsv.saturation,
                divisions: 100,
                label: '${(hsv.saturation * 100).round()}%',
                onChanged: (value) =>
                    setState(() => hsv = hsv.withSaturation(value)),
              ),
              Text('밝기 ${(hsv.value * 100).round()}%'),
              Slider(
                value: hsv.value,
                divisions: 100,
                label: '${(hsv.value * 100).round()}%',
                onChanged: (value) =>
                    setState(() => hsv = hsv.withValue(value)),
              ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, hsv.toColor().toARGB32()),
            child: const Text('선택'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showFolderDialog(
  BuildContext context,
  AppController controller, {
  Folder? folder,
  String? initialParentId,
}) async {
  final name = TextEditingController(text: folder?.name ?? '');
  final colors = [0xFF167C6A, 0xFF4C6FFF, 0xFFCC6B3D, 0xFF8A5FC7];
  var selected = folder?.color ?? colors.first;
  var customColor = colors.contains(selected) ? 0xFF2E748C : selected;
  var parentId = folder?.parentId ?? initialParentId;
  final excluded = folder == null
      ? const <String>{}
      : {folder.id, ...controller.descendantFolderIds(folder.id)};
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(folder == null ? '새 폴더' : '폴더 수정'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              maxLength: 80,
              decoration: const InputDecoration(labelText: '폴더 이름'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue: parentId,
              decoration: const InputDecoration(labelText: '상위 폴더'),
              items: [
                const DropdownMenuItem(value: null, child: Text('최상위')),
                ...controller.visibleFolders
                    .where((candidate) => !excluded.contains(candidate.id))
                    .map(
                      (candidate) => DropdownMenuItem(
                        value: candidate.id,
                        child: Text(
                          controller
                              .folderPath(candidate.id)
                              .map((value) => value.name)
                              .join(' / '),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
              ],
              onChanged: (value) => setState(() => parentId = value),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ...colors.map(
                  (color) => InkWell(
                    borderRadius: BorderRadius.circular(30),
                    onTap: () => setState(() => selected = color),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Color(color),
                        shape: BoxShape.circle,
                        border: selected == color
                            ? Border.all(color: Colors.black, width: 3)
                            : null,
                      ),
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(30),
                  onTap: () async {
                    final picked = await showColorPickerDialog(
                      context,
                      selected,
                    );
                    if (picked == null) return;
                    setState(() {
                      customColor = picked;
                      selected = picked;
                    });
                  },
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: Color(customColor),
                      shape: BoxShape.circle,
                      border: selected == customColor
                          ? Border.all(color: Colors.black, width: 3)
                          : null,
                    ),
                    child: const Icon(
                      Icons.colorize_rounded,
                      color: Colors.white,
                      size: 19,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.maxFinite,
            child: _SheetActions(
              onCancel: () => Navigator.pop(context),
              onSave: () async {
                final saved = await controller.saveFolder(
                  folder: folder,
                  name: name.text,
                  color: selected,
                  parentId: parentId,
                  updateParent: folder != null,
                );
                if (saved != null && context.mounted) Navigator.pop(context);
              },
            ),
          ),
        ],
      ),
    ),
  );
  name.dispose();
}

Future<void> showFolderMenu(
  BuildContext context,
  AppController controller,
  Folder folder,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text(
              '폴더',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('이름과 색상 수정'),
            onTap: () => Navigator.pop(context, 'edit'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: const Text('폴더 삭제'),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (action == 'edit') {
    await showFolderDialog(context, controller, folder: folder);
    return;
  }
  if (action == 'delete') {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${folder.name} 폴더를 삭제할까요?'),
        content: const Text('안의 항목과 하위 폴더는 한 단계 위로 이동합니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.deleteFolder(folder);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    this.count,
    this.action,
    this.onTap,
  });
  final String title;
  final int? count;
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.35,
        ),
      ),
      if (count != null) ...[
        const SizedBox(width: 7),
        Text(
          '$count',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF8B95A1),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
      const Spacer(),
      if (action != null)
        TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF6B7684),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(action!),
        ),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: const Color(0xFF9AA5A2)),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF6F7B78), height: 1.45),
          ),
        ],
      ),
    ),
  );
}

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
