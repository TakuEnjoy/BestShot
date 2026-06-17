import 'dart:io';
import 'package:path/path.dart' as p;
import '../../models/photo_entry.dart';

class SortResult {
  SortResult({
    required this.successCount,
    required this.failedFiles,
  });
  final int successCount;
  final List<String> failedFiles; // 失敗したファイルの元パス一覧
}

class SortService {
  /// 選択された写真の一括移動またはコピーを実行します。
  /// [sortMap] : PhotoKey ➔ FolderName
  /// [entries] : PhotoEntry のリスト（ファイルの元パス取得用）
  /// [isCopy] : trueならコピー、falseなら移動
  /// [onProgress] : 進捗通知用のコールバック (現在の完了数, 合計数)
  static Future<SortResult> executeSort({
    required Map<String, String> sortMap,
    required List<PhotoEntry> entries,
    required bool isCopy,
    void Function(int done, int total)? onProgress,
  }) async {
    final entryMap = {for (final e in entries) e.key: e};
    final List<MapEntry<PhotoEntry, String>> targets = [];

    for (final mEntry in sortMap.entries) {
      final key = mEntry.key;
      final folderName = mEntry.value;
      final entry = entryMap[key];
      if (entry != null && entry.filePath != null) {
        targets.add(MapEntry(entry, folderName));
      }
    }

    if (targets.isEmpty) {
      return SortResult(successCount: 0, failedFiles: []);
    }

    final total = targets.length;
    int done = 0;
    int successCount = 0;
    final List<String> failed = [];

    // 1. 事前チェック（書き込み権限のテスト）
    try {
      final Set<String> targetParentDirs = {};
      for (final t in targets) {
        final parentDir = p.dirname(t.key.filePath!);
        targetParentDirs.add(parentDir);
      }

      // 各インポート元フォルダの直下にテスト用ファイルを作成してみる
      for (final parent in targetParentDirs) {
        final testFile = File(p.join(parent, '.bestshot_write_test_tmp'));
        try {
          await testFile.writeAsString('test');
          await testFile.delete();
        } catch (e) {
          throw Exception('書き込み権限がありません: $parent (エラー: $e)');
        }
      }
    } catch (e) {
      // 事前チェックに失敗した場合は、全ファイルを失敗扱いとして安全に即時中断
      return SortResult(
        successCount: 0,
        failedFiles: targets.map((t) => t.key.filePath!).toList(),
      );
    }

    // 2. 一括処理の実行
    for (final t in targets) {
      final entry = t.key;
      final folderName = t.value;
      final srcPath = entry.filePath!;
      final srcFile = File(srcPath);

      if (!await srcFile.exists()) {
        failed.add(srcPath);
        done++;
        onProgress?.call(done, total);
        continue;
      }

      final srcDir = p.dirname(srcPath);
      final destDir = Directory(p.join(srcDir, folderName));
      var destPath = '';

      try {
        if (!await destDir.exists()) {
          await destDir.create(recursive: true);
        }

        // コピー先のファイル名を決定 (衝突回避のため連番付与)
        final srcBaseName = p.basename(srcPath);
        destPath = p.join(destDir.path, srcBaseName);
        var destFile = File(destPath);
        if (await destFile.exists()) {
          final ext = p.extension(srcBaseName);
          final baseWithoutExt = p.basenameWithoutExtension(srcBaseName);
          var counter = 1;
          while (true) {
            final newName = '${baseWithoutExt}_$counter$ext';
            destPath = p.join(destDir.path, newName);
            destFile = File(destPath);
            if (!await destFile.exists()) {
              break;
            }
            counter++;
          }
        }

        // 一時ファイルパス（.tmp）
        final tmpPath = '$destPath.tmp';
        final tmpFile = File(tmpPath);

        // (A) コピーの実行
        final iosSink = tmpFile.openWrite();
        await iosSink.addStream(srcFile.openRead());
        await iosSink.close();

        // (B) ベリファイ（ファイルサイズの検証）
        final srcLen = await srcFile.length();
        final tmpLen = await tmpFile.length();
        if (srcLen != tmpLen) {
          throw Exception('検証エラー: 転送後のファイルサイズが一致しません');
        }

        // (C) 本ファイル名へリネーム
        await tmpFile.rename(destPath);

        // (D) 移動モードなら元ファイルを安全に削除
        if (!isCopy) {
          await srcFile.delete();
        }

        successCount++;
        done++;
        onProgress?.call(done, total);
      } catch (e) {
        // エラー発生時は中途半端な一時ファイル（.tmp）をクリーンアップ
        final tmpPath = '$destPath.tmp';
        final tmpFile = File(tmpPath);
        if (await tmpFile.exists()) {
          try {
            await tmpFile.delete();
          } catch (_) {}
        }

        failed.add(srcPath);

        // 安全のため、エラー発生時点で一括処理を中断
        final remainingIndex = targets.indexOf(t) + 1;
        if (remainingIndex < targets.length) {
          failed.addAll(targets.sublist(remainingIndex).map((x) => x.key.filePath!));
        }
        break;
      }
    }

    return SortResult(
      successCount: successCount,
      failedFiles: failed,
    );
  }
}
