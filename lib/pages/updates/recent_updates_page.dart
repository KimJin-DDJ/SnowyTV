import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/updates/recent_updates_service.dart';
import 'package:kazumi/services/logging/logger.dart';

enum _SortMode {
  updated('更新时间'),
  added('添加时间'),
  watching('在看优先'),
  episodes('集数最多');

  const _SortMode(this.label);

  final String label;
}

/// 「最近更新」：MXdm 分类页的最新更新海报墙，标出追番 / 看过的新集数。
class RecentUpdatesPage extends StatefulWidget {
  const RecentUpdatesPage({super.key});

  @override
  State<RecentUpdatesPage> createState() => _RecentUpdatesPageState();
}

class _RecentUpdatesPageState extends State<RecentUpdatesPage> {
  final _service = RecentUpdatesService.instance;
  final _scrollController = ScrollController();

  // 只在本次 App 运行期间记住选择
  static UpdateCategory _lastCategory = UpdateCategory.all;
  static _SortMode _lastSort = _SortMode.updated;

  UpdateCategory _category = _lastCategory;
  _SortMode _sort = _lastSort;
  RecentUpdatesSnapshot? _snapshot;
  List<RecentUpdateItem> _items = const [];
  bool _loading = false;
  String? _error;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _load({bool force = false}) {
    final category = _category;
    final cached = _service.cached(category);
    _apply(cached);
    if (force || _service.isStale(cached)) {
      setState(() {
        _loading = true;
        _error = null;
      });
      _service.refresh(category).then((snap) {
        if (!mounted || _category != category) return;
        _apply(snap);
        setState(() => _loading = false);
      }, onError: (Object e) {
        KazumiLogger().w('RecentUpdates: refresh failed', error: e);
        if (!mounted || _category != category) return;
        setState(() {
          _loading = false;
          _error = '获取更新失败，请检查网络后重试';
        });
      });
    }
  }

  void _apply(RecentUpdatesSnapshot? snap) {
    final items = List<RecentUpdateItem>.of(snap?.items ?? const []);
    _service.annotate(items);
    _sortItems(items);
    setState(() {
      _snapshot = snap;
      _items = items;
    });
  }

  void _sortItems(List<RecentUpdateItem> items) {
    switch (_sort) {
      case _SortMode.updated:
        items.sort((a, b) => a.order.compareTo(b.order));
      case _SortMode.added:
        items.sort((a, b) => b.id.compareTo(a.id));
      case _SortMode.watching:
        int rank(RecentUpdateItem i) => i.watching
            ? 0
            : i.watchedEpisode > 0
                ? 1
                : 2;
        items.sort((a, b) {
          final r = rank(a).compareTo(rank(b));
          if (r != 0) return r;
          final badge = b.badge.compareTo(a.badge);
          return badge != 0 ? badge : a.order.compareTo(b.order);
        });
      case _SortMode.episodes:
        items.sort((a, b) => b.episode.compareTo(a.episode));
    }
  }

  void _selectCategory(UpdateCategory c) {
    if (c == _category) return;
    _category = c;
    _lastCategory = c;
    _jumpTop();
    _load();
  }

  void _selectSort(_SortMode s) {
    if (s == _sort) return;
    _sort = s;
    _lastSort = s;
    final items = List<RecentUpdateItem>.of(_items);
    _sortItems(items);
    setState(() => _items = items);
    _jumpTop();
  }

  void _jumpTop() {
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Future<void> _open(RecentUpdateItem item) async {
    if (_opening) return;
    _opening = true;
    try {
      if (item.localItem == null) {
        KazumiDialog.showToast(message: '正在查找「${item.title}」…');
      }
      final bangumi = await _service.resolveBangumi(item);
      if (!mounted) return;
      if (bangumi == null) {
        KazumiDialog.showToast(message: '没有在 Bangumi 找到「${item.title}」，可以试试搜索');
        return;
      }
      context.pushNamed('/info/', arguments: bangumi);
    } catch (e) {
      KazumiLogger().w('RecentUpdates: open failed', error: e);
      KazumiDialog.showToast(message: '打开失败，请重试');
    } finally {
      _opening = false;
    }
  }

  String _fetchedLabel() {
    final at = _snapshot?.fetchedAtMs ?? 0;
    if (at == 0) return '刷新';
    final t = DateTime.fromMillisecondsSinceEpoch(at);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)} 更新';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  for (final c in UpdateCategory.values)
                    _SegmentButton(
                      label: c.label,
                      selected: c == _category,
                      onTap: () => _selectCategory(c),
                    ),
                  const SizedBox(width: 12),
                  for (final s in _SortMode.values)
                    _SegmentButton(
                      label: s.label,
                      selected: s == _sort,
                      trailing: s == _sort ? Icons.arrow_downward : null,
                      onTap: () => _selectSort(s),
                    ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      '共有 ${_items.length} 个结果',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  _SegmentButton(
                    label: _fetchedLabel(),
                    selected: false,
                    leading: Icons.refresh,
                    onTap: _loading ? null : () => _load(force: true),
                  ),
                ],
              ),
            ),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_items.isEmpty) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error ?? '暂无更新'),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _load(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      const spacing = 10.0;
      const hPad = 12.0;
      final width = constraints.maxWidth - hPad * 2;
      final count = ((width + spacing) / (100 + spacing)).floor().clamp(3, 10);
      final cardWidth = (width - spacing * (count - 1)) / count;
      final posterHeight = cardWidth / 0.7;
      final textScale = MediaQuery.textScalerOf(context).scale(1);
      final extent = posterHeight + 36 * textScale;
      return GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(hPad, 4, hPad, 16),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: count,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 12,
          mainAxisExtent: extent,
        ),
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return _UpdateCard(
            key: ValueKey(item.id),
            item: item,
            posterWidth: cardWidth,
            posterHeight: posterHeight,
            onTap: () => _open(item),
          );
        },
      );
    });
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.leading,
    this.trailing,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? leading;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    return Material(
      color: selected
          ? scheme.surfaceContainerHighest
          : scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                Icon(leading, size: 14, color: scheme.primary),
                const SizedBox(width: 3),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: leading != null ? scheme.primary : color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 2),
                Icon(trailing, size: 12, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UpdateCard extends StatelessWidget {
  const _UpdateCard({
    super.key,
    required this.item,
    required this.posterWidth,
    required this.posterHeight,
    required this.onTap,
  });

  final RecentUpdateItem item;
  final double posterWidth;
  final double posterHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);
    final badge = item.badge;
    final String tagLine;
    if (item.watching) {
      tagLine = item.watchedEpisode > 0 ? '在看 · 看到${item.watchedEpisode}' : '在看';
    } else if (item.watchedEpisode > 0) {
      tagLine = '看到 ${item.watchedEpisode}';
    } else {
      tagLine = item.category;
    }
    final epLabel = item.episode > 0
        ? '更新 ${item.episode.toString().padLeft(2, '0')}'
        : item.status;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: posterHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                NetworkImgLayer(
                  src: item.cover,
                  width: posterWidth,
                  height: posterHeight,
                  filterQuality: FilterQuality.low,
                  borderRadius: BorderRadius.circular(6),
                ),
                if (item.watching)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: _Tag(
                      text: '在看',
                      color: scheme.primary,
                      textColor: scheme.onPrimary,
                    ),
                  ),
                if (badge > 0)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: _Tag(
                      text: badge > 99 ? '99+' : '$badge',
                      color: const Color(0xFFE53935),
                      textColor: Colors.white,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  tagLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: item.watching
                      ? muted.copyWith(color: scheme.primary)
                      : muted,
                ),
              ),
              Text(epLabel, maxLines: 1, style: muted),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.text,
    required this.color,
    required this.textColor,
  });

  final String text;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          color: textColor,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
