import 'package:flutter/foundation.dart';

import 'exif_summary.dart';
import 'semantic_object.dart';
import 'portrait_analysis.dart';
export 'semantic_object.dart';
export 'portrait_analysis.dart';

enum PhotoOrigin { deviceAsset, filePath }

class PhotoEntry {
  PhotoEntry({
    required this.key,
    required this.origin,
    required this.displayBytes,
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
    this.portrait = const PortraitAnalysis(),
    this.debugGridSharps,
  });

  /// Unique key across all imported items.
  final String key;

  final PhotoOrigin origin;

  /// Thumbnail bytes (JPEG/PNG) for grid display.
  final Uint8List displayBytes;

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

  /// Portrait-mode analysis results.
  final PortraitAnalysis portrait;

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
    Uint8List? displayBytes,
    ValueGetter<String?>? assetId,
    ValueGetter<String?>? filePath,
    String? pHashHex,
    double? sharpness,
    double? exposureScore,
    int? orbRows,
    int? orbCols,
    Uint8List? orbBytes,
    Uint8List? histogram,
    ValueGetter<Float32List?>? hueHistogram,
    ValueGetter<ExifSummary?>? exif,
    List<SemanticObject>? semanticObjects,
    double? faceQualityScore,
    PortraitAnalysis? portrait,
    ValueGetter<List<double>?>? debugGridSharps,
  }) {
    return PhotoEntry(
      key: key ?? this.key,
      origin: origin ?? this.origin,
      displayBytes: displayBytes ?? this.displayBytes,
      assetId: assetId != null ? assetId() : this.assetId,
      filePath: filePath != null ? filePath() : this.filePath,
      pHashHex: pHashHex ?? this.pHashHex,
      sharpness: sharpness ?? this.sharpness,
      exposureScore: exposureScore ?? this.exposureScore,
      orbRows: orbRows ?? this.orbRows,
      orbCols: orbCols ?? this.orbCols,
      orbBytes: orbBytes ?? this.orbBytes,
      histogram: histogram ?? this.histogram,
      hueHistogram: hueHistogram != null ? hueHistogram() : this.hueHistogram,
      exif: exif != null ? exif() : this.exif,
      semanticObjects: semanticObjects ?? this.semanticObjects,
      faceQualityScore: faceQualityScore ?? this.faceQualityScore,
      portrait: portrait ?? this.portrait,
      debugGridSharps: debugGridSharps != null
          ? debugGridSharps()
          : this.debugGridSharps,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PhotoEntry &&
        other.key == key &&
        other.origin == origin &&
        listEquals(other.displayBytes, displayBytes) &&
        other.assetId == assetId &&
        other.filePath == filePath &&
        other.pHashHex == pHashHex &&
        other.sharpness == sharpness &&
        other.exposureScore == exposureScore &&
        other.orbRows == orbRows &&
        other.orbCols == orbCols &&
        listEquals(other.orbBytes, orbBytes) &&
        listEquals(other.histogram, histogram) &&
        listEquals(other.hueHistogram, hueHistogram) &&
        other.exif == exif &&
        listEquals(other.semanticObjects, semanticObjects) &&
        other.faceQualityScore == faceQualityScore &&
        other.portrait == portrait &&
        listEquals(other.debugGridSharps, debugGridSharps);
  }

  @override
  int get hashCode {
    return key.hashCode ^
        origin.hashCode ^
        Object.hashAll(displayBytes) ^
        assetId.hashCode ^
        filePath.hashCode ^
        pHashHex.hashCode ^
        sharpness.hashCode ^
        exposureScore.hashCode ^
        orbRows.hashCode ^
        orbCols.hashCode ^
        Object.hashAll(orbBytes) ^
        Object.hashAll(histogram) ^
        (hueHistogram != null ? Object.hashAll(hueHistogram!) : 0) ^
        exif.hashCode ^
        Object.hashAll(semanticObjects) ^
        faceQualityScore.hashCode ^
        portrait.hashCode ^
        (debugGridSharps != null ? Object.hashAll(debugGridSharps!) : 0);
  }

  @override
  String toString() {
    return 'PhotoEntry(key: $key, origin: $origin, sharpness: $sharpness, exposure: $exposureScore, pHashHex: $pHashHex)';
  }
}
