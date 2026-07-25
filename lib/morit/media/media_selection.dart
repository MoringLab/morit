import 'media_provider.dart';

Future<void> startMediaDownloads(
  List<MediaCandidate> candidates,
  Future<void> Function(MediaCandidate) start,
) async {
  for (var offset = 0; offset < candidates.length; offset += 2) {
    await Future.wait(candidates.skip(offset).take(2).map(start));
  }
}

Set<Uri> initialMediaSelection(List<MediaCandidate> candidates) {
  final byAsset = <String, List<MediaCandidate>>{};
  for (final candidate in candidates.where((value) => !value.isPreview)) {
    byAsset.putIfAbsent(_assetKey(candidate), () => []).add(candidate);
  }
  return Set.unmodifiable({
    for (final values in byAsset.values)
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
            (value) => value.assetId == assetId && value.url != candidate.url,
          )
          .map((value) => value.url),
    );
  }
  return Set.unmodifiable(next);
}

Set<Uri> toggleAllMedia(
  List<MediaCandidate> candidates,
  Set<Uri> selectedUrls,
) {
  final all = initialMediaSelection(candidates);
  if (all.isEmpty) return Set.unmodifiable(selectedUrls);
  return allMediaAssetsSelected(candidates, selectedUrls)
      ? const {}
      : Set.unmodifiable(all);
}

bool allMediaAssetsSelected(
  List<MediaCandidate> candidates,
  Set<Uri> selectedUrls,
) {
  final availableAssets = candidates
      .where((value) => !value.isPreview)
      .map(_assetKey)
      .toSet();
  final selectedAssets = selectedMediaCandidates(
    candidates,
    selectedUrls,
  ).where((value) => !value.isPreview).map(_assetKey).toSet();
  return availableAssets.isNotEmpty &&
      selectedAssets.containsAll(availableAssets);
}

String _assetKey(MediaCandidate candidate) =>
    candidate.assetId ?? candidate.url.toString();

List<MediaCandidate> selectedMediaCandidates(
  List<MediaCandidate> candidates,
  Set<Uri> selectedUrls,
) => List.unmodifiable(
  candidates.where((candidate) => selectedUrls.contains(candidate.url)),
);
