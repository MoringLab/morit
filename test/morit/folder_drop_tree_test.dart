import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morit/morit/data/morit_models.dart';
import 'package:morit/morit/folder_drop_tree.dart';

void main() {
  final now = DateTime.utc(2026, 7, 23);

  Folder folder(String id, {String? parentId}) => Folder(
    id: id,
    userId: 'user-1',
    name: id,
    color: 0xFF167C6A,
    parentId: parentId,
    createdAt: now,
    updatedAt: now,
  );

  test('folder tree expands hierarchy and rejects unsafe destinations', () {
    final folders = [folder('업무'), folder('하위', parentId: '업무'), folder('개인')];
    expect(
      shouldShowFolderDropTree((
        type: 'item',
        id: 'root-item',
        showTree: false,
      )),
      isFalse,
    );
    expect(
      shouldShowFolderDropTree((
        type: 'item',
        id: 'nested-item',
        showTree: true,
      )),
      isTrue,
    );

    expect(
      visibleFolderDropRows(folders, const {}).map((row) => row.folder.id),
      ['업무', '개인'],
    );
    expect(
      visibleFolderDropRows(folders, const {
        '업무',
      }).map((row) => (row.folder.id, row.depth)),
      [('업무', 0), ('하위', 1), ('개인', 0)],
    );

    const draggedFolder = (type: 'folder', id: '업무', showTree: true);
    final folderIds = folders.map((value) => value.id).toSet();
    expect(
      canDropInFolder(
        data: draggedFolder,
        sourceFolderId: null,
        destinationFolderId: null,
        folderIds: folderIds,
        blockedFolderIds: const {'업무', '하위'},
      ),
      isFalse,
    );
    expect(
      canDropInFolder(
        data: draggedFolder,
        sourceFolderId: null,
        destinationFolderId: '하위',
        folderIds: folderIds,
        blockedFolderIds: const {'업무', '하위'},
      ),
      isFalse,
    );
    expect(
      canDropInFolder(
        data: draggedFolder,
        sourceFolderId: null,
        destinationFolderId: '개인',
        folderIds: folderIds,
        blockedFolderIds: const {'업무', '하위'},
      ),
      isTrue,
    );
  });

  testWidgets('hover expands a folder, previews its path and accepts drop', (
    tester,
  ) async {
    final folders = [folder('업무'), folder('하위', parentId: '업무')];
    const data = (type: 'item', id: 'memo-1', showTree: true);
    String? droppedFolderId;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              FolderDropTree(
                data: data,
                folders: folders,
                expandDelay: const Duration(milliseconds: 100),
                canDrop: (_) => true,
                pathLabel: (folderId) =>
                    folderId == null ? '루트' : '루트 / $folderId',
                onDrop: (folderId) => droppedFolderId = folderId,
              ),
              Align(
                alignment: Alignment.topCenter,
                child: LongPressDraggable<FolderDragData>(
                  data: data,
                  feedback: const Material(child: Text('이동 중')),
                  child: const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('드래그'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('하위'), findsNothing);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('드래그')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.text('업무')));
    await tester.pump();

    expect(find.text('이동 위치 · 루트 / 업무'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('하위'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    expect(droppedFolderId, '업무');
  });
}
