/// Desktop `/activity/nightjar/:messageId` — the receipt a Nightjar activity
/// row opens.
///
/// A ZEC row opens a transaction receipt: status, timestamp, txid, fee, and
/// the other party. **There is no transaction behind a Nightjar row.** A
/// Nightjar payment is a message written to a public channel, carried inside
/// a Zcash transaction this wallet may not have made and cannot read. So this
/// is a receipt for a *message*, and three fields a ZEC receipt has are
/// deliberately absent — each of them because the `nightjarReplay` contract in
/// `lib/src/rust/api/nightjar.dart` says the wallet cannot know it:
///
/// * **No recipient, and no "to" row.** The outputs of a message that are not
///   this wallet's are ciphertexts addressed to keys it has not got. Their
///   amounts are not zero and are not small — they are unknowable. The counts
///   `ownedOutputs` and `totalOutputs` are shown *as counts*, which is what
///   they are; their difference is never turned into an amount, because that
///   difference is exactly the part nobody on this side can name.
/// * **No "Completed".** A Zcash transaction is mined or it is not; a Nightjar
///   message is *applied*, *ignored*, or still *below finality*, and those are
///   states of a replay, not of a chain. [NightjarActivityMessageState] says
///   which, and [nightjarActivityStateLabel] is the only copy that reports it.
/// * **No fee.** The ZEC that carried the message was attached to shielded
///   outputs addressed to the *channel* — not to a miner, and not to the
///   recipient. When [NightjarActivityDetailArgs.carrierZatoshi] is supplied
///   it is shown under a label that says where it went, and never as a fee.
///
/// The classification — sent, received, moved within this wallet, a net — is
/// `nightjar_activity_message.dart`'s and is not repeated here: this screen
/// takes the very [NightjarActivityItem] the tapped row was built from, so the
/// verb and the amount on the receipt are the same strings the row showed,
/// produced by the same two functions. What the row could not carry, and what
/// [NightjarActivityDetailArgs] adds, is the message's notes, its replay
/// state, and the carrying Zcash transaction where one is known.
///
/// Amounts are [BigInt] base units plus an `int decimals` all the way to the
/// string, through `formatNightjarAmount`. No floating point.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/address_display.dart';
import '../../../core/formatting/date_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/privacy/privacy_mask.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/privacy_mode_provider.dart';
import '../../nightjar_assets/widgets/nightjar_asset_row_data.dart';
import '../../nightjar_assets/widgets/nightjar_assets_feed.dart';
import '../../nightjar_assets/widgets/nightjar_facts_card.dart';
import '../nightjar_activity_message.dart';
import '../nightjar_activity_row_mapper.dart'
    show
        kNightjarActivityAmountPrivacyMaskLength,
        nightjarActivityAmountText,
        nightjarActivityTitle;

/// The go_router path for one Nightjar message receipt.
///
/// It lives under `/activity`, not under `/nightjar`, for two reasons: it is
/// an activity receipt rather than an asset screen, and a `msg_id` and an
/// `asset_id` are both 32-byte hex, so a route registered beside
/// `/nightjar/:assetId` would have to guess which of the two a path held.
const String nightjarActivityDetailRoutePattern =
    '/activity/nightjar/:messageId';

/// Where an activity row opens. One function, so the feed and the router
/// cannot disagree about the path.
///
/// The receipt itself travels in `extra` as a [NightjarActivityDetailArgs] —
/// the id in the path identifies the message and is deliberately not enough to
/// rebuild it, because the classification that makes it a receipt is the
/// mapper's and is not in a URL.
String nightjarActivityDetailRouteFor(String messageId) =>
    '/activity/nightjar/$messageId';

const String kNightjarActivityDetailTitle = 'Nightjar message';

/// Shown when the route is reached without an argument — a window restore, a
/// deep link, a hot reload.
const String kNightjarActivityDetailNoMessageText =
    'There is no Nightjar message to show. Open it again from the activity '
    'list.';

/// What the replay did with the message. This is the row that replaces ZEC's
/// "Status", and it must never be given ZEC's vocabulary.
enum NightjarActivityMessageState {
  /// The state machine accepted it: every proof verified, the id rebound to
  /// its own body, and the transition applied. This is the only state a
  /// message with notes in `NjView` can be in, which is why it is the default.
  applied,

  /// The state machine refused it, so none of it counts. Normal on a public
  /// channel — anyone may write to one, including with junk. The reason is the
  /// machine's own; see [NightjarActivityDetailArgs.stateReason].
  ignored,

  /// It completes above the finality cut-off, so the replay is holding it back
  /// and none of it counts yet. It is not lost; it is early.
  belowFinality,
}

/// Which side of the message a note is on.
enum NightjarActivityNoteRole {
  /// The message consumed it: this wallet's money going in.
  spent,

  /// The message appended it: this wallet's money coming out. The message may
  /// have appended other outputs too, addressed to keys this wallet has not
  /// got — those are not here and cannot be.
  created,
}

/// One of this wallet's notes on one side of the message.
///
/// Every field is on `NjNote` (as carried through [NightjarNoteRowData]).
/// Nothing is derived, and in particular nothing stands in for an output the
/// wallet does not own.
@immutable
class NightjarActivityDetailNote {
  const NightjarActivityDetailNote({
    required this.role,
    required this.position,
    required this.amount,
    required this.decimals,
    required this.createdHeight,
    this.spentByMessageId,
    this.spentHeight,
    this.policyText,
  });

  /// Builds one from the note row the Nightjar view already carries.
  factory NightjarActivityDetailNote.fromRowData(
    NightjarNoteRowData note, {
    required NightjarActivityNoteRole role,
  }) {
    return NightjarActivityDetailNote(
      role: role,
      position: note.position,
      amount: note.amount,
      decimals: note.decimals,
      createdHeight: note.createdHeight,
      spentByMessageId: note.spentBy,
      spentHeight: note.spentHeight,
      policyText: note.policyText,
    );
  }

  /// Whether this message spent the note or created it.
  final NightjarActivityNoteRole role;

  /// `NjNote.position` — the note's slot in the commitment tree, and the only
  /// thing that identifies it.
  final BigInt position;

  /// `NjNote.amount`, in integer base units of the asset.
  final BigInt amount;

  /// Base-unit exponent for [amount]. A display hint; no arithmetic uses it.
  final int decimals;

  /// `NjNote.created` — the completion height of the message that appended
  /// this note, which for a `published` note is the transition that created it
  /// and not the `NOTE` message that disclosed it.
  final BigInt createdHeight;

  /// `NjNote.spent_by`, the message that nullified this note. Null while the
  /// note is unspent.
  final String? spentByMessageId;

  /// `NjNote.spent_height` — when the money left.
  final BigInt? spentHeight;

  /// `NjNote.policy` in its text form, e.g. `pk(<ak>) && before(1300)`. Null or
  /// empty when the note carries none.
  ///
  /// Worth a row of its own: being able to nullify a note is not the same as
  /// being able to open it today, and a timelocked note is listed and is not
  /// spendable. The policy text is what says so.
  final String? policyText;

  bool get hasPolicy => (policyText ?? '').trim().isNotEmpty;
}

/// Everything the Nightjar activity receipt shows, and the whole contract the
/// activity feed has to satisfy to open it.
///
/// [item] is the classified row itself — the same instance `onItemTap` was
/// handed — so the receipt cannot disagree with the row about what happened or
/// about how much. Everything else on this record is what a row had no space
/// for, and every one of those fields is nullable: a thing the wallet cannot
/// know is left null and the screen omits the row, rather than printing a
/// placeholder that reads like a fact.
@immutable
class NightjarActivityDetailArgs {
  const NightjarActivityDetailArgs({
    required this.item,
    this.notes = const [],
    this.state = NightjarActivityMessageState.applied,
    this.stateReason,
    this.txidHex,
    this.carrierZatoshi,
  });

  /// The row that was tapped, classified by `nightjar_activity_message.dart`.
  final NightjarActivityItem item;

  /// This wallet's notes on both sides of the message, spent ones and created
  /// ones. Never the message's other outputs — it has no way to hold those.
  ///
  /// Build it with [buildNightjarActivityDetailNotes], which selects them out
  /// of the same view the row came from.
  final List<NightjarActivityDetailNote> notes;

  /// What the replay did with the message.
  ///
  /// Defaults to [NightjarActivityMessageState.applied] because that is the
  /// only state a message reachable from the feed can be in: the replay
  /// reports notes for applied messages and for no others. A caller that opens
  /// this screen from somewhere else — an ignored-message list, a preview —
  /// must pass the real one.
  final NightjarActivityMessageState state;

  /// The state machine's own reason, for [NightjarActivityMessageState
  /// .ignored]. Null when it gave none, and never shown for another state.
  final String? stateReason;

  /// Txid of the Zcash transaction whose memos carried this message, when the
  /// view has one.
  ///
  /// Null is the ordinary case for this cut: `nightjarReplay` is handed message
  /// bodies, not transactions, so the carrier is usually simply not known. An
  /// absent row says that better than an "unknown" would.
  final String? txidHex;

  /// Zatoshi the carrying transaction attached to the channel's own outputs,
  /// when it is known.
  ///
  /// **Not a fee.** It went to the channel address, not to a miner and not to
  /// a recipient, and [kNightjarActivityCarrierNote] says so beside it. Null
  /// leaves the row out entirely, which is better than a zero that reads as
  /// "this was free".
  final BigInt? carrierZatoshi;

  String get messageId => item.msgId;

  String get assetId => item.assetId;

  /// The declared symbol, trimmed, or an empty string.
  String get symbol => item.symbol?.trim() ?? '';

  /// The declared name, or the truncated asset id — [NightjarActivityItem
  /// .assetLabel], so the receipt's title is the row's supporting line.
  String get assetTitle => item.assetLabel;

  Iterable<NightjarActivityDetailNote> get spentNotes =>
      notes.where((note) => note.role == NightjarActivityNoteRole.spent);

  Iterable<NightjarActivityDetailNote> get createdNotes =>
      notes.where((note) => note.role == NightjarActivityNoteRole.created);
}

/// This wallet's notes on both sides of [msgId], out of the view the row came
/// from.
///
/// A selection, not a classification: a note is an input of the message when it
/// names it in `spentBy` and an output when it names it in `createdBy`, which
/// is the grouping key `nightjarReplay` documents. Inputs come first, each side
/// ordered by tree position so two replays of one channel produce one order.
///
/// [assetId] narrows it to the asset the row is about. A message can move two
/// assets — a `buy` carries the maker's and the taker's — and the row is per
/// asset, so the receipt is too; pass null to take every asset the message
/// touched.
List<NightjarActivityDetailNote> buildNightjarActivityDetailNotes({
  required NightjarViewData view,
  required String msgId,
  String? assetId,
}) {
  if (msgId.isEmpty) return const [];
  final spent = <NightjarActivityDetailNote>[];
  final created = <NightjarActivityDetailNote>[];
  for (final asset in view.assets) {
    if (assetId != null && asset.assetId != assetId) continue;
    for (final note in asset.notes) {
      if (note.spentBy == msgId) {
        spent.add(
          NightjarActivityDetailNote.fromRowData(
            note,
            role: NightjarActivityNoteRole.spent,
          ),
        );
      }
      if (note.createdBy == msgId) {
        created.add(
          NightjarActivityDetailNote.fromRowData(
            note,
            role: NightjarActivityNoteRole.created,
          ),
        );
      }
    }
  }
  spent.sort((a, b) => a.position.compareTo(b.position));
  created.sort((a, b) => a.position.compareTo(b.position));
  return [...spent, ...created];
}

/// What the replay did. Never "Completed": nothing here was mined, confirmed,
/// or accepted by consensus, and borrowing ZEC's word would claim all three.
String nightjarActivityStateLabel(NightjarActivityMessageState state) {
  return switch (state) {
    NightjarActivityMessageState.applied => 'Applied',
    NightjarActivityMessageState.ignored => 'Ignored',
    NightjarActivityMessageState.belowFinality => 'Below finality',
  };
}

/// `1,240` — a height or a tree position, comma-grouped.
///
/// [formatNightjarAmount] at zero decimals is exactly integer grouping, so the
/// whole feature has one grouping implementation rather than two that could
/// drift apart.
String nightjarActivityHeightText(BigInt value) =>
    formatNightjarAmount(value, 0);

/// `2 of 2` — a count of this wallet's share of one side of the message.
///
/// A count and never an amount. The inputs figure is the authorship evidence:
/// owning every input is what makes "Sent" sayable at all. The outputs figure
/// is the opposite — a difference there is an output addressed to somebody
/// else, and how much is in it is unknowable, so the difference stays a count.
String nightjarActivityShareText(int owned, int total) => '$owned of $total';

/// A note amount, symbol included. Unsigned — a note's value has no direction;
/// its [NightjarActivityDetailNote.role] carries that.
String nightjarActivityNoteAmountText(
  NightjarActivityDetailNote note,
  String symbol, {
  bool privacyModeEnabled = false,
}) {
  if (privacyModeEnabled) {
    return hideAmountIfPrivacyMode(
      '',
      privacyModeEnabled: true,
      maskLength: kNightjarActivityAmountPrivacyMaskLength,
      denomination: symbol,
    );
  }
  final text = formatNightjarAmount(note.amount, note.decimals);
  return symbol.isEmpty ? text : '$text $symbol';
}

/// The "Message" card: what happened, what the replay did with it, how much,
/// where it landed, this wallet's share of each side, and the ids.
///
/// There is no "To" row and there never will be one — see the library doc.
List<NightjarAssetFactData> buildNightjarActivityMessageFacts(
  NightjarActivityDetailArgs args, {
  bool privacyModeEnabled = false,
}) {
  final item = args.item;
  final timestamp = item.timestamp;
  final reason = args.stateReason?.trim();
  final carrier = args.carrierZatoshi;
  final txid = args.txidHex?.trim();
  return [
    // The row's own verb, from the row's own function, so the receipt and the
    // feed cannot say two different things about one message.
    NightjarAssetFactData(label: 'Event', value: nightjarActivityTitle(item)),
    NightjarAssetFactData(
      label: 'State',
      value: nightjarActivityStateLabel(args.state),
    ),
    if (args.state == NightjarActivityMessageState.ignored &&
        reason != null &&
        reason.isNotEmpty)
      NightjarAssetFactData(label: 'Reason', value: reason),
    NightjarAssetFactData(
      label: 'Amount',
      value: nightjarActivityAmountText(
        item,
        privacyModeEnabled: privacyModeEnabled,
      ),
    ),
    NightjarAssetFactData(
      label: 'Completed at height',
      value: nightjarActivityHeightText(item.height),
    ),
    // Only when a block time was actually learned. Nightjar messages carry
    // heights, never times, so an undated message keeps the height row alone
    // rather than being given a plausible-looking moment.
    if (timestamp != null)
      NightjarAssetFactData(
        label: 'Timestamp',
        value: formatDayMonthTime(timestamp),
      ),
    // Counts, deliberately. See [nightjarActivityShareText].
    if (item.totalInputs > 0)
      NightjarAssetFactData(
        label: 'Inputs owned',
        value: nightjarActivityShareText(item.ownedInputs, item.totalInputs),
      ),
    if (item.totalOutputs > 0)
      NightjarAssetFactData(
        label: 'Outputs readable',
        value: nightjarActivityShareText(item.ownedOutputs, item.totalOutputs),
      ),
    NightjarAssetFactData(
      label: 'Message id',
      value: truncateNightjarAssetId(args.messageId),
      copyText: args.messageId,
    ),
    // Present only when the view actually has the carrying transaction.
    if (txid != null && txid.isNotEmpty)
      NightjarAssetFactData(
        label: 'Zcash tx id',
        value: truncatedTxid(txid),
        copyText: txid,
      ),
    // Deliberately not labelled a fee. See [kNightjarActivityCarrierNote].
    if (carrier != null && carrier > BigInt.zero)
      NightjarAssetFactData(
        label: 'Paid to the channel',
        value: hideAmountIfPrivacyMode(
          ZecAmount.fromZatoshi(carrier).fee.toString(),
          privacyModeEnabled: privacyModeEnabled,
        ),
      ),
  ];
}

/// The sentence the message card ends on: the one thing this receipt cannot
/// tell the user, said plainly rather than left to be inferred from a row that
/// is not there.
String nightjarActivityMessageFootnote(NightjarActivityDetailArgs args) {
  final base = switch (args.item.kind) {
    NightjarActivityKind.sent =>
      'The amount above is what left this wallet — the notes it spent, less '
          'the notes it kept. It is not what a recipient received.',
    NightjarActivityKind.received =>
      'A Nightjar message is written to a public channel. Nothing in it names '
          'a sender this wallet can verify, so there is no sender to show.',
    NightjarActivityKind.selfTransfer =>
      'Every note this message spent came back to this wallet, so nothing left '
          'it. Consolidating notes and paying your own address both look like '
          'this, and neither moved money out.',
    NightjarActivityKind.netChange =>
      'This wallet funded part of this message, so the amount above is its own '
          'net change in it — not a payment it made and not one it received.',
    NightjarActivityKind.settling =>
      'This row is about the channel rather than about one message, so there '
          'is nothing here to itemise.',
  };
  final state = switch (args.state) {
    NightjarActivityMessageState.applied => null,
    NightjarActivityMessageState.ignored =>
      'The state machine refused this message, so none of it counts. Anyone '
          'may write to a public channel, including with junk.',
    NightjarActivityMessageState.belowFinality =>
      'This message is not deep enough yet, so the replay is holding it back '
          'and none of it counts. It is not lost; it is early.',
  };
  // Said wherever it is true, not only on a send: this is the one sentence
  // that explains the "Outputs readable" count and the absence of a recipient
  // row, and a receipt or a net can have an unreadable output too.
  final unreadable = args.item.hasUnreadableOutputs
      ? kNightjarActivityUnreadableOutputsNote
      : null;
  final carrier = args.carrierZatoshi;
  final carrierNote = carrier != null && carrier > BigInt.zero
      ? kNightjarActivityCarrierNote
      : null;
  return [base, ?unreadable, ?state, ?carrierNote].join(' ');
}

/// Why there is no recipient on this screen, and why the outputs count is a
/// count.
///
/// An output this wallet does not hold is a ciphertext addressed to a key it
/// has not got. `createdOutputs − ownedOutputs` therefore says how many such
/// outputs exist and nothing whatever about their value: the difference is
/// unknowable, not zero, and turning it into an amount would be the one
/// invention this screen exists to avoid.
const String kNightjarActivityUnreadableOutputsNote =
    'This message appended outputs this wallet cannot read. They are addressed '
    'to keys it has not got, so how much is in them is unknowable rather than '
    'zero, and there is no recipient to show.';

/// Why the ZEC figure on this screen is not a fee.
///
/// A Nightjar memo rides an ordinary shielded output addressed to the
/// *channel*, and that output has to carry value or the proposer drops it as
/// dust. None of it reaches a miner as this message's fee and none of it
/// reaches the recipient — so the row is labelled for where it went, and this
/// sentence says the rest.
const String kNightjarActivityCarrierNote =
    'The ZEC above was attached to the memos that carried this message to the '
    'channel. It is not a network fee and no recipient received it.';

/// The "Asset" card: the declared name and symbol where there are any, and the
/// asset id always.
List<NightjarAssetFactData> buildNightjarActivityAssetFacts(
  NightjarActivityDetailArgs args,
) {
  final item = args.item;
  return [
    if (item.hasName)
      NightjarAssetFactData(label: 'Name', value: item.name!.trim()),
    if (item.hasSymbol)
      NightjarAssetFactData(label: 'Symbol', value: args.symbol),
    // Always, and last, so the identity is the line the eye ends on.
    // `spec/asset-metadata-v0.md` section 5: the id is the identity, and it
    // must be visible wherever a name or a logo is.
    NightjarAssetFactData(
      label: 'Asset id',
      value: truncateNightjarAssetId(args.assetId),
      copyText: args.assetId,
    ),
  ];
}

/// What the asset card has to say about a name, which is: a name is a claim.
String nightjarActivityAssetFootnote(NightjarActivityDetailArgs args) {
  return args.item.hasName
      ? 'The name and symbol are whatever this asset\'s issuer published. The '
            'asset id is the identity — two issuers can declare the same name.'
      : 'This asset\'s issuer has published no name. The asset id is its only '
            'identifier.';
}

/// One note's facts: what it is worth, where it sits, when it appeared, and —
/// for a spent one — the message that consumed it.
List<NightjarAssetFactData> buildNightjarActivityNoteFacts(
  NightjarActivityDetailNote note,
  String symbol, {
  bool privacyModeEnabled = false,
}) {
  final spentBy = note.spentByMessageId?.trim();
  final spentHeight = note.spentHeight;
  final policy = note.policyText?.trim();
  return [
    NightjarAssetFactData(
      label: 'Amount',
      value: nightjarActivityNoteAmountText(
        note,
        symbol,
        privacyModeEnabled: privacyModeEnabled,
      ),
    ),
    NightjarAssetFactData(
      label: 'Position',
      value: nightjarActivityHeightText(note.position),
    ),
    NightjarAssetFactData(
      label: 'Created at height',
      value: nightjarActivityHeightText(note.createdHeight),
    ),
    if (spentBy != null && spentBy.isNotEmpty)
      NightjarAssetFactData(
        label: 'Spent by',
        value: truncateNightjarAssetId(spentBy),
        copyText: spentBy,
      ),
    if (spentHeight != null)
      NightjarAssetFactData(
        label: 'Spent at height',
        value: nightjarActivityHeightText(spentHeight),
      ),
    // Shown only when the note carries one. A "None" would be a claim about a
    // spend condition; an absent row says the same thing without making it.
    if (policy != null && policy.isNotEmpty)
      NightjarAssetFactData(label: 'Policy', value: policy),
  ];
}

/// Heading for one note card. Notes have no names, so they are told apart by
/// the side they are on and numbered within it.
String nightjarActivityNoteCardTitle(
  NightjarActivityNoteRole role,
  int index,
  int count,
) {
  final base = role == NightjarActivityNoteRole.spent
      ? 'Note this message spent'
      : 'Note this message created';
  return count <= 1 ? base : '$base ${index + 1} of $count';
}

/// Desktop `/activity/nightjar/:messageId`.
class NightjarActivityDetailScreen extends ConsumerWidget {
  const NightjarActivityDetailScreen({required this.args, super.key});

  /// Null when the route was reached without a message.
  final NightjarActivityDetailArgs? args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: AppPaneScrollScaffold(
          toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: kNightjarCardWidth,
              child: NightjarActivityDetailBody(
                args: args,
                privacyModeEnabled: ref.watch(privacyModeProvider),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The receipt itself, without chrome, so the desktop pane, the mobile screen,
/// a test and Widgetbook all render the same thing.
class NightjarActivityDetailBody extends StatelessWidget {
  const NightjarActivityDetailBody({
    required this.args,
    this.showTitle = true,
    this.privacyModeEnabled = false,
    super.key,
  });

  /// Null when the route was reached without a message.
  final NightjarActivityDetailArgs? args;

  /// Desktop draws its own title; the mobile top nav already carries one.
  final bool showTitle;

  final bool privacyModeEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final args = this.args;

    if (args == null) {
      return const NightjarMessageCard(
        key: ValueKey('nightjar_activity_detail_missing'),
        text: kNightjarActivityDetailNoMessageText,
        width: kNightjarCardWidth,
      );
    }

    final spent = args.spentNotes.toList();
    final created = args.createdNotes.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTitle) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
            child: Text(
              args.assetTitle,
              key: const ValueKey('nightjar_activity_detail_title'),
              style: AppTypography.headlineSmall.copyWith(
                color: colors.text.accent,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.base),
        ],
        NightjarFactsCard(
          key: const ValueKey('nightjar_activity_detail_message'),
          title: 'Message',
          facts: buildNightjarActivityMessageFacts(
            args,
            privacyModeEnabled: privacyModeEnabled,
          ),
          footnote: nightjarActivityMessageFootnote(args),
        ),
        const SizedBox(height: AppSpacing.md),
        NightjarFactsCard(
          key: const ValueKey('nightjar_activity_detail_asset'),
          title: 'Asset',
          facts: buildNightjarActivityAssetFacts(args),
          footnote: nightjarActivityAssetFootnote(args),
        ),
        for (var i = 0; i < spent.length; i++) ...[
          const SizedBox(height: AppSpacing.md),
          NightjarFactsCard(
            key: ValueKey('nightjar_activity_detail_spent_note_$i'),
            title: nightjarActivityNoteCardTitle(
              NightjarActivityNoteRole.spent,
              i,
              spent.length,
            ),
            facts: buildNightjarActivityNoteFacts(
              spent[i],
              args.symbol,
              privacyModeEnabled: privacyModeEnabled,
            ),
          ),
        ],
        for (var i = 0; i < created.length; i++) ...[
          const SizedBox(height: AppSpacing.md),
          NightjarFactsCard(
            key: ValueKey('nightjar_activity_detail_created_note_$i'),
            title: nightjarActivityNoteCardTitle(
              NightjarActivityNoteRole.created,
              i,
              created.length,
            ),
            facts: buildNightjarActivityNoteFacts(
              created[i],
              args.symbol,
              privacyModeEnabled: privacyModeEnabled,
            ),
          ),
        ],
        if (spent.isEmpty && created.isEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          const NightjarMessageCard(
            key: ValueKey('nightjar_activity_detail_no_notes'),
            text:
                'This wallet holds no notes from this message. Whatever it '
                'appended is addressed to keys this wallet has not got.',
            width: kNightjarCardWidth,
          ),
        ],
        const SizedBox(height: AppSpacing.base),
      ],
    );
  }
}
