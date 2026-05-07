import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../../models/photo_entry.dart';
import '../../platform/recycle_bin_windows.dart';

class DeleteService {
  /// Behavior:
  /// - Windows: move files to Recycle Bin
  /// - Android/iOS: use PhotoManager editor delete (may be "Recently Deleted"/trash depending OS)
  static Future<void> moveToTrash(List<PhotoEntry> entries) async {
    if (entries.isEmpty) return;

    if (Platform.isWindows) {
      final paths = entries
          .where((e) => e.origin == PhotoOrigin.filePath && e.filePath != null)
          .map((e) => e.filePath!)
          .toList(growable: false);
      RecycleBinWindows.moveToRecycleBin(paths);
      return;
    }

    final ids =
        entries.where((e) => e.origin == PhotoOrigin.deviceAsset && e.assetId != null).map((e) => e.assetId!).toList();
    if (ids.isEmpty) return;

    await PhotoManager.editor.deleteWithIds(ids);
  }
}

