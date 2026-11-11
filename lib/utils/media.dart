import 'dart:io';

import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Returns the stream format if [url] points directly to a media playlist or
/// video file (rather than an HTML play page), or `null` otherwise.
VideoSourceFormat? detectDirectVideoSourceFormat(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;

  final pathLower = uri.path.toLowerCase();
  if (pathLower.endsWith('.html') ||
      pathLower.endsWith('.htm') ||
      pathLower.endsWith('.php') ||
      pathLower.endsWith('.asp') ||
      pathLower.endsWith('.aspx') ||
      pathLower.endsWith('.jsp')) {
    return null;
  }
  if (pathLower.endsWith('.m3u8')) {
    return VideoSourceFormat.hls;
  }
  if (pathLower.endsWith('.mp4') ||
      pathLower.endsWith('.mkv') ||
      pathLower.endsWith('.flv') ||
      pathLower.endsWith('.webm')) {
    return VideoSourceFormat.auto;
  }
  return null;
}

String decodeVideoSource(String iframeUrl) {
  final decodedUrl = Uri.decodeFull(iframeUrl);
  final regExp = RegExp(
    r'(http[s]?://.*?\.m3u8)|(http[s]?://.*?\.mp4)',
    caseSensitive: false,
  );

  final uri = Uri.parse(decodedUrl);
  final params = uri.queryParameters;

  var matchedUrl = iframeUrl;
  params.forEach((key, value) {
    if (regExp.hasMatch(value)) {
      matchedUrl = value;
      return;
    }
  });

  return Uri.encodeFull(matchedUrl);
}

int extractEpisodeNumber(String input) {
  final regExp = RegExp(r'第?(\d+)[话集]?');
  final match = regExp.firstMatch(input);

  if (match != null && match.group(1) != null) {
    return int.tryParse(match.group(1)!) ?? 0;
  }

  return 0;
}

Future<String> getPlayerTempPath() async {
  final directory = await getTemporaryDirectory();
  return directory.path;
}

String buildShadersAbsolutePath(String baseDirectory, List<String> shaders) {
  final absolutePaths = shaders.map((shader) {
    return path.join(baseDirectory, shader);
  }).toList();
  if (Platform.isWindows) {
    return absolutePaths.join(';');
  }
  return absolutePaths.join(':');
}
