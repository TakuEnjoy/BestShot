import 'dart:developer' as developer;
import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../../models/photo_entry.dart';
import '../../platform/recycle_bin.dart';

/// Result of a delete/trash operation.
class DeleteResult {
  const DeleteResult({
    this.success = const [],
    this.failed = const [],
    this.unprocessed = const [],
    this.errorMessage,
  });

  /// Successfully deleted or moved to trash entries.
  final List<PhotoEntry> success;

  /// Entries that explicitly failed to delete.
  final List<PhotoEntry> failed;

  /// Entries that were not processed because an earlier error caused the operation to abort.
  final List<PhotoEntry> unprocessed;

  /// Detail message of failure if any.
  final String? errorMessage;

  /// Returns true if all requested items succeeded.
  bool get isAllSuccess => failed.isEmpty && unprocessed.isEmpty;
}

class DeleteService {
  /// Behavior:
  /// - Windows: move files to Recycle Bin via SHFileOperation.
  ///   If it fails (e.g. MAX_PATH exceeded or shell error), NEVER fall back to File.delete().
  ///   Instead, abort immediately and return the failed and unprocessed entries.
  /// - Android/iOS: delete local files or use PhotoManager editor delete.
  static Future<DeleteResult> moveToTrash(List<PhotoEntry> entries) async {
    if (entries.isEmpty) return const DeleteResult();

    if (Platform.isWindows) {
      final success = <PhotoEntry>[];
      final failed = <PhotoEntry>[];
      final unprocessed = <PhotoEntry>[];
      String? errorMessage;

      for (int i = 0; i < entries.length; i++) {
        final entry = entries[i];
        final path = entry.filePath;

        if (path == null || entry.origin != PhotoOrigin.filePath) {
          failed.add(entry);
          errorMessage = '無効なファイルパスです: ${entry.key}';
          unprocessed.addAll(entries.sublist(i + 1));
          break;
        }

        if (path.length > 259) {
          failed.add(entry);
          errorMessage = 'ファイルパスが長すぎるためゴミ箱に移動できません (MAX_PATH制限): $path';
          // DO NOT fallback to direct delete. Abort immediately.
          unprocessed.addAll(entries.sublist(i + 1));
          break;
        }

        try {
          RecycleBinWindows.moveToRecycleBin([path]);
          if (File(path).existsSync()) {
            throw Exception('ゴミ箱への移動が完了しませんでした（ファイルが残存しています）');
          }
          success.add(entry);
        } catch (e, s) {
          developer.log('Windows recycle bin error for $path: $e\n$s');
          failed.add(entry);
          errorMessage = 'ゴミ箱への移動に失敗しました ($path): $e';
          // DO NOT fallback to direct delete. Abort immediately.
          unprocessed.addAll(entries.sublist(i + 1));
          break;
        }
      }

      return DeleteResult(
        success: success,
        failed: failed,
        unprocessed: unprocessed,
        errorMessage: errorMessage,
      );
    }

    final success = <PhotoEntry>[];
    final failed = <PhotoEntry>[];
    final unprocessed = <PhotoEntry>[];
    String? errorMessage;

    // Delete local files on mobile (Android/iOS) for folder-imported photos
    final fileEntries = entries
        .where((e) => e.origin == PhotoOrigin.filePath && e.filePath != null)
        .toList();

    for (int i = 0; i < fileEntries.length; i++) {
      final entry = fileEntries[i];
      try {
        final file = File(entry.filePath!);
        if (await file.exists()) {
          await file.delete();
        }
        success.add(entry);
      } catch (e, s) {
        developer.log('File delete error for ${entry.filePath}: $e\n$s');
        failed.add(entry);
        errorMessage = 'ファイル削除に失敗しました (${entry.filePath}): $e';
        unprocessed.addAll(fileEntries.sublist(i + 1));
        break;
      }
    }

    // PhotoManager deletion for backward compatibility with legacy imported device assets
    final assetEntries = entries
        .where((e) => e.origin == PhotoOrigin.deviceAsset && e.assetId != null)
        .toList();

    if (failed.isNotEmpty) {
      unprocessed.addAll(assetEntries);
    } else if (assetEntries.isNotEmpty) {
      final ids = assetEntries.map((e) => e.assetId!).toList();
      try {
        final deletedIds = await PhotoManager.editor.deleteWithIds(ids);
        final deletedIdSet = deletedIds.toSet();
        for (final entry in assetEntries) {
          if (deletedIdSet.contains(entry.assetId)) {
            success.add(entry);
          } else {
            failed.add(entry);
          }
        }
        if (failed.isNotEmpty && errorMessage == null) {
          errorMessage = '一部の写真の削除がキャンセルまたは失敗しました';
        }
      } catch (e, s) {
        developer.log('PhotoManager delete error: $e\n$s');
        failed.addAll(assetEntries);
        errorMessage = '写真の削除に失敗しました: $e';
      }
    }

    return DeleteResult(
      success: success,
      failed: failed,
      unprocessed: unprocessed,
      errorMessage: errorMessage,
    );
  }
}
