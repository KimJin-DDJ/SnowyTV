import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/player_keyboard_shortcuts.dart';
import 'package:kazumi/pages/player/player_transport_bar.dart';
import 'package:kazumi/pages/video/video_side_panel.dart';
import 'package:kazumi/services/plugin/plugin_search_service.dart';

void main() {
  testWidgets('selecting episodes opens the side panel in compact controls', (
    tester,
  ) async {
    final panel = GlobalKey<VideoSidePanelState>();
    final play = FocusNode();
    addTearDown(play.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              SizedBox(
                width: 480,
                child: PlayerTransportBar(
                  compact: true,
                  playPause: TextButton(
                    focusNode: play,
                    autofocus: true,
                    onPressed: () {},
                    child: const Text('播放'),
                  ),
                  episodes: TextButton(
                    onPressed: () => panel.currentState!.toggle(),
                    child: const Text('选集'),
                  ),
                  nextEpisode: const SizedBox.shrink(),
                  progressBuilder: (_) => const SizedBox.shrink(),
                  timeLabel: const Text('0:00'),
                  timePlacement: PlayerTimeLabelPlacement.aboveProgress,
                  controls: const SizedBox.shrink(),
                  fullscreen: const SizedBox.shrink(),
                ),
              ),
              VideoSidePanel(
                key: panel,
                fullscreen: true,
                onClosed: play.requestFocus,
                child: const Text('第199集'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('第199集'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('第199集'), findsNothing);
    expect(play.hasPrimaryFocus, isTrue);
  });

  test('source search shortens only recognized season suffixes', () {
    expect(seriesSearchFallback('凡人修仙传 第四季'), '凡人修仙传');
    expect(seriesSearchFallback('凡人修仙传 新年番'), '凡人修仙传');
    expect(seriesSearchFallback('凡人修仙传'), isNull);
    expect(seriesSearchFallback('凡人修仙传：星海飞驰篇'), isNull);
  });

  testWidgets('direction keys seek only after the progress bar gains focus', (
    tester,
  ) async {
    final playerFocus = FocusNode();
    addTearDown(playerFocus.dispose);
    final seekSteps = <int>[];
    var shortcutCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: playerFocus,
            child: Row(
              children: [
                PlayerKeyboardShortcuts(
                  focusScopeNode: playerFocus,
                  shortcuts: const {
                    'forward': ['Arrow Right'],
                  },
                  actions: {'forward': () => shortcutCount++},
                  onNavigationKey: (event) =>
                      event.logicalKey == LogicalKeyboardKey.arrowRight ||
                          event.logicalKey == LogicalKeyboardKey.arrowLeft
                      ? KeyEventResult.ignored
                      : null,
                ),
                TextButton(
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('Play'),
                ),
                PlayerRemoteProgress(
                  onSeekStep: (step) async => seekSteps.add(step),
                  child: const SizedBox(width: 160, height: 32),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(seekSteps, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(seekSteps, [1, -1]);
    expect(shortcutCount, 0);
  });
}
