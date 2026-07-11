class PortraitAnalysis {
  const PortraitAnalysis({
    this.hasFace = false,
    this.eyesClosed = false,
    this.eyeOpenAvg,
    this.bothEyesDetected = false,
    this.faceX = 0,
    this.faceY = 0,
    this.faceW = 0,
    this.faceH = 0,
    this.faceSharpness = 0,
  });

  /// Portrait-mode: face detected in ROI analysis.
  final bool hasFace;

  /// Portrait-mode: true when judged as eyes closed.
  final bool eyesClosed;

  /// Portrait-mode: average eye open probability when available (0..1). -1 if unknown.
  final double? eyeOpenAvg;

  /// Portrait-mode: true when both eyes are confirmed.
  final bool bothEyesDetected;

  /// Portrait-mode: face bounding box in image pixel coordinates.
  final int faceX;
  final int faceY;
  final int faceW;
  final int faceH;

  /// Portrait-mode: Laplacian variance within face ROI.
  final double faceSharpness;

  PortraitAnalysis copyWith({
    bool? hasFace,
    bool? eyesClosed,
    double? Function()? eyeOpenAvg,
    bool? bothEyesDetected,
    int? faceX,
    int? faceY,
    int? faceW,
    int? faceH,
    double? faceSharpness,
  }) {
    return PortraitAnalysis(
      hasFace: hasFace ?? this.hasFace,
      eyesClosed: eyesClosed ?? this.eyesClosed,
      eyeOpenAvg: eyeOpenAvg != null ? eyeOpenAvg() : this.eyeOpenAvg,
      bothEyesDetected: bothEyesDetected ?? this.bothEyesDetected,
      faceX: faceX ?? this.faceX,
      faceY: faceY ?? this.faceY,
      faceW: faceW ?? this.faceW,
      faceH: faceH ?? this.faceH,
      faceSharpness: faceSharpness ?? this.faceSharpness,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PortraitAnalysis &&
        other.hasFace == hasFace &&
        other.eyesClosed == eyesClosed &&
        other.eyeOpenAvg == eyeOpenAvg &&
        other.bothEyesDetected == bothEyesDetected &&
        other.faceX == faceX &&
        other.faceY == faceY &&
        other.faceW == faceW &&
        other.faceH == faceH &&
        other.faceSharpness == faceSharpness;
  }

  @override
  int get hashCode {
    return hasFace.hashCode ^
        eyesClosed.hashCode ^
        eyeOpenAvg.hashCode ^
        bothEyesDetected.hashCode ^
        faceX.hashCode ^
        faceY.hashCode ^
        faceW.hashCode ^
        faceH.hashCode ^
        faceSharpness.hashCode;
  }
}
