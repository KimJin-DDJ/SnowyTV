import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/core/plugin_network_support.dart';
import 'package:kazumi/services/video_source/hls_sanitizing_proxy.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/utils/media.dart';

void main() {
  test('detectDirectVideoSourceFormat recognizes direct streams and ignores play pages', () {
    expect(
      detectDirectVideoSourceFormat('https://cdn.example.com/path/playlist.m3u8?token=1'),
      VideoSourceFormat.hls,
    );
    expect(
      detectDirectVideoSourceFormat('https://cdn.example.com/video/01.mp4'),
      VideoSourceFormat.auto,
    );
    expect(
      detectDirectVideoSourceFormat('https://example.com/player/?url=https://cdn.test/1.m3u8'),
      isNull,
    );
    expect(
      detectDirectVideoSourceFormat('https://example.com/play/1-1.html'),
      isNull,
    );
    expect(
      detectDirectVideoSourceFormat('https://next.xifanacg.com/anime/3252/play/47463'),
      isNull,
    );
  });

  test('HlsSanitizingProxy detects fake image headers and finds TS sync offset', () {
    final tsPackets = Uint8List(188 * 3);
    for (var i = 0; i < 3; i++) {
      tsPackets[i * 188] = 0x47;
    }

    final pngWrapped = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      ...List.filled(112, 0xAA),
      ...tsPackets,
    ]);
    expect(HlsSanitizingProxy.hasFakeImageHeader(pngWrapped), isTrue);
    expect(HlsSanitizingProxy.findMpegTsStartOffset(pngWrapped), 120);

    expect(HlsSanitizingProxy.hasFakeImageHeader(tsPackets), isFalse);
    expect(HlsSanitizingProxy.findMpegTsStartOffset(tsPackets), 0);
  });

  test('HlsSanitizingProxy rewrites playlist preserving discontinuity tags and proxies stripped segments', () async {
    final tsBody = Uint8List(188 * 3);
    for (var i = 0; i < 3; i++) {
      tsBody[i * 188] = 0x47;
      tsBody[i * 188 + 1] = i + 1;
    }
    final fakePngSeg = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      ...List.filled(200, 0x55),
      ...tsBody,
    ]);

    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((req) async {
      if (req.uri.path == '/list.webp') {
        req.response.headers.set(HttpHeaders.contentTypeHeader, 'image/webp');
        req.response.write('''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:5.0,
/seg0.webp
#EXT-X-DISCONTINUITY
#EXTINF:5.0,
/seg0.webp
#EXT-X-ENDLIST
''');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/seg0.webp') {
        req.response.headers.set(HttpHeaders.contentTypeHeader, 'image/webp');
        req.response.add(fakePngSeg);
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });

    final sourceUrl = 'http://127.0.0.1:${upstream.port}/list.webp';
    final proxiedUrl = await HlsSanitizingProxy.instance.preparePlaybackUrlIfNeeded(
      VideoSource(
        url: sourceUrl,
        offset: 0,
        type: VideoSourceType.online,
        format: VideoSourceFormat.hls,
      ),
      const {'user-agent': 'TestUA'},
    );

    expect(proxiedUrl, isNot(sourceUrl));
    expect(proxiedUrl, contains('/playlist/'));

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final m3u8Req = await client.getUrl(Uri.parse(proxiedUrl));
    final m3u8Resp = await m3u8Req.close();
    final rewritten = await utf8.decodeStream(m3u8Resp);
    expect(rewritten, contains('#EXT-X-DISCONTINUITY'));

    final segLine = const LineSplitter()
        .convert(rewritten)
        .firstWhere((l) => l.startsWith('http://127.0.0.1:'));
    final segReq = await client.getUrl(Uri.parse(segLine));
    final segResp = await segReq.close();
    final bytes = await segResp.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes, tsBody);
  });

  test('HlsSanitizingProxy skips proactive probe on ordinary .m3u8 and enables on forceProbe', () async {
    final tsBody = Uint8List(188 * 2);
    for (var i = 0; i < 2; i++) {
      tsBody[i * 188] = 0x47;
    }
    final fakePngSeg = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      ...List.filled(64, 0x33),
      ...tsBody,
    ]);

    var manifestHits = 0;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((req) async {
      if (req.uri.path == '/normal.m3u8') {
        manifestHits++;
        req.response.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
        req.response.write('''#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:5.0,
/seg0.jpg
#EXT-X-ENDLIST
''');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/seg0.jpg') {
        req.response.add(fakePngSeg);
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });

    final m3u8Source = VideoSource(
      url: 'http://127.0.0.1:${upstream.port}/normal.m3u8',
      offset: 0,
      type: VideoSourceType.online,
      format: VideoSourceFormat.hls,
    );

    final fastPath = await HlsSanitizingProxy.instance.preparePlaybackUrlIfNeeded(
      m3u8Source,
      const {'user-agent': 'TestUA'},
    );
    expect(fastPath, m3u8Source.url);
    expect(manifestHits, 0);

    final forcedPath = await HlsSanitizingProxy.instance.preparePlaybackUrlIfNeeded(
      m3u8Source,
      const {'user-agent': 'TestUA'},
      forceProbe: true,
    );
    expect(forcedPath, isNot(m3u8Source.url));
    expect(forcedPath, contains('/playlist/'));
    expect(manifestHits, 1);
  });

  test('PluginNetworkSupport initializes SecurityContext and WebView proxy rules cleanly', () {
    expect(PluginNetworkSupport.securityContext, isNotNull);
    expect(PluginNetworkSupport.isDohResolvedHost('example.com'), isFalse);
    expect(
      PluginNetworkSupport.shouldProxyInWebView(
        Uri.parse('https://www.agedm.io/play/20220408/1/1'),
      ),
      isTrue,
    );
    expect(
      PluginNetworkSupport.shouldProxyInWebView(Uri.parse('https://example.com/a')),
      isFalse,
    );
    expect(
      PluginNetworkSupport.shouldProxyInWebView(Uri.parse('about:blank')),
      isFalse,
    );
  });
}
