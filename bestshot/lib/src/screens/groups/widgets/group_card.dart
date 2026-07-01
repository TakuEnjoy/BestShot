import 'package:flutter/material.dart';

import '../../../models/photo_group.dart';
import 'photo_tile.dart';

class ExpandableGroupCard extends StatelessWidget {
  const ExpandableGroupCard({
    super.key,
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

    return Material(
      color: theme.colorScheme.surface,
      elevation: isKeyboardGroupFocused ? 4 : 0,
      shadowColor: isKeyboardGroupFocused
          ? theme.colorScheme.primary.withValues(alpha: 0.3)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isKeyboardGroupFocused
              ? theme.colorScheme.primary
              : theme.dividerColor.withValues(alpha: 0.12),
          width: isKeyboardGroupFocused ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isKeyboardGroupFocused
                        ? theme.colorScheme.primary
                        : theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    group.id,
                    style: TextStyle(
                      color: isKeyboardGroupFocused
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        '${group.items.length} 枚',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: onSelectBestOnly,
                        icon: const Icon(Icons.playlist_remove, size: 16),
                        label: const Text(
                          'Best以外を削除候補に',
                          style: TextStyle(fontSize: 11),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ),

                if (group.isBurst) ...[
                  const Icon(Icons.bolt, size: 14, color: Colors.orange),
                  const SizedBox(width: 4),
                  Text(
                    '連写',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '最高鮮明度: ${best.sharpness.toStringAsFixed(0)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
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
                        child: PhotoTile(
                          thumbnailPath: e.thumbnailPath,
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
      ),
    );
  }
}
