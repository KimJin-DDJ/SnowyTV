import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';

void showQualityInspectorSheet(
  BuildContext context, {
  required PlayerController playerController,
  required VideoPageController videoPageController,
  VoidCallback? onSwitchRoad,
}) {
  // 仅在面板打开期间轮询原生统计，关闭（任何方式）后立即停止
  final debug = playerController.debug;
  debug.startLiveStats();
  showAdaptiveBottomSheet<void>(
    context: context,
    maxHeightFactor: 0.88,
    compactLandscapeMaxHeightFactor: 0.95,
    builder: (context) => QualityInspectorSheet(
      playerController: playerController,
      videoPageController: videoPageController,
      onSwitchRoad: onSwitchRoad,
    ),
  ).whenComplete(debug.stopLiveStats);
}

class QualityInspectorSheet extends StatelessWidget {
  const QualityInspectorSheet({
    super.key,
    required this.playerController,
    required this.videoPageController,
    this.onSwitchRoad,
  });

  final PlayerController playerController;
  final VideoPageController videoPageController;
  final VoidCallback? onSwitchRoad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          MaterialBottomSheetHeader(
            title: '画质检测与规格参数',
            onClose: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: _DpadScroll(
              builder: (scrollController) => Observer(
              builder: (context) {
                final debug = playerController.debug;
                final resolution = (debug.playerWidth > 0 && debug.playerHeight > 0)
                    ? '${debug.playerWidth} × ${debug.playerHeight}'
                    : '检测中...';
                final qualityLabel = debug.qualityBadgeText;
                final bitrate = debug.formattedBitrate;
                final fps = debug.formattedFps.isNotEmpty ? debug.formattedFps : '检测中...';
                final vCodec = debug.videoCodec.isNotEmpty ? debug.videoCodec.toUpperCase() : '检测中...';
                final aCodec = debug.audioCodec.isNotEmpty ? debug.audioCodec.toUpperCase() : '检测中...';
                final hwdec = debug.hwdecActive.isNotEmpty
                    ? (debug.hwdecActive == 'no'
                        ? '软件解码 (CPU)'
                        : debug.hwdecActive.startsWith('mediacodec')
                            ? 'MediaCodec 硬件解码'
                            : debug.hwdecActive)
                    : '检测中...';
                final pixelFormat = debug.pixelFormat.isNotEmpty ? debug.pixelFormat : '检测中...';
                final drops = '${debug.droppedFrames} 帧';

                // 当前线路名称
                final currentRoadIndex = videoPageController.selectedEpisode.road;
                final roadName = (videoPageController.roadList.length > currentRoadIndex)
                    ? videoPageController.roadList[currentRoadIndex].name
                    : '线路 ${currentRoadIndex + 1}';

                return ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  children: [
                    // 1. 画质评级卡片 (Hero Card)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF00382B), Color(0xFF004D40)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF00BFA5).withValues(alpha: 0.4), width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00BFA5).withValues(alpha: 0.15),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00BFA5).withValues(alpha: 0.2),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.verified_rounded,
                              color: Color(0xFF64FFDA),
                              size: 32,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      qualityLabel,
                                      style: theme.textTheme.titleLarge?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF64FFDA).withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        vCodec,
                                        style: const TextStyle(
                                          color: Color(0xFF64FFDA),
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '$resolution · $fps · $bitrate',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 2. 核心流媒体规格网格
                    Text(
                      '技术规格检测',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      childAspectRatio: 2.6,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      children: [
                        _metricCard(context, '物理分辨率', resolution, Icons.tv_rounded),
                        _metricCard(context, '实时码率', bitrate, Icons.speed_rounded),
                        _metricCard(context, '画面帧率', fps, Icons.slow_motion_video_rounded),
                        _metricCard(context, '视频编码', vCodec, Icons.video_file_rounded),
                        _metricCard(context, '音频编码', aCodec, Icons.audiotrack_rounded),
                        _metricCard(context, '解码引擎', hwdec, Icons.memory_rounded),
                        _metricCard(context, '色彩空间', pixelFormat, Icons.palette_rounded),
                        _metricCard(context, '渲染丢帧', drops, Icons.auto_graph_rounded),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // 3. 画质优化引擎状态
                    Text(
                      '已生效的画质与性能调优',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TonalCard(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Column(
                          children: [
                            _optimizationRow(
                              'HLS 清晰度选择',
                              'MXdm 在 Chromecast HD 上优先选择设备可解码的分流',
                              true,
                            ),
                            const Divider(height: 16),
                            _optimizationRow(
                              'MediaCodec 硬件加速解码',
                              'OpenGL 纹理加速 + 软解智能兜底，杜绝非标视频黑屏与闪退',
                              true,
                            ),
                            const Divider(height: 16),
                            _optimizationRow(
                              '动画音频时钟锁相同步 (video-sync: audio)',
                              '解决 24fps 动画在 60Hz 屏幕上的帧步进失配，画面平滑无抖动',
                              true,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 4. 大屏电视推荐设置 (三星 75寸 专属指南)
                    Text(
                      '75寸 4K 电视推荐画质设置',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TonalCard(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.tune_rounded, color: Color(0xFF64FFDA), size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  '三星/主流大屏最佳匹配',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '• 图像模式：选【自然】或【电影】，色调选【标准/暖色1】\n'
                              '• 图像锐度：调至【8 ~ 12】（让 1080P 动漫线条刀刻般清晰）\n'
                              '• 动态清晰度：选【自定义】，消除抖动设为【3 ~ 4】\n'
                              '• 数字杂音过滤 / 降噪：必须设为【关闭】（保留动漫纯净线条）',
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 4. 线路建议与切换
                    Text(
                      '当前片源线路',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TonalCard(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            const Icon(Icons.alt_route_rounded, color: Color(0xFF64FFDA)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '当前线路: $roadName',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '不同线路提供不同清晰度（如 1080P/2.5K/超清），可随时切换',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (onSwitchRoad != null)
                              FilledButton.tonalIcon(
                                style: ButtonStyle(
                                  shape: WidgetStateProperty.resolveWith((states) {
                                    return RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      side: states.contains(WidgetState.focused)
                                          ? const BorderSide(color: Color(0xFF00E676), width: 2)
                                          : BorderSide.none,
                                    );
                                  }),
                                ),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  onSwitchRoad!();
                                },
                                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                                label: const Text('切换线路'),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                );
              },
            ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricCard(BuildContext context, String title, String value, IconData icon) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _optimizationRow(String title, String subtitle, bool enabled) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          enabled ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
          color: enabled ? const Color(0xFF00E676) : Colors.grey,
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 让遥控器上下键可以滚动面板内容。
/// 焦点停在滚动区域本身时，上下键直接滚动；滚到底后再按下键，
/// 交给默认焦点移动，落到「切换线路」等按钮上。
class _DpadScroll extends StatefulWidget {
  const _DpadScroll({required this.builder});

  final Widget Function(ScrollController controller) builder;

  @override
  State<_DpadScroll> createState() => _DpadScrollState();
}

class _DpadScrollState extends State<_DpadScroll> {
  final _controller = ScrollController();
  final _focusNode = FocusNode(debugLabel: 'Quality inspector scroll');
  static const _step = 240.0;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (!node.hasPrimaryFocus) {
      // 焦点在「切换线路」等按钮上时，按上键回到滚动区域继续往上翻。
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        node.requestFocus();
        return KeyEventResult.handled;
      }
      // 「切换线路」已经是最后一个按钮，再按下键不要把焦点送出面板。
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        final buttons = node.traversalDescendants
            .where((d) => d.canRequestFocus && d.context != null);
        final focused = FocusManager.instance.primaryFocus;
        if (buttons.isNotEmpty && buttons.last == focused) {
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }
    if (!_controller.hasClients) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final down = key == LogicalKeyboardKey.arrowDown;
    if (!down && key != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final pos = _controller.position;
    final atEdge = down
        ? pos.pixels >= pos.maxScrollExtent - 1
        : pos.pixels <= pos.minScrollExtent + 1;
    if (atEdge) {
      if (!down) return KeyEventResult.ignored;
      // 滚到底后，把焦点交给面板里最后一个按钮（「切换线路」）。
      final buttons = node.traversalDescendants
          .where((d) => d.canRequestFocus && d.context != null)
          .toList();
      if (buttons.isEmpty) return KeyEventResult.ignored;
      buttons.last.requestFocus();
      return KeyEventResult.handled;
    }
    final target = (pos.pixels + (down ? _step : -_step))
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: widget.builder(_controller),
      );
}
