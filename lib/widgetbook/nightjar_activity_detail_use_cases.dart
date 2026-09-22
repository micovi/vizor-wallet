// ignore_for_file: depend_on_referenced_packages
// widgetbook is dev-only; see `widgetbook.dart` for the boundary.

/// Widgetbook use cases for the receipt a Nightjar activity row opens.
///
/// The three fixtures are the three shapes that are hard to reach by hand and
/// easy to get wrong:
///
/// * a **send**, which is the one that must not grow a recipient — its message
///   appended an output this wallet cannot read, and the gallery is where
///   somebody would notice a "To" row appearing;
/// * a **receipt of an unnamed asset**, where the asset id is the only
///   identifier there is;
/// * a **net**, a message this wallet only part-funded, whose `+` means
///   something other than "somebody paid me".
///
/// Every one is a plain record, so the gallery never touches a provider, the
/// Rust bridge, or the network.
library;

import 'package:flutter/widgets.dart';

import '../src/core/theme/app_theme.dart';
import '../src/features/activity/nightjar_activity_message.dart';
import '../src/features/activity/screens/nightjar_activity_detail_screen.dart';

const _namedAssetId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
const _unnamedAssetId =
    '0f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f4030201009f8e7d6c5b4a';
const _messageId =
    '82852615a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c';
const _earlierMessageId =
    'ea47c855f0e1d2c3b4a596877869504132231415f6e7d8c9bab1a29384756617';
const _txid =
    '9f8e7d6c5b4a39281716059483726150f1e2d3c4b5a69788796a5b4c3d2e1f0a';

Widget _stage(BuildContext context, Widget child, {double width = 440}) {
  return ColoredBox(
    color: context.colors.background.window,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}

/// A payment this wallet authored: two of its notes in, its change back out,
/// and one output it cannot read. The unreadable output is the whole point of
/// the fixture — nothing on the screen may put an amount or an address on it.
NightjarActivityDetailArgs _sent() => NightjarActivityDetailArgs(
  item: NightjarActivityItem(
    msgId: _messageId,
    assetId: _namedAssetId,
    kind: NightjarActivityKind.sent,
    delta: -BigInt.from(1250000),
    moved: BigInt.from(2000000),
    decimals: 6,
    height: BigInt.from(1240),
    name: 'Harbour credit',
    symbol: 'HBC',
    timestamp: DateTime.utc(2026, 5, 25, 13, 30),
    ownedInputs: 1,
    totalInputs: 1,
    ownedOutputs: 1,
    totalOutputs: 2,
  ),
  txidHex: _txid,
  carrierZatoshi: BigInt.from(20000),
  notes: [
    NightjarActivityDetailNote(
      role: NightjarActivityNoteRole.spent,
      position: BigInt.from(41),
      amount: BigInt.from(2000000),
      decimals: 6,
      createdHeight: BigInt.from(1180),
      spentByMessageId: _messageId,
      spentHeight: BigInt.from(1240),
      policyText: 'pk(ak) && before(1300)',
    ),
    NightjarActivityDetailNote(
      role: NightjarActivityNoteRole.created,
      position: BigInt.from(58),
      amount: BigInt.from(750000),
      decimals: 6,
      createdHeight: BigInt.from(1240),
    ),
  ],
);

/// An asset nobody has named, arriving. The asset id is its only identifier
/// and is the line the card ends on.
NightjarActivityDetailArgs _received() => NightjarActivityDetailArgs(
  item: NightjarActivityItem(
    msgId: _earlierMessageId,
    assetId: _unnamedAssetId,
    kind: NightjarActivityKind.received,
    delta: BigInt.from(3),
    moved: BigInt.zero,
    decimals: 0,
    height: BigInt.from(1199),
    ownedInputs: 0,
    totalInputs: 0,
    ownedOutputs: 1,
    totalOutputs: 1,
  ),
  notes: [
    NightjarActivityDetailNote(
      role: NightjarActivityNoteRole.created,
      position: BigInt.from(7),
      amount: BigInt.from(3),
      decimals: 0,
      createdHeight: BigInt.from(1199),
    ),
  ],
);

/// A message this wallet funded one input of out of two — a fill. Its `+` is a
/// net, not a receipt, and the card has to say so.
NightjarActivityDetailArgs _netChange() => NightjarActivityDetailArgs(
  item: NightjarActivityItem(
    msgId: _messageId,
    assetId: _namedAssetId,
    kind: NightjarActivityKind.netChange,
    delta: BigInt.from(500000),
    moved: BigInt.from(1000000),
    decimals: 6,
    height: BigInt.from(1262),
    name: 'Harbour credit',
    symbol: 'HBC',
    ownedInputs: 1,
    totalInputs: 2,
    ownedOutputs: 1,
    totalOutputs: 3,
  ),
  notes: [
    NightjarActivityDetailNote(
      role: NightjarActivityNoteRole.spent,
      position: BigInt.from(61),
      amount: BigInt.from(1000000),
      decimals: 6,
      createdHeight: BigInt.from(1205),
      spentByMessageId: _messageId,
      spentHeight: BigInt.from(1262),
    ),
    NightjarActivityDetailNote(
      role: NightjarActivityNoteRole.created,
      position: BigInt.from(90),
      amount: BigInt.from(1500000),
      decimals: 6,
      createdHeight: BigInt.from(1262),
    ),
  ],
);

Widget buildNightjarActivityDetailSentUseCase(BuildContext context) {
  return _stage(context, NightjarActivityDetailBody(args: _sent()));
}

Widget buildNightjarActivityDetailReceivedUseCase(BuildContext context) {
  return _stage(context, NightjarActivityDetailBody(args: _received()));
}

Widget buildNightjarActivityDetailNetChangeUseCase(BuildContext context) {
  return _stage(context, NightjarActivityDetailBody(args: _netChange()));
}

Widget buildNightjarActivityDetailNoMessageUseCase(BuildContext context) {
  return _stage(context, const NightjarActivityDetailBody(args: null));
}
