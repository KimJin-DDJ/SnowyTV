import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

enum MxdmSourceStatus { unavailable, exceedsLimit, unknown, compatible }

class MxdmSourceCheck {
  const MxdmSourceCheck(this.status, {this.hlsBitrateLimit});

  final MxdmSourceStatus status;
  final int? hlsBitrateLimit;
}

const _unknown = MxdmSourceCheck(MxdmSourceStatus.unknown);
const _unavailable = MxdmSourceCheck(MxdmSourceStatus.unavailable);
final _resolutionPattern = RegExp(r'^(\d+)x(\d+)$', caseSensitive: false);

MxdmSourceCheck inspectMxdmHlsManifest(
  String content,
  String url, {
  required bool limitTo1080p,
}) {
  final firstLine = content.trimLeft().split('\n').first.trimRight();
  if (firstLine.startsWith('<')) return _unavailable;
  if (firstLine != '#EXTM3U') return _unknown;
  if (!limitTo1080p) return const MxdmSourceCheck(MxdmSourceStatus.compatible);
  if (M3u8Parser.detectType(content) != M3u8Type.master) return _unknown;

  final variants = M3u8Parser.parseMasterPlaylist(content, url).variants;
  if (variants.isEmpty) return _unknown;
  final tiers = <int, List<bool?>>{};
  var hasUnknown = false;
  for (final variant in variants) {
    final fits = _fitsChromecastHd(variant);
    if (fits == null) hasUnknown = true;
    if (variant.bandwidth > 0) {
      tiers.putIfAbsent(variant.bandwidth, () => []).add(fits);
    }
  }

  final orderedRates = tiers.keys.toList()..sort((a, b) => b.compareTo(a));
  for (final rate in orderedRates) {
    // mpv can choose any variant at the target rate. Keep the master so
    // its linked audio and subtitle tracks remain available.
    if (tiers[rate]!.every((fits) => fits == true)) {
      final limit = rate == orderedRates.first ? null : rate;
      return MxdmSourceCheck(
        MxdmSourceStatus.compatible,
        hlsBitrateLimit: limit,
      );
    }
  }

  return hasUnknown
      ? _unknown
      : const MxdmSourceCheck(MxdmSourceStatus.exceedsLimit);
}

bool? _fitsChromecastHd(M3u8Variant variant) {
  final frameRate = variant.frameRate;
  if (frameRate != null && frameRate > 60) return false;
  final match = _resolutionPattern.firstMatch(variant.resolution ?? '');
  final width = int.tryParse(match?.group(1) ?? '');
  final height = int.tryParse(match?.group(2) ?? '');
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  if (width > 1920 || height > 1080) return false;
  if (variant.bandwidth <= 0) return null;
  return true;
}

class MxdmTvSourceProbe {
  MxdmTvSourceProbe({required this.limitTo1080p});

  static const _deadline = Duration(seconds: 3);
  static const _maxBytes = 512 * 1024;
  static const _unavailableStatuses = {401, 403, 404, 410};

  final bool limitTo1080p;
  Dio? _dio;
  CancelToken? _activeRequest;
  bool _closed = false;

  Future<MxdmSourceCheck> inspect(
    VideoSource source,
    Map<String, String> headers,
  ) async {
    final uri = Uri.tryParse(source.url);
    if (_closed || uri == null || !{'http', 'https'}.contains(uri.scheme)) {
      return _unknown;
    }
    if (source.format != VideoSourceFormat.hls &&
        !uri.path.toLowerCase().endsWith('.m3u8')) {
      return _unknown;
    }

    final token = CancelToken();
    _activeRequest = token;
    try {
      return await _fetchManifest(uri, headers, token).timeout(
        _deadline,
        onTimeout: () {
          token.cancel('MXdm manifest probe timed out');
          return _unknown;
        },
      );
    } on DioException {
      return _unknown;
    } on FormatException {
      return _unknown;
    } finally {
      if (identical(_activeRequest, token)) _activeRequest = null;
    }
  }

  Future<MxdmSourceCheck> _fetchManifest(
    Uri uri,
    Map<String, String> headers,
    CancelToken token,
  ) async {
    final dio = _dio ??= DioFactory.createForConfig(
      NetworkConfig.fromSettings(
        connectTimeout: _deadline,
        receiveTimeout: _deadline,
      ).copyWith(enableLog: false),
    );
    final response = await dio.getUri<ResponseBody>(
      uri,
      cancelToken: token,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    final body = response.data;
    if (status < 200 || status >= 300) {
      await body?.stream.listen(null).cancel();
      return _unavailableStatuses.contains(status) ? _unavailable : _unknown;
    }
    if (body == null) return _unknown;

    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (bytes.length + chunk.length > _maxBytes) return _unknown;
      bytes.add(chunk);
    }
    return inspectMxdmHlsManifest(
      utf8.decode(bytes.takeBytes(), allowMalformed: true),
      uri.toString(),
      limitTo1080p: limitTo1080p,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _activeRequest?.cancel('MXdm source probe closed');
    _dio?.close(force: true);
  }
}
