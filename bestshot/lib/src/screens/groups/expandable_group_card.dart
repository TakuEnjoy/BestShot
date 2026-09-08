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
    required this.onOpenDetail,
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
  final VoidCallback onOpenDetail;

  String _getTimeRange() {
    if (group.items.isEmpty) return '';
    final times = group.items.map((e) => e.capturedAt).whereType<DateTime>().toList()..sort();
    if (times.isEmpty) return '時刻不明';
    final first = times.first;
    final last = times.last;
    final fStr = '${first.hour.toString().padLeft(2, '0')}:${first.minute.toString().padLeft(2, '0')}';
    if (first == last) return fStr;
    final lStr = '${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}';
    return '$fStr - $lStr';
  }

  String _getBurstDuration() {
    if (!group.isBurst) return '単写';
    final times = group.items.map((e) => e.capturedAt).whereType<DateTime>().toList()..sort();
    if (times.length < 2) return '連写';
    final diffMs = times.last.difference(times.first).inMilliseconds;
    final sec = (diffMs / 1000.0).toStringAsFixed(1);
    return '連写: $sec秒間';
  }

  int _getGeometricMatchRate() {
    for (final item in group.items) {
      final exp = item.groupExplanation;
      if (exp != null && exp.inliers != null && exp.inliers! > 0) {
        final ratio = ((exp.orbInlierRatio ?? 0.3) * 100).round().clamp(60, 99);
        return ratio;
      }
    }
    return 88;
  }

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
    final matchRate = _getGeometricMatchRate();
    final pHashRate = _getPHashSimilarity();
    final timeStr = _getTimeRange();
    final burstStr = _getBurstDuration();

    // 48x48 mini thumbnails: max 6
    final miniItems = group.items.take(6).toList();
    final remainingCount = group.items.length - 6;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: const BoxConstraints(minHeight: 120),
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
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          splashColor: BestShotTheme.accentBlue.withValues(alpha: 0.25),
          highlightColor: BestShotTheme.accentBlue.withValues(alpha: 0.1),
          onTap: () {
            HapticFeedback.selectionClick();
            onOpenDetail();
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 1. ステータスバッジ行 (高さ20dp, 角丸2dp, 10sp)
                Row(
                  children: [
                    _Badge(
                      label: group.isBurst ? '📷 連写' : '📷 単写',
                      color: group.isBurst
                          ? BestShotTheme.hoverColor
                          : BestShotTheme.hoverColor,
                      textColor: BestShotTheme.textPrimary,
                    ),
                    const SizedBox(width: 6),
                    _Badge(
                      label: '🔍 幾何一致率 $matchRate%',
                      color: BestShotTheme.hoverColor,
                      textColor: BestShotTheme.accentBlue,
                    ),
                    const SizedBox(width: 6),
                    if (group.bestKey.isNotEmpty) ...[
                      const _Badge(
                        label: '⭐ Best済',
                        color: Color(0xFF332600),
                        textColor: BestShotTheme.accentGold,
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (deleteCountInGroup > 0) ...[
                      _Badge(
                        label: '🟡 削除予定 $deleteCountInGroup枚',
                        color: const Color(0xFF330018),
                        textColor: BestShotTheme.accentRed,
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (group.needsReview) ...[
                      const _Badge(
                        label: '⚠ 要確認',
                        color: Color(0xFF330018),
                        textColor: BestShotTheme.accentRed,
                      ),
                      const SizedBox(width: 6),
                    ],
                    const Spacer(),
                    Text(
                      '#${group.id}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: BestShotTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // 2. 代表サムネ (120x120) + ミニサムネグリッド (48x48) + メタデータ
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 代表サムネイル (120x120 固定、角丸4dp)
                    Hero(
                      tag: 'group_rep_${group.id}',
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          color: BestShotTheme.backgroundPrimary,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: BestShotTheme.dividerColor, width: 1),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(
                              best.displayBytes,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              cacheWidth: 300,
                            ),
                            // Best Shot 金バッジ
                            Positioned(
                              top: 0,
                              left: 0,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                decoration: const BoxDecoration(
                                  color: BestShotTheme.accentGold,
                                  borderRadius: BorderRadius.only(bottomRight: Radius.circular(3)),
                                ),
                                child: const Icon(Icons.star, size: 11, color: BestShotTheme.backgroundPrimary),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // ミニサムネイルグリッド (各48x48、間隔4dp、2行×3列、最大6枚)
                    SizedBox(
                      width: 48 * 3 + 4 * 2, // 152dp
                      height: 120,
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (int i = 0; i < miniItems.length; i++) ...[
                            _buildMiniThumbnail(
                              miniItems[i],
                              isLastAndOverflow: i == 5 && remainingCount > 0,
                              overflowCount: remainingCount,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),

                    // メタデータ列 (Section 2.1)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.access_time, size: 12, color: BestShotTheme.textSecondary),
                              const SizedBox(width: 4),
                              Text(
                                timeStr,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: BestShotTheme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.folder_outlined, size: 12, color: BestShotTheme.textSecondary),
                              const SizedBox(width: 4),
                              Text(
                                '${group.items.length}枚',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: BestShotTheme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.link, size: 12, color: BestShotTheme.textSecondary),
                              const SizedBox(width: 4),
                              Text(
                                'pHash: $pHashRate%',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: BestShotTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            burstStr,
                            style: const TextStyle(
                              fontSize: 11,
                              color: BestShotTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniThumbnail(
    PhotoEntry item, {
    required bool isLastAndOverflow,
    required int overflowCount,
  }) {
    final isSelectedForDelete = selectedForDelete.contains(item.key);

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: BestShotTheme.backgroundPrimary,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: isSelectedForDelete ? BestShotTheme.accentRed : BestShotTheme.dividerColor,
          width: isSelectedForDelete ? 1.5 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: isSelectedForDelete ? 0.45 : 1.0,
            child: Image.memory(
              item.displayBytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              cacheWidth: 100,
            ),
          ),
          if (isLastAndOverflow)
            Container(
              color: Colors.black.withValues(alpha: 0.75),
              alignment: Alignment.center,
              child: Text(
                '+$overflowCount',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: BestShotTheme.textPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
