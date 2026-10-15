import 'dart:developer' as developer;
import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../../models/photo_entry.dart';
import 'ios_file_trash.dart';

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
  /// Files are retained in BestShot Trash; library assets use PhotoKit.
  static Future<DeleteResult> moveToTrash(List<PhotoEntry> entries) async {
    if (entries.isEmpty) return const DeleteResult();

    final success = <PhotoEntry>[];
    final failed = <PhotoEntry>[];
    final unprocessed = <PhotoEntry>[];
    String? errorMessage;

    // Retain folder-imported originals so they can be restored in Files.
    final fileEntries = entries
        .where((e) => e.origin == PhotoOrigin.filePath && e.filePath != null)
        .toList();

    for (int i = 0; i < fileEntries.length; i++) {
      final entry = fileEntries[i];
      try {
        final file = File(entry.filePath!);
        await IosFileTrash.move(file);
        success.add(entry);
      } catch (e, s) {
        developer.log('File delete error for ${entry.filePath}: $e\n$s');
        failed.add(entry);
        errorMessage = 'ファイル削除に失敗しました (${entry.filePath}): $e';
        unprocessed.addAll(fileEntries.sublist(i + 1));
        break;
      }
    }

    // PhotoKit owns library assets and presents the system deletion confirmation.
    final assetEntries = entries
        .where((e) => e.origin == PhotoOrigin.deviceAsset && e.assetId != null)
        .toList();

    if (failed.isNotEmpty) {
      unprocessed.addAll(assetEntries);
    } else if (assetEntries.isNotEmpty) {
      final ids = assetEntries.map((e) => e.assetId!).toList();
      try {
        final deletedIds = await PhotoManager.editor
            .deleteWithIds(ids)
            .timeout(const Duration(seconds: 30));
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
