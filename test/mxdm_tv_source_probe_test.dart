import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/video_source/mxdm_tv_source_probe.dart';

void main() {
  MxdmSourceCheck inspect(String lines) => inspectMxdmHlsManifest(
    '#EXTM3U\n$lines',
    'https://example.com/master.m3u8',
    limitTo1080p: true,
  );

  test('rejects overwide streams and accepts compatible widescreen', () {
    expect(
      inspect(
        '#EXT-X-STREAM-INF:BANDWIDTH=8,RESOLUTION=2578x1080\nwide.m3u8',
      ).status,
      MxdmSourceStatus.exceedsLimit,
    );
    expect(
      inspect(
        '#EXT-X-STREAM-INF:BANDWIDTH=8,RESOLUTION=1920x804\na.m3u8',
      ).status,
      MxdmSourceStatus.compatible,
    );
  });

  test('caps above the highest compatible size tier', () {
    final result = inspect(
      '''#EXT-X-STREAM-INF:BANDWIDTH=900,RESOLUTION=3840x2160
4k.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=500,RESOLUTION=1920x1080
hd.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=200,RESOLUTION=1280x720
sd.m3u8''',
    );
    expect(result.status, MxdmSourceStatus.compatible);
    expect(result.hlsBitrateLimit, 500);
  });

  test('equal bandwidth requires every variant to be safe', () {
    expect(
      inspect('''#EXT-X-STREAM-INF:BANDWIDTH=500,RESOLUTION=1920x1080
a
#EXT-X-STREAM-INF:BANDWIDTH=500,RESOLUTION=3840x2160
b''').status,
      MxdmSourceStatus.exceedsLimit,
    );
  });

  test('unknown metadata remains unknown and media playlist is not judged', () {
    expect(
      inspect('#EXT-X-STREAM-INF:BANDWIDTH=900\na').status,
      MxdmSourceStatus.unknown,
    );
    expect(
      inspect('#EXTINF:5,\nsegment.ts\n#EXT-X-ENDLIST').status,
      MxdmSourceStatus.unknown,
    );
  });

  test('recognizes HTML and rejects frame rates above 60', () {
    expect(
      inspectMxdmHlsManifest(
        '<html>login</html>',
        'https://x/a',
        limitTo1080p: true,
      ).status,
      MxdmSourceStatus.unavailable,
    );
    expect(
      inspect(
        '#EXT-X-STREAM-INF:BANDWIDTH=500,RESOLUTION=1920x1080,FRAME-RATE=60.1\na',
      ).status,
      MxdmSourceStatus.exceedsLimit,
    );
    expect(
      inspect(
        '#EXT-X-STREAM-INF:BANDWIDTH=500,RESOLUTION=1920x1080,FRAME-RATE=60\na',
      ).status,
      MxdmSourceStatus.compatible,
    );
  });
}
