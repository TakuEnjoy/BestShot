import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// インポート・選別処理が完了した写真の一意キーを永続化し、
/// 次回の差分インポート（重複防止・前回の続きから再開）を管理するサービス。
class ImportHistoryService {
  ImportHistoryService._internal();
  static final ImportHistoryService instance = ImportHistoryService._internal();

  Set<String> _processedKeys = {};
  bool _initialized = false;
  File? _historyFile;

  /// 履歴管理サービスを初期化し、保存ファイルを読み込みます
  Future<void> init() async {
    if (_initialized) return;
    try {
      final docDir = await getApplicationDocumentsDirectory();
      _historyFile = File(p.join(docDir.path, 'processed_history.json'));
      await _loadHistory();
    } catch (_) {
      // 初期化失敗時はメモリのみで動作
    }
    _initialized = true;
  }

  Future<void> _loadHistory() async {
    if (_historyFile == null) return;
    if (!await _historyFile!.exists()) {
      _processedKeys = {};
      return;
    }
    try {
      final content = await _historyFile!.readAsString();
      final data = json.decode(content) as Map<String, dynamic>;
      final keys = data['processed_keys'] as List<dynamic>?;
      if (keys != null) {
        _processedKeys = keys.cast<String>().toSet();
      }
    } catch (_) {
      _processedKeys = {};
    }
  }

  Future<void> _saveHistory() async {
    if (_historyFile == null) return;
    try {
      final data = {'processed_keys': _processedKeys.toList()};
      await _historyFile!.writeAsString(json.encode(data));
    } catch (_) {
      // 保存エラーは無視
    }
  }

  /// 指定されたアセットキー（"file:パス" または "asset:アセットID"）が処理済みか判定します。
  Future<bool> isProcessed(String key) async {
    await init();
    return _processedKeys.contains(key);
  }

  /// 処理済みキーを保存します
  Future<void> saveKey(String key) async {
    await init();
    if (_processedKeys.add(key)) {
      await _saveHistory();
    }
  }

  /// 複数の処理済みキーを一括で保存します
  Future<void> saveKeys(List<String> keys) async {
    await init();
    bool added = false;
    for (final key in keys) {
      if (_processedKeys.add(key)) {
        added = true;
      }
    }
    if (added) {
      await _saveHistory();
    }
  }

  /// 処理履歴をすべてクリアし、初期状態にリセットします
  Future<void> clearHistory() async {
    await init();
    _processedKeys.clear();
    if (_historyFile != null && await _historyFile!.exists()) {
      try {
        await _historyFile!.delete();
      } catch (_) {}
    }
  }
}
