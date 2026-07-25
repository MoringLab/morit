import 'dart:async';

import 'package:flutter/material.dart';

import 'data/morit_models.dart';

typedef FolderDragData = ({String type, String id, bool showTree});
typedef FolderDropRow = ({Folder folder, int depth});

final activeFolderDrag = ValueNotifier<FolderDragData?>(null);

bool shouldShowFolderDropTree(FolderDragData? data) => data?.showTree == true;

bool canDropInFolder({
  required FolderDragData data,
  required String? sourceFolderId,
  required String? destinationFolderId,
  required Set<String> folderIds,
  Set<String> blockedFolderIds = const {},
}) {
  if (data.type != 'item' && data.type != 'folder') return false;
  if (sourceFolderId == destinationFolderId) return false;
  if (destinationFolderId == null) return true;
  return folderIds.contains(destinationFolderId) &&
      !blockedFolderIds.contains(destinationFolderId);
}

List<FolderDropRow> visibleFolderDropRows(
  List<Folder> folders,
  Set<String> expandedFolderIds,
) {
  final children = <String?, List<Folder>>{};
  for (final folder in folders.where((value) => !value.deleted)) {
    (children[folder.parentId] ??= []).add(folder);
  }
  final result = <FolderDropRow>[];
  final seen = <String>{};

  void append(String? parentId, int depth) {
    for (final folder in children[parentId] ?? const <Folder>[]) {
      if (!seen.add(folder.id)) continue;
      result.add((folder: folder, depth: depth));
      if (expandedFolderIds.contains(folder.id)) {
        append(folder.id, depth + 1);
      }
    }
  }

  append(null, 0);
  return result;
}

class FolderDropTree extends StatefulWidget {
  const FolderDropTree({
    super.key,
    required this.data,
    required this.folders,
    required this.canDrop,
    required this.pathLabel,
    required this.onDrop,
    this.initiallyExpanded = const {},
    this.expandDelay = const Duration(milliseconds: 600),
  });

  final FolderDragData data;
  final List<Folder> folders;
  final bool Function(String? folderId) canDrop;
  final String Function(String? folderId) pathLabel;
  final ValueChanged<String?> onDrop;
  final Set<String> initiallyExpanded;
  final Duration expandDelay;

  @override
  State<FolderDropTree> createState() => _FolderDropTreeState();
}

class _FolderDropTreeState extends State<FolderDropTree> {
  final _scrollController = ScrollController();
  late final Set<String> _expanded = {...widget.initiallyExpanded};
  Timer? _expandTimer;
  Timer? _scrollTimer;
  String? _hoveredFolderId;
  String? _previewFolderId;
  bool _hasPreview = false;
  bool _previewAllowed = true;
  int _scrollDirection = 0;

  @override
  void dispose() {
    _expandTimer?.cancel();
    _scrollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _hover(String? folderId, Offset globalOffset) {
    final allowed = widget.canDrop(folderId);
    if (!_hasPreview ||
        _previewFolderId != folderId ||
        _previewAllowed != allowed) {
      setState(() {
        _hasPreview = true;
        _previewFolderId = folderId;
        _previewAllowed = allowed;
      });
    }
    _updateAutoScroll(globalOffset.dy);
    if (_hoveredFolderId == folderId) return;
    _hoveredFolderId = folderId;
    _expandTimer?.cancel();
    if (folderId == null ||
        !allowed ||
        _expanded.contains(folderId) ||
        !widget.folders.any((folder) => folder.parentId == folderId)) {
      return;
    }
    _expandTimer = Timer(widget.expandDelay, () {
      if (!mounted || _hoveredFolderId != folderId) return;
      setState(() => _expanded.add(folderId));
    });
  }

  void _leave(String? folderId) {
    if (_hoveredFolderId != folderId) return;
    _hoveredFolderId = null;
    _expandTimer?.cancel();
  }

  void _updateAutoScroll(double globalY) {
    final height = MediaQuery.sizeOf(context).height;
    final panelHeight = (height * 0.58).clamp(280.0, 520.0);
    final panelTop = height - panelHeight;
    final direction = globalY < panelTop + 72
        ? -1
        : globalY > height - 72
        ? 1
        : 0;
    if (_scrollDirection == direction) return;
    _scrollDirection = direction;
    _scrollTimer?.cancel();
    if (direction == 0) return;
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      final next = (_scrollController.offset + direction * 12)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (next == _scrollController.offset) return;
      _scrollController.jumpTo(next);
    });
  }

  Widget _target({
    required String? folderId,
    required Widget child,
    required bool allowed,
  }) => DragTarget<FolderDragData>(
    onWillAcceptWithDetails: (details) =>
        details.data == widget.data && allowed,
    onMove: (details) => _hover(folderId, details.offset),
    onLeave: (_) => _leave(folderId),
    onAcceptWithDetails: (_) => widget.onDrop(folderId),
    builder: (context, candidates, rejected) {
      final hovering = candidates.isNotEmpty || rejected.isNotEmpty;
      return AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: allowed ? 1 : 0.38,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: hovering
                ? (allowed
                      ? const Color(0xFF00A884).withValues(alpha: 0.11)
                      : Theme.of(
                          context,
                        ).colorScheme.error.withValues(alpha: 0.08))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: hovering
                ? Border.all(
                    color: allowed
                        ? const Color(0xFF00A884)
                        : Theme.of(context).colorScheme.error,
                  )
                : null,
          ),
          child: child,
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final rows = visibleFolderDropRows(widget.folders, _expanded);
    final height = (MediaQuery.sizeOf(context).height * 0.58)
        .clamp(280.0, 520.0)
        .toDouble();
    final preview = !_hasPreview
        ? '폴더 위에 놓으면 이동 경로를 확인할 수 있어요'
        : _previewAllowed
        ? '이동 위치 · ${widget.pathLabel(_previewFolderId)}'
        : '이 위치로는 이동할 수 없어요';

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.16),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            minimum: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Material(
              elevation: 18,
              color: const Color(0xFFFDFEFE),
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(28),
              child: SizedBox(
                height: height,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.drive_file_move_outline,
                            color: Color(0xFF008F72),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '폴더로 이동',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  preview,
                                  key: const ValueKey('folder-drop-preview'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _previewAllowed
                                        ? const Color(0xFF6B7684)
                                        : Theme.of(context).colorScheme.error,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
                        children: [
                          _target(
                            folderId: null,
                            allowed: widget.canDrop(null),
                            child: const ListTile(
                              minTileHeight: 52,
                              leading: Icon(Icons.home_outlined),
                              title: Text(
                                '루트',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                          for (final row in rows)
                            Padding(
                              padding: EdgeInsets.only(left: row.depth * 20.0),
                              child: _target(
                                folderId: row.folder.id,
                                allowed: widget.canDrop(row.folder.id),
                                child: ListTile(
                                  minTileHeight: 52,
                                  leading: Icon(
                                    _expanded.contains(row.folder.id)
                                        ? Icons.folder_open_rounded
                                        : Icons.folder_rounded,
                                    color: Color(row.folder.color),
                                  ),
                                  title: Text(
                                    row.folder.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  trailing:
                                      widget.folders.any(
                                        (folder) =>
                                            folder.parentId == row.folder.id,
                                      )
                                      ? Icon(
                                          _expanded.contains(row.folder.id)
                                              ? Icons.expand_less_rounded
                                              : Icons.chevron_right_rounded,
                                          color: const Color(0xFF8B95A1),
                                        )
                                      : widget.canDrop(row.folder.id)
                                      ? null
                                      : const Icon(
                                          Icons.block_rounded,
                                          size: 18,
                                        ),
                                ),
                              ),
                            ),
                        ],
                      ),
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
