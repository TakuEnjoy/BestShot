import 'dart:typed_data';

import '../services/importing/import_service.dart';

enum PhotoOrigin { deviceAsset, filePath }

class SemanticObject {
  const SemanticObject({
    required this.label,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final String label;

  /// Normalized 0..1 coords relative to image.
  final double x;
  final double y;
  final double w;
  final double h;
}

class PhotoEntry {
  PhotoEntry({
    required this.key,
    required this.origin,
    required this.thumbnailPath,
    this.assetId,
    this.filePath,
    required this.pHashHex,
    required this.sharpness,
    required this.exposureScore,
    required this.orbRows,
    required this.orbCols,
    required this.orbBytes,
    required this.histogram,
    this.hueHistogram,
    this.exif,
    this.semanticObjects = const [],
    this.faceQualityScore = 0,
    this.hasPortraitFace = false,
    this.portraitEyesClosed = false,
    this.portraitEyeOpenAvg = -1,
    this.portraitBothEyesDetected = false,
    this.portraitFaceX = 0,
    this.portraitFaceY = 0,
    this.portraitFaceW = 0,
    this.portraitFaceH = 0,
    this.portraitFaceSharpness = 0,
    this.debugGridSharps,
  });

  /// Unique key across all imported items.
  final String key;

  final PhotoOrigin origin;

  /// Thumbnail file path (JPEG/PNG) for grid display.
  final String? thumbnailPath;

  /// `photo_manager` AssetEntity id when [origin] == deviceAsset.
  final String? assetId;

  /// File path when [origin] == filePath.
  final String? filePath;

  /// pHash (after grayscale + histogram equalization), 64-bit as 16 hex chars.
  final String pHashHex;

  /// Laplacian variance (higher => sharper).
  final double sharpness;

  /// 0..1, higher is better (less clipping + mean near mid).
  final double exposureScore;

  /// ORB descriptors: rows x cols bytes (cols usually 32).
  final int orbRows;
  final int orbCols;
  final Uint8List orbBytes;

  /// Luma histogram (256 entries).
  final Uint8List histogram;

  /// HSV Hue histogram (180 entries).
  final Float32List? hueHistogram;

  /// Optional EXIF summary (F/SS/ISO).
  final ExifSummary? exif;

  /// ML Kit object detection results (if available).
  final List<SemanticObject> semanticObjects;

  /// ML Kit face-based preference (higher => better expression/eyes).
  final double faceQualityScore;

  /// Portrait-mode: face detected in ROI analysis.
  final bool hasPortraitFace;

  /// Portrait-mode: true when judged as eyes closed.
  final bool portraitEyesClosed;

  /// Portrait-mode: average eye open probability when available (0..1). -1 if unknown.
  final double portraitEyeOpenAvg;

  /// Portrait-mode: true when both eyes are confirmed.
  final bool portraitBothEyesDetected;

  /// Portrait-mode: face bounding box in image pixel coordinates.
  final int portraitFaceX;
  final int portraitFaceY;
  final int portraitFaceW;
  final int portraitFaceH;

  /// Portrait-mode: Laplacian variance within face ROI.
  final double portraitFaceSharpness;

  /// Debug info: Laplacian variance for each of the 4x4 grid cells.
  final List<double>? debugGridSharps;

  DateTime? get capturedAt => exif?.capturedAt;

  String get exifText {
    final e = exif;
    if (e == null) return '';
    final parts = <String>[];

    // Add captured time if available
    if (e.capturedAt != null) {
      final t = e.capturedAt!;
      final timeStr =
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
      parts.add(timeStr);
    }

    if (e.fNumber != null && e.fNumber!.isNotEmpty) parts.add('F${e.fNumber}');
    if (e.shutter != null && e.shutter!.isNotEmpty) parts.add(e.shutter!);
    if (e.iso != null && e.iso!.isNotEmpty) parts.add('ISO${e.iso}');
    return parts.join('  ');
  }

  PhotoEntry copyWith({
    String? key,
    PhotoOrigin? origin,
    String? thumbnailPath,
    String? assetId,
    String? filePath,
    String? pHashHex,
    double? sharpness,
    double? exposureScore,
    int? orbRows,
    int? orbCols,
    Uint8List? orbBytes,
    Uint8List? histogram,
    Float32List? hueHistogram,
    ExifSummary? exif,
    List<SemanticObject>? semanticObjects,
    double? faceQualityScore,
    bool? hasPortraitFace,
    bool? portraitEyesClosed,
    double? portraitEyeOpenAvg,
    bool? portraitBothEyesDetected,
    int? portraitFaceX,
    int? portraitFaceY,
    int? portraitFaceW,
    int? portraitFaceH,
    double? portraitFaceSharpness,
    List<double>? debugGridSharps,
  }) {
    return PhotoEntry(
      key: key ?? this.key,
      origin: origin ?? this.origin,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      assetId: assetId ?? this.assetId,
      filePath: filePath ?? this.filePath,
      pHashHex: pHashHex ?? this.pHashHex,
      sharpness: sharpness ?? this.sharpness,
      exposureScore: exposureScore ?? this.exposureScore,
      orbRows: orbRows ?? this.orbRows,
      orbCols: orbCols ?? this.orbCols,
      orbBytes: orbBytes ?? this.orbBytes,
      histogram: histogram ?? this.histogram,
      hueHistogram: hueHistogram ?? this.hueHistogram,
      exif: exif ?? this.exif,
      semanticObjects: semanticObjects ?? this.semanticObjects,
      faceQualityScore: faceQualityScore ?? this.faceQualityScore,
      hasPortraitFace: hasPortraitFace ?? this.hasPortraitFace,
      portraitEyesClosed: portraitEyesClosed ?? this.portraitEyesClosed,
      portraitEyeOpenAvg: portraitEyeOpenAvg ?? this.portraitEyeOpenAvg,
      portraitBothEyesDetected:
          portraitBothEyesDetected ?? this.portraitBothEyesDetected,
      portraitFaceX: portraitFaceX ?? this.portraitFaceX,
      portraitFaceY: portraitFaceY ?? this.portraitFaceY,
      portraitFaceW: portraitFaceW ?? this.portraitFaceW,
      portraitFaceH: portraitFaceH ?? this.portraitFaceH,
      portraitFaceSharpness:
          portraitFaceSharpness ?? this.portraitFaceSharpness,
      debugGridSharps: debugGridSharps ?? this.debugGridSharps,
    );
  }
}
