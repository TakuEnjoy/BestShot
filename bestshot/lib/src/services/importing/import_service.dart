import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../../models/photo_entry.dart';
import '../analysis/analysis_types.dart';

class ImportedItem {
  ImportedItem({
    required this.key,
    required this.origin,
    required this.thumbnailPath,
    this.assetId,
    this.filePath,
    this.exifSummary,
  });

  final String key;
  final PhotoOrigin origin;
  final String thumbnailPath;
  final String? assetId;
  final String? filePath;
  final ExifSummary? exifSummary;

  AnalyzeInput toAnalyzeInput() =>
      AnalyzeInput(key: key, thumbnailPath: thumbnailPath, filePath: filePath);
}

class ExifSummary {
  ExifSummary({
    required this.fNumber,
    required this.shutter,
    required this.iso,
    required this.capturedAt,
    this.orientation = 1,
  });

  final String? fNumber;
  final String? shutter;
  final String? iso;
  final DateTime? capturedAt;
  final int orientation;
}

class ImportService {
  static Future<FolderScanResult?> scanFolder(String dir) async {
    final directory = Directory(dir);
    if (!await directory.exists()) return null;

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

    final filesByDate = <DateTime, List<File>>{};

    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (!exts.contains(ext)) continue;

      try {
        final stat = await entity.stat();
        final modDate = stat.modified;
        final dateOnly = DateTime(modDate.year, modDate.month, modDate.day);

        if (!filesByDate.containsKey(dateOnly)) {
          filesByDate[dateOnly] = [];
        }
        filesByDate[dateOnly]!.add(entity);
      } catch (_) {
        // Skip files that fail to stat
      }
    }

    return FolderScanResult(folderPath: dir, filesByDate: filesByDate);
  }

  static Future<List<ImportedItem>> importLocalFiles(
    List<File> files, {
    required int thumbnailMaxEdge,
    required String tempDirPath,
    void Function(int done, int total)? onProgress,
    void Function(List<String> failedPaths)? onFailed,
  }) async {
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

    final out = <ImportedItem>[];
    final failedPaths = <String>[];
    var done = 0;
    for (final f in files) {
      try {
        final fName = p.basename(f.path);
        final result = await Isolate.run(() async {
          final ext = p.extension(f.path).toLowerCase();
          final bytes = await f.readAsBytes();
          final decodeSource = rawExts.contains(ext)
              ? (_extractEmbeddedJpeg(bytes) ?? bytes)
              : bytes;

          final exifSummary = await _readExifSummary(f);
          final orientation = exifSummary?.orientation ?? 1;

          final mat = cv.imdecode(decodeSource, cv.IMREAD_COLOR);
          if (mat.isEmpty) return null;

          cv.Mat workMat = mat;
          if (orientation == 3) {
            workMat = cv.rotate(mat, cv.ROTATE_180);
            mat.dispose();
          } else if (orientation == 6) {
            workMat = cv.rotate(mat, cv.ROTATE_90_CLOCKWISE);
            mat.dispose();
          } else if (orientation == 8) {
            workMat = cv.rotate(mat, cv.ROTATE_90_COUNTERCLOCKWISE);
            mat.dispose();
          }

          final w = workMat.cols;
          final h = workMat.rows;
          cv.Mat resized;
          if (w > thumbnailMaxEdge || h > thumbnailMaxEdge) {
            double scale = w >= h ? thumbnailMaxEdge / w : thumbnailMaxEdge / h;
            resized = cv.resize(workMat, (
              (w * scale).round(),
              (h * scale).round(),
            ));
          } else {
            resized = workMat.clone();
          }

          final encodeRes = cv.imencode(
            '.jpg',
            resized,
            params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 85]),
          );
          final jpg = encodeRes.$2;

          workMat.dispose();
          resized.dispose();

          final thumbId = '${DateTime.now().microsecondsSinceEpoch}_$fName';
          final thumbFile = File(p.join(tempDirPath, 'thumb_$thumbId.jpg'));
          await thumbFile.writeAsBytes(jpg);

          return _ImportPayload(
            thumbnailPath: thumbFile.path,
            exif: exifSummary,
          );
        });

        if (result != null) {
          out.add(
            ImportedItem(
              key: 'file:${f.path}',
              origin: PhotoOrigin.filePath,
              thumbnailPath: result.thumbnailPath,
              filePath: f.path,
              exifSummary: result.exif,
            ),
          );
        } else {
          failedPaths.add(f.path);
        }
      } catch (e) {
        failedPaths.add(f.path);
      } finally {
        done++;
        onProgress?.call(done, files.length);
      }
    }
    if (failedPaths.isNotEmpty) {
      onFailed?.call(failedPaths);
    }
    return out;
  }

  static Future<List<ImportedItem>> importPhotoManagerAssets(
    List<AssetEntity> assets, {
    required int thumbnailMaxEdge,
    required String tempDirPath,
    void Function(int done, int total)? onProgress,
    void Function(List<String> failedPaths)? onFailed,
  }) async {
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

    final out = <ImportedItem>[];
    final failedPaths = <String>[];
    var done = 0;
    for (final asset in assets) {
      try {
        final f = await asset.file;
        if (f == null) {
          failedPaths.add('asset:${asset.id}');
          continue;
        }

        final fName = p.basename(f.path);
        final result = await Isolate.run(() async {
          final ext = p.extension(f.path).toLowerCase();
          final bytes = await f.readAsBytes();
          final decodeSource = rawExts.contains(ext)
              ? (_extractEmbeddedJpeg(bytes) ?? bytes)
              : bytes;

          final exifSummary = await _readExifSummary(f);
          final orientation = exifSummary?.orientation ?? 1;

          final mat = cv.imdecode(decodeSource, cv.IMREAD_COLOR);
          if (mat.isEmpty) return null;

          cv.Mat workMat = mat;
          if (orientation == 3) {
            workMat = cv.rotate(mat, cv.ROTATE_180);
            mat.dispose();
          } else if (orientation == 6) {
            workMat = cv.rotate(mat, cv.ROTATE_90_CLOCKWISE);
            mat.dispose();
          } else if (orientation == 8) {
            workMat = cv.rotate(mat, cv.ROTATE_90_COUNTERCLOCKWISE);
            mat.dispose();
          }

          final w = workMat.cols;
          final h = workMat.rows;
          cv.Mat resized;
          if (w > thumbnailMaxEdge || h > thumbnailMaxEdge) {
            double scale = w >= h ? thumbnailMaxEdge / w : thumbnailMaxEdge / h;
            resized = cv.resize(workMat, (
              (w * scale).round(),
              (h * scale).round(),
            ));
          } else {
            resized = workMat.clone();
          }

          final encodeRes = cv.imencode(
            '.jpg',
            resized,
            params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 85]),
          );
          final jpg = encodeRes.$2;

          workMat.dispose();
          resized.dispose();

          final thumbId = '${DateTime.now().microsecondsSinceEpoch}_$fName';
          final thumbFile = File(
            p.join(tempDirPath, 'thumb_asset_$thumbId.jpg'),
          );
          await thumbFile.writeAsBytes(jpg);

          return _ImportPayload(
            thumbnailPath: thumbFile.path,
            exif: exifSummary,
          );
        });

        if (result != null) {
          out.add(
            ImportedItem(
              key: 'asset:${asset.id}',
              origin: PhotoOrigin.deviceAsset,
              thumbnailPath: result.thumbnailPath,
              assetId: asset.id,
              filePath: f.path,
              exifSummary: result.exif,
            ),
          );
        } else {
          failedPaths.add('asset:${asset.id}');
        }
      } catch (e) {
        failedPaths.add('asset:${asset.id}');
      } finally {
        done++;
        onProgress?.call(done, assets.length);
      }
    }
    if (failedPaths.isNotEmpty) {
      onFailed?.call(failedPaths);
    }
    return out;
  }
}

class FolderScanResult {
  FolderScanResult({required this.folderPath, required this.filesByDate});

  final String folderPath;
  final Map<DateTime, List<File>> filesByDate;
}

Uint8List? _extractEmbeddedJpeg(Uint8List bytes) {
  try {
    int bestStart = -1;
    int bestEnd = -1;
    int maxLen = 0;
    int currentStart = -1;

    // O(N) スキャンによる高速化
    for (int i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0xFF) {
        if (bytes[i + 1] == 0xD8) {
          if (currentStart == -1) currentStart = i;
        } else if (bytes[i + 1] == 0xD9) {
          if (currentStart != -1) {
            int end = i + 2;
            int len = end - currentStart;
            if (len > maxLen) {
              maxLen = len;
              bestStart = currentStart;
              bestEnd = end;
            }
            currentStart = -1;
          }
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
    final fnum = _parseFNumber(getTag('EXIF FNumber') ?? getTag('FNumber'));
    final expo = getTag('EXIF ExposureTime') ?? getTag('ExposureTime');
    final iso = getTag('EXIF ISOSpeedRatings') ?? getTag('ISOSpeedRatings');
    final dt =
        getTag('EXIF DateTimeOriginal') ??
        getTag('EXIF DateTimeDigitized') ??
        getTag('Image DateTime') ??
        getTag('DateTime');
    final capturedAt = _parseExifDateTime(dt);
    final orientationStr = getTag('EXIF Orientation') ?? getTag('Orientation');
    final orientation = int.tryParse(orientationStr ?? '') ?? 1;
    return ExifSummary(
      fNumber: fnum,
      shutter: expo,
      iso: iso,
      capturedAt: capturedAt,
      orientation: orientation,
    );
  } catch (_) {
    return null;
  }
}

String? _parseFNumber(String? raw) {
  if (raw == null) return null;
  raw = raw.trim();
  if (raw.isEmpty) return null;

  // もし "14/5" のような分数形式なら、浮動小数点数に変換する
  final parts = raw.split('/');
  if (parts.length == 2) {
    final num = double.tryParse(parts[0].trim());
    final den = double.tryParse(parts[1].trim());
    if (num != null && den != null && den != 0) {
      final val = num / den;
      return _formatFValue(val);
    }
  }

  // もし通常の数値（例: "2.8"）なら、パースしてフォーマット
  final val = double.tryParse(raw);
  if (val != null) {
    return _formatFValue(val);
  }

  return raw;
}

String _formatFValue(double val) {
  final rounded = (val * 10).round() / 10;
  if (rounded == rounded.toInt()) {
    return rounded.toInt().toString();
  }
  return rounded.toString();
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

class _ImportPayload {
  _ImportPayload({required this.thumbnailPath, this.exif});
  final String thumbnailPath;
  final ExifSummary? exif;
}
