// DanDanPlay API credentials for the client signature flow.
// Release/PR CI injects them via --dart-define=DANDANAPI_APPID / DANDANAPI_KEY.
const Map<String, String> dandanCredentials = {
  'id': String.fromEnvironment('DANDANAPI_APPID'),
  'value': String.fromEnvironment('DANDANAPI_KEY'),
};

/// Local builds without --dart-define get empty credentials, which makes
/// every signed DanDanPlay request fail with HTTP 403.
bool get hasDandanCredentials =>
    (dandanCredentials['id'] ?? '').isNotEmpty &&
    (dandanCredentials['value'] ?? '').isNotEmpty;
