part of '../groups_screen.dart';

class _PhotoTile extends StatefulWidget {
  const _PhotoTile({
    required this.bytes,
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

  final Uint8List bytes;
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
  State<_PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<_PhotoTile> {
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
            color: hasFolder ? getFolderColor(sortFolder, widget.customFolders) : Colors.black.withOpacity(0.5),
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
                  style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
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
                  Icon(Icons.create_new_folder, size: 16, color: theme.colorScheme.primary),
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
                    Icon(Icons.folder, size: 16, color: getFolderColor(folder, widget.customFolders)),
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
      child: IgnorePointer(
        ignoring: widget.isProcessing,
        child: InkWell(
          onTap: () => widget.onChanged(!widget.selectedForDelete),
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              // Image and its clipping
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                      child: Opacity(
                        opacity: widget.selectedForDelete ? 0.45 : 1.0,
                        child: ColorFiltered(
                          colorFilter: ColorFilter.mode(
                            widget.selectedForDelete ? Colors.grey : Colors.transparent,
                            BlendMode.saturation,
                          ),
                          child: Image.memory(
                            widget.bytes,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            cacheWidth: 400,
                          ),
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
                          borderRadius: BorderRadius.circular(8),
                          border: widget.isKeyboardFocused
                              ? Border.all(color: colorScheme.primary, width: 3)
                              : (widget.selectedForDelete
                                  ? Border.all(color: colorScheme.error, width: 3)
                                  : (widget.sortFolder != null
                                      ? Border.all(color: getFolderColor(widget.sortFolder!, widget.customFolders), width: 3)
                                      : Border.all(
                                          color: _isHovered
                                              ? Colors.white.withOpacity(0.4)
                                              : Colors.white.withOpacity(0.1),
                                          width: _isHovered ? 1.5 : 1,
                                        ))),
                          boxShadow: widget.isKeyboardFocused
                              ? [
                                  BoxShadow(
                                    color: colorScheme.primary.withOpacity(0.5),
                                    blurRadius: 10,
                                    spreadRadius: 1.5,
                                  )
                                ]
                              : null,
                          color: widget.selectedForDelete
                              ? colorScheme.error.withOpacity(0.1)
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
                            color: Colors.black.withOpacity(0.6),
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
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          color: Colors.black.withOpacity(0.65),
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
                                : Colors.black.withOpacity(0.5),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            widget.loupeSelected ? Icons.zoom_in_map : Icons.zoom_in,
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
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
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
