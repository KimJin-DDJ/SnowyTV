import 'package:kazumi/services/video_source/mxdm_tv_source_probe.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

typedef MxdmTvSourceSelection<T> = ({
  T episode,
  VideoSource source,
  MxdmSourceCheck check,
});

final _regularEpisode = RegExp(r'^第?\s*(\d+)\s*[集话話]?$');

/// Use a unique label match. A list position can identify a different episode
/// when one of the roads includes a recap or a special.
int? matchingMxdmEpisodeIndex(String title, List<String> labels) {
  String key(String value) {
    final label = value.trim();
    final number = int.tryParse(
      _regularEpisode.firstMatch(label)?.group(1) ?? '',
    );
    return number?.toString() ?? label;
  }

  final expected = key(title);
  if (expected.isEmpty) return null;
  int? match;
  for (var index = 0; index < labels.length; index++) {
    if (key(labels[index]) != expected) continue;
    if (match != null) return null;
    match = index;
  }
  return match;
}

Future<MxdmTvSourceSelection<T>?> selectMxdmTvSource<T>(
  Iterable<T> candidates, {
  required Future<VideoSource> Function(T episode, Duration timeout) resolve,
  required Future<MxdmSourceCheck> Function(VideoSource source) inspect,
  required bool Function() isActive,
}) async {
  final elapsed = Stopwatch()..start();
  final roads = candidates.take(4).toList();
  final checkedSources = <String>{};
  MxdmTvSourceSelection<T>? fallback;
  var preferred = true;
  for (final episode in roads) {
    if (!isActive()) return null;
    final remaining = const Duration(seconds: 18) - elapsed.elapsed;
    if (remaining <= Duration.zero) break;
    final isPreferred = preferred;
    final limit = Duration(
      seconds: roads.length == 1 ? 15 : (isPreferred ? 8 : 5),
    );
    preferred = false;

    final VideoSource source;
    try {
      source = await resolve(episode, remaining < limit ? remaining : limit);
    } on VideoSourceCancelledException {
      return null;
    } catch (_) {
      continue;
    }
    if (!isActive()) return null;
    if (!checkedSources.add(source.url)) continue;

    final check = await inspect(source);
    if (!isActive()) return null;
    if (check.status == MxdmSourceStatus.unavailable) continue;

    final selection = (episode: episode, source: source, check: check);
    if (check.status == MxdmSourceStatus.compatible ||
        (isPreferred && check.status == MxdmSourceStatus.unknown)) {
      return selection;
    }
    if (fallback == null || check.status.index > fallback.check.status.index) {
      fallback = selection;
    }
  }
  return isActive() ? fallback : null;
}
