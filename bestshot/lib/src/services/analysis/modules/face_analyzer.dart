import 'dart:io';
import 'dart:typed_data';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'sharpness_evaluator.dart';

class PortraitResult {
  const PortraitResult({
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
  });

  const PortraitResult.none()
    : hasFace = false,
      faceX = 0,
      faceY = 0,
      faceW = 0,
      faceH = 0,
      faceSharpness = 0,
      eyeOpenAvg = -1,
      eyesClosed = false,
      bothEyesDetected = false,
      eyeSharpness = -1;

  final bool hasFace;
  final int faceX;
  final int faceY;
  final int faceW;
  final int faceH;
  final double faceSharpness;
  final double eyeOpenAvg;
  final bool eyesClosed;
  final bool bothEyesDetected;
  final double eyeSharpness;
}

class FaceAnalyzer {
  static Future<PortraitResult> portraitAnalyze(
    Uint8List bytes, {
    required FaceDetector faceDetector,
    required Directory tmpDir,
  }) async {
    cv.Mat? mat;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) {
        return const PortraitResult.none();
      }

      final fp = p.join(
        tmpDir.path,
        'bestshot_portrait_${bytes.length}_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      final file = File(fp);
      await file.writeAsBytes(bytes, flush: true);

      final input = InputImage.fromFilePath(fp);
      final faces = await faceDetector.processImage(input);

      // Clean up the temp file immediately.
      if (await file.exists()) {
        await file.delete();
      }

      if (faces.isEmpty) {
        return const PortraitResult.none();
      }

      // Find largest area to determine threshold
      double maxArea = 0;
      for (final f in faces) {
        final area = (f.boundingBox.width * f.boundingBox.height).toDouble();
        if (area > maxArea) {
          maxArea = area;
        }
      }

      // Keep only faces that are at least 25% of the largest face area
      final mainFaces = faces.where((f) {
        final area = f.boundingBox.width * f.boundingBox.height;
        return area >= (maxArea * 0.25);
      }).toList();

      // Primary face is the largest one
      Face primaryFace = mainFaces.first;
      var primaryArea =
          primaryFace.boundingBox.width * primaryFace.boundingBox.height;
      for (final f in mainFaces.skip(1)) {
        final area = f.boundingBox.width * f.boundingBox.height;
        if (area > primaryArea) {
          primaryFace = f;
          primaryArea = area;
        }
      }

      double totalFaceSharpness = 0.0;
      double totalEyeSharpness = 0.0;
      int eyeSharpnessCount = 0;
      double minEyeOpen = 1.0;
      bool anyEyesClosed = false;
      bool allBothEyesDetected = true;
      bool anyBothEyesDetected = false;

      for (final face in mainFaces) {
        final bb = face.boundingBox;
        final rx = bb.left.round();
        final ry = bb.top.round();
        final rw = bb.width.round();
        final rh = bb.height.round();

        // Sharpness calculation in face ROI
        final roi = cv.Rect(rx, ry, rw, rh);
        var fSharp = SharpnessEvaluator.calcLaplacianVarianceInRoi(mat, roi);
        if (fSharp <= 0) {
          fSharp = SharpnessEvaluator.fallbackLaplacianVariance(
            bytes,
            x: rx,
            y: ry,
            w: rw,
            h: rh,
          );
        }
        totalFaceSharpness += fSharp;

        // Eye open probability (0.0 to 1.0)
        final le = face.leftEyeOpenProbability;
        final re = face.rightEyeOpenProbability;
        var faceEyeAvg = -1.0;
        var faceEyesClosed = false;

        if (le != null && re != null) {
          faceEyeAvg = (le + re) / 2.0;
          anyBothEyesDetected = true;
          faceEyesClosed = (faceEyeAvg < 0.4) || (le < 0.2) || (re < 0.2);
        } else if (le != null) {
          faceEyeAvg = le;
          faceEyesClosed = le < 0.4;
          allBothEyesDetected = false;
        } else if (re != null) {
          faceEyeAvg = re;
          faceEyesClosed = re < 0.4;
          allBothEyesDetected = false;
        } else {
          allBothEyesDetected = false;
        }

        if (faceEyeAvg >= 0) {
          if (faceEyeAvg < minEyeOpen) {
            minEyeOpen = faceEyeAvg;
          }
          if (faceEyesClosed) {
            anyEyesClosed = true;
          }
        }

        // Eye Sharpness (using landmarks)
        final leftLandmark = face.landmarks[FaceLandmarkType.leftEye];
        final rightLandmark = face.landmarks[FaceLandmarkType.rightEye];

        if (leftLandmark != null) {
          final ex = leftLandmark.position.x;
          final ey = leftLandmark.position.y;
          final ew = (rw * 0.15)
              .round(); // Eye ROI size approx 15% of face width
          final eroi = cv.Rect(
            (ex - ew / 2).round(),
            (ey - ew / 2).round(),
            ew,
            ew,
          );
          final v = SharpnessEvaluator.calcLaplacianVarianceInRoi(mat, eroi);
          if (v > 0) {
            totalEyeSharpness += v;
            eyeSharpnessCount++;
          }
        }
        if (rightLandmark != null) {
          final ex = rightLandmark.position.x;
          final ey = rightLandmark.position.y;
          final ew = (rw * 0.15).round();
          final eroi = cv.Rect(
            (ex - ew / 2).round(),
            (ey - ew / 2).round(),
            ew,
            ew,
          );
          final v = SharpnessEvaluator.calcLaplacianVarianceInRoi(mat, eroi);
          if (v > 0) {
            totalEyeSharpness += v;
            eyeSharpnessCount++;
          }
        }
      }

      final avgFaceSharpness = totalFaceSharpness / mainFaces.length;
      var avgEyeSharpness = -1.0;
      if (eyeSharpnessCount > 0) {
        final avgV = totalEyeSharpness / eyeSharpnessCount;
        avgEyeSharpness = (avgV / 1000.0).clamp(0.0, 1.0);
      }

      final finalEyeOpenAvg = (minEyeOpen == 1.0 && !anyBothEyesDetected)
          ? -1.0
          : minEyeOpen;

      final pBb = primaryFace.boundingBox;
      return PortraitResult(
        hasFace: true,
        faceX: pBb.left.round(),
        faceY: pBb.top.round(),
        faceW: pBb.width.round(),
        faceH: pBb.height.round(),
        faceSharpness: avgFaceSharpness,
        eyeOpenAvg: finalEyeOpenAvg,
        eyesClosed: anyEyesClosed,
        bothEyesDetected: allBothEyesDetected,
        eyeSharpness: avgEyeSharpness,
      );
    } catch (e) {
      return const PortraitResult.none();
    } finally {
      mat?.dispose();
    }
  }
}
