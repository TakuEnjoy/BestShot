import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import '../models/review_session.dart';
import '../models/photo_entry.dart';
import '../models/photo_group.dart';
import 'analysis/analysis_types.dart';

class ReviewSessionStore {
  static const _channel = MethodChannel('com.example.bestshot/vision');

  static Future<bool> save(ReviewSession session) async {
    final bookmarks = await _channel
        .invokeMapMethod<String, String>('captureFolderBookmarks', {
          'paths': session.groups
              .expand((g) => g.items)
              .map((e) => e.filePath)
              .whereType<String>()
              .toList(),
        });
    session.directoryBookmarks.addAll(bookmarks ?? {});
    final bytes = await Isolate.run(() => encode(session));
    return await _channel.invokeMethod<bool>('saveReviewSession', {
          'bytes': bytes,
        }) ??
        false;
  }

  /// Write beside the destination, then replace it only after a complete flush.
  static Future<void> writeSnapshot(String path, Uint8List bytes) async {
    final directory = await Directory(
      File(path).parent.path,
    ).createTemp('.bestshot-save-');
    final temporary = File(
      '${directory.path}${Platform.pathSeparator}session.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
      await directory.delete();
    }
  }

  static Future<ReviewSession?> open() async {
    final bytes = await _channel.invokeMethod<Uint8List>('openReviewSession');
    if (bytes == null) return null;
    final session = await Isolate.run(() => decode(bytes));
    if (session.directoryBookmarks.isNotEmpty) {
      final restoredPaths =
          await _channel.invokeMapMethod<String, String>(
            'restoreFolderBookmarks',
            session.directoryBookmarks,
          ) ??
          {};
      session.groups = session.groups
          .map(
            (group) => group.copyWith(
              items: group.items.map((photo) {
                final path = photo.filePath;
                if (path == null) return photo;
                // Prefer the most specific authorized folder when scopes overlap.
                final roots = restoredPaths.keys.toList()
                  ..sort((a, b) => b.length.compareTo(a.length));
                for (final root in roots) {
                  if (path.startsWith('$root/')) {
                    return photo.copyWith(
                      filePath: () =>
                          '${restoredPaths[root]}${path.substring(root.length)}',
                    );
                  }
                }
                return photo;
              }).toList(),
            ),
          )
          .toList();
    }
    return session;
  }

  static Uint8List encode(ReviewSession session) => Uint8List.fromList(
    gzip.encode(
      utf8.encode(
        jsonEncode({
          'schema': 1,
          'iosDirectoryBookmarks': session.directoryBookmarks,
          'mode': session.mode.name,
          'groups': [
            for (final g in session.groups)
              {
                'id': g.id,
                'best': g.bestKey,
                'delete': g.deleteCandidateKeys.toList(),
                'burst': g.isBurst,
                'review': g.needsReview,
                'items': g.items.map(_photoJson).toList(),
              },
          ],
          'decisions': session.decisions.map((k, v) => MapEntry(k, v.name)),
          'protected': session.protectedKeys.toList(),
          'reviewed': session.reviewedGroupIds.toList(),
          'names': session.groupNames,
          'folders': session.folders,
          'customFolders': session.customFolders,
          'delete': session.deleteKeys.where(session.canDelete).toList(),
          'comparison': session.comparisonKeys,
          'groupOrder': session.groupOrder.name,
          'photoOrder': session.photoOrder.name,
          'unreviewedOnly': session.unreviewedOnly,
          'decisionFilter': session.decisionFilter?.name,
          'activeKey': session.activeKey,
        }),
      ),
    ),
  );

  static ReviewSession decode(Uint8List bytes) {
    final data =
        jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>;
    if (data['schema'] != 1) throw const FormatException('対応していない保存形式です');
    final ids = <String>{};
    final keys = <String>{};
    final groups = <PhotoGroup>[];
    for (final raw in data['groups'] as List) {
      final g = raw as Map<String, dynamic>;
      final items = (g['items'] as List)
          .map((e) => _photo(e as Map<String, dynamic>))
          .toList();
      if (!ids.add(g['id'] as String) ||
          items.isEmpty ||
          !items.any((e) => e.key == g['best']) ||
          items.any((e) => !keys.add(e.key))) {
        throw const FormatException('グループまたは写真のデータが不正です');
      }
      groups.add(
        PhotoGroup(
          id: g['id'],
          items: items,
          bestKey: g['best'],
          deleteCandidateKeys: (g['delete'] as List).cast<String>().where(
            (k) => items.any((e) => e.key == k),
          ),
          isBurst: g['burst'],
          needsReview: g['review'],
        ),
      );
    }
    final session = ReviewSession(
      groups: groups,
      mode: DetectionMode.values.byName(data['mode']),
    );
    session.directoryBookmarks.addAll(
      (data['iosDirectoryBookmarks'] as Map?)?.cast<String, String>() ?? {},
    );
    session.decisions.addAll(
      (data['decisions'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, PhotoDecision.values.byName(v)),
      ),
    );
    session.protectedKeys.addAll(
      (data['protected'] as List).cast<String>().where(keys.contains),
    );
    session.reviewedGroupIds.addAll(
      (data['reviewed'] as List).cast<String>().where(ids.contains),
    );
    session.groupNames.addAll((data['names'] as Map).cast<String, String>());
    session.folders.addAll((data['folders'] as Map).cast<String, String>());
    session.customFolders.addAll(
      (data['customFolders'] as List).cast<String>(),
    );
    session.deleteKeys.addAll(
      (data['delete'] as List).cast<String>().where(
        (key) => keys.contains(key) && session.canDelete(key),
      ),
    );
    session.comparisonKeys.addAll(
      (data['comparison'] as List).cast<String>().where(keys.contains).take(4),
    );
    session.groupOrder = GroupOrder.values.byName(data['groupOrder']);
    session.photoOrder = PhotoOrder.values.byName(data['photoOrder']);
    session.unreviewedOnly = data['unreviewedOnly'] == true;
    session.decisionFilter = data['decisionFilter'] == null
        ? null
        : PhotoDecision.values.byName(data['decisionFilter']);
    session.activeKey = keys.contains(data['activeKey'])
        ? data['activeKey']
        : null;
    return session;
  }

  static Map<String, dynamic> _photoJson(PhotoEntry e) {
    final x = e.exif;
    final p = e.portrait;
    final s = e.scoreExplanation;
    final g = e.groupExplanation;
    return {
      'key': e.key,
      'origin': e.origin.name,
      'path': e.filePath,
      'asset': e.assetId,
      'originalFilename': e.originalFilename,
      'thumbnail': base64Encode(e.displayBytes),
      'hash': e.pHashHex,
      'sharpness': e.sharpness,
      'exposure': e.exposureScore,
      'faceQuality': e.faceQualityScore,
      'orbRows': e.orbRows,
      'orbCols': e.orbCols,
      'orb': base64Encode(e.orbBytes),
      'keypoints': e.orbKeypoints.toList(),
      'histogram': base64Encode(e.histogram),
      'hue': e.hueHistogram?.toList(),
      'embeddings': e.embeddings,
      'debug': e.debugGridSharps,
      'semantic': [
        for (final o in e.semanticObjects)
          {'label': o.label, 'x': o.x, 'y': o.y, 'w': o.w, 'h': o.h},
      ],
      'exif': x == null
          ? null
          : {
              'fNumber': x.fNumber,
              'shutter': x.shutter,
              'iso': x.iso,
              'time': x.capturedAt?.toIso8601String(),
              'focal': x.focalLength,
              'camera': x.cameraModel,
              'lens': x.lensModel,
              'bias': x.exposureBias,
              'width': x.imageWidth,
              'height': x.imageHeight,
            },
      'portrait': {
        'face': p.hasFace,
        'closed': p.eyesClosed,
        'eye': p.eyeOpenAvg,
        'both': p.bothEyesDetected,
        'x': p.faceX,
        'y': p.faceY,
        'w': p.faceW,
        'h': p.faceH,
        'imageWidth': p.faceImageWidth,
        'imageHeight': p.faceImageHeight,
        'sharpness': p.faceSharpness,
      },
      'score': s == null
          ? null
          : {
              'total': s.totalScore,
              'raw': s.rawSharpness,
              'effective': s.effectiveSharpness,
              'normalized': s.normalizedSharpness,
              'exposure': s.exposureScore,
              'face': s.faceQualityScore,
              'rule': s.ruleName,
              'formula': s.formulaText,
            },
      'match': g == null
          ? null
          : {
              'type': g.matchType,
              'description': g.description,
              'category': g.category,
              'seconds': g.diffSeconds,
              'hash': g.pHashDistance,
              'color': g.colorDistance,
              'matches': g.orbMatches,
              'inliers': g.inliers,
              'ratio': g.orbInlierRatio,
              'embedding': g.embeddingSimilarity,
              'crop': g.cropPair,
              'semantic': g.semanticMatch,
              'confidence': g.confidence,
              'review': g.needsReview,
              'reference': g.referenceKey,
            },
    };
  }

  static Float32List _floats(dynamic value) => Float32List.fromList(
    (value as List).map((v) => (v as num).toDouble()).toList(),
  );
  static PhotoEntry _photo(Map<String, dynamic> d) {
    final dynamic x = d['exif'],
        p = d['portrait'],
        s = d['score'],
        g = d['match'];
    return PhotoEntry(
      key: d['key'],
      origin: PhotoOrigin.values.byName(d['origin']),
      filePath: d['path'],
      assetId: d['asset'],
      originalFilename: d['originalFilename'],
      displayBytes: base64Decode(d['thumbnail']),
      pHashHex: d['hash'],
      sharpness: (d['sharpness'] as num).toDouble(),
      exposureScore: (d['exposure'] as num).toDouble(),
      faceQualityScore: (d['faceQuality'] as num).toDouble(),
      orbRows: d['orbRows'],
      orbCols: d['orbCols'],
      orbBytes: base64Decode(d['orb']),
      orbKeypoints: _floats(d['keypoints']),
      histogram: base64Decode(d['histogram']),
      hueHistogram: d['hue'] == null ? null : _floats(d['hue']),
      embeddings: (d['embeddings'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, _floats(v)),
      ),
      debugGridSharps: (d['debug'] as List?)
          ?.map((v) => (v as num).toDouble())
          .toList(),
      semanticObjects: (d['semantic'] as List)
          .map(
            (v) => SemanticObject(
              label: v['label'],
              x: (v['x'] as num).toDouble(),
              y: (v['y'] as num).toDouble(),
              w: (v['w'] as num).toDouble(),
              h: (v['h'] as num).toDouble(),
            ),
          )
          .toList(),
      exif: x == null
          ? null
          : ExifSummary(
              fNumber: x['fNumber'],
              shutter: x['shutter'],
              iso: x['iso'],
              capturedAt: x['time'] == null ? null : DateTime.parse(x['time']),
              focalLength: x['focal'],
              cameraModel: x['camera'],
              lensModel: x['lens'],
              exposureBias: x['bias'],
              imageWidth: x['width'],
              imageHeight: x['height'],
            ),
      portrait: PortraitAnalysis(
        hasFace: p['face'],
        eyesClosed: p['closed'],
        eyeOpenAvg: (p['eye'] as num?)?.toDouble(),
        bothEyesDetected: p['both'],
        faceX: p['x'],
        faceY: p['y'],
        faceW: p['w'],
        faceH: p['h'],
        faceImageWidth: p['imageWidth'] ?? 0,
        faceImageHeight: p['imageHeight'] ?? 0,
        faceSharpness: (p['sharpness'] as num).toDouble(),
      ),
      scoreExplanation: s == null
          ? null
          : ScoreExplanation(
              totalScore: (s['total'] as num).toDouble(),
              rawSharpness: (s['raw'] as num).toDouble(),
              effectiveSharpness: (s['effective'] as num).toDouble(),
              normalizedSharpness: (s['normalized'] as num).toDouble(),
              exposureScore: (s['exposure'] as num).toDouble(),
              faceQualityScore: (s['face'] as num).toDouble(),
              ruleName: s['rule'],
              formulaText: s['formula'],
            ),
      groupExplanation: g == null
          ? null
          : GroupMatchExplanation(
              matchType: g['type'],
              description: g['description'],
              category: g['category'],
              diffSeconds: (g['seconds'] as num?)?.toDouble(),
              pHashDistance: g['hash'],
              colorDistance: (g['color'] as num?)?.toDouble(),
              orbMatches: g['matches'],
              inliers: g['inliers'],
              orbInlierRatio: (g['ratio'] as num?)?.toDouble(),
              embeddingSimilarity: (g['embedding'] as num?)?.toDouble(),
              cropPair: g['crop'],
              semanticMatch: g['semantic'],
              confidence: (g['confidence'] as num).toDouble(),
              needsReview: g['review'],
              referenceKey: g['reference'],
            ),
    );
  }
}
