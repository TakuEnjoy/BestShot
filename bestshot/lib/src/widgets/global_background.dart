import 'package:flutter/material.dart';

class GlobalBackground extends StatelessWidget {
  const GlobalBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFF0F0C29),
            Color(0xFF1E1A45),
            Color(0xFF24243E),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: child,
    );
  }
}
