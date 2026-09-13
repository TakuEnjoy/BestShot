import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/navigation/fast_route.dart';
import '../models/photo_entry.dart';
import '../models/photo_group.dart';
import '../theme/bestshot_theme.dart';
import 'groups_screen.dart' show getFolderColor;
import 'loupe_screen.dart';

class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({
    super.key,
    required this.group,
    required this.selectedForDelete,
    this.selectedForDeleteNotifier,
    required this.onToggleDelete,
    required this.loupeSelection,
    required this.onToggleLoupe,
    required this.onSetBest,
    required this.selectedSortFolders,
    required this.customFolders,
    required this.onSortFolderChanged,
    required this.processingKeys,
  });

  final PhotoGroup group;
  final Set<String> selectedForDelete;
  final ValueNotifier<Set<String>>? selectedForDeleteNotifier;
  final void Function(String key, bool selected) onToggleDelete;
  final List<String> loupeSelection;
  final void Function(String key) onToggleLoupe;
  final ValueChanged<String> onSetBest;
  final Map<String, String> selectedSortFolders;
  final List<String> customFolders;
  final void Function(String key, String? folder) onSortFolderChanged;
  final Set<String> processingKeys;

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  late List<PhotoEntry> _items;
  late final ValueNotifier<String> _activeKeyNotifier;
  late final ValueNotifier<Set<String>> _deleteSelectionNotifier;
  bool _sortByQuality = false;

  // キャッシュ (Step 4: 重い初期化処理の非同期化・キャッシュ化)
  final Map<String, int> _qualityScores = {};
  final Map<String, int> _noiseScores = {};
  final Map<String, int> _compositionScores = {};
  final Map<String, String> _fileSizeCache = {};

  // BottomSheet controller / state
  final DraggableScrollableController _sheetController = DraggableScrollableController();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _items = List.of(widget.group.items);
    final initialActiveKey = widget.group.bestKey.isNotEmpty
        ? widget.group.bestKey
        : (_items.isNotEmpty ? _items.first.key : '');
    _activeKeyNotifier = ValueNotifier<String>(initialActiveKey);
    _deleteSelectionNotifier = widget.selectedForDeleteNotifier ??
        ValueNotifier<Set<String>>(Set.of(widget.selectedForDelete));

    _precomputeScores();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _activeKeyNotifier.dispose();
    if (widget.selectedForDeleteNotifier == null) {
      _deleteSelectionNotifier.dispose();
    }
    _sheetController.dispose();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    final activeKey = _activeKeyNotifier.value;

    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.keyD ||
        key == LogicalKeyboardKey.keyX) {
      if (activeKey.isNotEmpty) {
        final current = _deleteSelectionNotifier.value;
        final next = Set<String>.from(current);
        final nextState = !current.contains(activeKey);
        if (nextState) {
          next.add(activeKey);
        } else {
          next.remove(activeKey);
        }
        _deleteSelectionNotifier.value = next;
        widget.onToggleDelete(activeKey, nextState);
        return true;
      }
    }

    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowDown) {
      final idx = _items.indexWhere((e) => e.key == activeKey);
      if (idx >= 0 && idx < _items.length - 1) {
        _activeKeyNotifier.value = _items[idx + 1].key;
        return true;
      }
    }

    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowUp) {
      final idx = _items.indexWhere((e) => e.key == activeKey);
      if (idx > 0) {
        _activeKeyNotifier.value = _items[idx - 1].key;
        return true;
      }
    }

    return false;
  }

  void _precomputeScores() {
    for (final e in _items) {
      _qualityScores[e.key] = _calculateQualityScoreRaw(e);
      _noiseScores[e.key] = _calculateNoiseScoreRaw(e);
      _compositionScores[e.key] = _calculateCompositionScoreRaw(e);
      _fileSizeCache[e.key] = _formatFileSizeRaw(e);
    }
  }

  int _getQualityScore(PhotoEntry e) => _qualityScores[e.key] ?? _calculateQualityScoreRaw(e);
  int _getNoiseScore(PhotoEntry e) => _noiseScores[e.key] ?? _calculateNoiseScoreRaw(e);
  int _getCompositionScore(PhotoEntry e) => _compositionScores[e.key] ?? _calculateCompositionScoreRaw(e);
  String _getFileSize(PhotoEntry e) => _fileSizeCache[e.key] ?? _formatFileSizeRaw(e);

  void _toggleSortQuality() {
    setState(() {
      _sortByQuality = !_sortByQuality;
      if (_sortByQuality) {
        _items.sort((a, b) => b.sharpness.compareTo(a.sharpness));
      } else {
        _items = List.of(widget.group.items);
      }
    });
  }

  void _selectAllForDelete() {
    final current = _deleteSelectionNotifier.value;
    final allMarked = _items.every((e) => current.contains(e.key));
    final next = Set<String>.from(current);
    for (final e in _items) {
      if (e.key != widget.group.bestKey) {
        if (allMarked) {
          next.remove(e.key);
          widget.onToggleDelete(e.key, false);
        } else {
          next.add(e.key);
          widget.onToggleDelete(e.key, true);
        }
      }
    }
    _deleteSelectionNotifier.value = next;
  }

  void _clearAllDelete() {
    final current = _deleteSelectionNotifier.value;
    final next = Set<String>.from(current);
    for (final e in _items) {
      if (next.contains(e.key)) {
        next.remove(e.key);
        widget.onToggleDelete(e.key, false);
      }
    }
    _deleteSelectionNotifier.value = next;
  }

  int _calculateQualityScoreRaw(PhotoEntry e) {
    // 0..100 quality metric
    final sNorm = ((e.sharpness / 6.0).clamp(0.0, 100.0) * 0.4);
    final eNorm = ((e.exposureScore * 100.0).clamp(0.0, 100.0) * 0.3);
    final faceScore = (e.portrait.faceSharpness > 0 ? (e.portrait.faceSharpness / 6.0).clamp(0.0, 100.0) : 80.0) * 0.3;
    final total = (sNorm + eNorm + faceScore).round().clamp(10, 99);
    return total;
  }

  int _calculateNoiseScoreRaw(PhotoEntry e) {
    final iso = int.tryParse(e.exif?.iso ?? '');
    if (iso == null || iso <= 0) return 82;
    if (iso <= 200) return 94;
    if (iso <= 800) return 86;
    if (iso <= 3200) return 74;
    return 60;
  }

  int _calculateCompositionScoreRaw(PhotoEntry e) {
    final fp = e.focusPoint;
    if (fp == null) return 85;
    // Rule of thirds lines: 0.333, 0.667
    final dxDist = ((fp.dx - 0.333).abs()).clamp(0.0, 1.0);
    final dxDist2 = ((fp.dx - 0.667).abs()).clamp(0.0, 1.0);
    final bestX = dxDist < dxDist2 ? dxDist : dxDist2;
    final score = (95 - (bestX * 40)).round().clamp(70, 98);
    return score;
  }

  String _getFocusPointDescription(PhotoEntry e) {
    final fp = e.focusPoint;
    if (fp == null) return '中央';
    final x = fp.dx;
    final y = fp.dy;
    String horiz = '中央';
    if (x < 0.38) horiz = '左';
    if (x > 0.62) horiz = '右';

    String vert = '';
    if (y < 0.38) vert = '上';
    if (y > 0.62) vert = '下';

    if (horiz == '中央' && vert.isEmpty) return '中央';
    if (horiz == '中央') return vert;
    if (vert.isEmpty) return horiz;
    return '$vertやや$horiz';
  }

  String _formatFileSizeRaw(PhotoEntry e) {
    if (e.filePath != null) {
      try {
        final f = File(e.filePath!);
        if (f.existsSync()) {
          final bytes = f.lengthSync();
          final mb = bytes / (1024 * 1024);
          return '${mb.toStringAsFixed(1)}MB';
        }
      } catch (_) {}
    }
    final approxMb = (e.displayBytes.length * 8) / (1024 * 1024);
    return '${approxMb.toStringAsFixed(1)}MB';
  }

  String _formatResolution(PhotoEntry e) {
    if (e.exif != null) {
      // Return representative resolution or aspect ratio
      return '4000×3000';
    }
    return '4000×3000';
  }

  String _getTimeRange() {
    if (_items.isEmpty) return '';
    final times = _items.map((e) => e.capturedAt).whereType<DateTime>().toList()..sort();
    if (times.isEmpty) return '時刻不明';
    final first = times.first;
    final last = times.last;
    final fStr = '${first.year}-${first.month.toString().padLeft(2, '0')}-${first.day.toString().padLeft(2, '0')} ${first.hour.toString().padLeft(2, '0')}:${first.minute.toString().padLeft(2, '0')}';
    if (first == last) return fStr;
    final lStr = '${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}';
    return '$fStr - $lStr';
  }

  String _getBurstInfo() {
    if (!widget.group.isBurst) return '📷 単写';
    final times = _items.map((e) => e.capturedAt).whereType<DateTime>().toList()..sort();
    if (times.length < 2) return '📷 連写';
    final diffMs = times.last.difference(times.first).inMilliseconds;
    final sec = (diffMs / 1000.0).toStringAsFixed(1);
    return '📷 連写 ($sec秒間)';
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    // 横の長さに応じて2列か3列配置
    final crossAxisCount = width >= 1000 ? 3 : 2;

    return Scaffold(
      backgroundColor: BestShotTheme.backgroundPrimary,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. トップバー (高さ56dp)
                _buildTopBar(context),

                // 2. グループ情報行
                _buildGroupInfoRow(),

                // 3. アクションバー
                _buildActionBar(context),

                // 4. 画像グリッド
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 100), // Bottom padding for sheet
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                      childAspectRatio: 1.0, // 1:1 正方形
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return _buildGridThumbnail(item);
                    },
                  ),
                ),
              ],
            ),

            // 5. ドラッガブル・ボトムシート (Section 4.3: 最小化80dp ⇄ 展開40%)
            _buildInspectionBottomSheet(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: BestShotTheme.backgroundPrimary,
        border: Border(bottom: BorderSide(color: BestShotTheme.dividerColor, width: 1)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '戻る',
            icon: const Icon(Icons.arrow_back, color: BestShotTheme.textPrimary, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: 'グループ #${widget.group.id} ',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: BestShotTheme.textPrimary,
                ),
                children: [
                  TextSpan(
                    text: '(${_items.length}枚)',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: BestShotTheme.textSecondary,
                    ),
                  ),
                ],
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          // Best抽出ボタン
          TextButton.icon(
            onPressed: () {
              HapticFeedback.selectionClick();
              final next = Set<String>.from(_deleteSelectionNotifier.value);
              for (final item in _items) {
                if (item.key != widget.group.bestKey) {
                  next.add(item.key);
                  widget.onToggleDelete(item.key, true);
                } else {
                  next.remove(item.key);
                  widget.onToggleDelete(item.key, false);
                }
              }
              _deleteSelectionNotifier.value = next;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Best 以外の写真を削除予定に設定しました')),
              );
            },
            icon: const Icon(Icons.star_rounded, size: 16, color: BestShotTheme.accentGold),
            label: const Text(
              'Best抽出',
              style: TextStyle(
                color: BestShotTheme.accentGold,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 4),
          // ルーペ比較ボタン
          IconButton(
            tooltip: 'ルーペで比較',
            icon: const Icon(Icons.zoom_in, color: BestShotTheme.accentBlue, size: 22),
            onPressed: () {
              final targets = widget.loupeSelection.isNotEmpty
                  ? widget.loupeSelection.map((k) => _items.firstWhere((e) => e.key == k, orElse: () => _items.first)).toList()
                  : _items.take(4).toList();
              for (final item in targets.take(4)) {
                precacheImage(MemoryImage(item.displayBytes), context);
              }
              Navigator.of(context).push(
                FastRoute(
                  builder: (context) => LoupeScreen(
                    items: targets,
                    scores: targets.map((e) => e.sharpness).toList(),
                    isBests: targets.map((e) => e.key == widget.group.bestKey).toList(),
                    initialSelectedForDelete: _deleteSelectionNotifier.value,
                    onToggleDelete: (k, v) {
                      widget.onToggleDelete(k, v);
                      final current = _deleteSelectionNotifier.value;
                      final next = Set<String>.from(current);
                      if (v) {
                        next.add(k);
                      } else {
                        next.remove(k);
                      }
                      _deleteSelectionNotifier.value = next;
                    },
                    onSetBest: (k) {
                      widget.onSetBest(k);
                      setState(() {});
                    },
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildGroupInfoRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: BestShotTheme.surfaceColor,
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.calendar_today_outlined, size: 13, color: BestShotTheme.textSecondary),
              const SizedBox(width: 6),
              Text(
                _getTimeRange(),
                style: const TextStyle(fontSize: 12, color: BestShotTheme.textSecondary),
              ),
            ],
          ),
          Text(
            _getBurstInfo(),
            style: const TextStyle(fontSize: 12, color: BestShotTheme.textSecondary),
          ),
          if (widget.group.needsReview)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: BestShotTheme.accentRed.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: BestShotTheme.accentRed, width: 1),
              ),
              child: const Text(
                '要確認',
                style: TextStyle(
                  fontSize: 10,
                  color: BestShotTheme.accentRed,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActionBar(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: const BoxDecoration(
        color: BestShotTheme.backgroundPrimary,
        border: Border(bottom: BorderSide(color: BestShotTheme.dividerColor, width: 1)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ValueListenableBuilder<Set<String>>(
            valueListenable: _deleteSelectionNotifier,
            builder: (context, deleteSet, _) {
              final allMarked = _items.every((e) => deleteSet.contains(e.key));
              final hasMarked = _items.any((e) => deleteSet.contains(e.key));
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 全選択 / 解除
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: const Size(0, 30),
                      side: const BorderSide(color: BestShotTheme.dividerColor),
                    ),
                    onPressed: _selectAllForDelete,
                    child: Text(
                      allMarked ? '選択全解除' : '全選択',
                      style: const TextStyle(fontSize: 12, color: BestShotTheme.textPrimary),
                    ),
                  ),
                  if (hasMarked) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 30),
                        side: const BorderSide(color: BestShotTheme.dividerColor),
                      ),
                      onPressed: _clearAllDelete,
                      child: const Text(
                        '削除予定を解除',
                        style: TextStyle(fontSize: 12, color: BestShotTheme.accentRed),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),

          // 品質ソート
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: const Size(0, 30),
              side: BorderSide(
                color: _sortByQuality ? BestShotTheme.accentBlue : BestShotTheme.dividerColor,
              ),
              backgroundColor: _sortByQuality
                  ? BestShotTheme.accentBlue.withValues(alpha: 0.15)
                  : Colors.transparent,
            ),
            onPressed: _toggleSortQuality,
            icon: Icon(
              Icons.bar_chart,
              size: 14,
              color: _sortByQuality ? BestShotTheme.accentBlue : BestShotTheme.textSecondary,
            ),
            label: Text(
              '品質ソート',
              style: TextStyle(
                fontSize: 12,
                color: _sortByQuality ? BestShotTheme.accentBlue : BestShotTheme.textPrimary,
              ),
            ),
          ),

          // テンキー仕分けヒント (Windows)
          if (!Platform.isAndroid && !Platform.isIOS)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '1〜9: 仕分け',
                style: TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGridThumbnail(PhotoEntry item) {
    final isBest = item.key == widget.group.bestKey;
    final isLoupeSelected = widget.loupeSelection.contains(item.key);
    final sortFolder = widget.selectedSortFolders[item.key];
    final hasFolder = sortFolder != null;
    final qualityScore = _getQualityScore(item);

    return RepaintBoundary(
      child: ValueListenableBuilder<String>(
        valueListenable: _activeKeyNotifier,
        builder: (context, activeKey, _) {
          final isActive = item.key == activeKey;
          return ValueListenableBuilder<Set<String>>(
            valueListenable: _deleteSelectionNotifier,
            builder: (context, deleteSet, _) {
              final isSelectedForDelete = deleteSet.contains(item.key);

              Color borderColor = Colors.transparent;
              double borderWidth = 0;
              if (isSelectedForDelete) {
                borderColor = BestShotTheme.accentRed;
                borderWidth = 2.0;
              } else if (isActive) {
                borderColor = BestShotTheme.accentBlue;
                borderWidth = 2.0;
              } else if (hasFolder) {
                borderColor = getFolderColor(sortFolder, widget.customFolders);
                borderWidth = 2.0;
              }

              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  _activeKeyNotifier.value = item.key;
                },
                onDoubleTap: () {
                  final best = widget.group.items.firstWhere(
                    (e) => e.key == widget.group.bestKey,
                    orElse: () => widget.group.items.first,
                  );
                  final compareItems = best.key == item.key
                      ? (widget.group.items.length > 1
                          ? [best, widget.group.items.firstWhere((e) => e.key != best.key)]
                          : [best])
                      : [best, item];
                  precacheImage(MemoryImage(item.displayBytes), context);
                  Navigator.of(context).push(
                    FastRoute(
                      builder: (context) => LoupeScreen(
                        items: compareItems,
                        scores: compareItems.map((e) => e.sharpness).toList(),
                        isBests: compareItems.map((e) => e.key == widget.group.bestKey).toList(),
                        initialSelectedForDelete: _deleteSelectionNotifier.value,
                        onToggleDelete: (k, val) {
                          final current = _deleteSelectionNotifier.value;
                          final next = Set<String>.from(current);
                          if (val) {
                            next.add(k);
                          } else {
                            next.remove(k);
                          }
                          _deleteSelectionNotifier.value = next;
                          widget.onToggleDelete(k, val);
                        },
                        onSetBest: (k) {
                          widget.onSetBest(k);
                        },
                      ),
                    ),
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: BestShotTheme.surfaceColor,
                    borderRadius: BorderRadius.circular(4),
                    border: borderWidth > 0 ? Border.all(color: borderColor, width: borderWidth) : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 画像サムネイル (1:1 正方形クロップ)
                      Image.memory(
                        item.displayBytes,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        cacheWidth: 320,
                      ),

                      // 削除マーク時のダーク半透明オーバーレイ (saveLayerを回避)
                      if (isSelectedForDelete)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.55),
                          ),
                        ),

                      // Best Shot ゴールド角バッジ (⭐)
                      if (isBest)
                        Positioned(
                          top: 0,
                          left: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: const BoxDecoration(
                              color: BestShotTheme.accentGold,
                              borderRadius: BorderRadius.only(bottomRight: Radius.circular(4)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.star, size: 12, color: BestShotTheme.backgroundPrimary),
                                SizedBox(width: 2),
                                Text(
                                  'Best',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: BestShotTheme.backgroundPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // 削除予定 🗑️ アイコン (右上 - タップでトグル)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            final current = _deleteSelectionNotifier.value;
                            final next = Set<String>.from(current);
                            final nextState = !isSelectedForDelete;
                            if (nextState) {
                              next.add(item.key);
                            } else {
                              next.remove(item.key);
                            }
                            _deleteSelectionNotifier.value = next;
                            widget.onToggleDelete(item.key, nextState);
                          },
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: isSelectedForDelete
                                  ? BestShotTheme.accentRed
                                  : Colors.black.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(
                                color: isSelectedForDelete
                                    ? BestShotTheme.accentRed
                                    : Colors.white.withValues(alpha: 0.6),
                                width: 1,
                              ),
                            ),
                            child: Icon(
                              isSelectedForDelete ? Icons.delete : Icons.delete_outline,
                              size: 13,
                              color: isSelectedForDelete ? Colors.white : Colors.white70,
                            ),
                          ),
                        ),
                      ),

                      // ルーペ選択インジケーター
                      if (isLoupeSelected)
                        Positioned(
                          top: isBest ? 26 : 4,
                          left: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: BestShotTheme.accentBlue,
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              'L${widget.loupeSelection.indexOf(item.key) + 1}',
                              style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),

                      // 写真上オーバーレイ: #000000 40% Opacity 半透明バー (下部)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.4),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          child: Row(
                            children: [
                              // 品質スコア
                              Text(
                                '$qualityScore点',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: BestShotTheme.textPrimary,
                                ),
                              ),

                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildInspectionBottomSheet() {
    return ValueListenableBuilder<String>(
      valueListenable: _activeKeyNotifier,
      builder: (context, activeKey, _) {
        final activeEntry = _items.firstWhere(
          (e) => e.key == activeKey,
          orElse: () => _items.first,
        );

        return ValueListenableBuilder<Set<String>>(
          valueListenable: _deleteSelectionNotifier,
          builder: (context, deleteSet, _) {
            final isSelectedForDelete = deleteSet.contains(activeEntry.key);
            final isBest = activeEntry.key == widget.group.bestKey;
            final qualityScore = _getQualityScore(activeEntry);
            final sharpnessScore = ((activeEntry.sharpness / 6.0).clamp(0.0, 100.0)).round();
            final exposureScore = (activeEntry.exposureScore * 100.0).round().clamp(0, 100);
            final noiseScore = _getNoiseScore(activeEntry);
            final compositionScore = _getCompositionScore(activeEntry);
            final focusPos = _getFocusPointDescription(activeEntry);
            final filename = p.basename(activeEntry.filePath ?? 'DSC_${activeEntry.key.substring(0, 4)}.JPG');
            final fileSize = _getFileSize(activeEntry);

            return RepaintBoundary(
              child: DraggableScrollableSheet(
                controller: _sheetController,
                initialChildSize: 0.12, // ~80dp 相当
                minChildSize: 0.10,
                maxChildSize: 0.45,    // 展開時 ~40%
                snap: true,
                snapSizes: const [0.10, 0.45],
                builder: (context, scrollController) {
                  return Container(
                    decoration: const BoxDecoration(
                      color: BestShotTheme.surfaceColor,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
                      border: Border(
                        top: BorderSide(color: BestShotTheme.dividerColor, width: 1),
                        left: BorderSide(color: BestShotTheme.dividerColor, width: 1),
                        right: BorderSide(color: BestShotTheme.dividerColor, width: 1),
                      ),
                    ),
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      children: [
                        // ドラッグハンドル ≡
                        Center(
                          child: Container(
                            width: 32,
                            height: 4,
                            decoration: BoxDecoration(
                              color: BestShotTheme.dividerColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),

                        // 最小化時に常に見える行: 📊 選択中ファイル名 + 品質スコア
                        Row(
                          children: [
                            const Icon(Icons.bar_chart, size: 16, color: BestShotTheme.accentGold),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '選択中: $filename',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: BestShotTheme.textPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '$qualityScore 点',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: BestShotTheme.accentGold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // 展開時に見える詳細エリア (Section 2.2 / 4.3)
                        // 1. ファイル名 │ 解像度 │ 容量
                        Row(
                          children: [
                            const Icon(Icons.insert_drive_file_outlined, size: 13, color: BestShotTheme.textSecondary),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                filename,
                                style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('│', style: TextStyle(color: BestShotTheme.dividerColor)),
                            const SizedBox(width: 8),
                            const Icon(Icons.aspect_ratio, size: 13, color: BestShotTheme.textSecondary),
                            const SizedBox(width: 4),
                            Text(
                              _formatResolution(activeEntry),
                              style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
                            ),
                            const SizedBox(width: 8),
                            Text('│', style: TextStyle(color: BestShotTheme.dividerColor)),
                            const SizedBox(width: 8),
                            const Icon(Icons.sd_storage_outlined, size: 13, color: BestShotTheme.textSecondary),
                            const SizedBox(width: 4),
                            Text(
                              fileSize,
                              style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // 2. ピント位置バー
                        RepaintBoundary(
                          child: _buildMetricBar(
                            icon: Icons.center_focus_strong,
                            label: 'ピント',
                            score: sharpnessScore,
                            extraText: '($focusPos)',
                            barColor: BestShotTheme.accentGreen,
                          ),
                        ),
                        const SizedBox(height: 8),

                        // 3. 総合品質バー
                        RepaintBoundary(
                          child: _buildMetricBar(
                            icon: Icons.star_border,
                            label: '品質',
                            score: qualityScore,
                            extraText: '点',
                            barColor: BestShotTheme.accentGold,
                          ),
                        ),
                        const SizedBox(height: 6),

                        // 4. 内訳インジケーター (シャープネス、露出、ノイズ、構図)
                        RepaintBoundary(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 20),
                            child: Column(
                              children: [
                                _buildSubMetricRow('シャープネス', sharpnessScore, BestShotTheme.accentBlue),
                                const SizedBox(height: 4),
                                _buildSubMetricRow('露出', exposureScore, BestShotTheme.accentGold),
                                const SizedBox(height: 4),
                                _buildSubMetricRow('ノイズ', noiseScore, BestShotTheme.textSecondary),
                                const SizedBox(height: 4),
                                _buildSubMetricRow('構図', compositionScore, BestShotTheme.accentGreen),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // 5. アクションボタン: [🔴 削除予定に追加/解除]  [⭐ Best推薦]
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: isSelectedForDelete
                                        ? BestShotTheme.accentRed
                                        : BestShotTheme.dividerColor,
                                  ),
                                  backgroundColor: isSelectedForDelete
                                      ? BestShotTheme.accentRed.withValues(alpha: 0.15)
                                      : Colors.transparent,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                onPressed: () {
                                  HapticFeedback.selectionClick();
                                  final current = _deleteSelectionNotifier.value;
                                  final next = Set<String>.from(current);
                                  final nextState = !isSelectedForDelete;
                                  if (nextState) {
                                    next.add(activeEntry.key);
                                  } else {
                                    next.remove(activeEntry.key);
                                  }
                                  _deleteSelectionNotifier.value = next;
                                  widget.onToggleDelete(activeEntry.key, nextState);
                                },
                                icon: Icon(
                                  Icons.delete_outline,
                                  size: 16,
                                  color: isSelectedForDelete
                                      ? BestShotTheme.accentRed
                                      : BestShotTheme.textSecondary,
                                ),
                                label: Text(
                                  isSelectedForDelete ? '削除予定を解除' : '削除予定に追加',
                                  style: TextStyle(
                                    color: isSelectedForDelete
                                        ? BestShotTheme.accentRed
                                        : BestShotTheme.textPrimary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isBest
                                      ? BestShotTheme.accentGold
                                      : BestShotTheme.surfaceColor,
                                  foregroundColor: isBest
                                      ? BestShotTheme.backgroundPrimary
                                      : BestShotTheme.accentGold,
                                  side: BorderSide(
                                    color: BestShotTheme.accentGold,
                                    width: isBest ? 0 : 1,
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                onPressed: () {
                                  HapticFeedback.selectionClick();
                                  widget.onSetBest(activeEntry.key);
                                  setState(() {});
                                },
                                icon: Icon(
                                  isBest ? Icons.star : Icons.star_border,
                                  size: 16,
                                  color: isBest
                                      ? BestShotTheme.backgroundPrimary
                                      : BestShotTheme.accentGold,
                                ),
                                label: Text(
                                  isBest ? 'Best Shot中' : 'Best推薦に設定',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: isBest
                                        ? BestShotTheme.backgroundPrimary
                                        : BestShotTheme.accentGold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMetricBar({
    required IconData icon,
    required String label,
    required int score,
    required String extraText,
    required Color barColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: barColor),
        const SizedBox(width: 6),
        SizedBox(
          width: 50,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: BestShotTheme.textPrimary, fontWeight: FontWeight.w500),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: (score / 100.0).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: BestShotTheme.dividerColor,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '$score% $extraText',
          style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
        ),
      ],
    );
  }

  Widget _buildSubMetricRow(String label, int score, Color barColor) {
    return Row(
      children: [
        Text('├ ', style: TextStyle(color: BestShotTheme.dividerColor, fontSize: 11)),
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
          ),
        ),
        SizedBox(
          width: 30,
          child: Text(
            '$score',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: BestShotTheme.textPrimary),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: (score / 100.0).clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: BestShotTheme.dividerColor,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ),
      ],
    );
  }
}
