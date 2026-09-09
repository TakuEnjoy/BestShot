part of '../groups_screen.dart';

class _ExpandableGroupCard extends StatelessWidget {
  const _ExpandableGroupCard({
    required this.group,
    required this.selectedForDelete,
    required this.onToggleDelete,
    required this.loupeSelection,
    required this.onToggleLoupe,
    required this.onSelectBestOnly,
    required this.onSetBest,
    required this.isKeyboardGroupFocused,
    required this.keyboardPhotoKey,
    required this.onPhotoTileFocused,
    required this.selectedSortFolders,
    required this.onSortFolderChanged,
    required this.customFolders,
    required this.processingKeys,
    this.onOpenDetail,
  });

  final PhotoGroup group;
  final Set<String> selectedForDelete;
  final void Function(String key, bool selected) onToggleDelete;
  final List<String> loupeSelection;
  final void Function(String key) onToggleLoupe;
  final VoidCallback onSelectBestOnly;
  final ValueChanged<String> onSetBest;
  final bool isKeyboardGroupFocused;
  final String? keyboardPhotoKey;
  final ValueChanged<String> onPhotoTileFocused;
  final Map<String, String> selectedSortFolders;
  final void Function(String key, String? folder) onSortFolderChanged;
  final List<String> customFolders;
  final Set<String> processingKeys;
  final VoidCallback? onOpenDetail;

  int _getPHashSimilarity() {
    return 94;
  }

  @override
  Widget build(BuildContext context) {
    final best = group.items.firstWhere(
      (e) => e.key == group.bestKey,
      orElse: () => group.items.first,
    );

    final deleteCountInGroup = group.items.where((e) => selectedForDelete.contains(e.key)).length;
    final matchRate = group.geometricMatchRate;
    final pHashRate = _getPHashSimilarity();
    final timeStr = group.timeRange;
    final burstStr = group.burstDuration;

    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: BestShotTheme.surfaceColor,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isKeyboardGroupFocused
                ? BestShotTheme.accentBlue
                : (group.needsReview ? BestShotTheme.accentRed : BestShotTheme.dividerColor),
            width: isKeyboardGroupFocused ? 2.0 : 1.0,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. ヘッダー行 (グループID, 枚数, 削除候補ボタン, ステータスバッジ, 詳細ボタン)
            Row(
              children: [
                // グループID
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isKeyboardGroupFocused
                        ? BestShotTheme.accentBlue
                        : BestShotTheme.hoverColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    '#${group.id}',
                    style: TextStyle(
                      color: isKeyboardGroupFocused
                          ? BestShotTheme.backgroundPrimary
                          : BestShotTheme.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${group.items.length}枚',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: BestShotTheme.textPrimary,
                  ),
                ),
                const SizedBox(width: 10),

                // Best以外を削除候補に ボタン
                OutlinedButton.icon(
                  onPressed: onSelectBestOnly,
                  icon: const Icon(Icons.playlist_remove, size: 14, color: BestShotTheme.accentRed),
                  label: const Text(
                    'Best以外を削除候補に',
                    style: TextStyle(fontSize: 11, color: BestShotTheme.textPrimary),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: const BorderSide(color: BestShotTheme.dividerColor, width: 1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    backgroundColor: BestShotTheme.surfaceColor,
                  ),
                ),
                const SizedBox(width: 8),

                // ステータスバッジ群
                _Badge(
                  label: group.isBurst ? '📷 連写' : '📷 単写',
                  color: BestShotTheme.hoverColor,
                  textColor: BestShotTheme.textPrimary,
                ),
                const SizedBox(width: 6),
                _Badge(
                  label: '🔍 一致率 $matchRate%',
                  color: BestShotTheme.hoverColor,
                  textColor: BestShotTheme.accentBlue,
                ),
                if (group.bestKey.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  const _Badge(
                    label: '⭐ Best済',
                    color: Color(0xFF332600),
                    textColor: BestShotTheme.accentGold,
                  ),
                ],
                if (deleteCountInGroup > 0) ...[
                  const SizedBox(width: 6),
                  _Badge(
                    label: '🟡 削除予定 $deleteCountInGroup枚',
                    color: const Color(0xFF330018),
                    textColor: BestShotTheme.accentRed,
                  ),
                ],
                if (group.needsReview) ...[
                  const SizedBox(width: 6),
                  const _Badge(
                    label: '⚠ 要確認',
                    color: Color(0xFF330018),
                    textColor: BestShotTheme.accentRed,
                  ),
                ],

                const Spacer(),

                // 詳細インスペクション画面への遷移ボタン
                if (onOpenDetail != null)
                  IconButton(
                    icon: const Icon(Icons.analytics_outlined, size: 16, color: BestShotTheme.textSecondary),
                    tooltip: '詳細スコア・EXIF分析',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: onOpenDetail,
                  ),
              ],
            ),
            const SizedBox(height: 6),

            // 2. メタデータ行 (撮影時刻, 連写秒数, 最高鮮鋭度)
            Row(
              children: [
                if (timeStr.isNotEmpty) ...[
                  const Icon(Icons.access_time, size: 12, color: BestShotTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    timeStr,
                    style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
                  ),
                  const SizedBox(width: 12),
                ],
                if (group.isBurst) ...[
                  Text(
                    burstStr,
                    style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
                  ),
                  const SizedBox(width: 12),
                ],
                Text(
                  'pHash: $pHashRate%',
                  style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
                ),
                const SizedBox(width: 12),
                Text(
                  '最高鮮明度: ${best.sharpness.toStringAsFixed(0)}',
                  style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // 3. 写真の水平配置リスト (各150x150、間隔8dp)
            SizedBox(
              height: 150,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final e in group.items) ...[
                      SizedBox(
                        width: 150,
                        child: _PhotoTile(
                          bytes: e.displayBytes,
                          sharpness: e.sharpness,
                          exposureScore: e.exposureScore,
                          faceQualityScore: e.faceQualityScore,
                          exifText: e.exifText,
                          isBest: e.key == group.bestKey,
                          selectedForDelete: selectedForDelete.contains(e.key),
                          isProcessing: processingKeys.contains(e.key),
                          onChanged: (v) {
                            onPhotoTileFocused(e.key);
                            onToggleDelete(e.key, v);
                          },
                          onSetBest: () => onSetBest(e.key),
                          loupeSelected: loupeSelection.contains(e.key),
                          onToggleLoupe: () {
                            onPhotoTileFocused(e.key);
                            onToggleLoupe(e.key);
                          },
                          isKeyboardFocused: e.key == keyboardPhotoKey,
                          sortFolder: selectedSortFolders[e.key],
                          customFolders: customFolders,
                          onSortFolderChanged: (folder) {
                            onPhotoTileFocused(e.key);
                            onSortFolderChanged(e.key, folder);
                          },
                        ),
                      ),
                      if (e != group.items.last) const SizedBox(width: 8),
                    ],
                  ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
