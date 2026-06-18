import 'dart:typed_data';

enum DetectionMode { standard, portrait }

class AnalyzeInput {
  AnalyzeInput({
    required this.key,
    this.displayBytes,
    this.filePath,
  });

  final String key;
  final Uint8List? displayBytes;
  final String? filePath;
}

class AnalyzeOutput {
  AnalyzeOutput({
    required this.key,
    required this.pHashHex,
    required this.sharpness,
    required this.exposureScore,
    required this.orbRows,
    required this.orbCols,
    required this.orbBytes,
    required this.histogram,
    this.hueHistogram,
    required this.hasFace,
    required this.faceX,
    required this.faceY,
    required this.faceW,
    required this.faceH,
    required this.faceSharpness,
    required this.eyeOpenAvg,
    required this.eyesClosed,
    required this.bothEyesDetected,
    required this.eyeSharpness,
    this.debugGridSharps,
  });

  final String key;
  final String pHashHex;

  /// The score used for grouping/UI (mode-dependent).
  final double sharpness;
  final double exposureScore;
  final int orbRows;
  final int orbCols;
  final Uint8List orbBytes;
  final Uint8List histogram; // 256 bytes
  final Float32List? hueHistogram; // 180 floats


  /// Portrait-mode extras.
  final bool hasFace;
  final int faceX;
  final int faceY;
  final int faceW;
  final int faceH;

  /// Laplacian variance computed only within face ROI (0 if none).
  final double faceSharpness;

  /// Average of both eyes open probabilities when available (0..1). -1 if unknown.
  final double eyeOpenAvg;

  /// True when judged as "eyes closed" in portrait mode.
  final bool eyesClosed;

  /// True when both eyes are confidently detected (platform-dependent).
  final bool bothEyesDetected;

  /// Laplacian variance within eye ROIs (0..1 or absolute variance, -1 if none).
  final double eyeSharpness;

  /// Grid sharpness values (4x4, 16 elements).
  final List<double>? debugGridSharps;
}

