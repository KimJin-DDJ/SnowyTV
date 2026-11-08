import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';

class EpisodeSelectionPanel extends StatefulWidget {
  const EpisodeSelectionPanel({
    super.key,
    required this.title,
    required this.roads,
    required this.selectedRoad,
    required this.selectedEpisode,
    required this.onEpisodeSelected,
    required this.downloads,
    this.onDownload,
    this.isOffline = false,
    this.isPlaying = false,
    this.disableAnimations = false,
  });

  final String title;
  final List<Road> roads;
  final int selectedRoad;
  final int selectedEpisode;

  /// [fromRoadSwitch] 为 true 表示只是切换了线路，调用方应保持面板打开。
  final void Function(int episode, int road, {bool fromRoadSwitch})
  onEpisodeSelected;
  final ValueChanged<int>? onDownload;
  final Map<String, DownloadEpisode> downloads;
  final bool isOffline;
  final bool isPlaying;
  final bool disableAnimations;

  @override
  EpisodeSelectionPanelState createState() => EpisodeSelectionPanelState();
}

class EpisodeSelectionPanelState extends State<EpisodeSelectionPanel> {
  static const double _tileExtent = 56;
  static const double _tileSpacing = 8;
  static const double _gridPadding = 12;

  final _scrollController = ScrollController();
  final _currentEpisodeFocus = FocusNode(debugLabel: 'Current episode');
  final _roadFocus = FocusNode(debugLabel: 'Playback road selector');
  final _headerKey = GlobalKey();
  late int _visibleRoad = widget.selectedRoad;
  // 每次 build 时按宽度更新，供高度计算和方向键判断「第一行」使用。
  int _columns = 4;
  // 焦点是否在剧集格子里。Android 的返回键直接走路由出栈，不会变成按键事件，
  // 所以在格子里时通过 PopScope 拦截出栈，把焦点先移到播放线路。
  bool _focusInGrid = false;

  bool get _canLocate =>
      widget.selectedRoad >= 0 &&
      widget.selectedRoad < widget.roads.length &&
      widget.selectedEpisode > 0 &&
      widget.selectedEpisode <= widget.roads[widget.selectedRoad].data.length;

  /// 固定的工具栏高度，需要容纳「播放线路」选择器（两行文字）。
  double get _toolbarHeight {
    final scaler = MediaQuery.textScalerOf(context);
    return math.max(72, scaler.scale(20) * 2 + 40);
  }

  int _columnsFor(double width) {
    final usable = width - _gridPadding * 2;
    return ((usable + _tileSpacing) / 104).floor().clamp(4, 5);
  }

  /// 网格第一行在滚动坐标系中的起点：标题 + 固定工具栏 + 内边距。
  double get _gridTop {
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    final headerHeight = box?.size.height ?? 0;
    return headerHeight + _toolbarHeight + _gridPadding;
  }

  double _tileTop(int index) {
    final row = index ~/ _columns;
    return _gridTop + row * (_tileExtent + _tileSpacing);
  }

  /// 把第 [index] 个格子（倒序列表中的位置）滚到固定工具栏下面可见。
  /// 网格是固定行高的，所以直接算偏移，不依赖格子已经构建。
  void _keepIndexVisible(int index) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final toolbar = _toolbarHeight;
    final top = _tileTop(index);
    final bottom = top + _tileExtent;
    final viewport = position.viewportDimension;
    double? target;
    if (top - position.pixels < toolbar) {
      target = top - toolbar;
    } else if (bottom - position.pixels > viewport) {
      target = bottom - viewport;
    }
    if (target == null) return;
    _scrollController.jumpTo(target.clamp(0.0, position.maxScrollExtent));
  }

  void _selectRoad(int road) {
    if (road < 0 || road >= widget.roads.length) return;
    if (road != _visibleRoad) {
      setState(() => _visibleRoad = road);
    }
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    final count = widget.roads[road].data.length;
    if (count == 0) return;
    // 尽量保持同一集号；新线路集数不够时取最接近的一集。
    final episode = math.min(math.max(widget.selectedEpisode, 1), count);
    widget.onEpisodeSelected(episode, road, fromRoadSwitch: true);
  }

  Future<void> revealCurrentEpisode({bool requestFocus = false}) async {
    if (!_canLocate) return;
    setState(() => _visibleRoad = widget.selectedRoad);
    // 等待新线路的网格完成布局后再计算偏移。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        !_scrollController.hasClients ||
        !_canLocate ||
        _visibleRoad != widget.selectedRoad) {
      return;
    }

    // 列表按最新一集在前倒序显示。
    final count = widget.roads[widget.selectedRoad].data.length;
    _keepIndexVisible(count - widget.selectedEpisode);
    if (requestFocus) {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted && _currentEpisodeFocus.context != null) {
        _currentEpisodeFocus.requestFocus();
      }
    }
  }

  /// 格子上的返回键，或第一行按上键：焦点回到工具栏里的「播放线路」。
  /// 工具栏一直固定可见，不需要滚动。其它情况不处理，返回键照常关闭面板。
  KeyEventResult _handleTileKey(int index, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isBack =
        key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape;
    final isUpFromFirstRow =
        key == LogicalKeyboardKey.arrowUp && index < _columns;
    if (!isBack && !isUpFromFirstRow) return KeyEventResult.ignored;
    _roadFocus.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  void didUpdateWidget(covariant EpisodeSelectionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 控制器切换了线路（例如自动切到下一条线路）时，列表跟随播放线路。
    if (oldWidget.selectedRoad != widget.selectedRoad ||
        _visibleRoad >= widget.roads.length) {
      _visibleRoad = widget.selectedRoad;
      _focusInGrid = false;
    }
  }

  @override
  void dispose() {
    _currentEpisodeFocus.dispose();
    _roadFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final road = _visibleRoad >= 0 && _visibleRoad < widget.roads.length
        ? widget.roads[_visibleRoad]
        : null;
    final count = road?.data.length ?? 0;

    return PopScope(
      canPop: !_focusInGrid,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _roadFocus.requestFocus();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          _columns = _columnsFor(constraints.maxWidth);
          return Scrollbar(
            controller: _scrollController,
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    key: _headerKey,
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: Semantics(
                      header: true,
                      child: Text(
                        widget.title.isEmpty ? '剧集列表' : widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
                // 工具栏固定在顶部：播放线路选择器始终可见，不需要滚过剧集列表。
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _EpisodeToolbar(
                    height: _toolbarHeight,
                    color: colors.surface,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: _RoadSelector(
                              focusNode: _roadFocus,
                              roads: widget.roads,
                              visibleRoad: _visibleRoad,
                              isOffline: widget.isOffline,
                              onChanged: _selectRoad,
                              disableAnimations: widget.disableAnimations,
                            ),
                          ),
                          IconButton(
                            tooltip: '定位当前集',
                            onPressed: _canLocate ? revealCurrentEpisode : null,
                            icon: const Icon(
                              Icons.my_location_rounded,
                              size: 20,
                            ),
                          ),
                          if (!widget.isOffline)
                            IconButton.filledTonal(
                              tooltip: '缓存剧集',
                              onPressed: count > 0 && widget.onDownload != null
                                  ? () => widget.onDownload!(_visibleRoad)
                                  : null,
                              icon: const Icon(
                                Icons.download_rounded,
                                size: 20,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (count == 0)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: GeneralEmptyState(
                      icon: Icons.video_library_outlined,
                      title: '这条线路暂无剧集',
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      _gridPadding,
                      _gridPadding,
                      _gridPadding,
                      16 + MediaQuery.paddingOf(context).bottom,
                    ),
                    sliver: SliverGrid.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: _columns,
                        mainAxisExtent: _tileExtent,
                        crossAxisSpacing: _tileSpacing,
                        mainAxisSpacing: _tileSpacing,
                      ),
                      itemCount: count,
                      itemBuilder: (context, index) {
                        // 倒序：最新一集排在最前面。
                        final dataIndex = count - 1 - index;
                        final episode = dataIndex + 1;
                        final name =
                            dataIndex < road!.identifier.length &&
                                road.identifier[dataIndex].trim().isNotEmpty
                            ? road.identifier[dataIndex]
                            : '第$episode集';
                        final selected =
                            _visibleRoad == widget.selectedRoad &&
                            episode == widget.selectedEpisode;
                        return _EpisodeTile(
                          key: ValueKey('$_visibleRoad:$episode'),
                          name: name,
                          selected: selected,
                          isPlaying: widget.isPlaying,
                          isOffline: widget.isOffline,
                          download: widget.downloads[road.data[dataIndex]],
                          focusNode: selected ? _currentEpisodeFocus : null,
                          onTap: () => widget.onEpisodeSelected(
                            episode,
                            _visibleRoad,
                            fromRoadSwitch: false,
                          ),
                          onKeyEvent: (event) => _handleTileKey(index, event),
                          onFocusChange: (hasFocus) {
                            if (mounted && _focusInGrid != hasFocus) {
                              setState(() => _focusInGrid = hasFocus);
                            }
                            if (!hasFocus) return;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _keepIndexVisible(index);
                            });
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EpisodeToolbar extends SliverPersistentHeaderDelegate {
  const _EpisodeToolbar({
    required this.height,
    required this.color,
    required this.child,
  });

  final double height;
  final Color color;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => minExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) =>
      // Fill minExtent even when desktop controls use a smaller touch target.
      SizedBox.expand(
        child: ColoredBox(color: color, child: child),
      );

  @override
  bool shouldRebuild(covariant _EpisodeToolbar oldDelegate) =>
      height != oldDelegate.height ||
      color != oldDelegate.color ||
      child != oldDelegate.child;
}

class _RoadSelector extends StatefulWidget {
  const _RoadSelector({
    required this.focusNode,
    required this.roads,
    required this.visibleRoad,
    required this.isOffline,
    required this.onChanged,
    required this.disableAnimations,
  });

  final FocusNode focusNode;
  final List<Road> roads;
  final int visibleRoad;
  final bool isOffline;
  final ValueChanged<int> onChanged;
  final bool disableAnimations;

  @override
  State<_RoadSelector> createState() => _RoadSelectorState();
}

class _RoadSelectorState extends State<_RoadSelector> {
  FocusNode get _focusNode => widget.focusNode;
  final List<FocusNode> _itemFocus = [];

  FocusNode _itemNode(int index) {
    while (_itemFocus.length <= index) {
      _itemFocus.add(FocusNode(debugLabel: 'Road option ${_itemFocus.length}'));
    }
    return _itemFocus[index];
  }

  FocusNode? _focusBeforeOpen;
  bool _pointerActivation = false;

  String _name(int index) => index >= 0 && index < widget.roads.length
      ? (widget.roads[index].name.trim().isEmpty
            ? '播放线路 ${index + 1}'
            : widget.roads[index].name)
      : '暂无线路';

  int _count(int index) => index >= 0 && index < widget.roads.length
      ? widget.roads[index].data.length
      : 0;

  void _toggleMenu(MenuController controller) {
    final pointerActivation = _pointerActivation;
    _pointerActivation = false;
    if (controller.isOpen) {
      controller.close();
      return;
    }
    final previousFocus = FocusManager.instance.primaryFocus;
    _focusBeforeOpen = pointerActivation && previousFocus == _focusNode
        ? null
        : previousFocus;
    controller.open();
    // 遥控器：菜单打开后把焦点放到当前线路上，上下键才能在选项间移动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.isOpen || widget.roads.isEmpty) return;
      final index = widget.visibleRoad.clamp(0, widget.roads.length - 1);
      final node = _itemNode(index);
      if (node.context != null) node.requestFocus();
    });
  }

  void _handleClose() {
    if (!mounted) return;
    final previousFocus = _focusBeforeOpen;
    _focusBeforeOpen = null;
    if (previousFocus == null ||
        previousFocus.context?.mounted != true ||
        !previousFocus.canRequestFocus) {
      _focusNode.unfocus(
        disposition: UnfocusDisposition.previouslyFocusedChild,
      );
      return;
    }
    if (previousFocus is FocusScopeNode) {
      // Do not restore the scope's last child: it may be this menu button.
      previousFocus.requestScopeFocus();
    } else {
      previousFocus.requestFocus();
    }
  }

  @override
  void dispose() {
    for (final node in _itemFocus) {
      node.dispose();
    }
    super.dispose();
  }

  Widget _buildMenuItem(int index, double width) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final road = widget.roads[index];
    final selected = index == widget.visibleRoad;
    final last = index == widget.roads.length - 1;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 2),
      child: Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: MenuItemButton(
          key: ValueKey('road-option-$index'),
          focusNode: _itemNode(index),
          onPressed: () => widget.onChanged(index),
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(width, 56)),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: WidgetStatePropertyAll(
              selected ? colors.secondaryContainer : colors.surfaceContainerLow,
            ),
            foregroundColor: WidgetStatePropertyAll(
              selected ? colors.onSecondaryContainer : colors.onSurface,
            ),
            textStyle: WidgetStatePropertyAll(
              theme.textTheme.labelLarge?.copyWith(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: selected
                    ? BorderRadius.circular(20)
                    : BorderRadius.vertical(
                        top: Radius.circular(index == 0 ? 20 : 4),
                        bottom: Radius.circular(last ? 20 : 4),
                      ),
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_name(index), maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(
                '${road.data.length} 集',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected
                      ? colors.onSecondaryContainer
                      : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final canSwitch = widget.roads.length > 1;
    final reduceMotion =
        widget.disableAnimations || MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 200);

    return LayoutBuilder(
      builder: (context, constraints) {
        // 选择器在工具栏里比较窄，菜单至少保持一个可读的宽度。
        final width = math.min(
          math.max(constraints.maxWidth, 240.0),
          MediaQuery.sizeOf(context).width - 32,
        );
        return MenuAnchor(
          childFocusNode: _focusNode,
          crossAxisUnconstrained: false,
          consumeOutsideTap: true,
          animated: !reduceMotion,
          onClose: _handleClose,
          alignmentOffset: const Offset(0, 8),
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomStart,
            backgroundColor: WidgetStatePropertyAll(colors.surfaceContainer),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(3),
            padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            ),
            minimumSize: WidgetStatePropertyAll(Size(width, 0)),
            maximumSize: WidgetStatePropertyAll(
              Size(
                width,
                math.min(400, MediaQuery.sizeOf(context).height - 32),
              ),
            ),
            visualDensity: VisualDensity.standard,
          ),
          menuChildren: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Text(
                '选择播放线路',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            for (var i = 0; i < widget.roads.length; i++)
              _buildMenuItem(i, width - 16),
          ],
          builder: (context, controller, child) {
            final open = controller.isOpen;
            final foreground = open
                ? colors.onSecondaryContainer
                : colors.onSurface;
            return Semantics(
              button: canSwitch,
              expanded: canSwitch ? open : null,
              label: canSwitch ? '切换播放线路' : null,
              child: Material(
                animationDuration: duration,
                color: open
                    ? colors.secondaryContainer
                    : colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(open ? 16 : 20),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  focusNode: _focusNode,
                  onTapUp: canSwitch ? (_) => _pointerActivation = true : null,
                  // 只有一条线路时也保持可聚焦（返回键要把焦点移到这里），
                  // 只是按确认不弹菜单。
                  onTap: canSwitch ? () => _toggleMenu(controller) : () {},
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${widget.isOffline ? '离线观看' : '播放线路'} · '
                                '${_count(widget.visibleRoad)} 集',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: foreground,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _name(widget.visibleRoad),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: foreground,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (canSwitch) ...[
                          const SizedBox(width: 8),
                          AnimatedRotation(
                            turns: open ? 0.5 : 0,
                            duration: duration,
                            curve: Curves.easeOutCubic,
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: foreground,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 紧凑的剧集格子：只显示集名，当前集用主色填充，焦点用粗边框标出。
class _EpisodeTile extends StatefulWidget {
  const _EpisodeTile({
    super.key,
    required this.name,
    required this.selected,
    required this.isPlaying,
    required this.isOffline,
    required this.onTap,
    required this.onKeyEvent,
    required this.onFocusChange,
    this.download,
    this.focusNode,
  });

  final String name;
  final bool selected;
  final bool isPlaying;
  final bool isOffline;
  final VoidCallback onTap;
  final KeyEventResult Function(KeyEvent event) onKeyEvent;
  final ValueChanged<bool> onFocusChange;
  final DownloadEpisode? download;
  final FocusNode? focusNode;

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = widget.selected ? colors.onPrimary : colors.onSurface;
    final status = widget.isOffline
        ? DownloadStatus.completed
        : widget.download?.status;
    final downloadLabel = switch (status) {
      DownloadStatus.completed => '已缓存',
      DownloadStatus.downloading => '正在缓存',
      DownloadStatus.failed => '缓存失败',
      DownloadStatus.paused => '缓存已暂停',
      DownloadStatus.pending => '等待缓存',
      DownloadStatus.resolving => '正在解析',
      _ => null,
    };
    final statusIcon = switch (status) {
      DownloadStatus.completed => Icons.download_done_rounded,
      DownloadStatus.downloading => Icons.downloading_rounded,
      DownloadStatus.failed => Icons.error_outline_rounded,
      _ => null,
    };
    final iconColor = widget.selected
        ? foreground
        : status == DownloadStatus.failed
        ? colors.error
        : colors.onSurfaceVariant;
    final playbackLabel = widget.selected
        ? (widget.isPlaying ? '正在播放' : '当前选集')
        : '播放';

    return Semantics(
      button: true,
      onTap: widget.onTap,
      selected: widget.selected,
      inMutuallyExclusiveGroup: true,
      label:
          '${widget.name}，$playbackLabel'
          '${downloadLabel == null ? '' : '，$downloadLabel'}',
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) => widget.onKeyEvent(event),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.primary
                : colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _focused ? colors.onSurface : Colors.transparent,
              width: 3,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              focusNode: widget.focusNode,
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(12),
              excludeFromSemantics: true,
              onFocusChange: (hasFocus) {
                if (mounted) setState(() => _focused = hasFocus);
                widget.onFocusChange(hasFocus);
              },
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed) ||
                    states.contains(WidgetState.focused)) {
                  return foreground.withValues(alpha: 0.12);
                }
                if (states.contains(WidgetState.hovered)) {
                  return foreground.withValues(alpha: 0.08);
                }
                return null;
              }),
              child: ExcludeSemantics(
                child: Stack(
                  children: [
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          widget.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: foreground,
                            fontWeight: widget.selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    if (statusIcon != null)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Icon(statusIcon, size: 12, color: iconColor),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
