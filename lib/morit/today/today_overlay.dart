import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../folder_drop_tree.dart';
import '../morit_controller.dart';
import '../platform/morit_platform.dart';

Future<void> showTodayTasksModal(
  BuildContext context,
  AppController controller, {
  bool startAdding = false,
  String? initialEditId,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black54,
  builder: (context) => Dialog(
    elevation: 0,
    backgroundColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(16),
    child: TodayListPanel(
      controller: controller,
      startAdding: startAdding,
      initialEditId: initialEditId,
      onClose: () => Navigator.pop(context),
    ),
  ),
);

class TodayOverlayPage extends StatefulWidget {
  const TodayOverlayPage({
    super.key,
    required this.controller,
    required this.route,
  });

  final AppController controller;
  final String route;

  @override
  State<TodayOverlayPage> createState() => _TodayOverlayPageState();
}

class _TodayOverlayPageState extends State<TodayOverlayPage> {
  static const platform = MoritPlatform();
  Map<String, dynamic> payload = const {};
  late String route = widget.route;
  bool payloadLoaded = false;

  @override
  void initState() {
    super.initState();
    platform.setTodayOverlayHandler(_updatePayload);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final value = await platform.initialTodayOverlay();
      if (value != null) _updatePayload(value);
    } on MissingPluginException {
      // MainActivity fallback has no overlay-specific channel.
    } finally {
      if (mounted && !payloadLoaded) setState(() => payloadLoaded = true);
    }
  }

  void _updatePayload(Map<String, dynamic> value) {
    if (!mounted) return;
    final action = value['action'] as String?;
    final itemId = value['itemId'] as String?;
    setState(() {
      payloadLoaded = true;
      payload = {...payload, ...value};
      if (action != null) {
        route = '/today-overlay/$action${itemId == null ? '' : '/$itemId'}';
      }
    });
  }

  Future<void> close() async {
    try {
      await platform.closeTodayOverlay();
    } on MissingPluginException {
      SystemNavigator.pop();
    }
  }

  @override
  void dispose() {
    platform.setTodayOverlayHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!payloadLoaded) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (payload.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Material(
                  color: const Color(0xFFFBFDFC),
                  borderRadius: BorderRadius.circular(18),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.shield_outlined, size: 40),
                        const SizedBox(height: 12),
                        const Text(
                          '잠금화면 정책을 확인하지 못했습니다',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '앱을 연 뒤 다시 시도해 주세요.',
                          style: TextStyle(color: Color(0xFF6B7684)),
                        ),
                        const SizedBox(height: 18),
                        OutlinedButton(
                          onPressed: close,
                          child: const Text('취소'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final segments = Uri.tryParse(route)?.pathSegments ?? const <String>[];
    final mode = segments.length > 1 ? segments[1] : 'list';
    final itemId = segments.length > 2 ? segments[2] : null;
    final requiresUnlock = payload['requiresDeviceUnlock'] == true;
    final authorized = payload['authorized'] != false;
    final requiresPin = payload['requiresPin'] == true;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: requiresUnlock && !authorized
                ? _DeviceUnlockCard(
                    onUnlock: () => platform.requestTodayDeviceUnlock(),
                    onClose: close,
                  )
                : requiresPin
                ? _PinGate(
                    controller: widget.controller,
                    onClose: close,
                    child: TodayListPanel(
                      key: ValueKey(route),
                      controller: widget.controller,
                      startAdding: mode == 'add',
                      initialEditId: mode == 'edit' ? itemId : null,
                      initialToggleId: mode == 'toggle' ? itemId : null,
                      onClose: close,
                    ),
                  )
                : TodayListPanel(
                    key: ValueKey(route),
                    controller: widget.controller,
                    startAdding: mode == 'add',
                    initialEditId: mode == 'edit' ? itemId : null,
                    initialToggleId: mode == 'toggle' ? itemId : null,
                    onClose: close,
                  ),
          ),
        ),
      ),
    );
  }
}

class _DeviceUnlockCard extends StatelessWidget {
  const _DeviceUnlockCard({required this.onUnlock, required this.onClose});

  final Future<bool> Function() onUnlock;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 420),
    child: Material(
      color: const Color(0xFFFBFDFC),
      elevation: 16,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline_rounded, size: 42),
            const SizedBox(height: 12),
            const Text(
              '기기 잠금을 해제해 주세요',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              '오늘 할 일은 잠금 해제 후 수정할 수 있습니다.',
              style: TextStyle(color: Color(0xFF6B7684)),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => onUnlock(),
              child: const Text('잠금 해제'),
            ),
            TextButton(onPressed: onClose, child: const Text('취소')),
          ],
        ),
      ),
    ),
  );
}

class _PinGate extends StatefulWidget {
  const _PinGate({
    required this.controller,
    required this.child,
    required this.onClose,
  });

  final AppController controller;
  final Widget child;
  final VoidCallback onClose;

  @override
  State<_PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<_PinGate> {
  final pin = TextEditingController();
  bool authorized = false;
  bool checking = false;
  String? error;

  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  Future<void> verify() async {
    if (checking || pin.text.length < 4) return;
    setState(() {
      checking = true;
      error = null;
    });
    final valid = await widget.controller.verifyTodayPin(pin.text);
    if (!mounted) return;
    setState(() {
      checking = false;
      authorized = valid;
      error = valid ? null : 'PIN이 맞지 않습니다.';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (authorized) return widget.child;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Material(
        color: const Color(0xFFFBFDFC),
        elevation: 16,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Morit PIN 확인',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '이전',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                '잠금화면에서 오늘 할 일을 수정하려면 전용 PIN을 입력하세요.',
                style: TextStyle(color: Color(0xFF6B7684)),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: pin,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => verify(),
                decoration: InputDecoration(
                  labelText: '4~6자리 PIN',
                  errorText: error,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: widget.onClose,
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: checking ? null : verify,
                      child: Text(checking ? '확인 중' : '확인'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TodayListPanel extends StatefulWidget {
  const TodayListPanel({
    super.key,
    required this.controller,
    required this.onClose,
    this.startAdding = false,
    this.initialEditId,
    this.initialToggleId,
  });

  final AppController controller;
  final VoidCallback onClose;
  final bool startAdding;
  final String? initialEditId;
  final String? initialToggleId;

  @override
  State<TodayListPanel> createState() => _TodayListPanelState();
}

class _TodayListPanelState extends State<TodayListPanel> {
  final input = TextEditingController();
  final editInput = TextEditingController();
  final focusNode = FocusNode();
  final pendingFiles = <PlatformFile>[];
  final editFiles = <PlatformFile>[];
  final removedAttachmentIds = <String>{};
  late bool composing = widget.startAdding;
  bool initialActionApplied = false;
  MoritItem? editingItem;

  @override
  void initState() {
    super.initState();
    if (composing) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => focusNode.requestFocus(),
      );
    }
  }

  @override
  void dispose() {
    input.dispose();
    editInput.dispose();
    focusNode.dispose();
    super.dispose();
  }

  void applyInitialAction(List<MoritItem> items) {
    if (initialActionApplied) return;
    initialActionApplied = true;
    final editId = widget.initialEditId;
    final toggleId = widget.initialToggleId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final targetId = editId ?? toggleId;
      final item = targetId == null
          ? null
          : items.where((value) => value.id == targetId).firstOrNull;
      if (item == null) return;
      if (editId != null) {
        await edit(item);
      } else {
        await widget.controller.setTodayCompleted(
          item,
          !isTodayCompleted(item),
        );
      }
    });
  }

  Future<void> add() async {
    final value = input.text.trim();
    if (value.isEmpty) return;
    if (await widget.controller.addToday(value, pickedFiles: pendingFiles) ==
        null) {
      return;
    }
    input.clear();
    pendingFiles.clear();
    focusNode.requestFocus();
  }

  Future<void> pickInto(List<PlatformFile> target) async {
    final picked = await widget.controller.pickAttachmentFiles();
    if (picked.isEmpty || !mounted) return;
    final merged = <PlatformFile>[];
    final keys = <String>{};
    for (final file in [...target, ...picked]) {
      final key = '${normalizeAttachmentFileName(file.name)}:${file.size}';
      if (keys.add(key)) merged.add(file);
    }
    if (merged.length > 20 ||
        merged.fold<int>(0, (sum, file) => sum + file.size) >
            maxMoritAttachmentBytes) {
      widget.controller.showMessage('첨부 파일은 최대 20개, 총 500 MiB까지 추가할 수 있습니다.');
      return;
    }
    setState(() {
      target
        ..clear()
        ..addAll(merged);
    });
  }

  Future<void> edit(MoritItem item) async {
    setState(() {
      editingItem = item;
      editInput.text = item.note.isNotEmpty ? item.note : item.title;
      editFiles.clear();
      removedAttachmentIds.clear();
      composing = false;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => focusNode.requestFocus(),
    );
  }

  Future<void> saveEdit() async {
    final item = editingItem;
    if (item == null || editInput.text.trim().isEmpty) return;
    final saved = await widget.controller.updateTodayText(
      item,
      editInput.text,
      pickedFiles: editFiles,
      removedAttachmentIds: removedAttachmentIds,
    );
    if (!saved || !mounted) return;
    setState(() {
      editingItem = null;
      editFiles.clear();
      removedAttachmentIds.clear();
    });
  }

  Future<void> remove(MoritItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('할 일을 삭제할까요?'),
        content: const Text('메모와 동기화된 모든 기기에서도 삭제됩니다.'),
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
    if (confirmed == true) await widget.controller.deleteItem(item);
  }

  Widget buildEditPanel(BuildContext context, MoritItem item) {
    final attachments = widget.controller
        .attachmentsForItem(item.id)
        .where((value) => !removedAttachmentIds.contains(value.id))
        .toList();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
      child: Material(
        color: const Color(0xFFFBFDFC),
        elevation: 18,
        shadowColor: Colors.black38,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '목록으로',
                    onPressed: () => setState(() {
                      editingItem = null;
                      editFiles.clear();
                      removedAttachmentIds.clear();
                    }),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const Expanded(
                    child: Text(
                      '할 일 수정',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: editInput,
                focusNode: focusNode,
                autofocus: true,
                maxLength: 500,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '할 일'),
              ),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '첨부 파일',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => pickInto(editFiles),
                    icon: const Icon(Icons.attach_file_rounded, size: 18),
                    label: const Text('추가'),
                  ),
                ],
              ),
              if (attachments.isEmpty && editFiles.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4, bottom: 12),
                  child: Text(
                    '사진, 영상, 문서를 추가할 수 있어요.',
                    style: TextStyle(color: Color(0xFF6B7684)),
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final attachment in attachments)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title: Text(
                          attachment.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          attachment.lastError ??
                              switch (attachment.uploadState) {
                                AttachmentUploadState.pending => '업로드 대기 중',
                                AttachmentUploadState.uploading => '업로드 중',
                                AttachmentUploadState.uploaded => '동기화됨',
                                AttachmentUploadState.failed => '업로드 실패',
                                AttachmentUploadState.deleting => '삭제 중',
                              },
                        ),
                        onTap: () =>
                            widget.controller.openAttachment(attachment),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) async {
                            if (value == 'open') {
                              await widget.controller.openAttachment(
                                attachment,
                              );
                            } else if (value == 'retry') {
                              await widget.controller.retryAttachment(
                                attachment,
                              );
                            } else {
                              setState(
                                () => removedAttachmentIds.add(attachment.id),
                              );
                            }
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'open',
                              child: Text('열기'),
                            ),
                            if (attachment.uploadState ==
                                AttachmentUploadState.failed)
                              const PopupMenuItem(
                                value: 'retry',
                                child: Text('업로드 다시 시도'),
                              ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('삭제'),
                            ),
                          ],
                        ),
                      ),
                    for (final file in editFiles)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.upload_file_rounded),
                        title: Text(
                          file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: const Text('저장 시 업로드'),
                        trailing: IconButton(
                          tooltip: '첨부에서 제거',
                          onPressed: () =>
                              setState(() => editFiles.remove(file)),
                          icon: const Icon(Icons.remove_circle_outline_rounded),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: widget.onClose,
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: saveEdit,
                      child: const Text('저장'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final items = widget.controller.todayItems;
        applyInitialAction(items);
        final editing = editingItem;
        if (editing != null) return buildEditPanel(context, editing);
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
          child: Material(
            color: const Color(0xFFFBFDFC),
            elevation: 18,
            shadowColor: Colors.black38,
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                widget.controller.settings.compactUi ? 14 : 20,
                20,
                16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: '이전',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Text(
                                  '오늘 할 일',
                                  style: TextStyle(
                                    color: Color(0xFF17211F),
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(width: 7),
                                Text(
                                  '${widget.controller.allTodayItems.length}',
                                  style: const TextStyle(
                                    color: Color(0xFF8B95A1),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            const Text(
                              '완료한 일도 오늘은 여기에 남아 있어요',
                              style: TextStyle(color: Color(0xFF6B7684)),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          setState(() => composing = true);
                          focusNode.requestFocus();
                        },
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('추가'),
                      ),
                    ],
                  ),
                  AnimatedSize(
                    duration: widget.controller.settings.animationsEnabled
                        ? const Duration(milliseconds: 220)
                        : Duration.zero,
                    child: composing
                        ? Padding(
                            padding: const EdgeInsets.only(top: 16, bottom: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: input,
                                        focusNode: focusNode,
                                        maxLength: 500,
                                        minLines: 1,
                                        maxLines: 3,
                                        textInputAction: TextInputAction.done,
                                        onSubmitted: (_) => add(),
                                        decoration: const InputDecoration(
                                          counterText: '',
                                          hintText: '오늘 끝낼 일을 입력하세요',
                                          prefixIcon: Icon(
                                            Icons.edit_note_rounded,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton.filled(
                                      tooltip: '할 일 추가',
                                      onPressed: add,
                                      icon: const Icon(
                                        Icons.arrow_upward_rounded,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                OutlinedButton.icon(
                                  onPressed: () => pickInto(pendingFiles),
                                  icon: const Icon(
                                    Icons.attach_file_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('첨부 추가'),
                                ),
                                if (pendingFiles.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      for (final file in pendingFiles)
                                        InputChip(
                                          label: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 180,
                                            ),
                                            child: Text(
                                              file.name,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          onDeleted: () => setState(
                                            () => pendingFiles.remove(file),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: items.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 48),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.task_alt_rounded,
                                  size: 42,
                                  color: Color(0xFF9AA5B1),
                                ),
                                SizedBox(height: 10),
                                Text(
                                  '오늘 할 일이 없습니다',
                                  style: TextStyle(
                                    color: Color(0xFF6B7684),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ReorderableListView.builder(
                            shrinkWrap: true,
                            buildDefaultDragHandles: false,
                            itemCount: items.length,
                            onReorder: widget.controller.reorderToday,
                            itemBuilder: (context, index) {
                              final item = items[index];
                              return ReorderableDelayedDragStartListener(
                                key: ValueKey(item.id),
                                index: index,
                                child: TodayTaskRow(
                                  item: item,
                                  controller: widget.controller,
                                  onEdit: () => edit(item),
                                  onDelete: () => remove(item),
                                  allowFolderDrag: false,
                                ),
                              );
                            },
                          ),
                  ),
                  if (items.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '${items.where(isTodayCompleted).length}개 완료 · 길게 끌어 순서 변경',
                        style: const TextStyle(
                          color: Color(0xFF8B95A1),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: widget.onClose,
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
}

class TodayTaskRow extends StatelessWidget {
  const TodayTaskRow({
    super.key,
    required this.item,
    required this.controller,
    this.onEdit,
    this.onDelete,
    this.dense = false,
    this.allowFolderDrag = true,
  });

  final MoritItem item;
  final AppController controller;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool dense;
  final bool allowFolderDrag;

  @override
  Widget build(BuildContext context) {
    final completed = isTodayCompleted(item);
    final text = item.note.isNotEmpty ? item.note : item.title;
    final row = Semantics(
      checked: completed,
      label: text,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 1 : 3),
        child: Row(
          children: [
            Checkbox(
              value: completed,
              onChanged: (value) =>
                  controller.setTodayCompleted(item, value ?? false),
            ),
            Expanded(
              child: _MarkerText(
                text: text,
                completed: completed,
                animationsEnabled: controller.settings.animationsEnabled,
                style: controller.settings.completionStyle,
                maxLines: dense ? 2 : null,
              ),
            ),
            if (onEdit != null)
              IconButton(
                tooltip: '수정',
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 20),
              ),
            if (onDelete != null)
              IconButton(
                tooltip: '삭제',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
              ),
          ],
        ),
      ),
    );
    if (!allowFolderDrag) return row;
    final data = (type: 'item', id: item.id, showTree: false);
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
        child: SizedBox(
          width: 280,
          child: ListTile(
            leading: const Icon(
              Icons.task_alt_rounded,
              color: Color(0xFF008F72),
            ),
            title: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: row),
      child: row,
    );
  }
}

class _MarkerText extends StatelessWidget {
  const _MarkerText({
    required this.text,
    required this.completed,
    required this.animationsEnabled,
    required this.style,
    required this.maxLines,
  });

  final String text;
  final bool completed;
  final bool animationsEnabled;
  final String style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final strike = completed && {'marker', 'strike'}.contains(style);
    const textStyle = TextStyle(
      color: Color(0xFF17211F),
      fontWeight: FontWeight.w600,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: textStyle),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: maxLines,
          ellipsis: maxLines == null ? null : '…',
        )..layout(maxWidth: constraints.maxWidth);
        final markerRects = painter.computeLineMetrics().map((line) {
          final height = line.height * 0.48;
          return Rect.fromLTWH(
            line.left,
            line.baseline - height * 0.55,
            line.width,
            height,
          );
        }).toList();
        return TweenAnimationBuilder<double>(
          tween: Tween(end: completed ? 1 : 0),
          duration: animationsEnabled
              ? const Duration(milliseconds: 420)
              : Duration.zero,
          curve: Curves.easeOutCubic,
          builder: (context, progress, _) => CustomPaint(
            painter: style == 'marker'
                ? _MarkerPainter(markerRects, progress)
                : null,
            child: AnimatedOpacity(
              duration: animationsEnabled
                  ? const Duration(milliseconds: 180)
                  : Duration.zero,
              opacity: completed && style == 'dim' ? 0.48 : 1,
              child: Text(
                text,
                maxLines: maxLines,
                overflow: maxLines == null
                    ? TextOverflow.clip
                    : TextOverflow.ellipsis,
                style: textStyle.copyWith(
                  decoration: strike ? TextDecoration.lineThrough : null,
                  decorationThickness: 1.6,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MarkerPainter extends CustomPainter {
  const _MarkerPainter(this.rects, this.progress);

  final List<Rect> rects;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFDE59).withValues(alpha: 0.72);
    for (final rect in rects) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            rect.left,
            rect.top,
            rect.width * progress,
            rect.height,
          ),
          const Radius.circular(4),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MarkerPainter oldDelegate) =>
      progress != oldDelegate.progress || rects != oldDelegate.rects;
}
