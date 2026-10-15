import 'dart:io';

import 'package:path/path.dart' as p;

/// Files imports have no PhotoKit trash. Preserve them beside their source so
/// users can restore them in Files, without copying across security scopes.
class IosFileTrash {
  static const directoryName = 'BestShot Trash';

  static Future<void> move(File source) async {
    if (!await source.exists()) {
      throw FileSystemException('元のファイルが見つかりません', source.path);
    }
    final trash = Directory(p.join(source.parent.path, directoryName));
    await trash.create(recursive: true);
    final destination = await trash.createTemp('photo_');
    try {
      await source.rename(p.join(destination.path, p.basename(source.path)));
    } catch (_) {
      await destination.delete();
      rethrow; // Never fall back to permanent deletion.
    }
  }
}
