import 'dart:async';

/// Monotonic startup milestones for one episode resolution / playback attempt.
///
/// Android's bundled media_kit renderer does not expose a reliable physical
/// first-frame event. The output-ready callback is a proxy based on video
/// parameters / surface sizing and playback progress. This intentionally
/// accepts no URL or title so diagnostics cannot emit signed playback URLs.
final class PlaybackStartupTiming {
  PlaybackStartupTiming({required void Function(String) onEvent})
      : _onEvent = onEvent {
    _clock.start();
    _emit('parse_start');
  }

  final void Function(String) _onEvent;
  final Stopwatch _clock = Stopwatch();
  Timer? _rendererReadyTimeout;
  int _attempt = 0;
  int? _openStartedMicros;
  bool _rendererReadyRecorded = false;

  int get _elapsedMs => _clock.elapsedMilliseconds;

  void _emit(String event) {
    _onEvent('startup_timing event=$event elapsed_ms=$_elapsedMs');
  }

  void addressReady(String format) {
    _onEvent('startup_timing event=address_ready elapsed_ms=$_elapsedMs '
        'parse_ms=$_elapsedMs format=$format '
        'first_segment_signal=unavailable');
  }

  void playerOpenStarted() {
    _rendererReadyTimeout?.cancel();
    _attempt++;
    _openStartedMicros = _clock.elapsedMicroseconds;
    _rendererReadyRecorded = false;
    _onEvent('startup_timing event=player_open_start attempt=$_attempt '
        'elapsed_ms=$_elapsedMs');
    _rendererReadyTimeout = Timer(const Duration(seconds: 60), () {
      if (_rendererReadyRecorded || _openStartedMicros == null) return;
      final openMs =
          (_clock.elapsedMicroseconds - _openStartedMicros!) ~/ 1000;
      _onEvent('startup_timing event=renderer_ready_timeout '
          'attempt=$_attempt open_ms=$openMs timeout_ms=60000 '
          'first_frame_signal=unavailable');
    });
  }

  void videoOutputReady({Duration? openDuration}) {
    final openStartedMicros = _openStartedMicros;
    if (_rendererReadyRecorded || openStartedMicros == null) return;
    _rendererReadyRecorded = true;
    _rendererReadyTimeout?.cancel();
    final openMs = openDuration?.inMilliseconds ??
        (_clock.elapsedMicroseconds - openStartedMicros) ~/ 1000;
    _onEvent('startup_timing event=video_output_ready attempt=$_attempt '
        'open_ms=$openMs elapsed_ms=$_elapsedMs '
        'signal=media_kit_output_ready_proxy '
        'first_frame_signal=unavailable');
  }

  void dispose() {
    _rendererReadyTimeout?.cancel();
    _clock.stop();
  }
}
