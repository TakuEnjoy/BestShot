import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../../models/photo_entry.dart';

class DeleteService {
  /// Behavior:
  /// - Android/iOS: use PhotoManager editor delete (may be "Recently Deleted"/trash depending OS)
  static Future<void> moveToTrash(List<PhotoEntry> entries) async {
    if (entries.isEmpty) return;

    // Delete local files on mobile (Android/iOS) for folder-imported photos
    final filePaths = entries
        .where((e) => e.origin == PhotoOrigin.filePath && e.filePath != null)
        .map((e) => e.filePath!)
        .toList();
    if (filePaths.isNotEmpty) {
      for (final path in filePaths) {
        try {
          final file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {
          // Skip on permission errors or missing files
        }
      }
    }

    // Keep PhotoManager deletion for backward compatibility with legacy imported device assets
    final ids = entries
        .where((e) => e.origin == PhotoOrigin.deviceAsset && e.assetId != null)
        .map((e) => e.assetId!)
        .toList();
    if (ids.isEmpty) return;

    try {
      await PhotoManager.editor.deleteWithIds(ids);
    } catch (_) {}
  }
}
