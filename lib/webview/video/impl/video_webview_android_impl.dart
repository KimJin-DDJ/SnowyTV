import 'dart:async';
import 'dart:ui';
import 'package:kazumi/request/core/plugin_network_support.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart'
    as android_webview;
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/utils/http_headers.dart';

class VideoWebviewAndroidImpl
    extends VideoWebviewController<PlatformInAppWebViewController> {
  PlatformHeadlessInAppWebView? headlessWebView;
  bool hasInjectedScripts = false;
  bool shouldInjectIframeRedirect = false;
  bool useLegacyParser = false;
  Timer? videoParserTimer;

  @override
  Future<void> init() async {
    await _setupProxy();
    headlessWebView ??= PlatformHeadlessInAppWebView(
      PlatformHeadlessInAppWebViewCreationParams(
        initialSize: const Size(360, 640),
        initialSettings: InAppWebViewSettings(
          userAgent: getRandomUA(),
          mediaPlaybackRequiresUserGesture: false,
          cacheEnabled: true,
          upgradeKnownHostsToHTTPS: false,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
          safeBrowsingEnabled: false,
          geolocationEnabled: false,
          javaScriptEnabled: true,
          supportMultipleWindows: false,
        ),
        onWebViewCreated: (controller) {
          KazumiLogger().i('[WebView Android] Created');
          webviewController = controller;
          initEventController.add(true);
        },
        shouldInterceptRequest: (controller, request) async {
          if (!useLegacyParser && !isVideoSourceLoaded) {
            final url = request.url.toString();
            final lower = url.toLowerCase();
            if (!_isAdUrl(lower) &&
                (_isM3U8Url(lower) ||
                    _isRangeVideoRequest(lower, request.headers))) {
              _handleVideoResolved(
                url,
                'Native intercepted video URL',
                format: _isM3U8Url(lower) && lower.contains('.m3u8')
                    ? VideoSourceFormat.hls
                    : VideoSourceFormat.auto,
              );
            }
          }
          final method = (request.method ?? 'GET').toUpperCase();
          if ((method == 'GET' || method == 'HEAD') &&
              PluginNetworkSupport.shouldProxyInWebView(request.url)) {
            final fetched = await PluginNetworkSupport.fetchForWebView(
              request.url,
              method: method,
              headers: request.headers ?? const {},
            );
            if (fetched != null && fetched.statusCode < 300) {
              return WebResourceResponse(
                contentType: fetched.contentType,
                contentEncoding: fetched.contentEncoding,
                statusCode: fetched.statusCode,
                reasonPhrase: fetched.reasonPhrase,
                headers: fetched.headers,
                data: fetched.data,
              );
            }
          }
          return null;
        },
        onLoadStart: (controller, url) async {
          logEventController.add('started loading: $url');
        },
        onLoadStop: (controller, url) async {
          logEventController.add('loading completed: $url');
          if (url.toString() != 'about:blank') {
            await _pollVideoSource();
          }
        },
        onConsoleMessage: (controller, consoleMessage) {
          logEventController.add(
              'Console [${consoleMessage.messageLevel}]: ${consoleMessage.message}');
        },
        onReceivedError: (controller, request, error) {
          logEventController
              .add('Error: ${error.description} - ${request.url}');
        },
      ),
    );
    await headlessWebView?.run();
  }

  void _handleVideoResolved(
    String url,
    String sourceDesc, {
    VideoSourceFormat format = VideoSourceFormat.auto,
  }) {
    if (isVideoSourceLoaded) return;
    String cleanUrl = url.trim();
    if (cleanUrl.startsWith('//')) {
      cleanUrl = 'https:$cleanUrl';
    }
    // 部分站点把参数直接拼在 .m3u8 后面（如 xx.m3u8&t=hls），没有 '?' 会导致 404。
    final badQuery = RegExp(r'\.m3u8&', caseSensitive: false);
    if (!cleanUrl.contains('?') && badQuery.hasMatch(cleanUrl)) {
      cleanUrl = cleanUrl.replaceFirst(badQuery, '.m3u8?');
    }
    if (_isPageUrl(cleanUrl)) {
      // MacCMS 的 MacPlayer.Url 等字段是播放页自身地址，不是视频流；忽略后继续轮询。
      logEventController.add('Ignored page URL from $sourceDesc: $cleanUrl');
      KazumiLogger().d('[WebView Android] ignored page URL ($sourceDesc): $cleanUrl');
      return;
    }
    logEventController.add('$sourceDesc: $cleanUrl');
    KazumiLogger().i('[WebView Android] $sourceDesc: $cleanUrl');
    isIframeLoaded = true;
    isVideoSourceLoaded = true;
    videoLoadingEventController.add(false);
    videoParserTimer?.cancel();
    videoParserTimer = null;
    unloadPage();
    notifyVideoSourceResolved(cleanUrl, format: format);
  }

  String? _loadingPageUrl;

  /// 播放页地址（或任意 .html/.htm 页面）不是可播放的视频流。
  bool _isPageUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    if (path.endsWith('.html') || path.endsWith('.htm')) return true;
    final page = _loadingPageUrl == null ? null : Uri.tryParse(_loadingPageUrl!);
    return page != null &&
        page.host == uri.host &&
        page.path == uri.path &&
        page.query == uri.query;
  }

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    _loadingPageUrl = url;
    this.useLegacyParser = useLegacyParser;
    if (!hasInjectedScripts) {
      addJavaScriptHandlers(useLegacyParser);
      await addUserScripts(useLegacyParser);
      hasInjectedScripts = true;
    }
    count = 0;
    this.offset = offset;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;
    shouldInjectIframeRedirect = true;
    videoLoadingEventController.add(true);

    _startVideoParserTimer();
    await webviewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void addJavaScriptHandlers(bool useLegacyParser) {
    logEventController.add('Adding LogBridge handler');
    webviewController?.addJavaScriptHandler(
        handlerName: 'LogBridge',
        callback: (args) {
          String message = args[0].toString();
          if (message.contains('about:blank')) {
            return;
          }
          logEventController.add(message);
        });

    if (useLegacyParser) {
      logEventController.add('Adding JSBridgeDebug handler');
      webviewController?.addJavaScriptHandler(
          handlerName: 'JSBridgeDebug',
          callback: (args) {
            String message = args[0].toString();
            logEventController.add('Callback received: $message');
            if ((message.contains('http') || message.startsWith('//')) &&
                !_isAdUrl(message.toLowerCase())) {
              logEventController.add('Parsing video source $message');
              String encodedUrl = Uri.encodeFull(message);
              final decoded = decodeVideoSource(encodedUrl);
              if (decoded != encodedUrl) {
                _handleVideoResolved(decoded, 'Decoded legacy video source');
              }
            }
          });
    } else {
      logEventController.add('Adding VideoBridgeDebug handler');
      webviewController?.addJavaScriptHandler(
          handlerName: 'VideoBridgeDebug',
          callback: (args) {
            String message = args[0].toString().trim();
            final formatHint =
                args.length > 1 ? args[1]?.toString() : null;
            final format = formatHint == 'hls'
                ? VideoSourceFormat.hls
                : VideoSourceFormat.auto;
            logEventController.add('Callback received: $message');
            if ((message.contains('http') || message.startsWith('//')) &&
                !isVideoSourceLoaded &&
                !_isAdUrl(message.toLowerCase())) {
              _handleVideoResolved(
                message,
                'JSBridge video source',
                format: format,
              );
            }
          });
    }
  }

  Future<void> addUserScripts(bool useLegacyParser) async {
    final List<UserScript> scripts = [];

    // Older Android TV WebViews (e.g. Chromium 113) lack AbortSignal.any /
    // Promise.withResolvers used by modern Next.js/Supabase player pages.
    const String webCompatScript = """
      (function() {
        if (typeof AbortSignal !== 'undefined') {
          if (typeof AbortSignal.any !== 'function') {
            AbortSignal.any = function(signals) {
              var controller = new AbortController();
              if (!signals) return controller.signal;
              var list = Array.from(signals);
              for (var i = 0; i < list.length; i++) {
                var sig = list[i];
                if (!sig) continue;
                if (sig.aborted) {
                  try { controller.abort(sig.reason); } catch (_) { controller.abort(); }
                  return controller.signal;
                }
                (function(s) {
                  s.addEventListener('abort', function() {
                    if (!controller.signal.aborted) {
                      try { controller.abort(s.reason); } catch (_) { controller.abort(); }
                    }
                  }, { once: true });
                })(sig);
              }
              return controller.signal;
            };
          }
          if (typeof AbortSignal.timeout !== 'function') {
            AbortSignal.timeout = function(ms) {
              var controller = new AbortController();
              setTimeout(function() {
                try {
                  controller.abort(new DOMException('Signal timed out.', 'TimeoutError'));
                } catch (_) {
                  controller.abort();
                }
              }, ms);
              return controller.signal;
            };
          }
        }
        if (typeof Promise !== 'undefined' && typeof Promise.withResolvers !== 'function') {
          Promise.withResolvers = function() {
            var resolve, reject;
            var promise = new Promise(function(res, rej) {
              resolve = res;
              reject = rej;
            });
            return { promise: promise, resolve: resolve, reject: reject };
          };
        }
      })();
    """;
    scripts.add(UserScript(
      source: webCompatScript,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      forMainFrameOnly: false,
    ));

    if (useLegacyParser) {
      logEventController.add('Adding JSBridgeDebug UserScript');
      const String jsBridgeDebugScript = """
        window.flutter_inappwebview.callHandler('LogBridge', 'JSBridgeDebug script loaded: ' + window.location.href);
        function processIframeElement(iframe) {
          window.flutter_inappwebview.callHandler('LogBridge', 'Processing iframe element');
          let src = iframe.getAttribute('src');
          if (src) {
            window.flutter_inappwebview.callHandler('JSBridgeDebug', src);
          }
        }

        const _observer = new MutationObserver((mutations) => {
          mutations.forEach(mutation => {
            if (mutation.type === 'attributes' && mutation.target.nodeName === 'IFRAME') {
              processIframeElement(mutation.target);
            } else {
              mutation.addedNodes.forEach(node => {
                if (node.nodeName === 'IFRAME') processIframeElement(node);
                if (node.querySelectorAll) {
                  node.querySelectorAll('iframe').forEach(processIframeElement);
                }
              });
            }
          });  
        });

        _observer.observe(document.documentElement, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ['src']
        });
      """;
      scripts.add(UserScript(
        source: jsBridgeDebugScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ));
    } else {
      logEventController.add('Adding VideoBridgeDebug UserScripts');
      const String blobParserScript = """
        window.flutter_inappwebview.callHandler('LogBridge', 'BlobParser script loaded: ' + window.location.href);

        function _isStreamUrl(u) {
          if (!u || typeof u !== 'string') return false;
          const low = u.toLowerCase();
          if (low.includes('googleads') || low.includes('adtrafficquality') || low.includes('prestrain.html') || low.includes('adposter')) return false;
          return low.includes('.m3u8') || low.includes('.mp4');
        }

        // 1. Intercept fetch immediately on request URL
        const _fetch = window.fetch;
        if (_fetch) {
          window.fetch = function (...args) {
            try {
              const reqUrl = (typeof args[0] === 'string') ? args[0] : (args[0] && args[0].url);
              if (_isStreamUrl(reqUrl)) {
                window.flutter_inappwebview.callHandler('LogBridge', 'Fetch stream URL: ' + reqUrl);
                window.flutter_inappwebview.callHandler('VideoBridgeDebug', reqUrl);
              }
            } catch(e) {}
            return _fetch.apply(this, args);
          };
        }

        // 2. Intercept Response.text() for #EXTM3U bodies
        const _r_text = window.Response.prototype.text;
        window.Response.prototype.text = function () {
          return new Promise((resolve, reject) => {
            _r_text.call(this).then((text) => {
              resolve(text);
              if (typeof text === 'string' && text.trim().startsWith("#EXTM3U")) {
                window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found in response: ' + this.url);
                window.flutter_inappwebview.callHandler('VideoBridgeDebug', this.url, 'hls');
              }
            }).catch(reject);
          });
        };

        // 3. Intercept XMLHttpRequest.open immediately on URL
        const _open = window.XMLHttpRequest.prototype.open;
        window.XMLHttpRequest.prototype.open = function (...args) {
          try {
            const reqUrl = args[1];
            if (_isStreamUrl(reqUrl)) {
              window.flutter_inappwebview.callHandler('LogBridge', 'XHR stream URL: ' + reqUrl);
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', reqUrl);
            }
          } catch(e) {}

          this.addEventListener("load", () => {
            try {
              if (!this.responseType || this.responseType === 'text') {
                let content = this.responseText;
                if (content && content.trim().startsWith("#EXTM3U")) {
                  window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found in XHR: ' + args[1]);
                  window.flutter_inappwebview.callHandler('VideoBridgeDebug', args[1], 'hls');
                }
              }
            } catch(e) {}
          });
          return _open.apply(this, args);
        };
      """;

      const String videoTagParserScript = """
        window.flutter_inappwebview.callHandler('LogBridge', 'VideoTagParser script loaded: ' + window.location.href);

        function _isDirectMediaUrl(u) {
          if (!u || typeof u !== 'string') return false;
          var s = u.trim();
          if (!(s.indexOf('http') === 0 || s.indexOf('//') === 0)) return false;
          var clean = s.split('#')[0].split('?')[0].toLowerCase();
          if (clean.endsWith('.html') || clean.endsWith('.htm')) return false;
          return clean.endsWith('.m3u8') ||
                 clean.endsWith('.mp4') ||
                 clean.endsWith('.flv') ||
                 clean.endsWith('.mkv') ||
                 clean.endsWith('.webm') ||
                 clean.endsWith('.mknvideo') ||
                 clean.endsWith('.ts') ||
                 s.toLowerCase().indexOf('.m3u8') !== -1;
        }

        function _findStreamInScripts() {
          try {
            // MacCMS 播放页把真实地址放在 player_aaaa.url（可能经过 escape/base64），
            // 但部分站点会填中间网页地址（如 quan.qq.com、xifanacg、bilibili），仅直链媒体才提前返回。
            var _pa = window.player_aaaa; var _pu = _pa && _pa.url ? String(_pa.url) : '';
            if (_pu && _pa.encrypt == 1) { try { _pu = unescape(_pu); } catch(e) {} }
            if (_pu && _pa.encrypt == 2) { try { _pu = unescape(atob(_pu)); } catch(e) {} }
            if (_isDirectMediaUrl(_pu)) {
              return _pu;
            }
            // Check global player objects
            if (window.art && window.art.option && window.art.option.url) {
              return window.art.option.url;
            }
            if (window.dp && window.dp.video && window.dp.video.url) {
              return window.dp.video.url;
            }
            if (window.player && window.player.url) {
              return window.player.url;
            }
            if (window.MacPlayer && window.MacPlayer.PlayUrl &&
                _isDirectMediaUrl(String(window.MacPlayer.PlayUrl))) {
              return window.MacPlayer.PlayUrl;
            }

            // Check inline script tags
            const scripts = document.getElementsByTagName('script');
            const m3u8Regex = /https?:\\/\\/[^'"<>\\s\\\\]+?\\.(?:m3u8|mp4)[^'"<>\\s\\\\]*/gi;
            for (let i = 0; i < scripts.length; i++) {
              const text = scripts[i].textContent || scripts[i].innerText;
              if (text) {
                const matches = text.match(m3u8Regex) || [];
                for (let j = 0; j < matches.length; j++) {
                  const candidate = matches[j];
                  const low = candidate.toLowerCase();
                  if (!low.includes('googleads') && !low.includes('prestrain.html') && !low.includes('adposter') && !low.includes('baidu.com')) {
                    return candidate;
                  }
                }
              }
            }
          } catch(e) {}
          return null;
        }

        function _triggerPlayAttempts() {
          try {
            if (window.art && typeof window.art.play === 'function') window.art.play();
            if (window.dp && typeof window.dp.play === 'function') window.dp.play();
            const btn = document.querySelector('.art-icon-state, .art-state, .dplayer-mobile-play, .dplayer-play-icon, button.play, .play-btn');
            if (btn) btn.click();
            const videos = document.querySelectorAll('video');
            for (let i = 0; i < videos.length; i++) {
              videos[i].muted = true;
              videos[i].play().catch(() => {});
            }
          } catch(e) {}
        }

        function processVideoElement(video) {
          let src = video.getAttribute('src') || video.currentSrc || video.src;
          if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads') && !src.toLowerCase().includes('adposter')) {
            window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found: ' + src);
            window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
            return true;
          }
          const sources = video.getElementsByTagName('source');
          for (let source of sources) {
            src = source.getAttribute('src');
            if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads') && !src.toLowerCase().includes('adposter')) {
              window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found (source tag): ' + src);
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
              return true;
            }
          }
          return false;
        }

        function runFullDetection() {
          const scriptUrl = _findStreamInScripts();
          if (scriptUrl) {
            window.flutter_inappwebview.callHandler('LogBridge', 'Stream URL found in page script/player: ' + scriptUrl);
            window.flutter_inappwebview.callHandler('VideoBridgeDebug', scriptUrl);
            return;
          }

          for (const video of document.querySelectorAll("video")) {
            if (processVideoElement(video)) return;
          }

          _triggerPlayAttempts();
        }

        const _observer = new MutationObserver((mutations) => {
          for (const mutation of mutations) {
            if (mutation.type === "attributes" && mutation.target.nodeName === "VIDEO") {
              if (processVideoElement(mutation.target)) return;
            }
            for (const node of mutation.addedNodes) {
              if (node.nodeName === "VIDEO") {
                if (processVideoElement(node)) return;
              }
              if (node.querySelectorAll) {
                for (const video of node.querySelectorAll("video")) {
                  if (processVideoElement(video)) return;
                }
              }
            }
          }
        });

        function setupVideoProcessing() {
          runFullDetection();
          if (document.body) {
            _observer.observe(document.body, {
              childList: true,
              subtree: true,
              attributes: true,
              attributeFilter: ['src']
            });
          }
          if (window !== window.top) {
            var _iframePollCount = 0;
            var _iframePoller = setInterval(function() {
              if (++_iframePollCount > 15) {
                clearInterval(_iframePoller);
                return;
              }
              runFullDetection();
            }, 1000);
          }
        }

        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', setupVideoProcessing);
        } else {
          setupVideoProcessing();
        }
      """;

      scripts.add(UserScript(
        source: blobParserScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ));
      scripts.add(UserScript(
        source: videoTagParserScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ));
    }

    await webviewController?.addUserScripts(
      userScripts: scripts,
    );
  }

  void _startVideoParserTimer() {
    videoParserTimer?.cancel();
    videoParserTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (isVideoSourceLoaded) {
        timer.cancel();
        return;
      }
      _pollVideoSource();
    });
  }

  Future<void> _pollVideoSource() async {
    if (isVideoSourceLoaded) return;

    if (useLegacyParser) {
      await webviewController?.evaluateJavascript(source: """
        (function() {
          var iframes = document.querySelectorAll('iframe');
          for (var i = 0; i < iframes.length; i++) {
            var src = iframes[i].getAttribute('src');
            if (src) {
              window.flutter_inappwebview.callHandler('JSBridgeDebug', src);
            }
          }
        })();
      """);
    } else {
      await webviewController?.evaluateJavascript(source: """
        (function() {
          try {
            function _isDirectMediaUrl(u) {
              if (!u || typeof u !== 'string') return false;
              var s = u.trim();
              if (!(s.indexOf('http') === 0 || s.indexOf('//') === 0)) return false;
              var clean = s.split('#')[0].split('?')[0].toLowerCase();
              if (clean.endsWith('.html') || clean.endsWith('.htm')) return false;
              return clean.endsWith('.m3u8') ||
                     clean.endsWith('.mp4') ||
                     clean.endsWith('.flv') ||
                     clean.endsWith('.mkv') ||
                     clean.endsWith('.webm') ||
                     clean.endsWith('.mknvideo') ||
                     clean.endsWith('.ts') ||
                     s.toLowerCase().indexOf('.m3u8') !== -1;
            }
            var _pa = window.player_aaaa; var _pu = _pa && _pa.url ? String(_pa.url) : '';
            if (_pu && _pa.encrypt == 1) { try { _pu = unescape(_pu); } catch(e) {} }
            if (_pu && _pa.encrypt == 2) { try { _pu = unescape(atob(_pu)); } catch(e) {} }
            if (_isDirectMediaUrl(_pu)) {
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', _pu);
              return;
            }
            if (window.art && window.art.option && window.art.option.url) {
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', window.art.option.url);
              return;
            }
            if (window.dp && window.dp.video && window.dp.video.url) {
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', window.dp.video.url);
              return;
            }
            if (window.player && window.player.url) {
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', window.player.url);
              return;
            }
            if (window.MacPlayer && window.MacPlayer.PlayUrl &&
                _isDirectMediaUrl(String(window.MacPlayer.PlayUrl))) {
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', window.MacPlayer.PlayUrl);
              return;
            }

            var scripts = document.getElementsByTagName('script');
            var m3u8Regex = /https?:\\/\\/[^'"<>\\s\\\\]+?\\.(?:m3u8|mp4)[^'"<>\\s\\\\]*/gi;
            for (var i = 0; i < scripts.length; i++) {
              var text = scripts[i].textContent || scripts[i].innerText;
              if (text) {
                var matches = text.match(m3u8Regex) || [];
                for (var m = 0; m < matches.length; m++) {
                  var cand = matches[m];
                  var candLow = cand.toLowerCase();
                  if (!candLow.includes('googleads') && !candLow.includes('prestrain.html') && !candLow.includes('adposter') && !candLow.includes('baidu.com')) {
                    window.flutter_inappwebview.callHandler('VideoBridgeDebug', cand);
                    return;
                  }
                }
              }
            }

            var videos = document.querySelectorAll('video');
            for (var j = 0; j < videos.length; j++) {
              var src = videos[j].getAttribute('src') || videos[j].currentSrc || videos[j].src;
              if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads') && !src.toLowerCase().includes('adposter')) {
                window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
                return;
              }
              var sources = videos[j].getElementsByTagName('source');
              for (var k = 0; k < sources.length; k++) {
                var s = sources[k].getAttribute('src');
                if (s && s.trim() !== '' && !src.startsWith('blob:') && !s.includes('googleads') && !s.toLowerCase().includes('adposter')) {
                  window.flutter_inappwebview.callHandler('VideoBridgeDebug', s);
                  return;
                }
              }
            }

            if (window.art && typeof window.art.play === 'function') window.art.play();
            if (window.dp && typeof window.dp.play === 'function') window.dp.play();
            var btn = document.querySelector('.art-icon-state, .art-state, .dplayer-mobile-play, .dplayer-play-icon, button.play, .play-btn');
            if (btn) btn.click();
          } catch(e) {}
        })();
      """);
    }
  }

  @override
  Future<void> unloadPage() async {
    videoParserTimer?.cancel();
    videoParserTimer = null;
    await webviewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri("about:blank")));
  }

  @override
  Future<void> dispose() async {
    videoParserTimer?.cancel();
    videoParserTimer = null;
    await headlessWebView?.dispose();
    headlessWebView = null;
    webviewController = null;
    disposeEventControllers();
  }

  bool _isM3U8Url(String lower) {
    if (_isAdUrl(lower)) return false;
    final uri = Uri.tryParse(lower);
    if (uri != null) {
      final path = uri.path;
      if (path.endsWith('.m3u8') ||
          path.endsWith('.mp4') ||
          path.endsWith('.mkv') ||
          path.endsWith('.flv')) {
        return true;
      }
    }
    if (lower.contains('.m3u8')) {
      return true;
    }
    return false;
  }

  bool _isRangeVideoRequest(String lower, Map<String, String>? headers) {
    if (headers == null) return false;
    final range = headers['Range'] ?? headers['range'];
    if (range == null || !range.startsWith('bytes=')) return false;
    if (_isAdUrl(lower)) return false;
    if (lower.endsWith('.js') ||
        lower.endsWith('.css') ||
        lower.endsWith('.html') ||
        lower.endsWith('.json') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.svg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.woff') ||
        lower.endsWith('.woff2') ||
        lower.endsWith('.ttf') ||
        lower.endsWith('.wasm')) {
      return false;
    }
    return true;
  }

  bool _isAdUrl(String lower) {
    return lower.contains('googleads') ||
        lower.contains('googlesyndication') ||
        lower.contains('adtrafficquality') ||
        lower.contains('doubleclick') ||
        lower.contains('adposter') ||
        lower.contains('/adv/') ||
        lower.contains('/ads/') ||
        lower.contains('prestrain.html') ||
        lower.contains('prestrain%2ehtml') ||
        lower.contains('cnzz.com') ||
        lower.contains('baidu.com') ||
        lower.contains('umeng.com');
  }

  Future<void> _setupProxy() async {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) {
      return;
    }

    final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
    if (formattedProxy == null) {
      return;
    }

    try {
      final proxyAvailable =
          await android_webview.AndroidWebViewFeature.instance()
              .isFeatureSupported(WebViewFeature.PROXY_OVERRIDE);
      if (!proxyAvailable) {
        KazumiLogger().w('WebView: 当前 Android 版本不支持代理');
        return;
      }

      final proxyController = android_webview.AndroidProxyController.instance();
      await proxyController.clearProxyOverride();
      await proxyController.setProxyOverride(
        settings: ProxySettings(
          proxyRules: [
            ProxyRule(url: formattedProxy),
          ],
        ),
      );
      KazumiLogger().i('WebView: 代理设置成功 $formattedProxy');
    } catch (e) {
      KazumiLogger().e('WebView: 设置代理失败 $e');
    }
  }
}
