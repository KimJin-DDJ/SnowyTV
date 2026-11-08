import 'dart:convert';

import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/clients/plugin_site_client.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 「最近更新」数据源：抓取 MXdm（dcc3.com）分类页。
///
/// MXdm 的 /type/guoman/ 分类页本身就按更新时间倒序，每项带
/// `更新至第N集`，比 Bangumi 时间表全得多（国漫基本都在）。
/// 结果缓存在 setting box 里，打开页面先显示缓存，过期再后台刷新。
enum UpdateCategory {
  /// 国漫 + 日漫交叉合并（各自按更新时间），国漫不会再缺
  all('', '全部', 0),
  guoman('guoman', '国漫', 3),
  riman('riman', '日漫', 2);

  const UpdateCategory(this.path, this.label, this.pages);

  final String path;
  final String label;
  final int pages;
}

class RecentUpdateItem {
  RecentUpdateItem({
    required this.id,
    required this.title,
    required this.cover,
    required this.status,
    required this.episode,
    required this.order,
    this.newCount = 0,
    this.newAtMs = 0,
    this.category = '',
  });

  /// 来源分类标签（国漫 / 日漫）
  final String category;

  /// MXdm 详情页 id（越大越新加入）
  final int id;
  final String title;
  final String cover;

  /// 原始状态文字，如「更新至第166集」「完结」
  final String status;

  /// 最新集数，解析不出来时为 0
  final int episode;

  /// 在分类页里的位置（= 更新时间排序）
  final int order;

  /// 相比上次抓取新增的集数
  int newCount;
  int newAtMs;

  // 以下由本地追番 / 历史匹配填入，不缓存
  bool watching = false;
  int watchedEpisode = 0;
  BangumiItem? localItem;

  /// 红色角标数字：看过的话 = 最新集 - 看到的集，否则 = 新增集数
  int get badge {
    if (watchedEpisode > 0 && episode > watchedEpisode) {
      return episode - watchedEpisode;
    }
    return newCount;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        't': title,
        'c': cover,
        's': status,
        'e': episode,
        'o': order,
        'n': newCount,
        'na': newAtMs,
        'g': category,
      };

  factory RecentUpdateItem.fromJson(Map<String, dynamic> json) =>
      RecentUpdateItem(
        id: json['id'] as int? ?? 0,
        title: json['t'] as String? ?? '',
        cover: json['c'] as String? ?? '',
        status: json['s'] as String? ?? '',
        episode: json['e'] as int? ?? 0,
        order: json['o'] as int? ?? 0,
        newCount: json['n'] as int? ?? 0,
        newAtMs: json['na'] as int? ?? 0,
        category: json['g'] as String? ?? '',
      );
}

class RecentUpdatesSnapshot {
  RecentUpdatesSnapshot(this.items, this.fetchedAtMs);

  final List<RecentUpdateItem> items;
  final int fetchedAtMs;

  bool get isEmpty => items.isEmpty;
}

class RecentUpdatesService {
  RecentUpdatesService._();

  static final RecentUpdatesService instance = RecentUpdatesService._();

  static const _fallbackBaseUrl = 'https://www.dcc3.com';
  static const _staleAfter = Duration(minutes: 30);
  static const _badgeKeep = Duration(days: 3);

  static SettingKey<String> _cacheKey(UpdateCategory c) => SettingKey<String>(
        'recentUpdatesCache_${c.path}',
        '',
        group: SettingGroup.misc,
      );

  static const _bangumiIdKey = SettingKey<String>(
    'recentUpdatesBangumiIds',
    '',
    group: SettingGroup.misc,
  );

  final Map<UpdateCategory, RecentUpdatesSnapshot> _memory = {};

  String get _baseUrl {
    try {
      final plugins = inject<PluginsController>().pluginList;
      for (final Plugin p in plugins) {
        if (pluginNameKey(p.name) == 'mxdm' && p.baseUrl.isNotEmpty) {
          final url = p.baseUrl;
          return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
        }
      }
    } catch (_) {}
    return _fallbackBaseUrl;
  }

  /// 读缓存（内存优先，其次 Hive），没有则返回 null。
  RecentUpdatesSnapshot? cached(UpdateCategory category) {
    if (category == UpdateCategory.all) {
      final parts = [
        cached(UpdateCategory.guoman),
        cached(UpdateCategory.riman),
      ].whereType<RecentUpdatesSnapshot>().toList();
      return parts.isEmpty ? null : _merge(parts);
    }
    final mem = _memory[category];
    if (mem != null) return mem;
    final raw = GStorage.getSetting<String>(_cacheKey(category));
    if (raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final items = (json['items'] as List)
          .map((e) => RecentUpdateItem.fromJson(e as Map<String, dynamic>))
          .toList();
      final snap = RecentUpdatesSnapshot(items, json['at'] as int? ?? 0);
      _memory[category] = snap;
      return snap;
    } catch (e) {
      KazumiLogger().w('RecentUpdates: bad cache', error: e);
      return null;
    }
  }

  /// 按各自的更新顺序交叉合并，order 重新编号。
  RecentUpdatesSnapshot _merge(List<RecentUpdatesSnapshot> parts) {
    final merged = <RecentUpdateItem>[];
    final seen = <int>{};
    final maxLen =
        parts.map((p) => p.items.length).reduce((a, b) => a > b ? a : b);
    for (var i = 0; i < maxLen; i++) {
      for (final p in parts) {
        if (i >= p.items.length) continue;
        final it = p.items[i];
        if (!seen.add(it.id)) continue;
        merged.add(RecentUpdateItem(
          id: it.id,
          title: it.title,
          cover: it.cover,
          status: it.status,
          episode: it.episode,
          order: merged.length,
          newCount: it.newCount,
          newAtMs: it.newAtMs,
          category: it.category,
        ));
      }
    }
    final at = parts.map((p) => p.fetchedAtMs).reduce((a, b) => a < b ? a : b);
    return RecentUpdatesSnapshot(merged, at);
  }

  bool isStale(RecentUpdatesSnapshot? snap) =>
      snap == null ||
      DateTime.now().millisecondsSinceEpoch - snap.fetchedAtMs >
          _staleAfter.inMilliseconds;

  /// 从 MXdm 抓取，和旧缓存对比算出新增集数，写回缓存。
  Future<RecentUpdatesSnapshot> refresh(UpdateCategory category) async {
    if (category == UpdateCategory.all) {
      final results = await Future.wait([
        for (final c in [UpdateCategory.guoman, UpdateCategory.riman])
          refresh(c).then<RecentUpdatesSnapshot?>((v) => v,
              onError: (Object e) {
            KazumiLogger().w('RecentUpdates: ${c.path} failed', error: e);
            return cached(c);
          }),
      ]);
      final parts = results.whereType<RecentUpdatesSnapshot>().toList();
      if (parts.isEmpty) throw Exception('MXdm 没有返回结果');
      return _merge(parts);
    }
    final base = _baseUrl;
    final pages = await Future.wait([
      for (var page = 1; page <= category.pages; page++)
        PluginSiteClient.instance
            .requestText(
              page == 1
                  ? '$base/type/${category.path}/'
                  : '$base/type/${category.path}/$page/',
              method: 'GET',
              headers: {'referer': '$base/'},
            )
            .catchError((Object e) {
          KazumiLogger().w('RecentUpdates: page $page failed', error: e);
          return '';
        }),
    ]);

    final items = <RecentUpdateItem>[];
    final seen = <int>{};
    for (final html in pages) {
      for (final item in _parse(html, base, items.length, category.label)) {
        if (seen.add(item.id)) items.add(item);
      }
    }
    if (items.isEmpty) {
      throw Exception('MXdm 没有返回结果');
    }

    final old = cached(category);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (old != null && old.items.isNotEmpty) {
      final oldById = {for (final o in old.items) o.id: o};
      for (final item in items) {
        final prev = oldById[item.id];
        if (prev == null) {
          // 新出现在列表里的番：标 1，免得没有任何提示
          item.newCount = item.episode > 0 ? 1 : 0;
          item.newAtMs = now;
        } else if (item.episode > prev.episode && prev.episode > 0) {
          item.newCount = item.episode - prev.episode;
          // 上次的角标还在有效期内就累加
          if (now - prev.newAtMs < _badgeKeep.inMilliseconds) {
            item.newCount += prev.newCount;
          }
          item.newAtMs = now;
        } else if (now - prev.newAtMs < _badgeKeep.inMilliseconds) {
          item.newCount = prev.newCount;
          item.newAtMs = prev.newAtMs;
        }
      }
    }

    final snap = RecentUpdatesSnapshot(items, now);
    _memory[category] = snap;
    await GStorage.putSetting<String>(
      _cacheKey(category),
      jsonEncode({
        'at': now,
        'items': items.map((e) => e.toJson()).toList(),
      }),
    );
    return snap;
  }

  static final _itemRe = RegExp(
    r'<li><a href="/detail/(\d+)/"[^>]*title="([^"]*)"[^>]*>\s*<img[^>]*data-original="([^"]*)"[\s\S]*?<p>([^<]*)</p>',
  );
  static final _epRe = RegExp(r'(\d+)\s*集');
  static final _anyNumRe = RegExp(r'(\d+)');

  List<RecentUpdateItem> _parse(
      String html, String base, int startOrder, String label) {
    final result = <RecentUpdateItem>[];
    for (final m in _itemRe.allMatches(html)) {
      final status = _unescape(m.group(4)!.trim());
      var cover = m.group(3)!;
      if (cover.startsWith('//')) cover = 'https:$cover';
      if (cover.startsWith('/')) cover = '$base$cover';
      result.add(RecentUpdateItem(
        id: int.parse(m.group(1)!),
        title: _unescape(m.group(2)!.trim()),
        cover: cover,
        status: status,
        episode: _episodeOf(status),
        order: startOrder + result.length,
        category: label,
      ));
    }
    return result;
  }

  static int _episodeOf(String status) {
    final m = _epRe.firstMatch(status) ??
        (status.contains('更新') ? _anyNumRe.firstMatch(status) : null);
    return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  /// 名字归一化：去空白和标点，第二季 / 第2季 / 2 统一。
  static String normalize(String name) {
    var s = name.toLowerCase();
    const cnNum = {
      '一': '1', '二': '2', '三': '3', '四': '4', '五': '5',
      '六': '6', '七': '7', '八': '8', '九': '9', '十': '10',
    };
    s = s.replaceAllMapped(RegExp(r'第([一二三四五六七八九十])[季部]'),
        (m) => '第${cnNum[m.group(1)]}季');
    s = s.replaceAllMapped(RegExp(r'第(\d+)[季部]'), (m) => m.group(1)!);
    s = s.replaceAll(RegExp(r'season\s*(\d+)'), r'$1');
    s = s.replaceAll(RegExp(r'[\s·・:：,，、!！?？\-—_()（）\[\]【】「」『』.。~～]'), '');
    // 「XX 第1季」和「XX」视为同一部
    if (s.endsWith('1') && s.length > 2 && !RegExp(r'\d1$').hasMatch(s)) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 用本地追番（在看优先）和观看历史标注每一项。
  void annotate(List<RecentUpdateItem> items) {
    final byName = <String, _LocalEntry>{};

    void put(BangumiItem b, {bool watching = false, int episode = 0}) {
      for (final n in [b.nameCn, b.name, ...b.alias]) {
        if (n.isEmpty) continue;
        final key = normalize(n);
        if (key.isEmpty) continue;
        final existing = byName[key];
        if (existing == null) {
          byName[key] = _LocalEntry(b, watching, episode);
        } else {
          existing.watching |= watching;
          if (episode > existing.episode) existing.episode = episode;
        }
      }
    }

    try {
      for (final h in GStorage.histories.values) {
        put(h.bangumiItem, episode: h.lastWatchEpisode);
      }
      for (final c in GStorage.collectibles.values) {
        put(c.bangumiItem,
            watching: c.type == CollectType.watching.value);
      }
    } catch (e) {
      KazumiLogger().w('RecentUpdates: annotate failed', error: e);
    }

    for (final item in items) {
      final entry = byName[normalize(item.title)];
      item.watching = entry?.watching ?? false;
      item.watchedEpisode = entry?.episode ?? 0;
      item.localItem = entry?.item;
    }
  }

  Map<String, int> _bangumiIds() {
    final raw = GStorage.getSetting<String>(_bangumiIdKey);
    if (raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as int));
    } catch (_) {
      return {};
    }
  }

  /// 找到对应的 Bangumi 条目，用来打开详情页。
  Future<BangumiItem?> resolveBangumi(RecentUpdateItem item) async {
    if (item.localItem != null) return item.localItem;
    final key = normalize(item.title);
    final ids = _bangumiIds();
    final cachedId = ids[key];
    if (cachedId != null) {
      final b = await BangumiApi.getBangumiInfoByID(cachedId);
      if (b != null) return b;
    }
    final page = await BangumiApi.bangumiSearch(item.title, limit: 10);
    final list = page?.items ?? const <BangumiItem>[];
    if (list.isEmpty) return null;
    BangumiItem best = list.first;
    for (final b in list) {
      if (normalize(b.nameCn) == key ||
          normalize(b.name) == key ||
          b.alias.any((a) => normalize(a) == key)) {
        best = b;
        break;
      }
    }
    ids[key] = best.id;
    await GStorage.putSetting<String>(_bangumiIdKey, jsonEncode(ids));
    return best;
  }
}

class _LocalEntry {
  _LocalEntry(this.item, this.watching, this.episode);

  final BangumiItem item;
  bool watching;
  int episode;
}
