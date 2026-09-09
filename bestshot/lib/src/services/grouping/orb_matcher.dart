import 'dart:math' as math;
import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;

class OrbPoint {
  final double x;
  final double y;
  const OrbPoint(this.x, this.y);
}

class OrbMatcher {
  /// Computes the number of inlier matches between two sets of ORB descriptors
  /// using KNN matching, Lowe's Ratio Test, RANSAC Affine/Homography estimation,
  /// spatial distribution checks, and transformation sanity validation.
  ///
  /// Returns a record of (inlierCount, inlierRatio, goodMatchCount).
  static (int, double, int) computeInliers({
    required int rowsA,
    required Uint8List bytesA,
    required Float32List keypointsA,
    required int rowsB,
    required Uint8List bytesB,
    required Float32List keypointsB,
    double ratioThreshold = 0.75,
    double ransacReprojThreshold = 6.0,
    double minBoundingBoxSpread = 50.0,
  }) {
    if (rowsA < 4 || rowsB < 4) return (0, 0.0, 0);
    if (bytesA.length < rowsA * 32 || bytesB.length < rowsB * 32) return (0, 0.0, 0);
    if (keypointsA.length < rowsA * 2 || keypointsB.length < rowsB * 2) return (0, 0.0, 0);

    cv.Mat? matA;
    cv.Mat? matB;
    cv.BFMatcher? matcher;
    try {
      // 1. Create Mat from ORB bytes
      matA = cv.Mat.fromList(rowsA, 32, cv.MatType.CV_8UC1, bytesA.toList());
      matB = cv.Mat.fromList(rowsB, 32, cv.MatType.CV_8UC1, bytesB.toList());
      matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING, crossCheck: false);
      final matches = matcher.knnMatch(matA, matB, 2);

      // 2. Lowe's Ratio Test
      final ptsA = <OrbPoint>[];
      final ptsB = <OrbPoint>[];

      for (final matchArray in matches) {
        if (matchArray.length >= 2) {
          final m = matchArray[0];
          final n = matchArray[1];
          if (m.distance < ratioThreshold * n.distance) {
            final idxA = m.queryIdx;
            final idxB = m.trainIdx;
            if (idxA * 2 + 1 < keypointsA.length && idxB * 2 + 1 < keypointsB.length) {
              ptsA.add(OrbPoint(keypointsA[idxA * 2], keypointsA[idxA * 2 + 1]));
              ptsB.add(OrbPoint(keypointsB[idxB * 2], keypointsB[idxB * 2 + 1]));
            }
          }
        }
      }

      final goodMatches = ptsA.length;
      if (goodMatches < 4) {
        return (0, 0.0, goodMatches);
      }

      // 3. RANSAC Affine Transformation Estimation
      // Robust multi-point RANSAC that fits affine model:
      // u = a*x + b*y + tx
      // v = c*x + d*y + ty
      final (inliers, bestInliersA, bestInliersB) = _ransacAffine(
        ptsA,
        ptsB,
        maxIterations: 80,
        threshold: ransacReprojThreshold,
      );

      if (inliers < 4) {
        return (0, 0.0, goodMatches);
      }

      // 4. Spatial Distribution Validation
      // Ensure inliers are not clustered into a tiny point/repetition
      double minAx = double.infinity, maxAx = -double.infinity;
      double minAy = double.infinity, maxAy = -double.infinity;
      double minBx = double.infinity, maxBx = -double.infinity;
      double minBy = double.infinity, maxBy = -double.infinity;

      for (var i = 0; i < bestInliersA.length; i++) {
        final pa = bestInliersA[i];
        final pb = bestInliersB[i];
        if (pa.x < minAx) minAx = pa.x;
        if (pa.x > maxAx) maxAx = pa.x;
        if (pa.y < minAy) minAy = pa.y;
        if (pa.y > maxAy) maxAy = pa.y;

        if (pb.x < minBx) minBx = pb.x;
        if (pb.x > maxBx) maxBx = pb.x;
        if (pb.y < minBy) minBy = pb.y;
        if (pb.y > maxBy) maxBy = pb.y;
      }

      final spanAx = maxAx - minAx;
      final spanAy = maxAy - minAy;
      final spanBx = maxBx - minBx;
      final spanBy = maxBy - minBy;

      final areaA = spanAx * spanAy;
      final areaB = spanBx * spanBy;

      if ((areaA < minBoundingBoxSpread && areaB < minBoundingBoxSpread) ||
          (spanAx < 10 && spanAy < 10) ||
          (spanBx < 10 && spanBy < 10)) {
        // Degenerate/collinear cluster
        return (0, 0.0, goodMatches);
      }

      final inlierRatio = goodMatches > 0 ? (inliers / goodMatches) : 0.0;
      return (inliers, inlierRatio, goodMatches);

    } catch (_) {
      return (0, 0.0, 0);
    } finally {
      matA?.dispose();
      matB?.dispose();
      matcher?.dispose();
    }
  }

  /// RANSAC Affine transformation estimation
  static (int, List<OrbPoint>, List<OrbPoint>) _ransacAffine(
    List<OrbPoint> ptsA,
    List<OrbPoint> ptsB, {
    required int maxIterations,
    required double threshold,
  }) {
    final n = ptsA.length;
    if (n < 3) return (0, const [], const []);

    final sqThresh = threshold * threshold;
    int bestInlierCount = 0;
    List<OrbPoint> bestInliersA = [];
    List<OrbPoint> bestInliersB = [];

    final rand = math.Random(42); // Deterministic seed for reproducible testing

    for (var iter = 0; iter < maxIterations; iter++) {
      // Pick 3 random distinct points
      final i1 = rand.nextInt(n);
      var i2 = rand.nextInt(n);
      while (i2 == i1) {
        i2 = rand.nextInt(n);
      }
      var i3 = rand.nextInt(n);
      while (i3 == i1 || i3 == i2) {
        i3 = rand.nextInt(n);
      }

      final p1 = ptsA[i1], q1 = ptsB[i1];
      final p2 = ptsA[i2], q2 = ptsB[i2];
      final p3 = ptsA[i3], q3 = ptsB[i3];

      // Solve 3-point affine transformation
      // det of matrix M = [ [x1, y1, 1], [x2, y2, 1], [x3, y3, 1] ]
      final detM = p1.x * (p2.y - p3.y) - p1.y * (p2.x - p3.x) + (p2.x * p3.y - p3.x * p2.y);
      if (detM.abs() < 1e-5) continue; // Collinear sample

      final invDet = 1.0 / detM;

      // Inverse matrix elements of M:
      final m00 = (p2.y - p3.y) * invDet;
      final m01 = (p3.y - p1.y) * invDet;
      final m02 = (p1.y - p2.y) * invDet;

      final m10 = (p3.x - p2.x) * invDet;
      final m11 = (p1.x - p3.x) * invDet;
      final m12 = (p2.x - p1.x) * invDet;

      final m20 = (p2.x * p3.y - p3.x * p2.y) * invDet;
      final m21 = (p3.x * p1.y - p1.x * p3.y) * invDet;
      final m22 = (p1.x * p2.y - p2.x * p1.y) * invDet;

      // Affine parameters: [a, b, tx] for u; [c, d, ty] for v
      final a = m00 * q1.x + m01 * q2.x + m02 * q3.x;
      final b = m10 * q1.x + m11 * q2.x + m12 * q3.x;
      final tx = m20 * q1.x + m21 * q2.x + m22 * q3.x;

      final c = m00 * q1.y + m01 * q2.y + m02 * q3.y;
      final d = m10 * q1.y + m11 * q2.y + m12 * q3.y;
      final ty = m20 * q1.y + m21 * q2.y + m22 * q3.y;

      // Sanity check: Affine determinant (scale & orientation)
      final detA = (a * d) - (b * c);
      // Reject if reflection (negative determinant) or extreme squeeze/stretch
      if (detA <= 0.05 || detA >= 25.0 || detA.isNaN) continue;

      // Count inliers
      int currentInliers = 0;
      final curA = <OrbPoint>[];
      final curB = <OrbPoint>[];

      for (var k = 0; k < n; k++) {
        final pa = ptsA[k];
        final pb = ptsB[k];

        final estU = a * pa.x + b * pa.y + tx;
        final estV = c * pa.x + d * pa.y + ty;

        final du = estU - pb.x;
        final dv = estV - pb.y;
        final errSq = du * du + dv * dv;

        if (errSq <= sqThresh) {
          currentInliers++;
          curA.add(pa);
          curB.add(pb);
        }
      }

      if (currentInliers > bestInlierCount) {
        bestInlierCount = currentInliers;
        bestInliersA = curA;
        bestInliersB = curB;

        // Early stop if almost all matches are inliers
        if (bestInlierCount >= (n * 0.90).round()) {
          break;
        }
      }
    }

    return (bestInlierCount, bestInliersA, bestInliersB);
  }
}
