import 'package:flutter/material.dart';

/// On-screen ^ < > directional controls for the walkthrough.
/// Forward/Back move between photo_points; Left/Right change look
/// direction at the current point.
class DirectionalNavArrows extends StatelessWidget {
  final bool canMoveForward;
  final bool canMoveBackward;
  final VoidCallback onForward;
  final VoidCallback onBackward;
  final VoidCallback onLookLeft;
  final VoidCallback onLookRight;

  const DirectionalNavArrows({
    super.key,
    required this.canMoveForward,
    required this.canMoveBackward,
    required this.onForward,
    required this.onBackward,
    required this.onLookLeft,
    required this.onLookRight,
  });

  Widget _arrowButton(IconData icon, VoidCallback? onTap) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withOpacity(enabled ? 0.45 : 0.2),
          border: Border.all(color: Colors.cyanAccent.withOpacity(enabled ? 0.6 : 0.15)),
        ),
        child: Icon(icon, color: Colors.white.withOpacity(enabled ? 1 : 0.3), size: 28),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 32,
      left: 0,
      right: 0,
      child: Column(
        children: [
          _arrowButton(Icons.keyboard_arrow_up, canMoveForward ? onForward : null),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _arrowButton(Icons.chevron_left, onLookLeft),
              const SizedBox(width: 40),
              _arrowButton(Icons.chevron_right, onLookRight),
            ],
          ),
          if (canMoveBackward) ...[
            const SizedBox(height: 12),
            _arrowButton(Icons.keyboard_arrow_down, onBackward),
          ],
        ],
      ),
    );
  }
}
