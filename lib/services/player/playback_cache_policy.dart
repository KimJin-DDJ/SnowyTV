import 'dart:async';
import 'dart:io';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/player/low_memory_mode.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';

class PlaybackCachePolicy {
  PlaybackCachePolicy({
    required bool Function() isLocalPlayback,
    required Player? Function() currentPlayer,
  })  : _isLocalPlayback = isLocalPlayback,
        _currentPlayer = currentPlayer;

  static const int _lowMemoryBufferSize = 2 * 1024 * 1024;
  /// Android/电视端安全缓存大小（32MB，平滑应对网络抖动且绝不撑爆 1.5GB 内存）
  static const int _androidBufferSize = 32 * 1024 * 1024;
  static const int _defaultBufferSize = 1500 * 1024 * 1024;

  final bool Function() _isLocalPlayback;
  final Player? Function() _currentPlayer;
  final AsyncSerialQueue _writes = AsyncSerialQueue();

  StreamSubscription<void>? _settingsSubscription;

  bool get networkAutomatic =>
      LowMemoryMode.current == LowMemoryMode.auto &&
      !_isLocalPlayback() &&
      MeteredNetworkService.isMetered;

  int get bufferSize {
    if (LowMemoryMode.current.isEnabled(
      isMetered: MeteredNetworkService.isMetered,
      isLocalPlayback: _isLocalPlayback(),
    )) {
      return _lowMemoryBufferSize;
    }
    if (Platform.isAndroid) {
      return _androidBufferSize;
    }
    return _defaultBufferSize;
  }

  void startWatching() {
    if (_settingsSubscription != null) {
      return;
    }
    _settingsSubscription = LowMemoryMode.watch().listen((_) => _onChanged());
    MeteredNetworkService.listenable.addListener(_onChanged);
  }

  void stopWatching() {
    MeteredNetworkService.listenable.removeListener(_onChanged);
    unawaited(_settingsSubscription?.cancel());
    _settingsSubscription = null;
  }

  Future<void> apply() async {
    final player = _currentPlayer();
    if (player == null) {
      return;
    }
    try {
      final pp = player.platform as NativePlayer;
      // A stale player's initialization must not block its replacement's writes.
      await pp.waitForPlayerInitialization;
      await _writes.run(() async {
        if (!identical(_currentPlayer(), player)) {
          return;
        }
        final size = bufferSize.toString();
        await pp.setProperty('demuxer-max-bytes', size);
        final backSize = (Platform.isAndroid
                ? (bufferSize ~/ 2).clamp(2 * 1024 * 1024, 16 * 1024 * 1024)
                : bufferSize)
            .toString();
        await pp.setProperty('demuxer-max-back-bytes', backSize);
      });
    } catch (e) {
      KazumiLogger().w(
        'PlaybackCachePolicy: failed to apply demuxer cache size',
        error: e,
      );
    }
  }

  void _onChanged() {
    unawaited(apply());
  }
}
