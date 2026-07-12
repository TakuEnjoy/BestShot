part of '../groups_screen.dart';

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

  // Professional, distinct label colors (Lightroom/Capture One style)
  const colors = [
    Color(0xFFE53E3E), // Red
    Color(0xFFD69E2E), // Yellow/Ochre
    Color(0xFF38A169), // Green
    Color(0xFF3182CE), // Blue
    Color(0xFF805AD5), // Purple
    Color(0xFFDD6B20), // Orange
    Color(0xFF319795), // Teal
    Color(0xFFD53F8C), // Pink
    Color(0xFF718096), // Slate
    Color(0xFF4A5568), // Dark Gray
  ];

  return colors[index % colors.length];
}