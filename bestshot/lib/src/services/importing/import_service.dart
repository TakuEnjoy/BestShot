import 'dart:io';
import 'dart:isolate';

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../models/photo_entry.dart';
import '../../utils/jpeg_utils.dart';
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

img.Image _resizeKeepingAspect(img.Image src, int maxEdge) {
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

    final List<File> targetFiles = [];

    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (!exts.contains(ext)) continue;
      targetFiles.add(entity);
    }

    if (targetFiles.isEmpty) {
      return FolderScanResult(folderPath: dir, filesByDate: {});
    }

    final filesByDate = <DateTime, List<File>>{};

    // 多重度制限（最大16並行）でEXIF/更新日時をスキャン
    var currentIndex = 0;

    Future<void> processNext() async {
      while (true) {
        final localIndex = currentIndex++;
        if (localIndex >= targetFiles.length) {
          break;
        }
        final file = targetFiles[localIndex];
        try {
          // EXIFから撮影日を優先取得 (先頭256KBのみロード)
          final summary = await _readExifSummary(file);
          final capturedAt = summary?.capturedAt;

          DateTime date;
          if (capturedAt != null) {
            date = DateTime(capturedAt.year, capturedAt.month, capturedAt.day);
          } else {
            // EXIFが無い、またはパース失敗時は modified (更新日時) をフォールバックに使用
            final stat = await file.stat();
            final modDate = stat.modified;
            date = DateTime(modDate.year, modDate.month, modDate.day);
          }

          // Dartのイベントループ上、Mapへの操作はスレッド安全
          filesByDate.putIfAbsent(date, () => []).add(file);
        } catch (_) {
          // 完全失敗時は modified のみを試みる
          try {
            final stat = await file.stat();
            final modDate = stat.modified;
            final date = DateTime(modDate.year, modDate.month, modDate.day);
            filesByDate.putIfAbsent(date, () => []).add(file);
          } catch (_) {}
        }
      }
    }

    final workerCount = targetFiles.length < 16 ? targetFiles.length : 16;
    final workers = List.generate(workerCount, (_) => processNext());
    await Future.wait(workers);

    return FolderScanResult(folderPath: dir, filesByDate: filesByDate);
  }

  static Future<List<ImportedItem>> importSelectedFiles(
    List<File> files, {
    required int thumbnailMaxEdge,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
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

    final processorCount = Platform.numberOfProcessors;
    final maxWorkers = (processorCount ~/ 2).clamp(1, 6);
    final workerCount = files.length < maxWorkers ? files.length : maxWorkers;

    final out = <ImportedItem>[];
    var done = 0;
    var currentIndex = 0;

    final receivePort = ReceivePort();
    receivePort.listen((message) {
      if (message is int) {
        // done increment
        done += message;
        onProgress?.call(done, files.length);
      }
    });

    var firstError = '';

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() == true) return;

        final startIndex = currentIndex;
        final chunkSize =
            5; // Process 5 files per isolate spawn to balance overhead vs progress updates
        currentIndex += chunkSize;

        if (startIndex >= files.length) return;

        final endIndex = (startIndex + chunkSize > files.length)
            ? files.length
            : startIndex + chunkSize;
        final chunk = files.sublist(startIndex, endIndex);

        final chunkPaths = chunk.map((f) => f.path).toList(growable: false);
        final sendPort = receivePort.sendPort;

        try {
          final task = _createIsolateTask(chunkPaths, sendPort, rawExts, thumbnailMaxEdge);
          final results = await Isolate.run(task);

          for (final res in results) {
            if (res != null) {
              if (res.error != null) {
                if (firstError.isEmpty) firstError = 'File: ${res.path}\nError: ${res.error}';
                debugPrint('Error processing ${res.path}: ${res.error}');
              } else if (res.jpg != null) {
                out.add(
                  ImportedItem(
                    key: 'file:${res.path}',
                    origin: PhotoOrigin.filePath,
                    displayBytes: res.jpg!,
                    filePath: res.path,
                    exifSummary: res.exif,
                  ),
                );
              }
            }
          }
        } catch (e, stack) {
          throw Exception('Isolate crash: $e\n$stack');
        }
      }
    }

    final futures = List.generate(workerCount, (_) => worker());
    await Future.wait(futures);
    receivePort.close();

    if (out.isEmpty && files.isNotEmpty) {
      throw Exception('全てのファイルの読み込みまたはデコードに失敗しました。\n詳細:\n$firstError');
    }

    return out;
  }
}

class FolderScanResult {
  FolderScanResult({required this.folderPath, required this.filesByDate});

  final String folderPath;
  final Map<DateTime, List<File>> filesByDate;
}

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
    final focalLength = _parseFocalLength(
      getTag('EXIF FocalLength') ??
          getTag('Image FocalLength') ??
          getTag('FocalLength'),
    );
    final cameraModel = _cleanExifString(
      getTag('Image Model') ?? getTag('EXIF Model') ?? getTag('Model'),
    );
    final lensModel = _cleanExifString(
      getTag('EXIF LensModel') ??
          getTag('Image LensModel') ??
          getTag('LensModel'),
    );
    final exposureBias = _parseExposureBias(
      getTag('EXIF ExposureBiasValue') ?? getTag('ExposureBiasValue'),
    );

    return ExifSummary(
      fNumber: fnum,
      shutter: expo,
      iso: iso,
      capturedAt: capturedAt,
      focalLength: focalLength,
      cameraModel: cameraModel,
      lensModel: lensModel,
      exposureBias: exposureBias,
    );
  } catch (_) {
    return null;
  }
}

String? _cleanExifString(String? raw) {
  if (raw == null) return null;
  final cleaned = raw.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
  return cleaned.isEmpty ? null : cleaned;
}

String? _parseFocalLength(String? raw) {
  if (raw == null) return null;
  raw = raw.trim();
  if (raw.isEmpty) return null;

  final parts = raw.split('/');
  if (parts.length == 2) {
    final num = double.tryParse(parts[0].trim());
    final den = double.tryParse(parts[1].trim());
    if (num != null && den != null && den != 0) {
      final val = (num / den).round();
      return '$val mm';
    }
  }

  final numMatch = RegExp(r'^\d+(\.\d+)?').firstMatch(raw);
  if (numMatch != null) {
    final val = double.tryParse(numMatch.group(0)!);
    if (val != null) {
      return '${val.round()} mm';
    }
  }

  return raw.endsWith('mm') ? raw : '$raw mm';
}

String? _parseExposureBias(String? raw) {
  if (raw == null) return null;
  raw = raw.trim();
  if (raw.isEmpty) return null;

  double? val;
  final parts = raw.split('/');
  if (parts.length == 2) {
    final num = double.tryParse(parts[0].trim());
    final den = double.tryParse(parts[1].trim());
    if (num != null && den != null && den != 0) {
      val = num / den;
    }
  } else {
    val = double.tryParse(raw);
  }

  if (val != null) {
    if (val.abs() < 0.05) return '±0.0 EV';
    final sign = val > 0 ? '+' : '';
    return '$sign${val.toStringAsFixed(1)} EV';
  }
  return raw;
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
  _ImportPayload({this.jpg, this.exif, required this.path, this.error});
  final Uint8List? jpg;
  final ExifSummary? exif;
  final String path;
  final String? error;
}

Future<List<_ImportPayload?>> Function() _createIsolateTask(
  List<String> chunkPaths,
  SendPort sendPort,
  Set<String> rawExts,
  int thumbnailMaxEdge,
) {
  return () async {
    final chunkOut = <_ImportPayload?>[];
    for (final path in chunkPaths) {
      final f = File(path);
      try {
        final ext = p.extension(f.path).toLowerCase();
        final bytes = await f.readAsBytes();
        final decodeSource = rawExts.contains(ext)
            ? (JpegUtils.extractEmbeddedJpeg(bytes) ?? bytes)
            : bytes;
        final decoded = img.decodeImage(decodeSource);
        if (decoded == null) {
          chunkOut.add(_ImportPayload(
              path: f.path,
              error: 'decodeImage returned null (format not supported by image package)'));
          sendPort.send(1);
          continue;
        }
        final upright = img.bakeOrientation(decoded);

        final resized = _resizeKeepingAspect(upright, thumbnailMaxEdge);
        final jpg = Uint8List.fromList(
          img.encodeJpg(resized, quality: 85),
        );
        final exifSummary = await _readExifSummary(f);

        chunkOut.add(
          _ImportPayload(jpg: jpg, exif: exifSummary, path: f.path),
        );
        sendPort.send(1);
      } catch (e, st) {
        chunkOut.add(_ImportPayload(path: f.path, error: '$e\n$st'));
        sendPort.send(1);
      }
    }
    return chunkOut;
  };
}
