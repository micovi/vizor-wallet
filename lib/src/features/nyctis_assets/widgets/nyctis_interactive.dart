/// The interactive building blocks every Nyctis surface shares: a pressable
/// row or tile, a disclosure, a copy action that says what it did, and an
/// inline caution line that does not lean on colour alone.
///
/// They exist so that a row, a grid tile, a link, a copy row and a "What this
/// means" toggle all behave the same way for a keyboard and a screen reader:
///
/// * **one announcement per control.** The label is written by the wallet and
///   the children's own text is excluded, so a row is read once ("NightCash,
///   988 NC, 3 notes") rather than as a list of its fragments, and an
///   issuer-supplied image never contributes an unlabeled node.
/// * **keyboard reachable with a visible focus ring.** Tab lands on it, the
///   ring is the same 2px `state.focusRing` the ZEC activity rows draw, and
///   Enter or Space activates it (WCAG 2.1.1, 2.4.7).
/// * **the same hover wash** as those rows (`state.hoverOpacity`).
///
/// Presentational and provider-free, like the rest of `widgets/`.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/app_toast.dart';

const _activationShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
};

/// A focusable, hoverable, keyboard-activatable surface with one
/// wallet-authored accessible name.
///
/// [semanticsLabel] replaces the children's semantics when set. Leave it null
/// only when the children already carry exactly one meaningful label.
class NyctisPressable extends StatefulWidget {
  const NyctisPressable({
    required this.onPressed,
    required this.child,
    this.semanticsLabel,
    this.semanticsHint,
    this.expanded,
    this.borderRadius = AppRadii.small,
    this.padding = EdgeInsets.zero,
    this.focusNode,
    super.key,
  });

  /// Null renders the child inert: no cursor, no focus stop, no action.
  final VoidCallback? onPressed;
  final Widget child;

  /// The one name a screen reader announces for the whole control.
  final String? semanticsLabel;

  /// What activating it does ("Opens asset"), announced after the label.
  final String? semanticsHint;

  /// Disclosure state, for a control that shows and hides content.
  final bool? expanded;

  /// Corner radius of the hover wash and the focus ring.
  final double borderRadius;

  /// Inset between the wash and the child, so the wash does not hug the text.
  final EdgeInsetsGeometry padding;

  final FocusNode? focusNode;

  @override
  State<NyctisPressable> createState() => _NyctisPressableState();
}

class _NyctisPressableState extends State<NyctisPressable> {
  bool _hovered = false;
  bool _focused = false;
  bool _hasFocus = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  void _setFocused(bool value) {
    if (_focused == value) return;
    setState(() => _focused = value);
  }

  void _activate() {
    _setHovered(false);
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final onPressed = widget.onPressed;
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(widget.borderRadius);

    final surface = Stack(
      clipBehavior: Clip.none,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: enabled && _hovered ? colors.state.hoverOpacity : null,
            borderRadius: radius,
          ),
          child: Padding(padding: widget.padding, child: widget.child),
        ),
        if (enabled && _focused)
          Positioned(
            left: -1,
            top: -1,
            right: -1,
            bottom: -1,
            child: IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey('nyctis_focus_ring'),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.state.focusRing, width: 2),
                  borderRadius: BorderRadius.circular(widget.borderRadius + 1),
                ),
              ),
            ),
          ),
      ],
    );

    final label = widget.semanticsLabel;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      hint: widget.semanticsHint,
      expanded: widget.expanded,
      // The Focus below is excluded with the children, so the node says for
      // itself that it takes keyboard focus.
      focusable: enabled,
      focused: enabled && _hasFocus,
      // The children's own text would otherwise be read after the label:
      // a title twice, a balance without its unit, an image with no name.
      excludeSemantics: label != null,
      onTap: enabled ? _activate : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: enabled ? (_) => _setHovered(true) : null,
        onExit: enabled ? (_) => _setHovered(false) : null,
        child: FocusableActionDetector(
          enabled: enabled,
          focusNode: widget.focusNode,
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onShowFocusHighlight: _setFocused,
          onFocusChange: (value) {
            if (_hasFocus != value) setState(() => _hasFocus = value);
          },
          shortcuts: _activationShortcuts,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<Intent>(
              onInvoke: (_) {
                _activate();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? _activate : null,
            child: surface,
          ),
        ),
      ),
    );
  }
}

/// Copies [text], shows the shared "Copied" toast, and tells a screen reader
/// what was copied — the toast is visual only.
///
/// [what] names the value in sentence case, e.g. `Asset id`.
Future<void> copyNyctisText(
  BuildContext context, {
  required String text,
  required String what,
}) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  showAppToast(context, 'Copied');
  await SemanticsService.sendAnnouncement(
    View.of(context),
    nyctisCopiedAnnouncement(what),
    Directionality.maybeOf(context) ?? TextDirection.ltr,
  );
}

/// What a screen reader hears after a copy.
String nyctisCopiedAnnouncement(String what) => '$what copied';

/// The accessible name of a copy control.
String nyctisCopyLabel(String what, String shownValue) =>
    'Copy $what, $shownValue';

/// Lower-cases the first letter of a sentence-case label so it can sit
/// mid-sentence: `Asset id` → `asset id`.
String nyctisMidSentence(String label) {
  if (label.isEmpty) return label;
  return label[0].toLowerCase() + label.substring(1);
}

/// A titled toggle that shows [builder]'s content only while open.
///
/// The content is built lazily, so a disclosure over two hundred note rows
/// costs nothing until someone opens it.
class NyctisDisclosure extends StatefulWidget {
  const NyctisDisclosure({
    required this.title,
    required this.builder,
    this.initiallyExpanded = false,
    this.toggleKey,
    super.key,
  });

  final String title;
  final WidgetBuilder builder;
  final bool initiallyExpanded;

  /// Key on the toggle row, for tests.
  final Key? toggleKey;

  @override
  State<NyctisDisclosure> createState() => _NyctisDisclosureState();
}

class _NyctisDisclosureState extends State<NyctisDisclosure> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        NyctisPressable(
          key: widget.toggleKey,
          onPressed: () => setState(() => _open = !_open),
          semanticsLabel: widget.title,
          expanded: _open,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: AppTypography.bodySmall.copyWith(
                    color: colors.text.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xxs),
              RotatedBox(
                quarterTurns: _open ? 2 : 0,
                child: AppIcon(
                  AppIcons.expand,
                  size: AppIconSize.medium,
                  color: colors.icon.regular,
                ),
              ),
            ],
          ),
        ),
        if (_open) ...[
          const SizedBox(height: AppSpacing.xs),
          widget.builder(context),
        ],
      ],
    );
  }
}

/// How an inline line of caution is marked.
enum NyctisNoticeTone { warning, error }

/// A sentence that needs attention, marked by an icon **and** carried in a
/// text colour that passes contrast in both themes.
///
/// The utility warning colour is 3.35:1 on white in the light theme, below
/// WCAG AA for body text, so the words are drawn in `text.primary` and the
/// caution is carried by the glyph (WCAG 1.4.1, 1.4.3).
class NyctisNoticeText extends StatelessWidget {
  const NyctisNoticeText({
    required this.text,
    this.tone = NyctisNoticeTone.warning,
    this.style,
    this.textAlign,
    super.key,
  });

  final String text;
  final NyctisNoticeTone tone;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final base = style ?? AppTypography.bodySmall;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: ExcludeSemantics(
            child: AppIcon(
              tone == NyctisNoticeTone.error
                  ? AppIcons.warningCircle
                  : AppIcons.warning,
              size: AppIconSize.medium,
              // The light warning gold is 2.4:1 as a glyph on white, under the
              // 3:1 non-text floor; the regular icon colour passes in both
              // themes. The error glyph passes as it is.
              color: tone == NyctisNoticeTone.error
                  ? colors.icon.destructive
                  : colors.icon.regular,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.xxs),
        Expanded(
          child: Text(
            text,
            textAlign: textAlign,
            style: base.copyWith(color: colors.text.primary),
          ),
        ),
      ],
    );
  }
}
