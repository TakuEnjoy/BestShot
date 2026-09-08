part of '../groups_screen.dart';

class _ExpandableGroupCard extends StatelessWidget {
  const _ExpandableGroupCard({
    required this.group,
    required this.selectedForDelete,
    required this.onToggleDelete,
    required this.loupeSelection,
    required this.onToggleLoupe,
    required this.onSelectBestOnly,
    required this.isKeyboardGroupFocused,
    required this.keyboardPhotoKey,
    required this.onPhotoTileFocused,
    required this.selectedSortFolders,
    required this.onSortFolderChanged,
    required this.customFolders,
    required this.processingKeys,
  });

  final PhotoGroup group;
  final Set<String> selectedForDelete;
  final void Function(String key, bool selected) onToggleDelete;
  final List<String> loupeSelection;
  final void Function(String key) onToggleLoupe;
  final VoidCallback onSelectBestOnly;
  final bool isKeyboardGroupFocused;
  final String? keyboardPhotoKey;
  final ValueChanged<String> onPhotoTileFocused;
  final Map<String, String> selectedSortFolders;
  final void Function(String key, String? folder) onSortFolderChanged;
  final List<String> customFolders;
  final Set<String> processingKeys;

  @override
  Widget build(BuildContext context) {
    final best = group.items.firstWhere(
      (e) => e.key == group.bestKey,
      orElse: () => group.items.first,
    );
    final theme = Theme.of(context);

    return GlassContainer(
      backgroundColor: isKeyboardGroupFocused ? theme.colorScheme.primary.withValues(alpha: 0.1) : null,
      borderColor: isKeyboardGroupFocused
          ? theme.colorScheme.primary
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: isKeyboardGroupFocused
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primaryContainer.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    group.id,
                    style: TextStyle(
                      color: isKeyboardGroupFocused
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(
                        '${group.items.length} 枚',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: onSelectBestOnly,
                        icon: const Icon(Icons.playlist_remove, size: 15),
                        label: const Text('Best以外を削除候補に', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          backgroundColor: theme.colorScheme.surfaceContainerHigh,
                          foregroundColor: theme.colorScheme.onSurfaceVariant,
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ],
                  ),
                ),

                if (group.isBurst) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.bolt, size: 14, color: Colors.orange),
                        const SizedBox(width: 3),
                        Text(
                          '連写',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.orange,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                if (group.needsReview) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 14, color: Colors.redAccent),
                        const SizedBox(width: 3),
                        Text(
                          '要確認',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '最高鮮明度: ${best.sharpness.toStringAsFixed(0)}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 140,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final e in group.items) ...[
                      SizedBox(
                        width: 140,
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
                      if (e != group.items.last) const SizedBox(width: 10),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
    );
  }
}
