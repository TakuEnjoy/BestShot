import 'package:flutter/material.dart';
import '../models/review_session.dart';
import '../models/photo_group.dart';

/// Manual edits share the same session used by the main viewer and persistence.
class ReviewToolsScreen extends StatefulWidget {
  const ReviewToolsScreen({super.key, required this.session});
  final ReviewSession session;
  @override
  State<ReviewToolsScreen> createState() => _ReviewToolsScreenState();
}

class _ReviewToolsScreenState extends State<ReviewToolsScreen> {
  final selectedGroups = <String>{};
  final selectedPhotos = <String>{};
  ReviewSession get session => widget.session;

  Future<void> rename(PhotoGroup group) async {
    var name = session.name(group);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('グループ名を変更'),
        content: TextFormField(
          initialValue: name,
          onChanged: (value) => name = value,
          maxLength: 80,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.trim()),
            child: const Text('変更'),
          ),
        ],
      ),
    );
    if (mounted && result != null && result.isNotEmpty) {
      setState(() => session.groupNames[group.id] = result);
    }
  }

  void split(PhotoGroup group) {
    try {
      setState(() {
        session.split(group.id, selectedPhotos);
        selectedPhotos.clear();
      });
    } on ArgumentError catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = session.sortedGroups(session.groups);
    return Scaffold(
      appBar: AppBar(
        title: const Text('選別・グループ編集'),
        actions: [
          TextButton(
            onPressed: selectedGroups.length < 2
                ? null
                : () => setState(() {
                    session.merge(selectedGroups);
                    selectedGroups.clear();
                    selectedPhotos.clear();
                  }),
            child: const Text('結合'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '確認済み ${session.reviewedGroupIds.length} / ${session.groups.length}グループ　'
                '除外は選別マークです。ファイルの削除は削除確認画面で実行します。\n'
                '保護した写真は削除・移動できません。「残す」「保留」も削除候補から外れます。',
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: session.groups.length,
                itemBuilder: (context, index) {
                  final group = groups[index];
                  return ExpansionTile(
                    key: ValueKey(group.id),
                    leading: Checkbox(
                      value: selectedGroups.contains(group.id),
                      onChanged: (value) => setState(() {
                        value == true
                            ? selectedGroups.add(group.id)
                            : selectedGroups.remove(group.id);
                      }),
                    ),
                    title: Text(session.name(group)),
                    subtitle: Text(
                      '${group.items.length}枚・${session.reviewedGroupIds.contains(group.id) ? "確認済み" : "未確認"}${group.needsReview ? "・AI要確認" : ""}',
                    ),
                    children: [
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: () => rename(group),
                            child: const Text('名前変更'),
                          ),
                          TextButton(
                            onPressed: () => split(group),
                            child: const Text('選択写真を分割'),
                          ),
                          FilterChip(
                            label: const Text('確認済み'),
                            selected: session.reviewedGroupIds.contains(
                              group.id,
                            ),
                            onSelected: (value) => setState(() {
                              value
                                  ? session.reviewedGroupIds.add(group.id)
                                  : session.reviewedGroupIds.remove(group.id);
                            }),
                          ),
                        ],
                      ),
                      for (final photo in session.sortedPhotos(group.items))
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          child: Row(
                            children: [
                              Checkbox(
                                value: selectedPhotos.contains(photo.key),
                                onChanged: (value) => setState(() {
                                  value == true
                                      ? selectedPhotos.add(photo.key)
                                      : selectedPhotos.remove(photo.key);
                                }),
                              ),
                              SizedBox(
                                width: 48,
                                height: 48,
                                child: Image.memory(
                                  photo.displayBytes,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const Icon(Icons.image_not_supported),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  (photo.originalFilename ??
                                          photo.filePath ??
                                          photo.key)
                                      .split(RegExp(r'[/\\]'))
                                      .last,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              PopupMenuButton<PhotoDecision>(
                                tooltip: '選別状態',
                                initialValue:
                                    session.decisions[photo.key] ??
                                    PhotoDecision.undecided,
                                onSelected: (value) => setState(
                                  () => session.setDecision(photo.key, value),
                                ),
                                itemBuilder: (_) => [
                                  for (final value in PhotoDecision.values)
                                    PopupMenuItem(
                                      value: value,
                                      child: Text(decisionLabels[value.index]),
                                    ),
                                ],
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    decisionLabels[(session.decisions[photo
                                                .key] ??
                                            PhotoDecision.undecided)
                                        .index],
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '保護',
                                icon: Icon(
                                  session.protectedKeys.contains(photo.key)
                                      ? Icons.lock
                                      : Icons.lock_open,
                                ),
                                onPressed: () => setState(
                                  () => session.setProtected(
                                    photo.key,
                                    !session.protectedKeys.contains(photo.key),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
