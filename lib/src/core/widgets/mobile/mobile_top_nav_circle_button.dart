import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../app_icon.dart';

/// The 44×44 secondary circle a mobile top nav carries as its trailing
/// action (Figma `Mobile Top Nav` trailing button) — the shape the address
/// book's add button uses, as a shared widget.
///
/// 44 logical pixels is the minimum touch target; a bare 24px glyph in the
/// same slot is not.
class MobileTopNavCircleButton extends StatelessWidget {
  const MobileTopNavCircleButton({
    required this.iconName,
    required this.semanticsLabel,
    required this.onPressed,
    super.key,
  });

  /// Diameter, and the touch target.
  static const double size = 44;

  /// Glyph size inside the circle.
  static const double iconSize = 20;

  final String iconName;
  final String semanticsLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: colors.button.secondary.bg,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: AppIcon(
              iconName,
              size: iconSize,
              color: enabled
                  ? colors.button.secondary.label
                  : colors.icon.disabled,
            ),
          ),
        ),
      ),
    );
  }
}
