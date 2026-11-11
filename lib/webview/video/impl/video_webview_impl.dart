import 'dart:async';
import 'dart:ui';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart'
    as android_webview;
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/utils/http_headers.dart';

class VideoWebviewImpl
    extends VideoWebviewController<PlatformInAppWebViewController> {
  PlatformHeadlessInAppWebView? headlessWebView;
  bool hasRegisteredHandlers = false;
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
          upgradeKnownHostsToHTTPS: false,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        ),
        onWebViewCreated: (controller) {
          print('[WebView] Created (legacy fallback)');
          webviewController = controller;
          initEventController.add(true);
        },
        shouldInterceptRequest: (controller, request) async {
          if (useLegacyParser || isVideoSourceLoaded) return null;
          final url = request.url.toString();
          final lower = url.toLowerCase();
          if (_isAdUrl(lower)) return null;
          if (_isM3U8Url(lower) ||
              _isRangeVideoRequest(lower, request.headers)) {
            logEventController.add('Native intercepted video URL: $url');
            isIframeLoaded = true;
            isVideoSourceLoaded = true;
            videoLoadingEventController.add(false);
            unloadPage();
            notifyVideoSourceResolved(url);
          }
          return null;
        },
        onLoadStart: (controller, url) async {
          logEventController.add('started loading: $url');
          if (url.toString() != 'about:blank') {
            await _onLoadStart();
          }
        },
        onLoadStop: (controller, url) async {
          logEventController.add('loading completed: $url');
          if (url.toString() != 'about:blank') {
            await _onLoadStop();
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

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    if (!hasRegisteredHandlers) {
      _addJavaScriptHandlers(useLegacyParser);
      hasRegisteredHandlers = true;
    }
    count = 0;
    this.offset = offset;
    this.useLegacyParser = useLegacyParser;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;
    videoLoadingEventController.add(true);

    await webviewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _addJavaScriptHandlers(bool useLegacyParser) {
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
            logEventController.add(
                'If there is audio but no video, please report it to the rule developer.');
            if ((message.contains('http') || message.startsWith('//')) &&
                !message.contains('googleads') &&
                !message.contains('googlesyndication.com') &&
                !message.contains('prestrain.html') &&
                !message.contains('prestrain%2Ehtml') &&
                !message.contains('adtrafficquality')) {
              logEventController.add('Parsing video source $message');
              String encodedUrl = Uri.encodeFull(message);
              if (decodeVideoSource(encodedUrl) != encodedUrl) {
                isIframeLoaded = true;
                isVideoSourceLoaded = true;
                videoLoadingEventController.add(false);
                logEventController.add(
                    'Loading video source ${decodeVideoSource(encodedUrl)}');
                unloadPage();
                final videoUrl = decodeVideoSource(encodedUrl);
                notifyVideoSourceResolved(videoUrl);
              }
            }
          });
    } else {
      logEventController.add('Adding VideoBridgeDebug handler');
      webviewController?.addJavaScriptHandler(
          handlerName: 'VideoBridgeDebug',
          callback: (args) {
            String message = args[0].toString().trim();
            if (message.startsWith('//')) {
              message = 'https:$message';
            }
            logEventController.add('Callback received: $message');
            if (message.contains('http') && !isVideoSourceLoaded) {
              logEventController.add('Loading video source: $message');
              isIframeLoaded = true;
              isVideoSourceLoaded = true;
              videoLoadingEventController.add(false);
              unloadPage();
              notifyVideoSourceResolved(message);
            }
          });
    }
  }

  Future<void> _onLoadStart() async {
    if (!useLegacyParser) {
      logEventController.add('Injecting blob parser script (onLoadStart)');
      await webviewController?.evaluateJavascript(source: """
        try { window.flutter_inappwebview.callHandler('LogBridge', 'BlobParser script loaded: ' + window.location.href); } catch(e) {}
        const _r_text = window.Response.prototype.text;
        window.Response.prototype.text = function () {
            return new Promise((resolve, reject) => {
                _r_text.call(this).then((text) => {
                    resolve(text);
                    if (text.trim().startsWith("#EXTM3U")) {
                        window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found: ' + this.url);
                        window.flutter_inappwebview.callHandler('VideoBridgeDebug', this.url);
                    }
                }).catch(reject);
            });
        }

        const _open = window.XMLHttpRequest.prototype.open;
        window.XMLHttpRequest.prototype.open = function (...args) {
            this.addEventListener("load", () => {
                try {
                    let content = this.responseText;
                    if (content.trim().startsWith("#EXTM3U")) {
                        window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found: ' + args[1]);
                        window.flutter_inappwebview.callHandler('VideoBridgeDebug', args[1]);
                    };
                } catch {}
            });
            return _open.apply(this, args);
        };

        function injectIntoIframe(iframe) {
          try {
            const iframeWindow = iframe.contentWindow;
            if (!iframeWindow) return;

            const iframe_r_text = iframeWindow.Response.prototype.text;
            iframeWindow.Response.prototype.text = function () {
              return new Promise((resolve, reject) => {
                iframe_r_text.call(this).then((text) => {
                  resolve(text);
                  if (text.trim().startsWith("#EXTM3U")) {
                    window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found in iframe: ' + this.url);
                    window.flutter_inappwebview.callHandler('VideoBridgeDebug', this.url);
                  }
                }).catch(reject);
              });
            }

            const iframe_open = iframeWindow.XMLHttpRequest.prototype.open;
            iframeWindow.XMLHttpRequest.prototype.open = function (...args) {
              this.addEventListener("load", () => {
                try {
                  let content = this.responseText;
                  if (content.trim().startsWith("#EXTM3U") && args[1] !== null && args[1] !== undefined) {
                    window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found in iframe: ' + args[1]);
                    window.flutter_inappwebview.callHandler('VideoBridgeDebug', args[1]);
                  };
                } catch {}
              });
              return iframe_open.apply(this, args);
            }
          } catch (e) {
            console.error('iframe inject failed:', e);
          }
        }

        function setupIframeListeners() {
          document.querySelectorAll('iframe').forEach(iframe => {
            if (iframe.contentDocument) {
              injectIntoIframe(iframe);
            }
            iframe.addEventListener('load', () => injectIntoIframe(iframe));
          });

          const observer = new MutationObserver(mutations => {
            mutations.forEach(mutation => {
              if (mutation.type === 'childList') {
                mutation.addedNodes.forEach(node => {
                  if (node.nodeName === 'IFRAME') {
                    node.addEventListener('load', () => injectIntoIframe(node));
                  }
                  if (node.querySelectorAll) {
                    node.querySelectorAll('iframe').forEach(iframe => {
                      iframe.addEventListener('load', () => injectIntoIframe(iframe));
                    });
                  }
                });
              }
            });
          });

          if (document.body) {
            observer.observe(document.body, { childList: true, subtree: true });
          } else {
            document.addEventListener('DOMContentLoaded', () => {
              observer.observe(document.body, { childList: true, subtree: true });
            });
          }
        }

        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', setupIframeListeners);
        } else {
          setupIframeListeners();
        }
      """);
    }
  }

  Future<void> _onLoadStop() async {
    if (!useLegacyParser) {
      logEventController.add('Injecting video tag parser script (onLoadStop)');
      await webviewController?.evaluateJavascript(source: """
        window.flutter_inappwebview.callHandler('LogBridge', 'VideoTagParser script loaded: ' + window.location.href);
        const _observer = new MutationObserver((mutations) => {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning for video elements...');
          for (const mutation of mutations) {
            if (mutation.type === "attributes" && mutation.target.nodeName === "VIDEO") {
              if (processVideoElement(mutation.target)) return;
              continue;
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
        function processVideoElement(video) {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning video element for source URL');
          let src = video.getAttribute('src');
          if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
            _observer.disconnect();
            window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found: ' + src);
            window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
            return true;
          }
          const sources = video.getElementsByTagName('source');
          for (let source of sources) {
            src = source.getAttribute('src');
            if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
              _observer.disconnect();
              window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found (source tag): ' + src);
              window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
              return true;
            }
          }
        }

        function setupVideoProcessing() {
          for (const video of document.querySelectorAll("video")) {
            if (processVideoElement(video)) return;
          }
          _observer.observe(document.body, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['src']
          });
        }
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', setupVideoProcessing);
        } else {
          setupVideoProcessing();
        }
      """);
    }

    if (useLegacyParser) {
      logEventController.add('Injecting JSBridgeDebug script (onLoadStop)');
      await webviewController?.evaluateJavascript(source: """
        window.flutter_inappwebview.callHandler('LogBridge', 'JSBridgeDebug script loaded: ' + window.location.href);
        function processIframeElement(iframe) {
          window.flutter_inappwebview.callHandler('LogBridge', 'Processing iframe element');
          let src = iframe.getAttribute('src');
          if (src) {
            window.flutter_inappwebview.callHandler('JSBridgeDebug', src);
          }
        }

        const _observer = new MutationObserver((mutations) => {
          window.flutter_inappwebview.callHandler('LogBridge', 'Scanning for iframes...');
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
      """);
    }

    _startVideoParserTimer();
  }

  void _startVideoParserTimer() {
    videoParserTimer?.cancel();
    logEventController.add('Starting video parser timer');
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
          window.flutter_inappwebview.callHandler('LogBridge', 'Timer scan: found ' + iframes.length + ' iframe(s)');
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
            if (window.MacPlayer && window.MacPlayer.PlayUrl) {
              var _mpu = String(window.MacPlayer.PlayUrl).trim();
              var _mclean = _mpu.split('#')[0].split('?')[0].toLowerCase();
              if (!_mclean.endsWith('.html') && !_mclean.endsWith('.htm') &&
                  (_mclean.endsWith('.m3u8') || _mclean.endsWith('.mp4') ||
                   _mclean.endsWith('.flv') || _mclean.endsWith('.mkv') ||
                   _mclean.endsWith('.webm') || _mclean.endsWith('.mknvideo') ||
                   _mclean.endsWith('.ts') ||
                   _mpu.toLowerCase().indexOf('.m3u8') !== -1)) {
                window.flutter_inappwebview.callHandler('VideoBridgeDebug', _mpu);
                return;
              }
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
                if (s && s.trim() !== '' && !s.startsWith('blob:') && !s.includes('googleads') && !s.toLowerCase().includes('adposter')) {
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
