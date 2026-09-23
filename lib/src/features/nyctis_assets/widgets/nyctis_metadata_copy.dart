/// Every sentence the issuer-metadata surface says, and the pure functions
/// that pick between them.
///
/// Kept apart from the widgets for the same reason `nyctis_asset_row_mapper
/// .dart` is: both form factors and the Widgetbook fixtures go through exactly
/// the same text, and the section 5 rules are testable without a
/// `BuildContext`.
///
/// The hardest line in this file is [kNyctisMetadataNotEvidenceText].
/// `spec/asset-metadata-v0.md` section 5 forbids a wallet from treating the
/// presence of metadata, a logo, or a pinned digest as evidence of legitimacy
/// **or presenting it as such** — and a green check beside a verified digest
/// is exactly that presentation. A pin says the bytes did not change. It says
/// nothing at all about who published them.
library;

import '../models/nyctis_asset_acceptance.dart';
import '../models/nyctis_asset_metadata.dart';
import '../models/nyctis_metadata_pointer.dart';

/// Heading for the whole surface.
const String kNyctisMetadataTitle = 'Issuer details';

/// Shown before acceptance, inside "What this means". It says what a fetch
/// costs, because that is the entire decision the user is being asked to
/// make. "Your IP address", not "this address": the card sits beside a
/// Nyctis address, and the host learns the network one.
const String kNyctisMetadataNotFetchedText =
    'This asset points at a document on a host the issuer chose. The wallet '
    'has not asked for it: asking would tell that host that someone at your '
    'IP address (or your Tor exit) is looking at this asset.';

/// The one sentence the card says before its button.
String nyctisMetadataLeadText(String origin) =>
    'Showing issuer details contacts $origin, which learns that someone at '
    'your IP address (or your Tor exit) is looking at this asset.';

/// The acceptance action itself. "Show", the one verb every acceptance in
/// this wallet uses.
const String kNyctisMetadataAcceptAction = 'Show issuer details';

/// The line that must survive every redesign of this card.
const String kNyctisMetadataNotEvidenceText =
    'A name, a symbol and a logo are decoration, not proof. Anyone can publish '
    'the same three for a different asset, so check the asset id.';

/// Shown once accepted, while the fetch is in flight.
const String kNyctisMetadataLoadingText = 'Fetching issuer details…';

/// Withdraws acceptance. "Stop showing", not "forget": nothing about the
/// asset or its balance changes.
const String kNyctisMetadataForgetAction = 'Stop showing issuer details';

/// The second, deliberate step when the asset's name or symbol collides with
/// one already accepted. It names the check the user is asserting they made.
const String kNyctisCollisionConfirmAction =
    'I checked the asset id — show anyway';

/// The line above that second step.
const String kNyctisCollisionConfirmPrompt =
    'Continue only if the asset id above is the one you expected.';

/// Backs out of the second step.
const String kNyctisCollisionCancelAction = 'Cancel';

/// Label on the already-accepted side of a collision.
const String kNyctisCollisionExistingLabel = 'Already shown';

/// Label on this asset's side of a collision.
const String kNyctisCollisionThisAssetLabel = 'This asset';

/// Label for the row that names the host a document came from or would come
/// from.
const String kNyctisMetadataHostLabel = 'Metadata host';

/// Label for the pinned / not pinned row.
const String kNyctisMetadataPinLabel = 'Pinned';

/// Section 2.1: a signed `uri` covers the pointer, not the bytes.
const String kNyctisMetadataPinnedValue = 'Yes, by digest';
const String kNyctisMetadataUnpinnedValue = 'No';

/// The footnote under a pinned document.
const String kNyctisMetadataPinnedNote =
    'The signed link pins these bytes to a digest, so they are the bytes the '
    'issuer signed for. That says nothing about who the issuer is.';

/// The footnote under an unpinned one. Section 2.1: not invalid, revocable by
/// someone who is not the issuer.
const String kNyctisMetadataUnpinnedNote =
    'The signed link carries no digest, so whoever controls the host can '
    'change what it serves at any time, including after the issuer has lost '
    'it.';

/// Nothing usable arrived. Section 3.2: absent, not an error — the asset is
/// still an asset and its signed name and symbol still render.
String nyctisMetadataAbsentText(String origin) =>
    'Nothing usable came back from $origin. Nothing is lost: the asset and its '
    'balance are unaffected.';

/// Accepted, and the asset is a collection member: its details come from the
/// collection's shared document, which has no per-asset description to show.
String nyctisMetadataFromCollectionText(String origin) =>
    'This asset is described by its collection\'s document from $origin, '
    'not by a document of its own. Its artwork, when it has any, is shown '
    'with the piece.';

/// Accepted, fetched, and the document carried nothing this wallet draws.
const String kNyctisMetadataEmptyText =
    'The document is readable and carries nothing this wallet shows.';

/// Why a `uri` will not be resolved at all, or null when it will be.
///
/// Every one of these is stated plainly rather than hidden, because the user
/// is otherwise looking at an asset whose metadata never appears and no reason
/// why. None of them is a fault in the asset.
String? nyctisPointerRefusalText(NyctisPointerRejection? rejection) {
  return switch (rejection) {
    null || NyctisPointerRejection.absent => null,
    NyctisPointerRejection.insecureScheme =>
      'This asset points at an http link. The wallet only fetches metadata '
          'over https.',
    NyctisPointerRejection.unsupportedScheme =>
      'This asset points at an IPFS link. This wallet has no IPFS route and '
          'will not borrow somebody else’s gateway to reach one.',
    NyctisPointerRejection.forbiddenScheme =>
      'This asset points at a link the wallet will not open.',
    NyctisPointerRejection.malformedDigest =>
      'The signed link carries a digest that is not a digest, so nothing it '
          'served could ever match it.',
    NyctisPointerRejection.malformed =>
      'The signed link is not a link the wallet can read.',
  };
}

/// The section 5 warning, or null when there is no collision.
///
/// `SHOULD warn, at the moment of acceptance, when the asset's name or symbol
/// matches one the user has already accepted for a different asset_id. That
/// collision is the attack; it is cheap to detect and there is no honest
/// reason for the user not to be told.`
String? nyctisCollisionWarningText({
  required List<NyctisNameCollision> collisions,
  String? name,
  String? symbol,
}) {
  if (collisions.isEmpty) return null;
  final matchesName = collisions.any((collision) => collision.matchesName);
  final matchesSymbol = collisions.any((collision) => collision.matchesSymbol);
  final subject = collisions.length == 1
      ? 'another asset you already show details for'
      : '${collisions.length} other assets you already show details for';

  final buffer = StringBuffer('This asset shares ');
  if (matchesName && matchesSymbol) {
    buffer.write('its name and symbol with $subject.');
  } else if (matchesName) {
    final label = (name ?? '').trim();
    buffer.write(
      label.isEmpty
          ? 'its name with $subject.'
          : 'the name "$label" with $subject.',
    );
  } else {
    final label = (symbol ?? '').trim();
    buffer.write(
      label.isEmpty
          ? 'its symbol with $subject.'
          : 'the symbol "$label" with $subject.',
    );
  }
  buffer.write(
    ' That is how an impersonator looks. Nothing in Nyctis makes a name '
    'unique, so compare the asset ids below — they are the only way to tell '
    'the assets apart.',
  );
  return buffer.toString();
}

/// The already-accepted ids a collision warning points at, truncated.
List<String> nyctisCollisionAssetIds(List<NyctisNameCollision> collisions) => [
  for (final collision in collisions) collision.existing.assetId,
];

/// Display label for a `rel` this wallet recognizes.
///
/// Section 4.3 defines no tokens and reserves none; these are the suggested
/// ones in current use. An unrecognized `rel` gets no label because it gets no
/// row — the same section says a wallet renders the ones it recognizes and
/// ignores the rest.
String nyctisLinkLabel(String rel) {
  return switch (rel) {
    'x' => 'X',
    'github' => 'GitHub',
    'discord' => 'Discord',
    'telegram' => 'Telegram',
    'docs' => 'Docs',
    'forum' => 'Forum',
    'audit' => 'Audit',
    _ => rel,
  };
}

/// What a link button says it will open, before it opens it.
///
/// Section 4.3: a wallet **MUST NOT** open a link without an explicit user
/// action, and **SHOULD** show the origin it is about to open. The origin is
/// in the label rather than in a tooltip or a second dialog so that it is read
/// in the same glance as the decision.
String nyctisLinkActionLabel(NyctisAssetLink link) =>
    '${nyctisLinkLabel(link.rel)} · ${nyctisUriOrigin(link.uri)}';

/// The same, for the top-level `website` member.
String nyctisWebsiteActionLabel(Uri website) =>
    'Website · ${nyctisUriOrigin(website)}';
