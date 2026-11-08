import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';

class PlatformEnvironmentService {
  PlatformEnvironmentService._();

  static const _intentChannel = MethodChannel('com.predidit.kazumi/intent');

  static Future<bool> isRunningOnX11() async {
    if (!Platform.isLinux) {
      return false;
    }
    try {
      return await _intentChannel.invokeMethod('isRunningOnX11');
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to check X11 environment: '${e.message}'.");
      return false;
    }
  }

  static Future<int> getAndroidSdkVersion() async {
    if (!Platform.isAndroid) {
      return 0;
    }
    try {
      return await _intentChannel.invokeMethod('getAndroidSdkVersion');
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to get Android SDK version: '${e.message}'.");
      return 0;
    }
  }

  static bool? _isTv;
  static bool? _isEmulator;

  static Future<bool> isAndroidTv() async {
    if (!Platform.isAndroid) return false;
    if (_isTv != null) return _isTv!;
    try {
      _isTv = await _intentChannel.invokeMethod<bool>('isAndroidTv') ?? false;
      return _isTv!;
    } on PlatformException catch (e) {
      KazumiLogger().w('Failed to detect Android TV', error: e);
      return false;
    }
  }

  static Future<bool> isEmulator() async {
    if (!Platform.isAndroid) return false;
    if (_isEmulator != null) return _isEmulator!;
    try {
      _isEmulator =
          await _intentChannel.invokeMethod<bool>('isEmulator') ?? false;
      return _isEmulator!;
    } on PlatformException catch (e) {
      KazumiLogger().w('Failed to detect Android Emulator', error: e);
      return false;
    }
  }
}
