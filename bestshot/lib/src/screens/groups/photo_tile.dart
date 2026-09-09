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
    this.onSetBest,
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
  final VoidCallback? onSetBest;

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
          widget.onSortFolderChanged(folder);
        },
        offset: const Offset(0, 24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: hasFolder
                ? getFolderColor(sortFolder, widget.customFolders)
                : Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(2),
            border: Border.all(
              color: hasFolder ? Colors.white38 : Colors.white24,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasFolder ? Icons.folder : Icons.folder_open,
                size: 12,
                color: Colors.white,
              ),
              if (hasFolder) ...[
                const SizedBox(width: 3),
                Text(
                  sortFolder,
                  style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
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
                  const Icon(Icons.create_new_folder, size: 16, color: BestShotTheme.accentBlue),
                  const SizedBox(width: 8),
                  const Text('新規フォルダを追加...'),
                ],
              ),
            ),
            PopupMenuItem<String?>(
              value: null,
              child: const Row(
                children: [
                  Icon(Icons.folder_off, size: 16, color: BestShotTheme.textSecondary),
                  SizedBox(width: 8),
                  Text('仕分けを解除'),
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
    final isBest = widget.isBest;
    final isDelete = widget.selectedForDelete;
    final sortFolder = widget.sortFolder;
    final hasFolder = sortFolder != null;

    // ボーダー（Pro Mode: 2px、純色、フラット、角丸4dp）
    Color borderColor = BestShotTheme.dividerColor;
    double borderWidth = 1.0;
    if (widget.isKeyboardFocused) {
      borderColor = BestShotTheme.accentBlue;
      borderWidth = 2.0;
    } else if (isDelete) {
      borderColor = BestShotTheme.accentRed;
      borderWidth = 2.0;
    } else if (hasFolder) {
      borderColor = getFolderColor(sortFolder, widget.customFolders);
      borderWidth = 2.0;
    } else if (_isHovered) {
      borderColor = BestShotTheme.hoverColor;
      borderWidth = 1.5;
    }

    return RepaintBoundary(
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: IgnorePointer(
          ignoring: widget.isProcessing,
          child: InkWell(
            onTap: () => widget.onChanged(!widget.selectedForDelete),
            onDoubleTap: widget.onSetBest,
            borderRadius: BorderRadius.circular(4),
            child: Container(
              decoration: BoxDecoration(
                color: BestShotTheme.surfaceColor,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: borderColor, width: borderWidth),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // サムネイル画像
                  Image.memory(
                    widget.bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: 320,
                  ),

                  // 削除マーク時のダーク半透明オーバーレイ (saveLayerを回避して高速化)
                  if (isDelete)
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
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: const BoxDecoration(
                        color: BestShotTheme.accentGold,
                        borderRadius: BorderRadius.only(bottomRight: Radius.circular(4)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.star, size: 11, color: BestShotTheme.backgroundPrimary),
                          SizedBox(width: 2),
                          Text(
                            'Best',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: BestShotTheme.backgroundPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 鮮鋭度バッジ (Best以外で左上、タップでBestに指定可能)
                if (!isBest)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: GestureDetector(
                      onTap: widget.onSetBest,
                      child: Container(
                        height: 18,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          widget.sharpness.toStringAsFixed(0),
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: BestShotTheme.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),

                // 削除チェック (右上)
                Positioned(
                  right: 2,
                  top: 2,
                  child: Checkbox(
                    value: widget.selectedForDelete,
                    onChanged: (v) => widget.onChanged(v ?? false),
                    activeColor: BestShotTheme.accentRed,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
                    side: const BorderSide(color: Colors.white, width: 1.5),
                  ),
                ),

                // 写真上オーバーレイ: #000000 40% Opacity 半透明バー (EXIFテキスト)
                if (widget.exifText.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 26,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.4),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Text(
                        widget.exifText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),

                // ルーペ比較ボタン (右下)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: widget.onToggleLoupe,
                      borderRadius: BorderRadius.circular(2),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: widget.loupeSelected
                              ? BestShotTheme.accentBlue
                              : Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Icon(
                          widget.loupeSelected ? Icons.zoom_in_map : Icons.zoom_in,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),

                // 仕分けフォルダボタン (左下)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: _buildSortFolderButtonForTile(theme),
                ),

                // バックグラウンド処理中オーバーレイ
                if (widget.isProcessing)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.6),
                      child: const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
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
      ),
    ),
  );
}
}
