import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/photo_entry.dart';
import '../services/analysis/analyzer_isolate.dart';
import '../services/analysis/analysis_types.dart';
import '../services/grouping/grouping.dart';
import '../services/importing/import_service.dart';
import '../services/importing/import_history_service.dart';
import '../services/semantic/mlkit_semantic_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'groups_screen.dart';

import 'import_view_model.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  late final ImportViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = ImportViewModel();
    _viewModel.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  bool get _busy => _viewModel.busy;
  String get _status => _viewModel.status;
  double? get _progress => _viewModel.progress;
  String get _stage => _viewModel.stage;
  DetectionMode get _detectionMode => _viewModel.detectionMode;
  int get _maxCount => _viewModel.maxCount;
  bool get _smartResume => _viewModel.smartResume;
  int get _burstMinutes => _viewModel.burstMinutes;
  int get _burstSeconds => _viewModel.burstSeconds;
  int get _burstWindowSeconds => _viewModel.burstWindowSeconds;

  set _busy(bool v) => _viewModel.setBusy(v);
  set _status(String v) =>
      _viewModel.updateProgress(_viewModel.stage, v, _viewModel.progress);
  set _progress(double? v) =>
      _viewModel.updateProgress(_viewModel.stage, _viewModel.status, v);
  set _stage(String v) =>
      _viewModel.updateProgress(v, _viewModel.status, _viewModel.progress);
  set _detectionMode(DetectionMode v) => _viewModel.setDetectionMode(v);
  set _maxCount(int v) => _viewModel.setMaxCount(v);
  set _smartResume(bool v) => _viewModel.setSmartResume(v);
  set _burstMinutes(int v) =>
      _viewModel.normalizeBurstTotal(v, _viewModel.burstSeconds);
  set _burstSeconds(int v) =>
      _viewModel.normalizeBurstTotal(_viewModel.burstMinutes, v);

  void _normalizeBurstTotal() {
    // Moved to ViewModel, no longer needed here, but kept for compatibility if called directly
  }

  Future<void> _runImportAndAnalyze(
    Future<List<ImportedItem>> Function(
      void Function(int done, int total) onProgress,
    )
    importer,
  ) async {
    // Note: _busy is already set to true by the caller functions.
    // We just update the status text here.
    setState(() {
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
            thumbnailPath: i.thumbnailPath,
            assetId: i.assetId,
            filePath: i.filePath,
            pHashHex: a.pHashHex,
            sharpness: a.sharpness,
            exposureScore: a.exposureScore,
            orbRows: a.orbRows,
            orbCols: a.orbCols,
            orbBytes: a.orbBytes,
            histogram: a.histogram,
            hueHistogram: a.hueHistogram,
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
            debugGridSharps: a.debugGridSharps,
          ),
        );
      }

      // Semantic analysis (Android/iOS only)
      var enrichedEntries = entries;
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
          builder: (_) =>
              GroupsScreen(groups: groups, detectionMode: _detectionMode),
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

  Future<void> _runFileImportAndAnalyze() async {
    if (_busy) return;

    List<File> selectedFiles = [];
    try {
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: [
          'jpg', 'jpeg', 'png', 'tif', 'tiff', 'webp', 'heic', 'heif',
          'dng', 'arw', 'nef', 'cr2', 'cr3', 'raf', 'rw2', 'orf'
        ],
      );
      if (res == null || res.paths.isEmpty) return;
      selectedFiles = res.paths
          .whereType<String>()
          .map((p) => File(p))
          .toList();
    } catch (e) {
      setState(() {
        _status = 'ファイル選択エラー: $e';
      });
      return;
    }

    if (selectedFiles.isEmpty) return;

    setState(() {
      _busy = true;
      _stage = 'スキャン';
      _status = '選択された写真を準備中...';
      _progress = null;
    });

    try {
      // 差分フィルタと最大数制限の適用
      final filteredFiles = <File>[];
      for (final file in selectedFiles) {
        if (filteredFiles.length >= _maxCount) break;
        if (_smartResume) {
          final isDone = await ImportHistoryService.instance.isProcessed(
            'file:${file.path}',
          );
          if (isDone) continue;
        }
        filteredFiles.add(file);
      }

      if (filteredFiles.isEmpty) {
        setState(() {
          _busy = false;
          _status = _smartResume ? '選択された写真はすべて処理済みです' : '写真が見つかりません';
          _stage = '';
        });
        return;
      }

      final filesByDate = <DateTime, List<File>>{};
      for (final file in filteredFiles) {
        try {
          final stat = await file.stat();
          final modDate = stat.modified;
          final dateOnly = DateTime(modDate.year, modDate.month, modDate.day);
          if (!filesByDate.containsKey(dateOnly)) {
            filesByDate[dateOnly] = [];
          }
          filesByDate[dateOnly]!.add(file);
        } catch (_) {
          final now = DateTime.now();
          final dateOnly = DateTime(now.year, now.month, now.day);
          if (!filesByDate.containsKey(dateOnly)) {
            filesByDate[dateOnly] = [];
          }
          filesByDate[dateOnly]!.add(file);
        }
      }

      final scanResult = FolderScanResult(
        folderPath: 'Selected Files',
        filesByDate: filesByDate,
      );

      if (!mounted) return;

      final confirmedFiles = await _showDateSelectionDialog(scanResult);
      if (confirmedFiles == null || confirmedFiles.isEmpty) {
        setState(() {
          _busy = false;
          _status = 'インポートがキャンセルされました';
          _stage = '';
        });
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final tempDirPath = tempDir.path;

      await _runImportAndAnalyze(
        (onProgress) => ImportService.importLocalFiles(
          confirmedFiles,
          thumbnailMaxEdge: 512,
          tempDirPath: tempDirPath,
          onProgress: onProgress,
        ),
      );

      // インポート完了したファイルのキーを履歴に保存
      final importedKeys = confirmedFiles.map((f) => 'file:${f.path}').toList();
      await ImportHistoryService.instance.saveKeys(importedKeys);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'スキャンエラー: $e';
        _stage = '';
      });
    }
  }

  Future<void> _runPhotoLibraryImportAndAnalyze() async {
    if (_busy) return;

    List<File> selectedFiles = [];
    try {
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
      );
      if (res == null || res.paths.isEmpty) return;
      selectedFiles = res.paths
          .whereType<String>()
          .map((p) => File(p))
          .toList();
    } catch (e) {
      setState(() {
        _status = '写真選択エラー: $e';
      });
      return;
    }

    if (selectedFiles.isEmpty) return;

    setState(() {
      _busy = true;
      _stage = 'スキャン';
      _status = '選択された写真を準備中...';
      _progress = null;
    });

    try {
      // 差分フィルタと最大数制限の適用
      final filteredFiles = <File>[];
      for (final file in selectedFiles) {
        if (filteredFiles.length >= _maxCount) break;
        if (_smartResume) {
          final isDone = await ImportHistoryService.instance.isProcessed(
            'file:${file.path}',
          );
          if (isDone) continue;
        }
        filteredFiles.add(file);
      }

      if (filteredFiles.isEmpty) {
        setState(() {
          _busy = false;
          _status = _smartResume ? '選択された写真はすべて処理済みです' : '写真が見つかりません';
          _stage = '';
        });
        return;
      }

      final filesByDate = <DateTime, List<File>>{};
      for (final file in filteredFiles) {
        try {
          final stat = await file.stat();
          final modDate = stat.modified;
          final dateOnly = DateTime(modDate.year, modDate.month, modDate.day);
          if (!filesByDate.containsKey(dateOnly)) {
            filesByDate[dateOnly] = [];
          }
          filesByDate[dateOnly]!.add(file);
        } catch (_) {
          final now = DateTime.now();
          final dateOnly = DateTime(now.year, now.month, now.day);
          if (!filesByDate.containsKey(dateOnly)) {
            filesByDate[dateOnly] = [];
          }
          filesByDate[dateOnly]!.add(file);
        }
      }

      final scanResult = FolderScanResult(
        folderPath: '写真ライブラリ',
        filesByDate: filesByDate,
      );

      if (!mounted) return;

      final confirmedFiles = await _showDateSelectionDialog(scanResult);
      if (confirmedFiles == null || confirmedFiles.isEmpty) {
        setState(() {
          _busy = false;
          _status = 'インポートがキャンセルされました';
          _stage = '';
        });
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final tempDirPath = tempDir.path;

      await _runImportAndAnalyze(
        (onProgress) => ImportService.importLocalFiles(
          confirmedFiles,
          thumbnailMaxEdge: 512,
          tempDirPath: tempDirPath,
          onProgress: onProgress,
        ),
      );

      // インポート完了したファイルのキーを履歴に保存
      final importedKeys = confirmedFiles.map((f) => 'file:${f.path}').toList();
      await ImportHistoryService.instance.saveKeys(importedKeys);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'スキャンエラー: $e';
        _stage = '';
      });
    }
  }

  Future<void> _clearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('履歴のクリア'),
        content: const Text(
          'これまでにインポート・選別処理した写真の履歴をすべて消去しますか？\n(実画像ファイルは削除されません。次回インポート時に最初から再スキャンされるようになります)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('クリア実行'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ImportHistoryService.instance.clearHistory();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('インポート履歴をリセットしました。')));
    }
  }

  Future<List<File>?> _showDateSelectionDialog(
    FolderScanResult scanResult,
  ) async {
    final filesByDate = scanResult.filesByDate;
    final allDates = filesByDate.keys.toList()
      ..sort((a, b) => b.compareTo(a)); // 初期降順

    final selectedDates = <DateTime>{...allDates}; // デフォルト全選択
    bool descending = true;

    return showDialog<List<File>>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            // 表示用のソート済み日付リスト
            final sortedDates = allDates.toList()
              ..sort((a, b) => descending ? b.compareTo(a) : a.compareTo(b));

            // 現在選択されている写真の合計枚数
            int totalSelected = 0;
            final selectedFilesList = <File>[];
            for (final d in selectedDates) {
              final files = filesByDate[d];
              if (files != null) {
                totalSelected += files.length;
                selectedFilesList.addAll(files);
              }
            }

            final isOverLimit = totalSelected > _maxCount;

            return AlertDialog(
              title: const Text('撮影日（日付）で絞り込み'),
              content: Container(
                constraints: const BoxConstraints(maxWidth: 480),
                width: MediaQuery.of(context).size.width * 0.9,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'フォルダ: ${scanResult.folderPath}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    // クイックコントロール行（折り返し対応のWrap）
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Wrap(
                          spacing: 4,
                          children: [
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  selectedDates.addAll(allDates);
                                });
                              },
                              child: const Text('すべて選択'),
                            ),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  selectedDates.clear();
                                });
                              },
                              child: const Text('クリア'),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 期間で選択
                            TextButton.icon(
                              onPressed: () async {
                                final range = await showDateRangePicker(
                                  context: context,
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime.now().add(
                                    const Duration(days: 365),
                                  ),
                                );
                                if (range != null) {
                                  setState(() {
                                    selectedDates.clear();
                                    for (final d in allDates) {
                                      if (d.isAfter(
                                            range.start.subtract(
                                              const Duration(seconds: 1),
                                            ),
                                          ) &&
                                          d.isBefore(
                                            range.end.add(
                                              const Duration(days: 1),
                                            ),
                                          )) {
                                        selectedDates.add(d);
                                      }
                                    }
                                  });
                                }
                              },
                              icon: const Icon(Icons.date_range, size: 16),
                              label: const Text('期間で選択'),
                            ),
                            // ソートトグル
                            IconButton(
                              tooltip: descending ? '新しい順' : '古い順',
                              icon: Icon(
                                descending
                                    ? Icons.arrow_downward
                                    : Icons.arrow_upward,
                              ),
                              onPressed: () {
                                setState(() {
                                  descending = !descending;
                                });
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Divider(),
                    // 日付リスト
                    Flexible(
                      child: Container(
                        height: 240,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: sortedDates.length,
                          itemBuilder: (context, index) {
                            final date = sortedDates[index];
                            final count = filesByDate[date]?.length ?? 0;
                            final dateStr =
                                '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
                            final isChecked = selectedDates.contains(date);

                            return CheckboxListTile(
                              title: Text('$dateStr ($count 枚)'),
                              value: isChecked,
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              onChanged: (val) {
                                setState(() {
                                  if (val == true) {
                                    selectedDates.add(date);
                                  } else {
                                    selectedDates.remove(date);
                                  }
                                });
                              },
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 選択枚数表示と警告
                    Text(
                      '選択中: $totalSelected 枚',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: isOverLimit ? Colors.orange : null,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (isOverLimit)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '※ 最大インポート件数（$_maxCount枚）を超えています。上位 $_maxCount枚のみインポートされます。',
                          style: TextStyle(
                            color: Colors.orange.shade800,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: selectedDates.isEmpty
                      ? null
                      : () {
                          final sortedSelectedDates = selectedDates.toList()
                            ..sort((a, b) => b.compareTo(a));

                          final filesToImport = <File>[];
                          for (final d in sortedSelectedDates) {
                            final files = filesByDate[d];
                            if (files != null) {
                              filesToImport.addAll(files);
                            }
                          }

                          final finalFiles = filesToImport.length > _maxCount
                              ? filesToImport.sublist(0, _maxCount)
                              : filesToImport;

                          Navigator.of(context).pop(finalFiles);
                        },
                  child: const Text('選択してインポート'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 800;
    final isSmallMobile = size.width < 600;

    // 1. Premium Hero Header
    final heroHeader = Container(
      padding: EdgeInsets.all(isSmallMobile ? 12 : 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.primary.withValues(alpha: 0.08),
            colorScheme.secondary.withValues(alpha: 0.03),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.auto_awesome_motion_rounded,
            size: isSmallMobile ? 28 : 40,
            color: colorScheme.primary,
          ),
          SizedBox(height: isSmallMobile ? 8 : 12),
          Text(
            '最高の瞬間を、AIが提案します。',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              fontSize: isSmallMobile ? 14 : null,
              color: Colors.white.withValues(alpha: 0.95),
            ),
          ),
          SizedBox(height: isSmallMobile ? 4 : 6),
          Text(
            '一眼レフやミラーレス of 連写・類似写真を、内容ベースで高速グループ化して「Best」を見つけ出します。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: isSmallMobile ? 10 : null,
              height: 1.4,
            ),
          ),
        ],
      ),
    );

    // 2. Info Card (Tech specs)
    final infoCard = _InfoCard();

    // 3. Parameters Card
    final parametersCard = Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(isSmallMobile ? 12 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.tune_rounded,
                  size: isSmallMobile ? 16 : 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '解析・グループ化設定',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: isSmallMobile ? 14 : null,
                  ),
                ),
              ],
            ),
            SizedBox(height: isSmallMobile ? 10 : 16),
            Text(
              '検出モード',
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: isSmallMobile ? 11 : null,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<DetectionMode>(
              isExpanded: true,
              initialValue: _detectionMode,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: isSmallMobile ? 8 : 12,
                ),
              ),
              items: const [
                DropdownMenuItem(
                  value: DetectionMode.standard,
                  child: Text('標準（全体ピント・構図スコア）'),
                ),
                DropdownMenuItem(
                  value: DetectionMode.portrait,
                  child: Text('ポートレート（顔優先・目閉じ判定）'),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      if (v != null) {
                        setState(() => _detectionMode = v);
                      }
                    },
            ),
            SizedBox(height: isSmallMobile ? 10 : 16),
            Text(
              '連写としてまとめる時間窓',
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: isSmallMobile ? 11 : null,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '合計: ${_formatBurstWindow(_burstWindowSeconds)}（1秒〜60分以内を1グループ化）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: isSmallMobile ? 10 : null,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _burstMinutes.clamp(0, 60),
                    decoration: InputDecoration(
                      labelText: '分',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      isDense: true,
                      contentPadding: isSmallMobile
                          ? const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            )
                          : null,
                    ),
                    items: [
                      for (var i = 0; i <= 60; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(i.toString().padLeft(2, '0')),
                        ),
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
                SizedBox(width: isSmallMobile ? 8 : 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _burstSeconds.clamp(0, 59),
                    decoration: InputDecoration(
                      labelText: '秒',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      isDense: true,
                      contentPadding: isSmallMobile
                          ? const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            )
                          : null,
                    ),
                    items: [
                      for (var i = 0; i < 60; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(i.toString().padLeft(2, '0')),
                        ),
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
            SizedBox(height: isSmallMobile ? 10 : 16),
            Text(
              '最大インポート件数',
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: isSmallMobile ? 11 : null,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: _maxCount,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                isDense: true,
                contentPadding: isSmallMobile
                    ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
                    : null,
              ),
              items: const [
                DropdownMenuItem(value: 50, child: Text('50枚')),
                DropdownMenuItem(value: 100, child: Text('100枚')),
                DropdownMenuItem(value: 200, child: Text('200枚')),
                DropdownMenuItem(value: 500, child: Text('500枚')),
                DropdownMenuItem(value: 1000, child: Text('1000枚')),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() => _maxCount = v);
                    },
            ),
            SizedBox(height: isSmallMobile ? 10 : 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'スマートレジューム（未処理のみ）',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: isSmallMobile ? 11 : null,
                ),
              ),
              subtitle: Text(
                '過去に選別完了した写真をスキップし、前回の続きからインポートします。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: isSmallMobile ? 9 : 10,
                ),
              ),
              value: _smartResume,
              onChanged: _busy ? null : (v) => setState(() => _smartResume = v),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.restore_rounded, size: 16),
              label: const Text('インポート処理履歴をクリア'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: BorderSide(
                  color: Colors.redAccent.withValues(alpha: 0.5),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _busy ? null : _clearHistory,
            ),
          ],
        ),
      ),
    );

    // 4. Hero Import Button (Beautiful Gradient Action Box)
    Widget? importButton;
    if (!_busy) {
      final photoLibraryBtn = Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withValues(alpha: 0.3),
              blurRadius: 12,
              spreadRadius: 1,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _runPhotoLibraryImportAndAnalyze,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: isSmallMobile ? 14 : 20,
                horizontal: 12,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(isSmallMobile ? 6 : 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.photo_library_rounded,
                      size: isSmallMobile ? 22 : 28,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: isSmallMobile ? 6 : 10),
                  Text(
                    '写真ライブラリからインポート',
                    style: TextStyle(
                      fontSize: isSmallMobile ? 13 : 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'iPad本体の写真から一括インポートします',
                    style: TextStyle(
                      fontSize: isSmallMobile ? 9 : 10,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final filePickerBtn = Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0D9488), Color(0xFF0F766E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0D9488).withValues(alpha: 0.3),
              blurRadius: 12,
              spreadRadius: 1,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _runFileImportAndAnalyze,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: isSmallMobile ? 14 : 20,
                horizontal: 12,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(isSmallMobile ? 6 : 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.file_open_rounded,
                      size: isSmallMobile ? 22 : 28,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: isSmallMobile ? 6 : 10),
                  Text(
                    'ファイルからインポート',
                    style: TextStyle(
                      fontSize: isSmallMobile ? 13 : 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'ファイル選択画面から複数写真を選択します',
                    style: TextStyle(
                      fontSize: isSmallMobile ? 9 : 10,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      importButton = isWide
          ? Row(
              children: [
                Expanded(child: photoLibraryBtn),
                const SizedBox(width: 16),
                Expanded(child: filePickerBtn),
              ],
            )
          : Column(
              children: [
                photoLibraryBtn,
                const SizedBox(height: 12),
                filePickerBtn,
              ],
            );
    }

    // 5. Status and Progress Display
    Widget? progressDisplay;
    if (_busy) {
      progressDisplay = Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colorScheme.primary.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(strokeWidth: 3.5),
            ),
            const SizedBox(height: 16),
            if (_stage.isNotEmpty)
              Text(
                _stage,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.primary,
                ),
              ),
            const SizedBox(height: 6),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
            if (_progress != null) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 8,
                  backgroundColor: colorScheme.primary.withValues(alpha: 0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${(_progress! * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      );
    }

    // 6. Non-busy error/info status
    Widget? errorDisplay;
    if (!_busy && _status.isNotEmpty) {
      errorDisplay = Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _status.contains('エラー')
                ? colorScheme.error.withValues(alpha: 0.12)
                : colorScheme.secondary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _status.contains('エラー')
                  ? colorScheme.error.withValues(alpha: 0.3)
                  : colorScheme.secondary.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Icon(
                _status.contains('エラー')
                    ? Icons.error_outline_rounded
                    : Icons.info_outline_rounded,
                color: _status.contains('エラー')
                    ? colorScheme.error
                    : colorScheme.secondary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _status,
                  style: TextStyle(
                    color: _status.contains('エラー')
                        ? colorScheme.error
                        : Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFF818CF8), Color(0xFF34D399)], // Indigo to Emerald
          ).createShader(bounds),
          child: const Text(
            'BestShot',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 24,
              letterSpacing: 1.5,
              color: Colors.white,
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 1150 : 580),
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isSmallMobile ? 16 : 24,
              vertical: isSmallMobile ? 12 : 20,
            ),
            child: isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 左カラム (説明、インポートボタン、進捗、InfoCard)
                      Expanded(
                        flex: 6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            heroHeader,
                            const SizedBox(height: 24),
                            ?importButton,
                            ?progressDisplay,
                            ?errorDisplay,
                            const SizedBox(height: 24),
                            infoCard,
                          ],
                        ),
                      ),
                      const SizedBox(width: 24),
                      // 右カラム (設定パネル)
                      Expanded(flex: 4, child: parametersCard),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      heroHeader,
                      SizedBox(height: isSmallMobile ? 12 : 20),
                      infoCard,
                      SizedBox(height: isSmallMobile ? 12 : 20),
                      parametersCard,
                      SizedBox(height: isSmallMobile ? 16 : 24),
                      ?importButton,
                      ?progressDisplay,
                      ?errorDisplay,
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.analytics_rounded,
              color: colorScheme.secondary,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI判定ロジックについて',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  DefaultTextStyle(
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: Colors.white.withValues(alpha: 0.65),
                      height: 1.4,
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('• 類似グルーピング: 高精度PerceptualHash (pHash) 解析'),
                        Text('• ピント解像評価: OpenCV Laplacian分散 による輪郭抽出'),
                        Text('• メモリ保護: 画像の軽量サムネイル化 ＆ 別Isolateでの並列解析'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
