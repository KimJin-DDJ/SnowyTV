/// Detects repeated HLS segment failures explicitly associated with HTTP 403.
///
/// An HTTP error can be retried for one segment. Requiring distinct segment
/// IDs avoids switching lines for a single bad segment or repeated retries.
class StartupHls403Guard {
  StartupHls403Guard({
    this.failureThreshold = 2,
    this.failureWindow = const Duration(seconds: 8),
  }) : assert(failureThreshold > 1);

  final int failureThreshold;
  final Duration failureWindow;
  final Map<String, Duration> _recentSegments = {};

  Duration? _pending403At;
  bool _hasVideo = false;
  bool _failed = false;

  bool get hasVideo => _hasVideo;
  bool get failed => _failed;

  void markVideoStarted() {
    _hasVideo = true;
    _pending403At = null;
    _recentSegments.clear();
  }

  /// Returns true once when two distinct failed HLS segments follow 403 logs.
  /// [timestamp] must come from a monotonic clock, such as [Stopwatch.elapsed].
  bool addLog(String text, Duration timestamp) {
    if (_hasVideo || _failed) return false;

    if (_http403Pattern.hasMatch(text)) {
      _pending403At = timestamp;
      return false;
    }

    final segment = _failedSegmentPattern.firstMatch(text);
    final failedAt = _pending403At;
    if (segment == null || failedAt == null) return false;

    _pending403At = null;
    final elapsed = timestamp - failedAt;
    if (elapsed.isNegative || elapsed > failureWindow) return false;

    _recentSegments.removeWhere((_, seenAt) {
      final age = timestamp - seenAt;
      return age.isNegative || age > failureWindow;
    });
    final segmentId = '${segment[2]}:${segment[1]}';
    _recentSegments.putIfAbsent(segmentId, () => timestamp);
    if (_recentSegments.length < failureThreshold) return false;

    _failed = true;
    return true;
  }

  static final RegExp _http403Pattern = RegExp(
    r'\bhttp(?:/\d(?:\.\d)?)?(?:\s+error)?\s+403\b|\b403\s+forbidden\b',
    caseSensitive: false,
  );

  static final RegExp _failedSegmentPattern = RegExp(
    r'Failed to open segment\s+(\d+)\s+of playlist\s+(\d+)',
    caseSensitive: false,
  );
}
