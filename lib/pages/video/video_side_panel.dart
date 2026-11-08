import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/side_panel_transition.dart';

class VideoSidePanel extends StatefulWidget {
  const VideoSidePanel({
    super.key,
    required this.fullscreen,
    required this.child,
    this.disableAnimations = false,
    this.onOpened,
    this.onClosed,
  });

  final bool fullscreen;
  final bool disableAnimations;
  final Widget child;
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  @override
  State<VideoSidePanel> createState() => VideoSidePanelState();
}

class VideoSidePanelState extends State<VideoSidePanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: SidePanelTransition.duration,
  );
  late final Animation<double> _opacity = _animation.drive(
    CurveTween(curve: Curves.easeIn),
  );
  LocalHistoryEntry? _historyEntry;
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'Video side panel');

  bool get _isOpening =>
      _animation.status == AnimationStatus.forward ||
      _animation.status == AnimationStatus.completed;

  void toggle() {
    if (_isOpening) {
      close();
    } else {
      if (widget.disableAnimations) {
        _animation.value = 1;
      } else {
        _animation.forward();
      }
      final route = ModalRoute.of(context);
      if (route != null) {
        final entry = LocalHistoryEntry(
          impliesAppBarDismissal: false,
          onRemove: () {
            if (_historyEntry == null) return;
            _historyEntry = null;
            close();
          },
        );
        _historyEntry = entry;
        route.addLocalHistoryEntry(entry);
      }
      widget.onOpened?.call();
      _ensureFocusInside();
    }
  }

  /// 遥控器操作时，面板打开后焦点必须进到面板里，否则方向键还在控制播放器，
  /// 面板里的「播放线路」和剧集都选不到。onOpened 里会尝试聚焦当前集，
  /// 这里兜底：几帧后焦点仍不在面板内，就落到面板第一个可聚焦控件上。
  void _ensureFocusInside() {
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (!mounted || !_isOpening || _scope.hasFocus) return;
      final first = _scope.traversalDescendants
          .where((node) => node.canRequestFocus && node.context != null)
          .firstOrNull;
      if (first != null) {
        first.requestFocus();
      } else {
        _scope.requestFocus();
      }
    });
  }

  void close() {
    _removeHistoryEntry();
    if (widget.disableAnimations) {
      _animation.value = 0;
    } else {
      _animation.reverse();
    }
    widget.onClosed?.call();
  }

  void _removeHistoryEntry() {
    final entry = _historyEntry;
    _historyEntry = null;
    entry?.remove();
  }

  @override
  void didUpdateWidget(VideoSidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset before rendering the new mode to avoid a sidebar flash.
    if (oldWidget.fullscreen != widget.fullscreen) {
      _removeHistoryEntry();
      _animation.value = 0;
    }
  }

  @override
  void dispose() {
    _removeHistoryEntry();
    _animation.dispose();
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        if (_animation.isDismissed) return const SizedBox.shrink();
        return Stack(
          alignment: Alignment.centerRight,
          children: [
            FadeTransition(
              opacity: _opacity,
              child: GestureDetector(
                onTap: close,
                child: SizedBox.expand(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Colors.black.withValues(alpha: 0.5),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SidePanelTransition(animation: _animation, child: child!),
          ],
        );
      },
      child: SizedBox(
        // Keep space outside the panel for dismissal.
        width: math.min(
          constraints.maxWidth * 0.9,
          (constraints.maxWidth / 3).clamp(320.0, 420.0),
        ),
        height: constraints.maxHeight,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadiusDirectional.only(
            topStart: Radius.circular(28),
            bottomStart: Radius.circular(28),
          ),
          clipBehavior: Clip.antiAlias,
          // Consume the hidden status-bar inset for the entire overlay.
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: SafeArea(
                child: FocusScope(node: _scope, child: widget.child)),
          ),
        ),
      ),
    ),
  );
}
