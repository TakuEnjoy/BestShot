import 'package:flutter/services.dart';

/// Keeps the selected folder's security scope alive in the native app session.
class IosFolderPicker {
  static const _channel = MethodChannel('com.example.bestshot/vision');

  static Future<String?> pick() =>
      _channel.invokeMethod<String>('pickDirectory');
}
