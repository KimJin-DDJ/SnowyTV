import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/pages/player/episode_comments_picker.dart';
import 'package:kazumi/pages/player/episode_comments_view.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';

class EpisodeCommentsSheet extends StatefulWidget {
  const EpisodeCommentsSheet({
    super.key,
    required this.videoPageController,
    required this.episode,
    required this.selection,
    required this.isActive,
  });

  final VideoPageController videoPageController;
  final int episode;
  final VideoEpisodeSelection selection;
  final bool isActive;

  @override
  State<EpisodeCommentsSheet> createState() => _EpisodeCommentsSheetState();
}

class _EpisodeCommentsSheetState extends State<EpisodeCommentsSheet>
    with KazumiDialogOwner {
  VideoPageController get _controller => widget.videoPageController;
  late int _selectedEpisode;
  EpisodeInfo? _pickedEpisode;
  bool _isLoading = false;
  bool _hasError = false;
  bool _isAndroidTv = false;
  bool _hasLoadedCurrentEpisode = false;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    unawaited(PlatformEnvironmentService.isAndroidTv().then((value) {
      if (mounted) setState(() => _isAndroidTv = value);
    }).catchError((Object _) {}));
    _resetAndScheduleRefresh();
  }

  @override
  void didUpdateWidget(covariant EpisodeCommentsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final becameActive = !oldWidget.isActive && widget.isActive;
    final controllerChanged =
        oldWidget.videoPageController != widget.videoPageController;
    if (oldWidget.selection != widget.selection ||
        controllerChanged ||
        (oldWidget.episode != widget.episode &&
            widget.episode != _selectedEpisode)) {
      _resetAndScheduleRefresh();
    } else if (becameActive && !_hasLoadedCurrentEpisode && !_isLoading) {
      _scheduleRefresh();
    }
  }

  void _resetAndScheduleRefresh() {
    dialogs.cancel();
    final version = ++_requestVersion;
    _selectedEpisode = widget.episode;
    _pickedEpisode = null;
    _hasError = false;
    _isLoading = false;
    _hasLoadedCurrentEpisode =
        _controller.commentsEpisode == _selectedEpisode &&
            _controller.episodeCommentsList.isNotEmpty;
    if (widget.isActive && !_hasLoadedCurrentEpisode) {
      _scheduleRefresh(version);
    }
  }

  void _scheduleRefresh([int? requestVersion]) {
    final version = requestVersion ?? ++_requestVersion;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive && version == _requestVersion) {
        unawaited(_loadComments());
      }
    });
  }

  Future<void> _loadComments() async {
    final version = ++_requestVersion;
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    try {
      final applied = await _controller.queryBangumiEpisodeCommentsByID(
        _controller.bangumiItem.id,
        _selectedEpisode,
        pickedEpisode: _pickedEpisode,
      );
      if (!mounted || version != _requestVersion) return;
      if (!applied) {
        setState(() => _isLoading = false);
        return;
      }
      _hasLoadedCurrentEpisode = true;
      setState(() => _isLoading = false);
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
    }
  }

  Future<void> _showEpisodeSelection() async {
    if (dialogs.isRunning) return;
    final controller = _controller;
    await dialogs.run((task) async {
      final episodes = await task.loading(
        message: '分集列表加载中',
        action: () =>
            BangumiApi.getBangumiEpisodesByID(controller.bangumiItem.id),
      );
      if (episodes.isEmpty) {
        KazumiDialog.showToast(message: '未找到分集列表');
        return;
      }
      final selected = await task.show<EpisodeInfo>(
        builder: (context) => EpisodeCommentsPicker(
          episodes: episodes,
          selectedEpisode: _selectedEpisode,
          selectedEpisodeId: _pickedEpisode?.id ?? _controller.episodeInfo.id,
        ),
      );
      if (selected.id == (_pickedEpisode?.id ?? _controller.episodeInfo.id)) {
        return;
      }
      _pickedEpisode = selected;
      _selectedEpisode = selected.episode.toInt();
      _hasLoadedCurrentEpisode = false;
      unawaited(_loadComments());
    }, errorMessage: '分集列表加载失败，请稍后重试');
  }

  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      final picked = _pickedEpisode;
      final matchesEpisode = picked != null
          ? _controller.episodeInfo.id == picked.id
          : _controller.commentsEpisode == _selectedEpisode;
      return EpisodeCommentsView(
        episode: _selectedEpisode,
        episodeInfo: picked ??
            (matchesEpisode && _controller.episodeInfo.id != 0
                ? _controller.episodeInfo
                : null),
        comments: matchesEpisode ? _controller.episodeCommentsList.toList() : [],
        isLoading: _isLoading,
        hasError: _hasError,
        isAscending: _controller.isCommentsAscending,
        onToggleSort: _controller.toggleSortOrder,
        onSelectEpisode: _showEpisodeSelection,
        onRefresh: _loadComments,
        isAndroidTv: _isAndroidTv,
      );
    });
  }
}
