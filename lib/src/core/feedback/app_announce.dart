import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// Speaks [message] through the platform screen reader (VoiceOver, TalkBack,
/// Narrator), without moving focus.
///
/// For state changes a sighted user sees happen somewhere else on screen — a
/// long operation starting, finishing or failing — and that a screen-reader
/// user would otherwise never hear about (WCAG 4.1.3). Does nothing when the
/// context is no longer mounted or no screen reader is listening.
Future<void> announceForAccessibility(
  BuildContext context,
  String message,
) async {
  final text = message.trim();
  if (text.isEmpty || !context.mounted) return;
  final view = View.maybeOf(context);
  if (view == null) return;
  await SemanticsService.sendAnnouncement(
    view,
    text,
    Directionality.maybeOf(context) ?? TextDirection.ltr,
  );
}
