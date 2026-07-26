import 'media_provider.dart';

Future<void> startMediaDownloads(
  List<MediaCandidate> candidates,
  Future<void> Function(MediaCandidate) start,
) async {
  Object? firstError;
  StackTrace? firstStack;
  for (var offset = 0; offset < candidates.length; offset += 2) {
    await Future.wait(
      candidates.skip(offset).take(2).map((candidate) async {
        try {
          await start(candidate);
        } on Object catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }),
    );
  }
  if (firstError != null) Error.throwWithStackTrace(firstError!, firstStack!);
}

List<List<MediaCandidate>> mediaCandidateGroups(
  List<MediaCandidate> candidates,
) {
  final byAsset = <String, List<MediaCandidate>>{};
  for (final candidate in candidates.where((value) => !value.isPreview)) {
    byAsset.putIfAbsent(_assetKey(candidate), () => []).add(candidate);
  }
  return List<List<MediaCandidate>>.unmodifiable(
    byAsset.values.map((values) => List<MediaCandidate>.unmodifiable(values)),
  );
}

Set<Uri> initialMediaSelection(List<MediaCandidate> candidates) {
  return Set.unmodifiable({
    for (final values in mediaCandidateGroups(candidates))
      (values.where((value) => value.recommended).firstOrNull ?? values.first)
          .url,
  });
}

Set<Uri> toggleMediaSelection(
  List<MediaCandidate> candidates,
  Set<Uri> selectedUrls,
  MediaCandidate candidate,
) {
  final available = candidates.map((value) => value.url).toSet();
  final next = selectedUrls.where(available.contains).toSet();
  if (!next.add(candidate.url)) {
    next.remove(candidate.url);
  } else if (candidate.assetId case final assetId?) {
    next.removeAll(
      candidates
          .where(
            (value) =>
                value.assetId == assetId &&
                value.kind == candidate.kind &&
                value.url != candidate.url,
          )
          .map((value) => value.url),
    );
  }
  return Set.unmodifiable(next);
}

String _assetKey(MediaCandidate candidate) => candidate.assetId == null
    ? candidate.url.toString()
    : '${candidate.assetId}:${candidate.kind.name}';

List<MediaCandidate> selectedMediaCandidates(
  List<MediaCandidate> candidates,
  Set<Uri> selectedUrls,
) => List.unmodifiable(
  candidates.where((candidate) => selectedUrls.contains(candidate.url)),
);
