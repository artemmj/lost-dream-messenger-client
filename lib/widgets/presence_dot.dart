import 'package:flutter/material.dart';

/// Точка присутствия: зелёная, если человек в сети, серая иначе.
///
/// Тот же маркер, что `.presence-dot` в эталонном фронтенде (8 px, #4caf50 /
/// #bbbbbb) — используется в шапке чата и в списке участников группы.
class PresenceDot extends StatelessWidget {
  final bool online;
  const PresenceDot({required this.online, super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: online ? const Color(0xFF4CAF50) : const Color(0xFFBBBBBB),
        ),
      );
}
