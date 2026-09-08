part of '../groups_screen.dart';

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.color,
    this.textColor = Colors.white,
  });

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: textColor,
          height: 1.1,
        ),
      ),
    );
  }
}

Color getFolderColor(String folder, List<String> customFolders) {
  final index = customFolders.indexOf(folder);
  if (index < 0) return const Color(0xFF3A3A3C);

  // Professional distinct palette (Section 1 & Lightroom/Capture One)
  const colors = [
    Color(0xFF3A86FF), // Blue
    Color(0xFFFF006E), // Red
    Color(0xFFFFBE0B), // Gold
    Color(0xFF00D084), // Green
    Color(0xFF8338EC), // Purple
    Color(0xFFFB5607), // Orange
    Color(0xFF06D6A0), // Teal
    Color(0xFFFF70A6), // Pink
    Color(0xFF70D6FF), // Sky Blue
    Color(0xFF8A8A8E), // Slate
  ];

  return colors[index % colors.length];
}