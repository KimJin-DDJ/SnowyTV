import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/async_session.dart';

String? seriesSearchFallback(String keyword) {
  final title = keyword.trim();
  final base = title.replaceFirst(
    RegExp(r'\s+(?:第[一二三四五六七八九十百0-9]+季|新?年番)$'),
    '',
  );
  return base.isEmpty || base == title ? null : base;
}

class PluginSearchService {
  PluginSearchService({
    required this.infoController,
    required this.pluginsController,
  });

  final InfoController infoController;
  final PluginsController pluginsController;
  final RuleCancelToken _cancelToken = RuleCancelToken();

  /// Per-plugin sessions so a replacement query (alias/manual search)
  /// invalidates the write-back of the still-running previous one.
  final Map<String, AsyncSessionOwner> _querySessions = {};
  final Map<String, String> _effectiveKeywords = {};
  bool _isCancelled = false;

  String? effectiveKeywordFor(String name) => _effectiveKeywords[name];

  Future<void> querySource(String keyword, String pluginName) async {
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name == pluginName) {
        infoController.pluginSearchResponseList.removeWhere(
          (response) => response.pluginName == pluginName,
        );
        infoController.pluginSearchStatus[pluginName] =
            PluginSearchStatus.pending;
        await _queryPlugin(plugin, keyword);
        return;
      }
    }
  }

  /// Publishes the result page harvested by the captcha webview, skipping
  /// one network round trip. Returns false when the HTML does not parse
  /// into results; callers should fall back to [querySource].
  bool applyHarvestedSearchResult(String pluginName, String html) {
    if (_isCancelled) return false;
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name != pluginName) continue;
      final result = plugin.parseHarvestedSearch(html);
      if (result == null) return false;
      infoController.pluginSearchResponseList.removeWhere(
        (response) => response.pluginName == pluginName,
      );
      infoController.pluginSearchStatus[pluginName] =
          PluginSearchStatus.success;
      pluginsController.validityTracker.markSearchValid(pluginName);
      infoController.pluginSearchResponseList.add(result);
      return true;
    }
    return false;
  }

  Future<void> queryAllSource(String keyword) async {
    infoController.pluginSearchResponseList.clear();
    infoController.pluginSearchStatus.clear();
    _effectiveKeywords.clear();

    final plugins = List<Plugin>.of(pluginsController.pluginList);
    final fallback = seriesSearchFallback(keyword);
    for (final plugin in plugins) {
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.pending;
    }
    await Future.wait(
      plugins.map((plugin) => _queryPlugin(plugin, keyword, fallback: fallback)),
    );
  }

  Future<void> _queryPlugin(Plugin plugin, String keyword,
      {String? fallback}) async {
    if (_isCancelled) return;
    final session = _querySessions
        .putIfAbsent(plugin.name, AsyncSessionOwner.new)
        .begin();
    Future<PluginSearchResponse> search(String query) => plugin.queryBangumi(
        query,
        shouldRethrow: true,
        cancelToken: _cancelToken,
      );
    _effectiveKeywords[plugin.name] = keyword;
    try {
      PluginSearchResponse result;
      try {
        result = await search(keyword);
      } on NoResultException {
        if (fallback == null || _isCancelled || session.isStale) rethrow;
        _effectiveKeywords[plugin.name] = fallback;
        result = await search(fallback);
      }
      if (_isCancelled || session.isStale) return;
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.success;
      if (result.data.isNotEmpty) {
        pluginsController.validityTracker.markSearchValid(plugin.name);
      }
      infoController.pluginSearchResponseList.add(result);
    } catch (error) {
      if (_isCancelled || session.isStale) return;
      _handleSearchError(plugin, error);
    }
  }

  void _handleSearchError(Plugin plugin, Object error) {
    if (error is CaptchaRequiredException) {
      KazumiLogger().i(
        'PluginSearchService: captcha required for ${error.pluginName}',
      );
      infoController.pluginSearchStatus[error.pluginName] =
          PluginSearchStatus.captcha;
      return;
    }
    if (error is NoResultException) {
      KazumiLogger().i(
        'PluginSearchService: no results for ${error.pluginName}',
      );
      infoController.pluginSearchStatus[error.pluginName] =
          PluginSearchStatus.noResult;
      return;
    }
    final name = error is SearchErrorException ? error.pluginName : plugin.name;
    KazumiLogger().w('PluginSearchService: search error for $name');
    infoController.pluginSearchStatus[name] = PluginSearchStatus.error;
  }

  void cancel() {
    _isCancelled = true;
    _cancelToken.cancel();
  }
}
