part of '../groups_screen.dart';

class _PortraitCardTile extends StatefulWidget {
  const _PortraitCardTile({
    required this.entry,
    required this.index,
    required this.timeStr,
    required this.isBest,
    required this.selectedForDelete,
    required this.loupeSelected,
    required this.isKeyboardFocused,
    required this.sortFolder,
    required this.customFolders,
    required this.isProcessing,
    required this.borderColor,
    required this.borderWidth,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSetBest,
    required this.onToggleDelete,
    required this.onToggleLoupe,
    required this.onOpenLoupe,
    required this.onSortFolderChanged,
  });

  final PhotoEntry entry;
  final int index;
  final String timeStr;
  final bool isBest;
  final bool selectedForDelete;
  final bool loupeSelected;
  final bool isKeyboardFocused;
  final String? sortFolder;
  final List<String> customFolders;
  final bool isProcessing;
  final Color borderColor;
  final double borderWidth;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onSetBest;
  final ValueChanged<bool?> onToggleDelete;
  final VoidCallback onToggleLoupe;
  final VoidCallback onOpenLoupe;
  final ValueChanged<String?> onSortFolderChanged;

  @override
  State<_PortraitCardTile> createState() => _PortraitCardTileState();
}

class _PortraitCardTileState extends State<_PortraitCardTile> {
  bool _isHovered = false;

  Widget _buildSortFolderButton(ThemeData theme) {
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
                  style: const TextStyle(
                    fontSize: 10,
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
            const PopupMenuItem<String?>(
              value: '__NEW_FOLDER__',
              child: Row(
                children: [
                  Icon(Icons.create_new_folder, size: 16, color: BestShotTheme.accentBlue),
                  SizedBox(width: 8),
                  Text('新規フォルダを追加...'),
                ],
              ),
            ),
            const PopupMenuItem<String?>(
              value: null,
              child: Row(
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

  Widget _buildEyeStatusBadge(PortraitAnalysis p) {
    if (!p.hasFace) {
      return const SizedBox.shrink();
    }
    if (p.eyesClosed) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
        decoration: BoxDecoration(
          color: BestShotTheme.accentRed.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: BestShotTheme.accentRed, width: 0.8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off, size: 10, color: BestShotTheme.accentRed),
            SizedBox(width: 2),
            Text(
              '目閉じ',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: BestShotTheme.accentRed,
              ),
            ),
          ],
        ),
      );
    }
    if (p.bothEyesDetected || (p.eyeOpenAvg != null && p.eyeOpenAvg! >= 0.7)) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
        decoration: BoxDecoration(
          color: const Color(0xFF16A34A).withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: const Color(0xFF16A34A), width: 0.8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility, size: 10, color: Color(0xFF34C759)),
            SizedBox(width: 2),
            Text(
              '目開きOK',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: Color(0xFF34C759),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
      decoration: BoxDecoration(
        color: BestShotTheme.accentBlue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: BestShotTheme.accentBlue.withValues(alpha: 0.4), width: 0.8),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.face, size: 10, color: BestShotTheme.accentBlue),
          SizedBox(width: 2),
          Text(
            '顔検知',
            style: TextStyle(
              fontSize: 9,
              color: BestShotTheme.accentBlue,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.entry.portrait;

    Color effectiveBorderColor = widget.borderColor;
    double effectiveBorderWidth = widget.borderWidth;
    if (!widget.loupeSelected &&
        !widget.isKeyboardFocused &&
        !widget.selectedForDelete &&
        widget.sortFolder == null &&
        _isHovered) {
      effectiveBorderColor = BestShotTheme.hoverColor;
      effectiveBorderWidth = 1.5;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: IgnorePointer(
        ignoring: widget.isProcessing,
        child: Container(
          decoration: BoxDecoration(
            color: BestShotTheme.surfaceColor,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: effectiveBorderColor, width: effectiveBorderWidth),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. サムネイル画像領域 (スタック配置)
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 画像 (タップで削除トグル、ダブルタップでBest指定)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onTap,
                        onDoubleTap: widget.onDoubleTap,
                        child: Image.memory(
                          widget.entry.displayBytes,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          cacheWidth: 320,
                        ),
                      ),
                    ),

                    // 削除指定時のダーク半透明オーバーレイ (GPU負荷ゼロ化)
                    if (widget.selectedForDelete)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.55),
                          ),
                        ),
                      ),

                    // Best Shot ゴールド角バッジ (⭐)
                    if (widget.isBest)
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
                    if (!widget.isBest)
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
                              widget.entry.sharpness.toStringAsFixed(0),
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: BestShotTheme.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),

                    // 削除チェック (右上 - クリックで削除トグル)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Checkbox(
                        value: widget.selectedForDelete,
                        onChanged: (v) => widget.onToggleDelete(v),
                        activeColor: BestShotTheme.accentRed,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
                        side: const BorderSide(color: Colors.white, width: 1.5),
                      ),
                    ),

                    // ルーペ比較ボタン (右下 - タップでルーペへ直接遷移)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Tooltip(
                        message: 'ルーペで比較',
                        child: GestureDetector(
                          onTap: widget.onOpenLoupe,
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
                      child: _buildSortFolderButton(theme),
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

              // 2. メタデータ行（撮影時刻、全体鮮鋭度、顔ROI鮮鋭度、目閉じ/瞳検知バッジ）
              Container(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                color: BestShotTheme.surfaceColor,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            widget.timeStr.isEmpty ? '（時刻不明）' : widget.timeStr,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: BestShotTheme.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          'S: ${widget.entry.sharpness.toStringAsFixed(0)}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: BestShotTheme.accentBlue,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          p.hasFace
                              ? '顔ROI: ${p.faceSharpness.toStringAsFixed(0)}'
                              : '顔なし',
                          style: TextStyle(
                            fontSize: 10,
                            color: p.hasFace
                                ? BestShotTheme.textSecondary
                                : BestShotTheme.textSecondary.withValues(alpha: 0.6),
                          ),
                        ),
                        _buildEyeStatusBadge(p),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
