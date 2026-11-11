import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kazumi/request/core/plugin_network_support.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

/// Local loopback HLS proxy for sources whose playlists are served with a
/// non-`.m3u8` extension (e.g. `.webp`) or whose MPEG-TS segments prepend a
/// fake image header (`PNG`, `WEBP`, `GIF`, `JPEG`) before the `0x47` sync byte.
class HlsSanitizingProxy {
  HlsSanitizingProxy._();

  static final HlsSanitizingProxy instance = HlsSanitizingProxy._();

  static const _maxSessions = 24;
  static const _probeTimeout = Duration(seconds: 5);
  static const _segmentTimeout = Duration(seconds: 15);
  static const _tsPacketSize = 188;

  HttpServer? _server;
  Future<HttpServer>? _starting;
  int _nextId = 0;
  final Map<String, _ProxySession> _sessions = {};
  final HttpClient _httpClient = PluginNetworkSupport.createHttpClient();

  /// Inspects [source] and returns a rewritten loopback playlist URL if its
  /// segments are disguised behind a fake image header (or if its HLS manifest
  /// uses a non-`.m3u8` URL); otherwise returns `source.url` unchanged.
  static bool _isKnownDisguisedHlsHost(String host) {
    final lower = host.toLowerCase();
    return lower.contains('hhjx') || lower.contains('danmuzf');
  }

  Future<String> preparePlaybackUrlIfNeeded(
    VideoSource source,
    Map<String, String> headers, {
    bool forceProbe = false,
  }) async {
    final uri = Uri.tryParse(source.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return source.url;
    }

    final isExplicitHls = source.format == VideoSourceFormat.hls;
    final pathLower = uri.path.toLowerCase();
    final isNormalM3u8Path = pathLower.endsWith('.m3u8');
    if (!isExplicitHls && !isNormalM3u8Path) {
      return source.url;
    }

    // Normal .m3u8 streams shouldn't incur an extra blocking HTTP roundtrip before
    // mpv opens them (especially across dead fallback CDN lines). Proactively
    // probe only when the playlist extension is non-standard (e.g. ezdmw .webp)
    // or the host is known to serve image-prefixed TS segments (e.g. hhjx).
    if (!forceProbe &&
        !_isKnownDisguisedHlsHost(uri.host) &&
        isNormalM3u8Path) {
      return source.url;
    }

    try {
      final manifest = await _fetchText(uri, headers).timeout(_probeTimeout);
      if (!manifest.trimLeft().startsWith('#EXTM3U')) {
        return source.url;
      }

      var samplePlaylistUri = uri;
      var sampleManifest = manifest;
      if (M3u8Parser.detectType(manifest) == M3u8Type.master) {
        final variants = M3u8Parser.parseMasterPlaylist(manifest, uri.toString()).variants;
        if (variants.isEmpty) return source.url;
        samplePlaylistUri = Uri.parse(variants.first.uri);
        sampleManifest = await _fetchText(samplePlaylistUri, headers).timeout(_probeTimeout);
        if (!sampleManifest.trimLeft().startsWith('#EXTM3U')) {
          return source.url;
        }
      }

      final firstSegmentUrl = _firstSegmentUrl(sampleManifest, samplePlaylistUri);
      if (firstSegmentUrl == null) {
        return source.url;
      }
      final segPath = Uri.tryParse(firstSegmentUrl)?.path.toLowerCase() ?? '';
      final suspiciousSegmentExt = !segPath.endsWith('.ts') && !segPath.endsWith('.m4s');
      if (!isExplicitHls && !suspiciousSegmentExt) {
        return source.url;
      }

      final headBytes = await _fetchHeadBytes(
        Uri.parse(firstSegmentUrl),
        headers,
      ).timeout(_probeTimeout);
      final hasImagePrefix = hasFakeImageHeader(headBytes);
      if (!hasImagePrefix && pathLower.endsWith('.m3u8')) {
        return source.url;
      }
      if (!hasImagePrefix && !isExplicitHls) {
        return source.url;
      }

      final server = await _ensureServer();
      final sessionId = '${++_nextId}';
      _storeSession(sessionId, _ProxySession(headers: Map.of(headers)));
      final proxied = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/playlist/$sessionId.m3u8',
        queryParameters: {'u': uri.toString()},
      ).toString();
      KazumiLogger().i(
        'HlsSanitizingProxy: proxying disguised HLS stream ($uri -> $proxied)',
      );
      return proxied;
    } catch (error) {
      KazumiLogger().w(
        'HlsSanitizingProxy: probe skipped for ${source.url}',
        error: error,
      );
      return source.url;
    }
  }

  /// Returns `true` when [bytes] starts with PNG, WebP (RIFF), GIF, or JPEG
  /// magic bytes instead of an MPEG-TS `0x47` sync byte.
  static bool hasFakeImageHeader(Uint8List bytes) {
    if (bytes.length < 4) return false;
    if (bytes[0] == 0x47) return false;
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return true;
    }
    // WebP / RIFF: 52 49 46 46 ... 57 45 42 50
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    // GIF8
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
      return true;
    }
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true;
    }
    return false;
  }

  /// Finds the byte offset where valid MPEG-TS packets (`0x47` spaced by 188
  /// bytes) begin, stripping any prepended fake image header.
  static int findMpegTsStartOffset(Uint8List bytes) {
    if (bytes.isEmpty) return 0;
    if (bytes[0] == 0x47 &&
        (bytes.length <= _tsPacketSize || bytes[_tsPacketSize] == 0x47)) {
      return 0;
    }
    final maxScan = bytes.length - _tsPacketSize * 2;
    for (var i = 0; i < maxScan; i++) {
      if (bytes[i] == 0x47 &&
          bytes[i + _tsPacketSize] == 0x47 &&
          bytes[i + _tsPacketSize * 2] == 0x47) {
        return i;
      }
    }
    final singleMax = bytes.length - _tsPacketSize;
    for (var i = 0; i < singleMax; i++) {
      if (bytes[i] == 0x47 && bytes[i + _tsPacketSize] == 0x47) {
        return i;
      }
    }
    return 0;
  }

  /// Rewrites a playlist's segment/variant/key URLs so mpv fetches them through
  /// this proxy while preserving `#EXT-X-DISCONTINUITY` and all other tags.
  String rewritePlaylist(
    String content,
    Uri upstreamUri, {
    required String sessionId,
    required int port,
  }) {
    final lines = const LineSplitter().convert(content);
    final out = StringBuffer();
    final isMaster = M3u8Parser.detectType(content) == M3u8Type.master;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.writeln(line);
        continue;
      }
      if (trimmed.startsWith('#EXT-X-KEY:') ||
          trimmed.startsWith('#EXT-X-MAP:')) {
        out.writeln(_rewriteAttributeUri(
          trimmed,
          upstreamUri,
          sessionId: sessionId,
          port: port,
          isPlaylist: false,
        ));
        continue;
      }
      if (trimmed.startsWith('#')) {
        out.writeln(line);
        continue;
      }
      final resolved = upstreamUri.resolve(trimmed).toString();
      out.writeln(_proxyUrl(
        resolved,
        sessionId: sessionId,
        port: port,
        isPlaylist: isMaster,
      ));
    }
    return out.toString();
  }

  String _rewriteAttributeUri(
    String line,
    Uri upstreamUri, {
    required String sessionId,
    required int port,
    required bool isPlaylist,
  }) {
    return line.replaceFirstMapped(
      RegExp(r'URI="([^"]+)"'),
      (match) {
        final rawUri = match.group(1)!;
        final resolved = upstreamUri.resolve(rawUri).toString();
        final proxied = _proxyUrl(
          resolved,
          sessionId: sessionId,
          port: port,
          isPlaylist: isPlaylist,
        );
        return 'URI="$proxied"';
      },
    );
  }

  String _proxyUrl(
    String targetUrl, {
    required String sessionId,
    required int port,
    required bool isPlaylist,
  }) {
    final path = isPlaylist ? '/playlist/$sessionId.m3u8' : '/seg/$sessionId.ts';
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: port,
      path: path,
      queryParameters: {'u': targetUrl},
    ).toString();
  }

  String? _firstSegmentUrl(String mediaManifest, Uri baseUri) {
    for (final rawLine in const LineSplitter().convert(mediaManifest)) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      return baseUri.resolve(trimmed).toString();
    }
    return null;
  }

  Future<HttpServer> _ensureServer() {
    if (_server != null) return Future.value(_server!);
    return _starting ??= HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        .then((server) {
      _server = server;
      server.listen(_handleRequest);
      return server;
    });
  }

  void _storeSession(String id, _ProxySession session) {
    if (_sessions.length >= _maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    _sessions[id] = session;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length != 2) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final kind = segments[0];
      final sessionId = segments[1].split('.').first;
      final session = _sessions[sessionId];
      final target = request.uri.queryParameters['u'];
      final targetUri = target == null ? null : Uri.tryParse(target);
      if (session == null ||
          targetUri == null ||
          (targetUri.scheme != 'http' && targetUri.scheme != 'https')) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      if (kind == 'playlist') {
        final content = await _fetchText(targetUri, session.headers);
        final rewritten = rewritePlaylist(
          content,
          targetUri,
          sessionId: sessionId,
          port: _server!.port,
        );
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/vnd.apple.mpegurl; charset=utf-8',
        );
        request.response.write(rewritten);
        await request.response.close();
        return;
      }

      if (kind == 'seg') {
        await _pipeSanitizedSegment(request, targetUri, session.headers);
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (error) {
      KazumiLogger().w('HlsSanitizingProxy: request error', error: error);
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _pipeSanitizedSegment(
    HttpRequest request,
    Uri targetUri,
    Map<String, String> headers,
  ) async {
    var upstreamResp = await _openSegment(targetUri, headers);
    if ((upstreamResp.statusCode == 400 || upstreamResp.statusCode == 403) &&
        headers.containsKey('referer')) {
      await upstreamResp.drain();
      final noReferer = Map<String, String>.of(headers)..remove('referer');
      upstreamResp = await _openSegment(targetUri, noReferer);
    }
    request.response.statusCode = upstreamResp.statusCode;
    request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');

    if (upstreamResp.statusCode < 200 || upstreamResp.statusCode >= 300) {
      await upstreamResp.drain();
      await request.response.close();
      return;
    }

    final headerBuffer = BytesBuilder(copy: false);
    var headerStripped = false;
    await for (final chunk in upstreamResp) {
      if (headerStripped) {
        request.response.add(chunk);
        continue;
      }
      headerBuffer.add(chunk);
      if (headerBuffer.length < 4096) {
        continue;
      }
      final probe = headerBuffer.takeBytes();
      final offset = hasFakeImageHeader(probe)
          ? findMpegTsStartOffset(probe)
          : 0;
      headerStripped = true;
      if (offset < probe.length) {
        request.response.add(Uint8List.sublistView(probe, offset));
      }
    }

    if (!headerStripped) {
      final probe = headerBuffer.takeBytes();
      final offset = hasFakeImageHeader(probe)
          ? findMpegTsStartOffset(probe)
          : 0;
      if (offset < probe.length) {
        request.response.add(Uint8List.sublistView(probe, offset));
      }
    }
    await request.response.close();
  }

  Future<HttpClientResponse> _openSegment(
    Uri targetUri,
    Map<String, String> headers,
  ) async {
    final upstreamReq =
        await _httpClient.getUrl(targetUri).timeout(_segmentTimeout);
    _applyHeaders(upstreamReq, headers);
    return upstreamReq.close().timeout(_segmentTimeout);
  }

  Future<String> _fetchText(Uri uri, Map<String, String> headers) async {
    final req = await _httpClient.getUrl(uri).timeout(_probeTimeout);
    _applyHeaders(req, headers);
    final resp = await req.close().timeout(_probeTimeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      await resp.drain();
      throw HttpException('HTTP ${resp.statusCode}', uri: uri);
    }
    return utf8.decodeStream(resp);
  }

  Future<Uint8List> _fetchHeadBytes(Uri uri, Map<String, String> headers) async {
    Future<HttpClientResponse> send(Map<String, String> h) async {
      final req = await _httpClient.getUrl(uri).timeout(_probeTimeout);
      _applyHeaders(req, h);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
      return req.close().timeout(_probeTimeout);
    }

    var resp = await send(headers);
    if ((resp.statusCode == 400 || resp.statusCode == 403) &&
        headers.containsKey('referer')) {
      await resp.drain();
      final noReferer = Map<String, String>.of(headers)..remove('referer');
      resp = await send(noReferer);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
      if (builder.length >= 2048) {
        break;
      }
    }
    return builder.takeBytes();
  }

  void _applyHeaders(HttpClientRequest request, Map<String, String> headers) {
    headers.forEach((key, value) {
      if (key.toLowerCase() != 'host') {
        request.headers.set(key, value);
      }
    });
  }
}

class _ProxySession {
  const _ProxySession({required this.headers});

  final Map<String, String> headers;
}
