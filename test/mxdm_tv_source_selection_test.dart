import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/video_source/mxdm_tv_source_probe.dart';
import 'package:kazumi/services/video_source/mxdm_tv_source_selection.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

VideoSource _source(int road) => VideoSource(
  url: 'https://example.org/$road.m3u8',
  offset: 81,
  type: VideoSourceType.online,
);

void main() {
  test('matches the episode label through specials and zero padding', () {
    expect(matchingMxdmEpisodeIndex('第11集', ['第10集', '总集篇', '第011话']), 2);
    expect(matchingMxdmEpisodeIndex('第11集', ['第11集预告', '第10集']), isNull);
    expect(matchingMxdmEpisodeIndex('第11集', ['第11集', '11']), isNull);
  });

  test(
    'uses the first compatible road after a broken and overwide road',
    () async {
      final checked = <int>[];
      final result = await selectMxdmTvSource(
        [1, 2, 3, 4],
        resolve: (road, timeout) async {
          checked.add(road);
          return _source(road);
        },
        inspect: (source) async {
          if (source.url == _source(1).url) {
            return const MxdmSourceCheck(MxdmSourceStatus.unavailable);
          }
          if (source.url == _source(2).url) {
            return const MxdmSourceCheck(MxdmSourceStatus.exceedsLimit);
          }
          return const MxdmSourceCheck(MxdmSourceStatus.compatible);
        },
        isActive: () => true,
      );
      expect(checked, [1, 2, 3]);
      expect(result?.episode, 3);
      expect(result?.source.offset, 81);
    },
  );

  test('keeps a manually selected road when its metadata is missing', () async {
    final result = await selectMxdmTvSource(
      [2, 1],
      resolve: (road, timeout) async {
        expect(road, 2);
        return _source(road);
      },
      inspect: (_) async => const MxdmSourceCheck(MxdmSourceStatus.unknown),
      isActive: () => true,
    );
    expect(result?.episode, 2);
  });

  test('keeps the wide stream when no other matching road is usable', () async {
    final result = await selectMxdmTvSource(
      [1, 2],
      resolve: (road, timeout) async => _source(road),
      inspect: (source) async => MxdmSourceCheck(
        source.url == _source(1).url
            ? MxdmSourceStatus.exceedsLimit
            : MxdmSourceStatus.unavailable,
      ),
      isActive: () => true,
    );
    expect(result?.episode, 1);
  });

  test('cancels selection when the user changes episodes', () async {
    var active = true;
    final result = await selectMxdmTvSource(
      [1, 2],
      resolve: (road, timeout) async => _source(road),
      inspect: (_) async {
        active = false;
        return const MxdmSourceCheck(MxdmSourceStatus.compatible);
      },
      isActive: () => active,
    );
    expect(result, isNull);
  });
}
