import 'photo_entry.dart';

class PhotoGroup {
  PhotoGroup({
    required this.id,
    required this.items,
    required this.bestKey,
    required this.deleteCandidateKeys,
    required this.isBurst,
    required this.isAllBlur,
  });

  final String id;
  final List<PhotoEntry> items;
  String bestKey; // Made mutable to allow changing best key from loupe preview
  final Set<String> deleteCandidateKeys;
  final bool isBurst;
  final bool isAllBlur;
}

