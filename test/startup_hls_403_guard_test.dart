import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/startup_hls_403_guard.dart';

void main() {
  group('StartupHls403Guard', () {
    test('requires two distinct segments paired with recent HTTP 403 logs', () {
      final guard = StartupHls403Guard();
      expect(guard.addLog('HTTP error 403 Forbidden', Duration.zero), isFalse);
      expect(
        guard.addLog(
          'Failed to open segment 12 of playlist 0',
          const Duration(milliseconds: 300),
        ),
        isFalse,
      );
      expect(
        guard.addLog('HTTP error 403 Forbidden', const Duration(seconds: 1)),
        isFalse,
      );
      expect(
        guard.addLog(
          'Failed to open segment 13 of playlist 0',
          const Duration(milliseconds: 1300),
        ),
        isTrue,
      );
      expect(guard.failed, isTrue);
    });

    test('ignores isolated 403s, duplicate segments, and expired pairs', () {
      final guard = StartupHls403Guard();
      expect(guard.addLog('HTTP error 403', Duration.zero), isFalse);
      expect(
        guard.addLog(
          'Failed to open segment 4 of playlist 1',
          const Duration(milliseconds: 50),
        ),
        isFalse,
      );
      expect(
        guard.addLog('HTTP error 403', const Duration(seconds: 1)),
        isFalse,
      );
      expect(
        guard.addLog(
          'Failed to open segment 4 of playlist 1',
          const Duration(seconds: 1, milliseconds: 50),
        ),
        isFalse,
      );
      expect(
        guard.addLog('HTTP error 403', const Duration(seconds: 10)),
        isFalse,
      );
      expect(
        guard.addLog(
          'Failed to open segment 5 of playlist 1',
          const Duration(seconds: 10, milliseconds: 50),
        ),
        isFalse,
      );
      expect(guard.failed, isFalse);
    });

    test('stops detection after video output is ready', () {
      final guard = StartupHls403Guard();
      guard.markVideoStarted();
      expect(guard.addLog('HTTP error 403', Duration.zero), isFalse);
      expect(
        guard.addLog(
          'Failed to open segment 1 of playlist 0',
          const Duration(milliseconds: 1),
        ),
        isFalse,
      );
    });
  });
}
