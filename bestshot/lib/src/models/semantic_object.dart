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
