import 'dart:io';
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../../models/photo_entry.dart';
import '../../platform/folder_picker_windows.dart';
import '../analysis/analysis_types.dart';

class ImportedItem {
  ImportedItem({
    required this.key,
    required this.origin,
    required this.displayBytes,
    this.assetId,
    this.filePath,
    this.exifSummary,
  });

  final String key;
  final PhotoOrigin origin;
  final Uint8List displayBytes;
  final String? assetId;
  final String? filePath;
  final ExifSummary? exifSummary;

  AnalyzeInput toAnalyzeInput() =>
      AnalyzeInput(key: key, displayBytes: displayBytes, filePath: filePath);
}

class ExifSummary {
  ExifSummary({
    required this.fNumber,
    required this.shutter,
    required this.iso,
    required this.capturedAt,
  });

  final String? fNumber;
  final String? shutter;
  final String? iso;
  final DateTime? capturedAt;
}

class ImportService {
  static Future<List<ImportedItem>> pickFromDeviceGallery({
    int thumbnailSize = 512,
    int maxCount = 200,
    void Function(int done, int total)? onProgress,
  }) async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) {
      return [];
    }

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    if (paths.isEmpty) return [];

    final path = paths.first;
    final count = minInt(await path.assetCountAsync, maxCount);
    final assets = await path.getAssetListRange(start: 0, end: count);

    final out = <ImportedItem>[];
    var done = 0;
    for (final asset in assets) {
      final thumb = await asset.thumbnailDataWithSize(
        ThumbnailSize(thumbnailSize, thumbnailSize),
        quality: 85,
      );
      if (thumb == null || thumb.isEmpty) continue;

      out.add(
        ImportedItem(
          key: 'asset:${asset.id}',
          origin: PhotoOrigin.deviceAsset,
          displayBytes: thumb,
          assetId: asset.id,
        ),
      );
      done++;
      onProgress?.call(done, assets.length);
    }
    return out;
  }

  static Future<List<ImportedItem>> pickFromFolderWindows({
    int thumbnailMaxEdge = 512,
    int maxCount = 200,
    void Function(int done, int total)? onProgress,
  }) async {
    final dir = FolderPickerWindows.pickFolder();
    if (dir == null || dir.isEmpty) return [];

    final directory = Directory(dir);
    if (!await directory.exists()) return [];

    final exts = <String>{
      '.jpg',
      '.jpeg',
      '.png',
      '.tif',
      '.tiff',
      '.webp',
      '.heic',
      '.heif',
      // RAW (Windows側はサムネ抽出が難しいので、現状はスキップ扱い)
      '.dng',
      '.arw',
      '.nef',
      '.cr2',
      '.cr3',
      '.raf',
      '.rw2',
      '.orf',
    };
    final rawExts = <String>{
      '.dng',
      '.arw',
      '.nef',
      '.cr2',
      '.cr3',
      '.raf',
      '.rw2',
      '.orf',
    };

    final files = <File>[];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (!exts.contains(ext)) continue;
      files.add(entity);
      if (files.length >= maxCount) break;
    }

    final out = <ImportedItem>[];
    var done = 0;
    for (final f in files) {
      try {
        final ext = p.extension(f.path).toLowerCase();
        final bytes = await f.readAsBytes();
        final decodeSource = rawExts.contains(ext)
            ? (_extractEmbeddedJpeg(bytes) ?? bytes)
            : bytes;
        final decoded = img.decodeImage(decodeSource);
        if (decoded == null) continue;
        final upright = img.bakeOrientation(decoded);
        final resized = _resizeKeepingAspect(upright, thumbnailMaxEdge);
        final jpg = Uint8List.fromList(img.encodeJpg(resized, quality: 85));
        final exifSummary = await _readExifSummary(f);

        out.add(
          ImportedItem(
            key: 'file:${f.path}',
            origin: PhotoOrigin.filePath,
            displayBytes: jpg,
            filePath: f.path,
            exifSummary: exifSummary,
          ),
        );
      } catch (_) {
        // Skip unreadable/unsupported files and keep going.
      } finally {
        done++;
        onProgress?.call(done, files.length);
      }
    }
    return out;
  }

  static Future<List<ImportedItem>> pickFromFolderAndroid({
    int thumbnailMaxEdge = 512,
    int maxCount = 200,
    void Function(int done, int total)? onProgress,
  }) async {
    // Android 11+ (API 30+) での広範なストレージアクセス権限要求を廃止。
    // 代わりに PhotoManager を使用したギャラリーアクセス、または
    // SAF (Storage Access Framework) を介した限定的なディレクトリ選択を利用します。

    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || dir.isEmpty) return [];

    final directory = Directory(dir);
    if (!await directory.exists()) return [];

    final exts = <String>{
      '.jpg',
      '.jpeg',
      '.png',
      '.tif',
      '.tiff',
      '.webp',
      '.heic',
      '.heif',
      '.dng',
      '.arw',
      '.nef',
      '.cr2',
      '.cr3',
      '.raf',
      '.rw2',
      '.orf',
    };
    final rawExts = <String>{
      '.dng',
      '.arw',
      '.nef',
      '.cr2',
      '.cr3',
      '.raf',
      '.rw2',
      '.orf',
    };

    final files = <File>[];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (!exts.contains(ext)) continue;
      files.add(entity);
      if (files.length >= maxCount) break;
    }

    final out = <ImportedItem>[];
    var done = 0;
    for (final f in files) {
      try {
        final ext = p.extension(f.path).toLowerCase();
        final bytes = await f.readAsBytes();
        final decodeSource = rawExts.contains(ext)
            ? (_extractEmbeddedJpeg(bytes) ?? bytes)
            : bytes;
        final decoded = img.decodeImage(decodeSource);
        if (decoded == null) continue;
        final upright = img.bakeOrientation(decoded);

        final resized = _resizeKeepingAspect(upright, thumbnailMaxEdge);
        final jpg = Uint8List.fromList(img.encodeJpg(resized, quality: 85));
        final exifSummary = await _readExifSummary(f);

        out.add(
          ImportedItem(
            key: 'file:${f.path}',
            origin: PhotoOrigin.filePath,
            displayBytes: jpg,
            filePath: f.path,
            exifSummary: exifSummary,
          ),
        );
      } catch (_) {
        // Skip unreadable/unsupported files and keep going.
      } finally {
        done++;
        onProgress?.call(done, files.length);
      }
    }

    return out;
  }

  static img.Image _resizeKeepingAspect(img.Image src, int maxEdge) {
    final w = src.width;
    final h = src.height;
    if (w <= maxEdge && h <= maxEdge) return src;
    if (w >= h) {
      final newW = maxEdge;
      final newH = (h * (maxEdge / w)).round();
      return img.copyResize(src, width: newW, height: newH);
    } else {
      final newH = maxEdge;
      final newW = (w * (maxEdge / h)).round();
      return img.copyResize(src, width: newW, height: newH);
    }
  }
}

Uint8List? _extractEmbeddedJpeg(Uint8List bytes) {
  try {
    // 1. マジックナンバーの高速スキャン（SOI: FF D8, EOI: FF D9）
    // 既存のロジックをより安全に改善。
    int bestStart = -1;
    int bestEnd = -1;
    int maxLen = 0;

    // 全体をスキャンすると遅いので、先頭と末尾の数MBに絞ることも検討できるが、
    // RAWの場合は中間に埋め込まれていることが多い。
    for (int i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8) {
        // SOI見つけた
        int start = i;
        // EOIを探す（次のSOIが見つかるか、ファイルの終わりまで）
        for (int j = i + 2; j < bytes.length - 1; j++) {
          if (bytes[j] == 0xFF && bytes[j + 1] == 0xD9) {
            int end = j + 2;
            int len = end - start;
            if (len > maxLen) {
              maxLen = len;
              bestStart = start;
              bestEnd = end;
            }
            // 大きなJPEGが見つかったら一旦その範囲をスキップして次を探す
            i = j;
            break;
          }
          // JPEGのセグメントとして不自然に長すぎる場合は中断（例: 50MB以上）
          if (j - start > 50 * 1024 * 1024) break;
        }
      }
    }

    if (bestStart >= 0 && bestEnd > bestStart) {
      return Uint8List.sublistView(bytes, bestStart, bestEnd);
    }
  } catch (_) {
    // 解析失敗時はnullを返す
  }
  return null;
}

int minInt(int a, int b) => a < b ? a : b;

Future<ExifSummary?> _readExifSummary(File f) async {
  try {
    // Read first 256KB; enough for most EXIF blocks.
    final bytes = await f
        .openRead(0, 256 * 1024)
        .fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final tags = await readExifFromBytes(bytes);

    String? getTag(String key) => tags[key]?.printable;
    final fnum = getTag('EXIF FNumber') ?? getTag('FNumber');
    final expo = getTag('EXIF ExposureTime') ?? getTag('ExposureTime');
    final iso = getTag('EXIF ISOSpeedRatings') ?? getTag('ISOSpeedRatings');
    final dt =
        getTag('EXIF DateTimeOriginal') ??
        getTag('EXIF DateTimeDigitized') ??
        getTag('Image DateTime') ??
        getTag('DateTime');
    final capturedAt = _parseExifDateTime(dt);
    return ExifSummary(
      fNumber: fnum,
      shutter: expo,
      iso: iso,
      capturedAt: capturedAt,
    );
  } catch (_) {
    return null;
  }
}

DateTime? _parseExifDateTime(String? s) {
  if (s == null) return null;
  // Typical: "2026:03:19 12:34:56"
  final m = RegExp(
    r'^(\d{4})[:\-](\d{2})[:\-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(s.trim());
  if (m == null) return null;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  final h = int.parse(m.group(4)!);
  final mi = int.parse(m.group(5)!);
  final se = int.parse(m.group(6)!);
  return DateTime(y, mo, d, h, mi, se);
}
