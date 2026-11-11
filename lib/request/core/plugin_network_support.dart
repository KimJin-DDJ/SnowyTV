import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kazumi/services/logging/logger.dart';

/// Network compatibility helpers for plugin sites:
/// 1. Bundles `SSL.com TLS RSA Root CA 2022` so sites whose CDN chains only to
///    that root (e.g. AGE) verify cleanly on older Android trust stores.
/// 2. Falls back to DNS-over-HTTPS (DoH) when the device/router DNS cannot
///    resolve a plugin domain (e.g. DM84's `dmbus.cc`), and tracks those hosts
///    so Android WebView can load their HTML via `shouldInterceptRequest`.
class PluginNetworkSupport {
  PluginNetworkSupport._();

  static const _dnsLookupTimeout = Duration(seconds: 2);
  static const _dohTimeout = Duration(seconds: 4);
  static const _dohCacheTtl = Duration(minutes: 5);

  /// Public root CA: SSL.com TLS RSA Root CA 2022
  /// SHA-256: 8F:AF:7D:2E:2C:B4:70:9B:B8:E0:B3:36:66:BF:75:A5:DD:45:B5:DE:48:0F:8E:A8:D4:BF:E6:BE:BC:17:F2:ED
  static const String _sslComRootCa2022Pem = '''
-----BEGIN CERTIFICATE-----
MIIFiTCCA3GgAwIBAgIQb77arXO9CEDii02+1PdbkTANBgkqhkiG9w0BAQsFADBO
MQswCQYDVQQGEwJVUzEYMBYGA1UECgwPU1NMIENvcnBvcmF0aW9uMSUwIwYDVQQD
DBxTU0wuY29tIFRMUyBSU0EgUm9vdCBDQSAyMDIyMB4XDTIyMDgyNTE2MzQyMloX
DTQ2MDgxOTE2MzQyMVowTjELMAkGA1UEBhMCVVMxGDAWBgNVBAoMD1NTTCBDb3Jw
b3JhdGlvbjElMCMGA1UEAwwcU1NMLmNvbSBUTFMgUlNBIFJvb3QgQ0EgMjAyMjCC
AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANCkCXJPQIgSYT41I57u9nTP
L3tYPc48DRAokC+X94xI2KDYJbFMsBFMF3NQ0CJKY7uB0ylu1bUJPiYYf7ISf5OY
t6/wNr/y7hienDtSxUcZXXTzZGbVXcdotL8bHAajvI9AI7YexoS9UcQbOcGV0ins
S657Lb85/bRi3pZ7QcacoOAGcvvwB5cJOYF0r/c0WRFXCsJbwST0MXMwgsadugL3
PnxEX4MN8/HdIGkWCVDi1FW24IBydm5MR7d1VVm0U3TZlMZBrViKMWYPHqIbKUBO
L9975hYsLfy/7PO0+r4Y9ptJ1O4Fbtk085zx7AGL0SDGD6C1vBdOSHtRwvzpXGk3
R2azaPgVKPC506QVzFpPulJwoxJF3ca6TvvC0PeoUidtbnm1jPx7jMEWTO6Af77w
dr5BUxIzrlo4QqvXDz5BjXYHMtWrifZOZ9mxQnUjbvPNQrL8VfVThxc7wDNY8VLS
+YCk8OjwO4s4zKTGkH8PnP2L0aPP2oOnaclQNtVcBdIKQXTbYxE3waWglksejBYS
d66UNHsef8JmAOSqg+qKkK3ONkRN0VHpvB/zagX9wHQfJRlAUW7qglFA35u5CCoG
AtUjHBPW6dvbxrB6y3snm/vg1UYk7RBLY0ulBY+6uB0rpvqR4pJSvezrZ5dtmi2f
gTIFZzL7SAg/2SW4BCUvAgMBAAGjYzBhMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0j
BBgwFoAU+y437uOEeicuzRk1sTN8/9REQrkwHQYDVR0OBBYEFPsuN+7jhHonLs0Z
NbEzfP/UREK5MA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOCAgEAjYlt
hEUY8U+zoO9opMAdrDC8Z2awms22qyIZZtM7QbUQnRC6cm4pJCAcAZli05bg4vsM
QtfhWsSWTVTNj8pDU/0quOr4ZcoBwq1gaAafORpR2eCNJvkLTqVTJXojpBzOCBvf
R4iyrT7gJ4eLSYwfqUdYe5byiB0YrrPRpgqU+tvT5TgKa3kSM/tKWTcWQA673vWJ
DPFs0/dRa1419dvAJuoSc06pkZCmF8NsLzjUo3KUQyxi4U5cMj29TH0ZR6LDSeeW
P4+a0zvkEdiLA9z2tmBVGKaBUfPhqBVq6+AL8BQx1rmMRTqoENjwuSfr98t67wVy
lrXEj5ZzxOhWc5y8aVFjvO9nHEMaX3cZHxj4HCUp+UmZKbaSPaKDN7EgkaibMOlq
bLQjk2UEqxHzDh1TJElTHaE/nUiSEeJ9DU/1172iWD54nR4fK/4huxoTtrEoZP2w
AgDHbICivRZQIA9ygV/MlP+7mea6kMvq+cYMwq7FGc4zoWtcu358NFcXrfA/rs3q
r5nsLFR+jM4uElZI7xc7P0peYNLcdDa8pUNjyw9bowJWCZ4kLOGGgYz+qxcs+sji
Mho6/4UIyYOf8kpIEFR3N+2ivEC+5BB09+Rbu7nzifmPQdjH5FCQNYA+HLhNkNPU
98OwoX6EyneSMSy4kLGCenROmxMmtNVQZlR4rmA=
-----END CERTIFICATE-----
''';

  static final SecurityContext _securityContext = _buildSecurityContext();
  static final Map<String, ({InternetAddress ip, DateTime expiresAt})>
      _dohCache = {};
  static final Map<String, Future<InternetAddress?>> _inFlightDoh = {};
  static final Set<String> _dohHosts = {};

  static SecurityContext get securityContext => _securityContext;

  static SecurityContext _buildSecurityContext() {
    final context = SecurityContext(withTrustedRoots: true);
    try {
      context.setTrustedCertificatesBytes(utf8.encode(_sslComRootCa2022Pem));
    } catch (e) {
      KazumiLogger().w('PluginNetworkSupport: failed to add SSL.com root: $e');
    }
    return context;
  }

  static const Set<String> _customSslHosts = <String>{
    'www.agedm.io',
    'agedm.io',
    'm.agedm.io',
  };

  static bool isDohResolvedHost(String host) {
    if (host.isEmpty) return false;
    return _dohHosts.contains(host.toLowerCase());
  }

  /// Whether WebView requests to [uri] should be routed through Dart's
  /// [fetchForWebView] (for DoH-resolved domains or hosts whose root CA is
  /// bundled in [_securityContext] but missing from older Android WebViews).
  static bool shouldProxyInWebView(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final lowerHost = uri.host.toLowerCase();
    if (lowerHost.isEmpty) return false;
    return isDohResolvedHost(lowerHost) || _customSslHosts.contains(lowerHost);
  }

  static HttpClient createHttpClient({
    bool enableDohFallback = true,
    bool allowBadCertificates = false,
  }) {
    final client = HttpClient(context: _securityContext);
    if (allowBadCertificates) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    if (enableDohFallback) {
      client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
        return connectWithDohFallback(
          uri,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
          allowBadCertificates: allowBadCertificates,
        );
      };
    }
    return client;
  }

  static Future<ConnectionTask<Socket>> connectWithDohFallback(
    Uri uri, {
    String? proxyHost,
    int? proxyPort,
    bool allowBadCertificates = false,
  }) async {
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    if (proxyHost != null) {
      return Socket.startConnect(proxyHost, proxyPort ?? port);
    }

    final host = uri.host;
    final cached = _cachedAddressFor(host);
    if (cached != null) {
      return _connectAddress(
        cached,
        port,
        tlsHost: uri.scheme == 'https' ? host : null,
        allowBadCertificates: allowBadCertificates,
      );
    }

    try {
      final addresses =
          await InternetAddress.lookup(host).timeout(_dnsLookupTimeout);
      if (addresses.isNotEmpty) {
        // Prefer IPv4 when available so Android TV/VMs without IPv6 routing
        // do not stall on unreachable AAAA endpoints.
        final preferred = addresses.firstWhere(
          (addr) => addr.type == InternetAddressType.IPv4,
          orElse: () => addresses.first,
        );
        return await _connectAddress(
          preferred,
          port,
          tlsHost: uri.scheme == 'https' ? host : null,
          allowBadCertificates: allowBadCertificates,
        );
      }
    } on SocketException {
      // Fall through to DoH resolution.
    } on TimeoutException {
      // Fall through to DoH resolution.
    }

    final dohIp = await resolveViaDoh(host);
    if (dohIp != null) {
      return _connectAddress(
        dohIp,
        port,
        tlsHost: uri.scheme == 'https' ? host : null,
        allowBadCertificates: allowBadCertificates,
      );
    }

    return Socket.startConnect(host, port);
  }

  static Future<ConnectionTask<Socket>> _connectAddress(
    InternetAddress address,
    int port, {
    String? tlsHost,
    required bool allowBadCertificates,
  }) async {
    final rawTask = await Socket.startConnect(address, port);
    if (tlsHost == null) {
      return rawTask;
    }
    return ConnectionTask.fromSocket(
      rawTask.socket.then(
        (socket) => SecureSocket.secure(
          socket,
          host: tlsHost,
          context: _securityContext,
          onBadCertificate: allowBadCertificates ? (_) => true : null,
        ),
      ),
      rawTask.cancel,
    );
  }

  static InternetAddress? _cachedAddressFor(String host) {
    final entry = _dohCache[host.toLowerCase()];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiresAt)) {
      _dohCache.remove(host.toLowerCase());
      return null;
    }
    return entry.ip;
  }

  static Future<InternetAddress?> resolveViaDoh(String host) {
    final key = host.toLowerCase();
    final cached = _cachedAddressFor(key);
    if (cached != null) return Future.value(cached);
    return _inFlightDoh.putIfAbsent(key, () async {
      try {
        final ip = await _queryDohEndpoints(host);
        if (ip != null) {
          _dohHosts.add(key);
          _dohCache[key] = (
            ip: ip,
            expiresAt: DateTime.now().add(_dohCacheTtl),
          );
          KazumiLogger().i(
            'PluginNetworkSupport: DoH resolved $host -> ${ip.address}',
          );
        }
        return ip;
      } finally {
        _inFlightDoh.remove(key);
      }
    });
  }

  static Future<InternetAddress?> _queryDohEndpoints(String host) async {
    final endpoints = <String>[
      'https://1.1.1.1/dns-query?name=${Uri.encodeComponent(host)}&type=A',
      'https://dns.alidns.com/resolve?name=${Uri.encodeComponent(host)}&type=1',
      'https://dns.google/resolve?name=${Uri.encodeComponent(host)}&type=1',
    ];
    final client = HttpClient(context: _securityContext);
    try {
      for (final endpoint in endpoints) {
        try {
          final request =
              await client.getUrl(Uri.parse(endpoint)).timeout(_dohTimeout);
          request.headers.set('accept', 'application/dns-json');
          final response = await request.close().timeout(_dohTimeout);
          if (response.statusCode != 200) {
            await response.drain();
            continue;
          }
          final body = await utf8.decodeStream(response).timeout(_dohTimeout);
          final parsed = jsonDecode(body);
          if (parsed is! Map<String, dynamic>) continue;
          final answers = parsed['Answer'];
          if (answers is! List) continue;
          for (final answer in answers) {
            if (answer is Map &&
                answer['type'] == 1 &&
                answer['data'] is String) {
              final address = InternetAddress.tryParse(answer['data'] as String);
              if (address != null &&
                  address.type == InternetAddressType.IPv4) {
                return address;
              }
            }
          }
        } catch (_) {
          // Try next DoH endpoint.
        }
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Fetches a resource for WebView `shouldInterceptRequest` when the host
  /// requires DoH resolution or custom TLS roots.
  static Future<({
    int statusCode,
    String reasonPhrase,
    String contentType,
    String contentEncoding,
    Map<String, String> headers,
    Uint8List data,
  })?> fetchForWebView(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
  }) async {
    if (method.toUpperCase() != 'GET') return null;
    final client = createHttpClient();
    try {
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 10));
      headers.forEach((key, value) {
        if (key.toLowerCase() != 'host') {
          request.headers.set(key, value);
        }
      });
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        if (values.isNotEmpty) {
          responseHeaders[name] = values.join(', ');
        }
      });
      final mimeType = response.headers.contentType?.mimeType ?? 'text/html';
      final charset = response.headers.contentType?.charset ?? 'utf-8';
      return (
        statusCode: response.statusCode,
        reasonPhrase: response.reasonPhrase.isEmpty ? 'OK' : response.reasonPhrase,
        contentType: mimeType,
        contentEncoding: charset,
        headers: responseHeaders,
        data: Uint8List.fromList(bytes),
      );
    } catch (error) {
      KazumiLogger().w(
        'PluginNetworkSupport: WebView DoH fetch failed for $uri',
        error: error,
      );
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
