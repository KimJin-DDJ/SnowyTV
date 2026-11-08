import 'package:lpinyin/lpinyin.dart';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 拼音首字母 / 全拼检索。
///
/// 遥控器上打中文很慢，所以搜索页支持直接输入拼音首字母：
/// 「斗破苍穹」→ `dpcq`，也可以输全拼前缀 `doupo`。
/// Bangumi 的搜索接口不认拼音，这里在本地已知的番剧（追番、观看历史、
/// 本次打开过的热门 / 时间表 / 搜索结果）里匹配。
class PinyinSearch {
  PinyinSearch._();

  static final _nonAlnum = RegExp(r'[^a-z0-9]');
  static final _pinyinQuery = RegExp(r'^[a-z0-9 ]+$');
  static final Map<String, _Keys> _cache = {};

  /// 本次运行里见过的番剧（热门、时间表、搜索结果）。
  static final Map<int, BangumiItem> _seen = {};
  static const _maxSeen = 3000;

  /// 输入是否像拼音（纯字母数字）。
  static bool isPinyinQuery(String query) {
    final q = query.trim().toLowerCase();
    return q.isNotEmpty && _pinyinQuery.hasMatch(q) && q.contains(RegExp('[a-z]'));
  }

  static void register(Iterable<BangumiItem> items) {
    for (final item in items) {
      if (item.id <= 0) continue;
      _seen.remove(item.id);
      _seen[item.id] = item;
    }
    while (_seen.length > _maxSeen) {
      _seen.remove(_seen.keys.first);
    }
  }

  static _Keys _keysOf(String title) => _cache.putIfAbsent(title, () {
        String initials = '';
        String full = '';
        try {
          initials = PinyinHelper.getShortPinyin(title).toLowerCase();
          full = PinyinHelper.getPinyinE(title,
                  separator: '', defPinyin: '', format: PinyinFormat.WITHOUT_TONE)
              .toLowerCase();
        } catch (_) {}
        return _Keys(
          initials.replaceAll(_nonAlnum, ''),
          full.replaceAll(_nonAlnum, ''),
          title.toLowerCase(),
        );
      });

  /// 分数越高越靠前；0 表示不匹配。
  static int score(String title, String query) {
    if (title.isEmpty) return 0;
    final raw = query.trim().toLowerCase();
    if (raw.isEmpty) return 0;
    final keys = _keysOf(title);
    if (keys.lower.startsWith(raw)) return 100;
    if (keys.lower.contains(raw)) return 80;
    if (!isPinyinQuery(raw)) return 0;
    final q = raw.replaceAll(' ', '');
    if (keys.initials.startsWith(q)) return 90;
    if (keys.full.startsWith(q)) return 85;
    if (keys.initials.contains(q)) return 70;
    if (keys.full.contains(q)) return 50;
    return 0;
  }

  static int scoreItem(BangumiItem item, String query) {
    var best = 0;
    for (final name in [item.nameCn, item.name, ...item.alias]) {
      final s = score(name, query);
      if (s > best) best = s;
      if (best >= 100) break;
    }
    return best;
  }

  static Iterable<BangumiItem> _localItems() sync* {
    try {
      for (final entry in GStorage.collectibles.values) {
        yield entry.bangumiItem;
      }
    } catch (_) {}
    try {
      for (final history in GStorage.histories.values) {
        yield history.bangumiItem;
      }
    } catch (_) {}
    yield* _seen.values.toList().reversed;
  }

  /// 在本地已知番剧里查找，最多 [limit] 条。
  static List<BangumiItem> searchLocal(String query, {int limit = 12}) {
    if (query.trim().isEmpty) return const [];
    final seenIds = <int>{};
    final scored = <(BangumiItem, int, int)>[];
    var order = 0;
    for (final item in _localItems()) {
      if (!seenIds.add(item.id)) continue;
      final s = scoreItem(item, query);
      if (s > 0) scored.add((item, s, order));
      order++;
    }
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      return byScore != 0 ? byScore : a.$3.compareTo(b.$3);
    });
    return [for (final e in scored.take(limit)) e.$1];
  }
}

class _Keys {
  const _Keys(this.initials, this.full, this.lower);
  final String initials;
  final String full;
  final String lower;
}
