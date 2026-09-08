import 'package:flutter/material.dart';
import '../theme/bestshot_theme.dart';

class GlobalBackground extends StatelessWidget {
  const GlobalBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: BestShotTheme.backgroundPrimary,
      child: child,
    );
  }
}
