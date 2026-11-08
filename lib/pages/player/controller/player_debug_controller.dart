// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:kazumi/services/logging/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mobx/mobx.dart';

part 'player_debug_controller.g.dart';

class PlayerDebugController = _PlayerDebugController
    with _$PlayerDebugController;

abstract class _PlayerDebugController with Store {
  /// LogLevel 0: 错误 1: 警告 2: 简略 3: 详细
  int playerLogLevel = 2;

  @observable
  ObservableList<String> playerLog = ObservableList.of([]);
  @observable
  int playerWidth = 0;
  @observable
  int playerHeight = 0;
  @observable
  String playerVideoParams = '';
  @observable
  String playerAudioParams = '';
  @observable
  String playerPlaylist = '';
  @observable
  String playerAudioTracks = '';
  @observable
  String playerVideoTracks = '';
  @observable
  String playerAudioBitrate = '';
  @observable
  String playerVideoBitrate = '';

  final Observable<double> _videoFps = Observable(0.0);
  double get videoFps => _videoFps.value;
  set videoFps(double v) => runInAction(() => _videoFps.value = v);

  final Observable<String> _videoCodec = Observable('');
  String get videoCodec => _videoCodec.value;
  set videoCodec(String v) => runInAction(() => _videoCodec.value = v);

  final Observable<String> _audioCodec = Observable('');
  String get audioCodec => _audioCodec.value;
  set audioCodec(String v) => runInAction(() => _audioCodec.value = v);

  final Observable<String> _pixelFormat = Observable('');
  String get pixelFormat => _pixelFormat.value;
  set pixelFormat(String v) => runInAction(() => _pixelFormat.value = v);

  final Observable<String> _hwdecActive = Observable('');
  String get hwdecActive => _hwdecActive.value;
  set hwdecActive(String v) => runInAction(() => _hwdecActive.value = v);

  final Observable<int> _droppedFrames = Observable(0);
  int get droppedFrames => _droppedFrames.value;
  set droppedFrames(int v) => runInAction(() => _droppedFrames.value = v);

  /// 简短画质徽章标签：如 1080P、2K、4K、720P
  String get qualityShortLabel {
    if (playerWidth <= 0 || playerHeight <= 0) return '检测中';
    final minDim = playerWidth > playerHeight ? playerHeight : playerWidth;
    final maxDim = playerWidth > playerHeight ? playerWidth : playerHeight;
    if (minDim >= 2000 || maxDim >= 3800) return '4K';
    if (minDim >= 1350) return '2K';
    if (minDim >= 900 || maxDim >= 1800) return '1080P';
    if (minDim >= 650 || maxDim >= 1200) return '720P';
    if (minDim >= 400 || maxDim >= 800) return '480P';
    return '${minDim}P';
  }

  /// 完整画质等级描述：如 1080P 宽银幕、1080P 高清、4K 极清
  String get qualityBadgeText {
    if (playerWidth <= 0 || playerHeight <= 0) return '检测画质...';
    final minDim = playerWidth > playerHeight ? playerHeight : playerWidth;
    final maxDim = playerWidth > playerHeight ? playerWidth : playerHeight;
    final isUltrawide = (maxDim / minDim) >= 2.0;

    if (minDim >= 2000 || maxDim >= 3800) {
      return isUltrawide ? '4K 宽银幕' : '4K 极清';
    }
    if (minDim >= 1350) {
      return isUltrawide ? '2K 宽银幕' : '2K 超清';
    }
    if (minDim >= 900 || maxDim >= 1800) {
      return isUltrawide ? '1080P 宽银幕' : '1080P 高清';
    }
    if (minDim >= 650 || maxDim >= 1200) return '720P 标清';
    if (minDim >= 400 || maxDim >= 800) return '480P 流畅';
    return '${minDim}P';
  }

  /// 格式化码率：如 3.2 Mbps、1850 kbps
  String get formattedBitrate {
    if (playerVideoBitrate.isNotEmpty) {
      final val = double.tryParse(playerVideoBitrate);
      if (val != null && val > 0) {
        return val >= 1000000
            ? '${(val / 1000000).toStringAsFixed(1)} Mbps'
            : '${(val / 1000).toStringAsFixed(0)} kbps';
      }
    }
    return '检测中...';
  }

  /// 格式化帧率：如 60 fps、23.98 fps、59.94 fps
  String get formattedFps {
    if (videoFps > 0) {
      final isInt = videoFps.truncateToDouble() == videoFps;
      if (isInt) return '${videoFps.toInt()} fps';
      // 去掉小数末尾多余的 0，如 24.00 -> 24，23.50 -> 23.5
      final text = videoFps.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
      return '$text fps';
    }
    return '';
  }

  Player? _nativeStatsPlayer;
  Timer? _liveStatsTimer;
  bool _liveStatsInFlight = false;

  StreamSubscription<PlayerLog>? playerLogSubscription;
  StreamSubscription<int?>? playerWidthSubscription;
  StreamSubscription<int?>? playerHeightSubscription;
  StreamSubscription<VideoParams>? playerVideoParamsSubscription;
  StreamSubscription<AudioParams>? playerAudioParamsSubscription;
  StreamSubscription<Playlist>? playerPlaylistSubscription;
  StreamSubscription<Track>? playerTracksSubscription;
  StreamSubscription<double?>? playerAudioBitrateSubscription;
  StreamSubscription<double?>? playerVideoBitrateSubscription;

  Future<void> setup(
    Player player, {
    required bool Function(Player player) isCurrentPlayer,
    required bool playerDebugMode,
  }) async {
    await playerLogSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerLogSubscription = player.stream.log.listen((event) {
      playerLog.add(event.toString());
      if (playerDebugMode) {
        KazumiLogger().i("MPV: ${event.toString()}", forceLog: true);
      }
    });
    await playerWidthSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerWidthSubscription = player.stream.width.listen((event) {
      playerWidth = event ?? 0;
    });
    await playerHeightSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerHeightSubscription = player.stream.height.listen((event) {
      playerHeight = event ?? 0;
    });
    await playerVideoParamsSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerVideoParamsSubscription = player.stream.videoParams.listen((event) {
      playerVideoParams = event.toString();
      if (event.w != null && event.w! > 0) playerWidth = event.w!;
      if (event.h != null && event.h! > 0) playerHeight = event.h!;
      if (event.pixelformat != null && event.pixelformat!.isNotEmpty) {
        pixelFormat = event.pixelformat!;
      }
    });
    await playerAudioParamsSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerAudioParamsSubscription = player.stream.audioParams.listen((event) {
      playerAudioParams = event.toString();
    });
    await playerPlaylistSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerPlaylistSubscription = player.stream.playlist.listen((event) {
      playerPlaylist = event.toString();
    });
    await playerTracksSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerTracksSubscription = player.stream.track.listen((event) {
      playerAudioTracks = event.audio.toString();
      playerVideoTracks = event.video.toString();
      final v = event.video;
      if (v != null) {
        if (v.fps != null && v.fps! > 0) videoFps = v.fps!;
        if (v.codec != null && v.codec!.isNotEmpty) videoCodec = v.codec!;
        if (v.w != null && v.w! > 0) playerWidth = v.w!;
        if (v.h != null && v.h! > 0) playerHeight = v.h!;
      }
      final a = event.audio;
      if (a != null && a.codec != null && a.codec!.isNotEmpty) {
        audioCodec = a.codec!;
      }
    });
    await playerAudioBitrateSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerAudioBitrateSubscription = player.stream.audioBitrate.listen((event) {
      playerAudioBitrate = event.toString();
    });
    await playerVideoBitrateSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerVideoBitrateSubscription = player.stream.videoBitrate.listen((event) {
      playerVideoBitrate = event.toString();
    });

    // 动态提取底层 MPV 解码参数与丢帧指标
    _nativeStatsPlayer = player;
    unawaited(refreshNativeStats());
  }

  /// 读取 MPV 原生统计属性并刷新观察字段，内部异常不会向外抛出
  Future<void> refreshNativeStats() async {
    final player = _nativeStatsPlayer;
    if (player == null || _liveStatsInFlight) return;
    _liveStatsInFlight = true;
    try {
      final pp = player.platform as NativePlayer;
      final fpsVal = double.tryParse(await pp.getProperty('estimated-vf-fps'));
      if (fpsVal != null && fpsVal > 0) videoFps = fpsVal;
      // 部分 libmpv 构建下 video-codec 为空，退回 video-format（如 h264/hevc）。
      var codecStr = await pp.getProperty('video-codec');
      if (codecStr.isEmpty) codecStr = await pp.getProperty('video-format');
      if (codecStr.isNotEmpty) videoCodec = codecStr;
      if (audioCodec.isEmpty) {
        final audioStr = await pp.getProperty('audio-codec-name');
        if (audioStr.isNotEmpty) audioCodec = audioStr;
      }
      final hwdecStr = await pp.getProperty('hwdec-current');
      if (hwdecStr.isNotEmpty) hwdecActive = hwdecStr;
      // 渲染丢帧 + 解码丢帧，任一读取失败时只累加另一项
      final renderDrops = int.tryParse(await pp.getProperty('frame-drop-count'));
      final decoderDrops =
          int.tryParse(await pp.getProperty('decoder-frame-drop-count'));
      if (renderDrops != null || decoderDrops != null) {
        droppedFrames = (renderDrops ?? 0) + (decoderDrops ?? 0);
      }
    } catch (e) {
      KazumiLogger().w('PlayerDebug: refresh native stats failed', error: e);
    } finally {
      _liveStatsInFlight = false;
    }
  }

  /// 仅在画质检测面板打开期间调用，每秒刷新一次原生统计
  void startLiveStats() {
    if (_liveStatsTimer != null) return;
    _liveStatsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(refreshNativeStats()),
    );
    unawaited(refreshNativeStats());
  }

  void stopLiveStats() {
    _liveStatsTimer?.cancel();
    _liveStatsTimer = null;
  }

  Future<void> cancel() async {
    stopLiveStats();
    _nativeStatsPlayer = null;
    videoFps = 0.0;
    videoCodec = '';
    audioCodec = '';
    pixelFormat = '';
    hwdecActive = '';
    droppedFrames = 0;
    // Detach fields before awaiting so a new player cannot lose its listeners.
    final logSubscription = playerLogSubscription;
    final widthSubscription = playerWidthSubscription;
    final heightSubscription = playerHeightSubscription;
    final videoParamsSubscription = playerVideoParamsSubscription;
    final audioParamsSubscription = playerAudioParamsSubscription;
    final playlistSubscription = playerPlaylistSubscription;
    final tracksSubscription = playerTracksSubscription;
    final audioBitrateSubscription = playerAudioBitrateSubscription;
    final videoBitrateSubscription = playerVideoBitrateSubscription;

    playerLogSubscription = null;
    playerWidthSubscription = null;
    playerHeightSubscription = null;
    playerVideoParamsSubscription = null;
    playerAudioParamsSubscription = null;
    playerPlaylistSubscription = null;
    playerTracksSubscription = null;
    playerAudioBitrateSubscription = null;
    playerVideoBitrateSubscription = null;

    await logSubscription?.cancel();
    await widthSubscription?.cancel();
    await heightSubscription?.cancel();
    await videoParamsSubscription?.cancel();
    await audioParamsSubscription?.cancel();
    await playlistSubscription?.cancel();
    await tracksSubscription?.cancel();
    await audioBitrateSubscription?.cancel();
    await videoBitrateSubscription?.cancel();
  }
}
