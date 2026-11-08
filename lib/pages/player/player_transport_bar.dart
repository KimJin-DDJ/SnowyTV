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
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyUpEvent) return KeyEventResult.ignored;
                  final key = event.logicalKey;
                  if (key == LogicalKeyboardKey.arrowRight ||
                      key == LogicalKeyboardKey.arrowLeft) {
                    final focused = FocusManager.instance.primaryFocus;
                    if (focused != null && node.hasFocus) {
                      // 按屏幕上的水平位置排序，只保留这一行内可见的按钮。
                      // 树顺序里混有全屏/隐藏节点，按树顺序跳会让焦点掉出控制栏。
                      final rowRect = node.rect.inflate(2);
                      final inRow = node.traversalDescendants.where((d) {
                        if (d.context == null || !d.canRequestFocus) {
                          return false;
                        }
                        final r = d.rect;
                        return r.width > 0 &&
                            r.height > 0 &&
                            rowRect.contains(r.center) &&
                            r.height <= rowRect.height;
                      }).toList();
                      final candidates = inRow
                          .where((c) => !inRow.any(
                              (o) => o != c && o.ancestors.contains(c)))
                          .toList()
                        ..sort((a, b) =>
                            a.rect.center.dx.compareTo(b.rect.center.dx));
                      final index = candidates.indexWhere(
                        (d) => d == focused || focused.ancestors.contains(d),
                      );
                      if (index != -1) {
                        final next = key == LogicalKeyboardKey.arrowRight
                            ? index + 1
                            : index - 1;
                        if (next >= 0 && next < candidates.length) {
                          candidates[next].requestFocus();
                        }
                        // 到达两端时停住，避免按键落到快进/快退。
                        return KeyEventResult.handled;
                      }
                    }
                  }
                  return KeyEventResult.ignored;
                },
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
            ),
            if (timePlacement != PlayerTimeLabelPlacement.aboveProgress)
              const SizedBox(height: 6),
          ],
        );
}
