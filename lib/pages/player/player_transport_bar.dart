import 'dart:async';

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum PlayerTimeLabelPlacement {
  aboveProgress,
  besideProgress,
  afterPlaybackButtons;

  static PlayerTimeLabelPlacement forViewport(
    Size viewport, {
    required bool desktop,
  }) {
    if (desktop) return afterPlaybackButtons;
    final hasRoomForSideLabels =
        viewport.shortestSide >= 600 &&
        viewport.shortestSide / viewport.longestSide >= 9 / 16;
    return hasRoomForSideLabels ? besideProgress : aboveProgress;
  }
}

class PlayerRemoteProgress extends StatelessWidget {
  const PlayerRemoteProgress({
    super.key,
    required this.onSeekStep,
    required this.child,
  });

  final Future<void> Function(int) onSeekStep;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    onKeyEvent: (_, event) {
      if (event is KeyUpEvent) return KeyEventResult.ignored;
      final direction = switch (event.logicalKey) {
        LogicalKeyboardKey.arrowLeft => -1,
        LogicalKeyboardKey.arrowRight => 1,
        _ => 0,
      };
      if (direction == 0) return KeyEventResult.ignored;
      unawaited(onSeekStep(direction));
      return KeyEventResult.handled;
    },
    child: Semantics(
      label: '播放进度',
      slider: true,
      child: Padding(padding: const EdgeInsets.all(4), child: child),
    ),
  );
}

class PlayerTransportBar extends StatelessWidget {
  const PlayerTransportBar({
    super.key,
    required this.compact,
    required this.playPause,
    required this.nextEpisode,
    this.episodes,
    required this.progressBuilder,
    required this.timeLabel,
    required this.timePlacement,
    required this.controls,
    required this.fullscreen,
  });

  final bool compact;
  final Widget playPause;
  final Widget nextEpisode;
  final Widget? episodes;
  final Widget Function(TimeLabelLocation location) progressBuilder;
  final Widget timeLabel;
  final PlayerTimeLabelPlacement timePlacement;
  final Widget controls;
  final Widget fullscreen;

  @override
  Widget build(BuildContext context) => compact
      ? Row(
          children: [
            playPause,
            ?episodes,
            Expanded(child: progressBuilder(TimeLabelLocation.none)),
            timeLabel,
            fullscreen,
          ],
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (timePlacement == PlayerTimeLabelPlacement.aboveProgress)
              Padding(
                padding: const EdgeInsets.only(left: 10, bottom: 10),
                child: timeLabel,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: progressBuilder(
                timePlacement == PlayerTimeLabelPlacement.besideProgress
                    ? TimeLabelLocation.sides
                    : TimeLabelLocation.none,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  playPause,
                  ?episodes,
                  nextEpisode,
                  if (timePlacement ==
                      PlayerTimeLabelPlacement.afterPlaybackButtons)
                    Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: timeLabel,
                    ),
                  Expanded(child: controls),
                  fullscreen,
                ],
              ),
            ),
            if (timePlacement != PlayerTimeLabelPlacement.aboveProgress)
              const SizedBox(height: 6),
          ],
        );
}
