// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/services/grouping/grouping.dart';
import 'package:bestshot/src/services/grouping/pair_evaluator.dart';
import 'package:bestshot/src/utils/jpeg_utils.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:exif/exif.dart';
import 'package:path/path.dart' as p;

DateTime? _parseExifDateTime(String? s) {
  if (s == null) return null;
  final m = RegExp(
    r'^(\d{4})[:\-](\d{2})[:\-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(s.trim());
  if (m == null) return null;
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
}

String _calcEqualizedPHashHex(cv.Mat mat) {
  try {
    final small = cv.resize(mat, (32, 32));
    final gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
    final eq = cv.equalizeHist(gray);
    final fGray = eq.convertTo(cv.MatType.CV_32FC1);
    final dctMat = cv.dct(fGray);
    final top8x8 = dctMat.region(cv.Rect(0, 0, 8, 8));
    final vals = <double>[];
    for (int r = 0; r < 8; r++) {
      for (int c = 0; c < 8; c++) {
        if (r == 0 && c == 0) continue;
        vals.add(top8x8.at<double>(r, c));
      }
    }
    vals.sort();
    final median = vals[vals.length ~/ 2];
    BigInt hash = BigInt.zero;
    for (int r = 0; r < 8; r++) {
      for (int c = 0; c < 8; c++) {
        if (r == 0 && c == 0) continue;
        hash <<= 1;
        if (top8x8.at<double>(r, c) > median) hash |= BigInt.one;
      }
    }
    small.dispose();
    gray.dispose();
    eq.dispose();
    fGray.dispose();
    dctMat.dispose();
    top8x8.dispose();
    return hash.toRadixString(16).padLeft(16, '0');
  } catch (_) {
    return '0000000000000000';
  }
}

Float32List _calcHueHistogram(cv.Mat bgr) {
  final hsv = cv.cvtColor(bgr, cv.COLOR_BGR2HSV);
  final histH = cv.calcHist(
    cv.VecMat.fromList([hsv]),
    cv.VecI32.fromList([0]),
    cv.Mat.empty(),
    cv.VecI32.fromList([180]),
    cv.VecF32.fromList([0, 180]),
  );
  final histS = cv.calcHist(
    cv.VecMat.fromList([hsv]),
    cv.VecI32.fromList([1]),
    cv.Mat.empty(),
    cv.VecI32.fromList([256]),
    cv.VecF32.fromList([0, 256]),
  );
  final histV = cv.calcHist(
    cv.VecMat.fromList([hsv]),
    cv.VecI32.fromList([2]),
    cv.Mat.empty(),
    cv.VecI32.fromList([256]),
    cv.VecF32.fromList([0, 256]),
  );
  cv.normalize(histH, histH, alpha: 1.0, normType: cv.NORM_L1);
  cv.normalize(histS, histS, alpha: 1.0, normType: cv.NORM_L1);
  cv.normalize(histV, histV, alpha: 1.0, normType: cv.NORM_L1);

  final combined = Float32List(692);
  combined.setRange(0, 180, Float32List.sublistView(histH.data));
  combined.setRange(180, 436, Float32List.sublistView(histS.data));
  combined.setRange(436, 692, Float32List.sublistView(histV.data));

  hsv.dispose();
  histH.dispose();
  histS.dispose();
  histV.dispose();
  return combined;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Production PhotoGrouper groups Test folder into exactly 20 ground-truth clusters', () async {
    final dirPath = r'C:\Users\makww\Documents\AiProjects\Test';
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      print('Test folder not present at $dirPath, skipping real folder test.');
      return;
    }

    final files = dir.listSync().whereType<File>().toList();
    files.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));

    final clahe = cv.createCLAHE(clipLimit: 3.0, tileGridSize: (8, 8));
    final orb = cv.ORB.create(nFeatures: 800, scaleFactor: 1.2, nLevels: 8, edgeThreshold: 15, fastThreshold: 10);

    final entries = <PhotoEntry>[];
    for (final f in files) {
      final name = p.basename(f.path);
      final bytes = await f.readAsBytes();
      cv.Mat mat;

      final isRaw = name.toLowerCase().endsWith('.dng') || name.toLowerCase().endsWith('.nef');
      if (isRaw) {
        final jpeg = JpegUtils.extractEmbeddedJpeg(bytes);
        expect(jpeg, isNotNull, reason: 'Embedded JPEG preview must be extractable from $name');
        mat = cv.imdecode(jpeg!, cv.IMREAD_COLOR);
      } else {
        mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      }
      expect(mat.rows, greaterThan(0), reason: '$name failed to decode Mat');

      final origW = mat.cols.toDouble();
      final origH = mat.rows.toDouble();
      final s = 640 / math.max(origW, origH);
      final res = cv.resize(mat, ((origW * s).round(), (origH * s).round()));
      mat.dispose();

      final pHash = _calcEqualizedPHashHex(res);
      final hueHist = _calcHueHistogram(res);

      final gray = cv.cvtColor(res, cv.COLOR_BGR2GRAY);
      res.dispose();

      final cl = clahe.apply(gray);
      gray.dispose();

      final (kp, desc) = orb.detectAndCompute(cl, cv.Mat.empty());
      cl.dispose();

      final rows = desc.rows;
      final bytesLen = rows * 32;
      final slicedBytes = Uint8List.fromList(desc.data.sublist(0, bytesLen));
      final kps = Float32List(rows * 2);
      for (var i = 0; i < rows; i++) {
        kps[i * 2] = kp[i].x;
        kps[i * 2 + 1] = kp[i].y;
      }
      kp.dispose();
      desc.dispose();

      final tags = await readExifFromBytes(bytes.sublist(0, bytes.length < 256 * 1024 ? bytes.length : 256 * 1024));
      final dt = tags['EXIF DateTimeOriginal'] ?? tags['Image DateTime'] ?? tags['DateTime'];
      final focal = tags['EXIF FocalLength']?.printable;
      final camera = tags['Image Model']?.printable;

      entries.add(
        PhotoEntry(
          key: name,
          origin: PhotoOrigin.filePath,
          displayBytes: Uint8List(0),
          filePath: f.path,
          pHashHex: pHash,
          sharpness: 100.0,
          exposureScore: 0.8,
          orbRows: rows,
          orbCols: 32,
          orbBytes: slicedBytes,
          orbKeypoints: kps,
          histogram: Uint8List(256),
          hueHistogram: hueHist,
          exif: ExifSummary(
            fNumber: null,
            shutter: null,
            iso: null,
            capturedAt: _parseExifDateTime(dt?.printable),
            cameraModel: camera,
            focalLength: focal,
          ),
        ),
      );
    }

    for (final e in entries) {
      print('${e.key.padRight(10)}: capturedAt=${e.exif?.capturedAt}, camera=${e.exif?.cameraModel}');
    }

    final focusKeys = ['81.jpg', '82.jpg', '83.dng', '131.jpg', '132.jpg'];
    print('\n--- Pairwise evaluation for 81, 82, 83, 131, 132 ---');
    for (int i = 0; i < entries.length; i++) {
      for (int j = i + 1; j < entries.length; j++) {
        final e1 = entries[i];
        final e2 = entries[j];
        if (focusKeys.contains(e1.key) && focusKeys.contains(e2.key)) {
          final res = PairSimilarityEvaluator.evaluate(e1, e2);
          print('${e1.key} <-> ${e2.key}: isSameScene=${res.isSameScene}, cat=${res.category}, conf=${res.confidence.toStringAsFixed(2)}, inliers=${res.orbInliers}, pDist=${res.pHashDistance}, cDist=${res.colorDistance?.toStringAsFixed(3)}, diffSec=${res.diffSeconds}, reason=${res.explanation}');
        }
      }
    }

    // Run production PhotoGrouper with default config
    final groups = PhotoGrouper.group(entries, const GroupingConfig());

    print('\n================ PRODUCTION GROUPER TEST RESULTS ================');
    print('Total groups formed: ${groups.length} (Expected: 20)');
    for (int i = 0; i < groups.length; i++) {
      final g = groups[i];
      final names = g.items.map((e) => e.key).toList()..sort();
      print('Group #${i + 1} (${names.length} photos): ${names.join(", ")}');
    }

    expect(groups.length, equals(20), reason: 'Expected exactly 20 groups');

    final groundTruthGroups = [
      ['01.jpg', '02.jpg'],
      ['11.jpg', '12.jpg'],
      ['21.jpg', '22.jpg'],
      ['31.JPG', '32.JPG'],
      ['41.JPG', '42.JPG'],
      ['51.NEF', '52.NEF'],
      ['61.dng', '62.dng'],
      ['71.jpg', '72.jpg'],
      ['81.jpg', '82.jpg', '83.dng'],
      ['91.jpg', '92.jpg'],
      ['101.jpg', '102.jpg'],
      ['111.jpg', '112.jpg'],
      ['121.jpg', '122.jpg'],
      ['131.jpg', '132.jpg'],
      ['141.jpg', '142.jpg'],
      ['151.jpg', '152.jpg'],
      ['X1.jpg', 'X2.jpg', 'X3.jpg'],
      ['IMG1.jpg'],
      ['IMG2.jpg'],
      ['IMG3.jpg'],
    ];

    for (final expected in groundTruthGroups) {
      final group = groups.firstWhere(
        (g) => g.items.any((e) => e.key == expected.first),
        orElse: () => throw TestFailure('Group containing ${expected.first} was not found'),
      );
      final actualNames = group.items.map((e) => e.key).toList()..sort();
      expect(
        actualNames,
        equals(expected..sort()),
        reason: 'Ground truth mismatch: Expected $expected, but got $actualNames',
      );
    }
  });
}
