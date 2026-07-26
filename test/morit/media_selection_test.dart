import 'package:flutter_test/flutter_test.dart';
import 'package:morit/morit/media/media_provider.dart';
import 'package:morit/morit/media/media_selection.dart';

void main() {
  test(
    'download preparation never exceeds the server per-user limit',
    () async {
      final candidates = List.generate(
        5,
        (index) => MediaCandidate(
          url: Uri.parse('https://download.example/$index'),
          kind: MediaKind.image,
          fileName: '$index.jpg',
          providerLabel: 'test',
        ),
      );
      var active = 0;
      var peak = 0;
      final completed = <String>[];

      await startMediaDownloads(candidates, (candidate) async {
        active += 1;
        peak = peak < active ? active : peak;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        completed.add(candidate.fileName);
        active -= 1;
      });

      expect(peak, 2);
      expect(
        completed.toSet(),
        candidates.map((value) => value.fileName).toSet(),
      );
    },
  );

  test('one failed preparation does not skip the remaining files', () async {
    final candidates = List.generate(
      5,
      (index) => MediaCandidate(
        url: Uri.parse('https://download.example/$index'),
        kind: MediaKind.image,
        fileName: '$index.jpg',
        providerLabel: 'test',
      ),
    );
    final attempted = <String>[];

    await expectLater(
      startMediaDownloads(candidates, (candidate) async {
        attempted.add(candidate.fileName);
        if (candidate.fileName == '1.jpg') throw StateError('failed');
      }),
      throwsStateError,
    );
    expect(
      attempted.toSet(),
      candidates.map((value) => value.fileName).toSet(),
    );
  });

  test('every media asset can be selected independently', () {
    MediaCandidate candidate(
      String path,
      MediaKind kind, {
      bool preview = false,
    }) => MediaCandidate(
      url: Uri.parse('https://cdn.example.com/$path'),
      kind: kind,
      fileName: path,
      providerLabel: 'Test',
      isPreview: preview,
    );

    final preview = candidate('preview.jpg', MediaKind.image, preview: true);
    final first = candidate('first.jpg', MediaKind.image);
    final second = candidate('second.jpg', MediaKind.image);
    final video = candidate('video.mp4', MediaKind.video);
    final candidates = [preview, first, second, video];

    var selected = initialMediaSelection(candidates);
    expect(selected, {first.url, second.url, video.url});

    selected = toggleMediaSelection(candidates, selected, second);
    expect(selected, {first.url, video.url});

    selected = toggleMediaSelection(candidates, selected, preview);
    expect(selected, {first.url, video.url, preview.url});

    selected = toggleMediaSelection(candidates, selected, video);
    expect(selected, {first.url, preview.url});
  });

  test('qualities are grouped and only one is selected per asset', () {
    MediaCandidate quality(String id, {bool recommended = false}) =>
        MediaCandidate(
          url: Uri.parse('https://api.example.com/selections/$id'),
          kind: MediaKind.video,
          fileName: '$id.mp4',
          providerLabel: 'Test',
          assetId: 'video-1',
          recommended: recommended,
        );

    final low = quality('720p');
    final high = quality('1080p', recommended: true);
    final audio = MediaCandidate(
      url: Uri.parse('https://api.example.com/selections/audio'),
      kind: MediaKind.audio,
      fileName: 'audio.m4a',
      providerLabel: 'Test',
      assetId: 'video-1',
    );
    final candidates = [low, high, audio];
    expect(mediaCandidateGroups(candidates), [
      [low, high],
      [audio],
    ]);
    var selected = initialMediaSelection(candidates);
    expect(selected, {high.url, audio.url});

    selected = toggleMediaSelection(candidates, selected, low);
    expect(selected, {low.url, audio.url});
  });
}
