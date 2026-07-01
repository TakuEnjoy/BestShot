import 'dart:io';
import 'package:flutter/material.dart';

class PhotoTile extends StatefulWidget {
  const PhotoTile({
    super.key,
    required this.thumbnailPath,
    required this.sharpness,
    required this.exposureScore,
    required this.faceQualityScore,
    required this.exifText,
    required this.isBest,
    required this.selectedForDelete,
    required this.onChanged,
    required this.loupeSelected,
    required this.onToggleLoupe,
    required this.isKeyboardFocused,
    required this.sortFolder,
    required this.customFolders,
    required this.onSortFolderChanged,
    required this.isProcessing,
  });

  final String? thumbnailPath;
  final double sharpness;
  final double exposureScore;
  final double faceQualityScore;
  final String exifText;
  final bool isBest;
  final bool selectedForDelete;
  final ValueChanged<bool> onChanged;
  final bool loupeSelected;
  final VoidCallback onToggleLoupe;
  final bool isKeyboardFocused;
  final String? sortFolder;
  final List<String> customFolders;
  final ValueChanged<String?> onSortFolderChanged;
  final bool isProcessing;

  @override
  State<PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<PhotoTile> {
  bool _isHovered = false;

  Widget _buildSortFolderButtonForTile(ThemeData theme) {
    final sortFolder = widget.sortFolder;
    final hasFolder = sortFolder != null;
    return Material(
      color: Colors.transparent,
      child: PopupMenuButton<String?>(
        tooltip: 'フォルダに仕分ける',
        onSelected: (folder) {
          if (folder == '__NEW_FOLDER__') {
            widget.onSortFolderChanged(folder);
          } else {
            widget.onSortFolderChanged(folder);
          }
        },
        offset: const Offset(0, 30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: hasFolder
                ? getFolderColor(sortFolder, widget.customFolders)
                : Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasFolder ? Icons.folder : Icons.folder_open,
                size: 16,
                color: Colors.white,
              ),
              if (hasFolder) ...[
                const SizedBox(width: 4),
                Text(
                  sortFolder,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
        itemBuilder: (context) {
          return [
            PopupMenuItem<String?>(
              value: '__NEW_FOLDER__',
              child: Row(
                children: [
                  Icon(
                    Icons.create_new_folder,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  const Text('新規フォルダを追加...'),
                ],
              ),
            ),
            PopupMenuItem<String?>(
              value: null,
              child: Row(
                children: [
                  Icon(Icons.folder_off, size: 16, color: theme.hintColor),
                  const SizedBox(width: 8),
                  const Text('仕分けを解除'),
                ],
              ),
            ),
            ...widget.customFolders.map((folder) {
              return PopupMenuItem<String?>(
                value: folder,
                child: Row(
                  children: [
                    Icon(
                      Icons.folder,
                      size: 16,
                      color: getFolderColor(folder, widget.customFolders),
                    ),
                    const SizedBox(width: 8),
                    Text(folder),
                  ],
                ),
              );
            }),
          ];
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: _isHovered ? 1.03 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: AnimatedPhysicalModel(
          shape: BoxShape.rectangle,
          borderRadius: BorderRadius.circular(16),
          elevation: _isHovered ? 6 : 1,
          color: Colors.transparent,
          shadowColor: Colors.black.withValues(alpha: 0.3),
          duration: const Duration(milliseconds: 150),
          child: IgnorePointer(
            ignoring: widget.isProcessing,
            child: InkWell(
              onTap: () => widget.onChanged(!widget.selectedForDelete),
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  // Image and its clipping
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Opacity(
                        opacity: widget.selectedForDelete ? 0.45 : 1.0,
                        child: ColorFiltered(
                          colorFilter: ColorFilter.mode(
                            widget.selectedForDelete
                                ? Colors.grey
                                : Colors.transparent,
                            BlendMode.saturation,
                          ),
                          child: widget.thumbnailPath != null
                              ? Image.file(
                                  File(widget.thumbnailPath!),
                                  fit: BoxFit.cover,
                                )
                              : const SizedBox(),
                        ),
                      ),
                    ),
                  ),

                  // Selection Overlay (Border) - Placed outside ClipRRect to avoid clipping
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: widget.isKeyboardFocused
                              ? Border.all(color: colorScheme.primary, width: 3)
                              : (widget.selectedForDelete
                                    ? Border.all(
                                        color: colorScheme.error,
                                        width: 3,
                                      )
                                    : (widget.sortFolder != null
                                          ? Border.all(
                                              color: getFolderColor(
                                                widget.sortFolder!,
                                                widget.customFolders,
                                              ),
                                              width: 3,
                                            )
                                          : Border.all(
                                              color: _isHovered
                                                  ? Colors.white.withValues(
                                                      alpha: 0.4,
                                                    )
                                                  : Colors.white.withValues(
                                                      alpha: 0.1,
                                                    ),
                                              width: _isHovered ? 1.5 : 1,
                                            ))),
                          boxShadow: widget.isKeyboardFocused
                              ? [
                                  BoxShadow(
                                    color: colorScheme.primary.withValues(
                                      alpha: 0.5,
                                    ),
                                    blurRadius: 10,
                                    spreadRadius: 1.5,
                                  ),
                                ]
                              : null,
                          color: widget.selectedForDelete
                              ? colorScheme.error.withValues(alpha: 0.1)
                              : Colors.transparent,
                        ),
                      ),
                    ),
                  ),

                  // Badges (Top Left)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Row(
                      children: [
                        if (widget.isBest)
                          const _Badge(label: 'Best', color: Color(0xFF22C55E)),
                        if (!widget.isBest)
                          _Badge(
                            label: widget.sharpness.toStringAsFixed(0),
                            color: Colors.black.withValues(alpha: 0.6),
                          ),
                      ],
                    ),
                  ),

                  // Checkbox (Top Right)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Checkbox(
                      value: widget.selectedForDelete,
                      onChanged: (v) => widget.onChanged(v ?? false),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      side: const BorderSide(color: Colors.white, width: 1.5),
                    ),
                  ),

                  // EXIF Overlay (Bottom)
                  if (widget.exifText.isNotEmpty)
                    Positioned(
                      left: 6,
                      right: 6,
                      bottom: 34,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: BackdropFilter(
                          filter: ColorFilter.mode(
                            Colors.black.withValues(alpha: 0.4),
                            BlendMode.srcOver,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            child: Text(
                              widget.exifText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Loupe Button (Bottom Right)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: widget.onToggleLoupe,
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: widget.loupeSelected
                                ? colorScheme.primary
                                : Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            widget.loupeSelected
                                ? Icons.zoom_in_map
                                : Icons.zoom_in,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Folder Button (Bottom Left)
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: _buildSortFolderButtonForTile(theme),
                  ),

                  // Processing Overlay
                  if (widget.isProcessing)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

Color getFolderColor(String folder, List<String> customFolders) {
  final index = customFolders.indexOf(folder);
  if (index < 0) return Colors.grey;

  // 10 distinct, pleasant colors for our folders
  const colors = [
    Color(0xFFEF4444), // Red
    Color(0xFFF97316), // Orange
    Color(0xFFFBBF24), // Amber/Yellow
    Color(0xFF10B981), // Emerald/Green
    Color(0xFF06B6D4), // Cyan
    Color(0xFF3B82F6), // Blue
    Color(0xFF6366F1), // Indigo
    Color(0xFF8B5CF6), // Violet
    Color(0xFFD946EF), // Magenta
    Color(0xFF64748B), // Slate/Grey
  ];

  return colors[index % colors.length];
}
