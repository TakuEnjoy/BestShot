import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/photo_entry.dart';
import '../services/analysis/analyzer_isolate.dart';
import '../services/analysis/analysis_types.dart';
import '../services/grouping/grouping.dart';
import '../services/importing/import_service.dart';
import '../services/semantic/mlkit_semantic_service.dart';
import 'groups_screen.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _busy = false;
  String _status = '';
  double? _progress; // null => indeterminate
  String _stage = '';
  DetectionMode _detectionMode = DetectionMode.standard;
  /// 連写ウィンドウ（1秒〜60分）。UIは分・秒で編集、初期 00分15秒。
  int _burstMinutes = 0;
  int _burstSeconds = 15;

  static const int _burstMinTotal = 1;
  static const int _burstMaxTotal = 60 * 60;

  int get _burstWindowSeconds {
    var total = _burstMinutes * 60 + _burstSeconds;
    if (total < _burstMinTotal) total = _burstMinTotal;
    if (total > _burstMaxTotal) total = _burstMaxTotal;
    return total;
  }

  void _normalizeBurstTotal() {
    var m = _burstMinutes.clamp(0, 60);
    var s = _burstSeconds.clamp(0, 59);
    var total = m * 60 + s;
    if (total > _burstMaxTotal) {
      total = _burstMaxTotal;
      m = total ~/ 60;
      s = total % 60;
    }
    if (total < _burstMinTotal) {
      m = 0;
      s = 1;
    }
    setState(() {
      _burstMinutes = m;
      _burstSeconds = s;
    });
  }

  Future<void> _runImportAndAnalyze(
    Future<List<ImportedItem>> Function(void Function(int done, int total) onProgress) importer,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _stage = 'インポート';
      _status = '写真を読み込み中...';
      _progress = 0;
    });

    try {
      final imported = await importer((done, total) {
        if (!mounted) return;
        setState(() {
          _progress = total <= 0 ? null : (done / total).clamp(0.0, 1.0);
          _status = '写真を読み込み中... ($done / $total)';
        });
      });
      if (!mounted) return;
      if (imported.isEmpty) {
        setState(() {
          _busy = false;
          _status = '写真が選択されませんでした（権限/対象0件）';
          _stage = '';
          _progress = null;
        });
        return;
      }

      setState(() {
        _stage = '解析';
        _status = 'バックグラウンド解析中（pHash + 鮮鋭度 + 露出）...';
        _progress = 0;
      });
      final analyzed = await AnalyzerIsolate.analyzeAll(
        imported.map((e) => e.toAnalyzeInput()).toList(growable: false),
        mode: _detectionMode,
        rootIsolateToken: RootIsolateToken.instance,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _progress = total <= 0 ? null : (done / total).clamp(0.0, 1.0);
            _status = 'バックグラウンド解析中... ($done / $total)';
          });
        },
      );

      final byKey = {for (final a in analyzed) a.key: a};

      final entries = <PhotoEntry>[];
      for (final i in imported) {
        final a = byKey[i.key];
        if (a == null) continue;
        entries.add(
          PhotoEntry(
            key: i.key,
            origin: i.origin,
            displayBytes: i.displayBytes,
            assetId: i.assetId,
            filePath: i.filePath,
            pHashHex: a.pHashHex,
            sharpness: a.sharpness,
            exposureScore: a.exposureScore,
            orbRows: a.orbRows,
            orbCols: a.orbCols,
            orbBytes: a.orbBytes,
            histogram: a.histogram,
            exif: i.exifSummary,
            hasPortraitFace: a.hasFace,
            portraitEyesClosed: a.eyesClosed,
            portraitEyeOpenAvg: a.eyeOpenAvg,
            portraitBothEyesDetected: a.bothEyesDetected,
            portraitFaceX: a.faceX,
            portraitFaceY: a.faceY,
            portraitFaceW: a.faceW,
            portraitFaceH: a.faceH,
            portraitFaceSharpness: a.faceSharpness,
          ),
        );
      }

      // Semantic analysis (Android/iOS only)
      var enrichedEntries = entries;
      if (Platform.isAndroid || Platform.isIOS) {
        setState(() {
          _stage = '物体/顔検出';
          _status = 'ML Kitで被写体/表情を解析中...';
          _progress = 0;
        });
        final svc = await MlKitSemanticService.create();
        try {
          enrichedEntries = await svc.enrich(
            entries,
            onProgress: (done, total) {
              if (!mounted) return;
              setState(() {
                _progress = total <= 0 ? null : (done / total).clamp(0.0, 1.0);
                _status = 'ML Kit解析中... ($done / $total)';
              });
            },
          );
        } finally {
          await svc.close();
        }
      }

      setState(() {
        _stage = 'グループ化';
        _status = '類似写真をグループ化中...';
        _progress = null;
      });
      final groups = PhotoGrouper.group(
        enrichedEntries,
        GroupingConfig(burstWindowSeconds: _burstWindowSeconds),
      );

      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '';
        _stage = '';
        _progress = null;
      });

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => GroupsScreen(groups: groups, detectionMode: _detectionMode),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'エラー: $e';
        _stage = '';
        _progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWindows = Platform.isWindows;
    final isAndroid = Platform.isAndroid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BestShot'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '一眼レフ/ミラーレスの連写・類似写真を、内容ベースでグループ化して「Best」を提案します。',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _InfoCard(),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '検出モード',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<DetectionMode>(
                          initialValue: _detectionMode,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: DetectionMode.standard,
                              child: Text('標準（全体スコア）'),
                            ),
                            DropdownMenuItem(
                              value: DetectionMode.portrait,
                              child: Text('ポートレート（顔優先・目閉じ判定）'),
                            ),
                          ],
                          onChanged: _busy
                              ? null
                              : (v) {
                                  if (v == null) return;
                                  // Portrait is supported only on Android/Windows in this build.
                                  if (v == DetectionMode.portrait && !(isWindows || isAndroid)) {
                                    setState(() => _detectionMode = DetectionMode.standard);
                                    return;
                                  }
                                  setState(() => _detectionMode = v);
                                },
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '連写としてまとめる時間',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '合計: ${_formatBurstWindow(_burstWindowSeconds)}（1秒〜60分）',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                initialValue: _burstMinutes.clamp(0, 60),
                                decoration: const InputDecoration(
                                  labelText: '分',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  for (var i = 0; i <= 60; i++)
                                    DropdownMenuItem(value: i, child: Text(i.toString().padLeft(2, '0'))),
                                ],
                                onChanged: _busy
                                    ? null
                                    : (v) {
                                        if (v == null) return;
                                        setState(() => _burstMinutes = v);
                                        _normalizeBurstTotal();
                                      },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                initialValue: _burstSeconds.clamp(0, 59),
                                decoration: const InputDecoration(
                                  labelText: '秒',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  for (var i = 0; i < 60; i++)
                                    DropdownMenuItem(value: i, child: Text(i.toString().padLeft(2, '0'))),
                                ],
                                onChanged: _busy
                                    ? null
                                    : (v) {
                                        if (v == null) return;
                                        setState(() => _burstSeconds = v);
                                        _normalizeBurstTotal();
                                      },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (isWindows)
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _runImportAndAnalyze(
                              (onProgress) => ImportService.pickFromFolderWindows(onProgress: onProgress),
                            ),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('フォルダからインポート（Windows）'),
                  )
                else if (isAndroid)
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _runImportAndAnalyze(
                              (onProgress) => ImportService.pickFromFolderAndroid(onProgress: onProgress),
                            ),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('フォルダからインポート（Android）'),
                  )
                else
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _runImportAndAnalyze(
                              (onProgress) => ImportService.pickFromDeviceGallery(onProgress: onProgress),
                            ),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('写真を選択（Android/iOS）'),
                  ),
                const SizedBox(height: 12),
                if (_busy && _stage.isNotEmpty)
                  Text(
                    '処理: $_stage',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                if (_status.isNotEmpty)
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                  ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: _progress),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatBurstWindow(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  final rem = seconds % 60;
  if (minutes < 60) {
    return rem == 0 ? '$minutes 分' : '$minutes 分 $rem 秒';
  }
  final hours = minutes ~/ 60;
  final minRem = minutes % 60;
  if (minRem == 0 && rem == 0) return '$hours 時間';
  if (rem == 0) return '$hours 時間 $minRem 分';
  return '$hours 時間 $minRem 分 $rem 秒';
}

class _InfoCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.bodyMedium!,
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('核となるロジック'),
              SizedBox(height: 8),
              Text('- 類似判定: pHash（image_compare / PerceptualHash）'),
              Text('- ピント判定: Laplacian variance（opencv_dart）'),
              Text('- メモリ節約: サムネ優先 + Isolate解析'),
            ],
          ),
        ),
      ),
    );
  }
}

