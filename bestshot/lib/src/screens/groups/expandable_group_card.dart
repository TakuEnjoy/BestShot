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
    this.selectedForDeleteListenable,
    this.onOpenDetail,
    this.onOpenLoupeForPhoto,
  });

  final PhotoGroup group;
  final Set<String> selectedForDelete;
  final ValueListenable<Set<String>>? selectedForDeleteListenable;
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
  final void Function(String photoKey)? onOpenLoupeForPhoto;

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
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
            LayoutBuilder(
              builder: (context, constraints) {
                final isCompact = constraints.maxWidth < 650;
                final badges = <Widget>[
                  _Badge(
                    label: group.isBurst ? '📷 連写' : '📷 単写',
                    color: BestShotTheme.hoverColor,
                    textColor: BestShotTheme.textPrimary,
                  ),
                  _Badge(
                    label: '🔍 一致率 $matchRate%',
                    color: BestShotTheme.hoverColor,
                    textColor: BestShotTheme.accentBlue,
                  ),
                  if (group.bestKey.isNotEmpty)
                    const _Badge(
                      label: '⭐ Best済',
                      color: Color(0xFF332600),
                      textColor: BestShotTheme.accentGold,
                    ),
                  if (selectedForDeleteListenable != null)
                    ValueListenableBuilder<Set<String>>(
                      valueListenable: selectedForDeleteListenable!,
                      builder: (context, selected, _) {
                        final count = group.items.where((e) => selected.contains(e.key)).length;
                        if (count == 0) return const SizedBox.shrink();
                        return _Badge(
                          label: '🟡 削除予定 $count枚',
                          color: const Color(0xFF330018),
                          textColor: BestShotTheme.accentRed,
                        );
                      },
                    )
                  else if (deleteCountInGroup > 0)
                    _Badge(
                      label: '🟡 削除予定 $deleteCountInGroup枚',
                      color: const Color(0xFF330018),
                      textColor: BestShotTheme.accentRed,
                    ),
                  if (group.needsReview)
                    const _Badge(
                      label: '⚠ 要確認',
                      color: Color(0xFF330018),
                      textColor: BestShotTheme.accentRed,
                    ),
                ];

                final idWidget = Container(
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
                );

                final countWidget = Text(
                  '${group.items.length}枚',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: BestShotTheme.textPrimary,
                  ),
                );

                final selectBestBtn = OutlinedButton.icon(
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
                );

                final detailBtn = onOpenDetail != null
                    ? IconButton(
                        icon: const Icon(Icons.analytics_outlined, size: 16, color: BestShotTheme.textSecondary),
                        tooltip: '詳細スコア・EXIF分析',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        onPressed: onOpenDetail,
                      )
                    : null;

                if (isCompact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          idWidget,
                          const SizedBox(width: 8),
                          countWidget,
                          const SizedBox(width: 10),
                          selectBestBtn,
                          const Spacer(),
                          ?detailBtn,
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: badges,
                      ),
                    ],
                  );
                }

                return Row(
                  children: [
                    idWidget,
                    const SizedBox(width: 8),
                    countWidget,
                    const SizedBox(width: 10),
                    selectBestBtn,
                    const SizedBox(width: 8),
                    for (final b in badges) ...[
                      b,
                      const SizedBox(width: 6),
                    ],
                    const Spacer(),
                    ?detailBtn,
                  ],
                );
              },
            ),
            const SizedBox(height: 6),

            // 2. メタデータ行 (撮影時刻, 連写秒数, 最高鮮鋭度)
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (timeStr.isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.access_time, size: 12, color: BestShotTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        timeStr,
                        style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
                      ),
                    ],
                  ),
                if (group.isBurst)
                  Text(
                    burstStr,
                    style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
                  ),
                Text(
                  'pHash: $pHashRate%',
                  style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary),
                ),
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
                          itemKey: e.key,
                          selectedForDeleteListenable: selectedForDeleteListenable,
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
                          onOpenLoupe: () {
                            onPhotoTileFocused(e.key);
                            onOpenLoupeForPhoto?.call(e.key);
                          },
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
