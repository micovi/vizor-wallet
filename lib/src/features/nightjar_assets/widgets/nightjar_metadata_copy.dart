/// Every sentence the issuer-metadata surface says, and the pure functions
/// that pick between them.
///
/// Kept apart from the widgets for the same reason `nightjar_asset_row_mapper
/// .dart` is: both form factors and the Widgetbook fixtures go through exactly
/// the same text, and the section 5 rules are testable without a
/// `BuildContext`.
///
/// The hardest line in this file is [kNightjarMetadataNotEvidenceText].
/// `spec/asset-metadata-v0.md` section 5 forbids a wallet from treating the
/// presence of metadata, a logo, or a pinned digest as evidence of legitimacy
/// **or presenting it as such** — and a green check beside a verified digest
/// is exactly that presentation. A pin says the bytes did not change. It says
/// nothing at all about who published them.
library;

import '../models/nightjar_asset_acceptance.dart';
import '../models/nightjar_asset_metadata.dart';
import '../models/nightjar_metadata_pointer.dart';

/// Heading for the whole surface.
const String kNightjarMetadataTitle = 'Issuer metadata';

/// Shown before acceptance. It says what a fetch costs, because that is the
/// entire decision the user is being asked to make.
const String kNightjarMetadataNotFetchedText =
    'This asset points at a document on a host the issuer chose. The wallet '
    "has not asked for it: the request would tell that host that someone at "
    'this address is looking at this asset.';

/// The acceptance action itself.
const String kNightjarMetadataAcceptAction = 'Fetch issuer metadata';

/// The line that must survive every redesign of this card.
const String kNightjarMetadataNotEvidenceText =
    'A name, a symbol and a logo are decoration, not proof. Anyone can publish '
    'the same three for a different asset, so check the asset id.';

/// Shown once accepted, while the fetch is in flight.
const String kNightjarMetadataLoadingText = 'Fetching issuer metadata...';

/// Withdraws acceptance.
const String kNightjarMetadataForgetAction = 'Forget this metadata';

/// Label for the row that names the host a document came from or would come
/// from.
const String kNightjarMetadataHostLabel = 'Metadata host';

/// Label for the pinned / not pinned row.
const String kNightjarMetadataPinLabel = 'Pinned';

/// Section 2.1: a signed `uri` covers the pointer, not the bytes.
const String kNightjarMetadataPinnedValue = 'Yes, by digest';
const String kNightjarMetadataUnpinnedValue = 'No';

/// The footnote under a pinned document.
const String kNightjarMetadataPinnedNote =
    'The signed link pins these bytes to a digest, so they are the bytes the '
    'issuer signed for. That says nothing about who the issuer is.';

/// The footnote under an unpinned one. Section 2.1: not invalid, revocable by
/// someone who is not the issuer.
const String kNightjarMetadataUnpinnedNote =
    'The signed link carries no digest, so whoever controls the host can '
    'change what it serves at any time, including after the issuer has lost '
    'it.';

/// Nothing usable arrived. Section 3.2: absent, not an error — the asset is
/// still an asset and its signed name and symbol still render.
String nightjarMetadataAbsentText(String origin) =>
    'Nothing usable came back from $origin. Nothing is lost: the asset and its '
    'balance are unaffected.';

/// Accepted, fetched, and the document carried nothing this wallet draws.
const String kNightjarMetadataEmptyText =
    'The document is readable and carries nothing this wallet shows.';

/// Why a `uri` will not be resolved at all, or null when it will be.
///
/// Every one of these is stated plainly rather than hidden, because the user
/// is otherwise looking at an asset whose metadata never appears and no reason
/// why. None of them is a fault in the asset.
String? nightjarPointerRefusalText(NightjarPointerRejection? rejection) {
  return switch (rejection) {
    null || NightjarPointerRejection.absent => null,
    NightjarPointerRejection.insecureScheme =>
      'This asset points at an http link. The wallet only fetches metadata '
          'over https.',
    NightjarPointerRejection.unsupportedScheme =>
      'This asset points at an IPFS link. This wallet has no IPFS route and '
          'will not borrow somebody else’s gateway to reach one.',
    NightjarPointerRejection.forbiddenScheme =>
      'This asset points at a link the wallet will not open.',
    NightjarPointerRejection.malformedDigest =>
      'The signed link carries a digest that is not a digest, so nothing it '
          'served could ever match it.',
    NightjarPointerRejection.malformed =>
      'The signed link is not a link the wallet can read.',
  };
}

/// The section 5 warning, or null when there is no collision.
///
/// `SHOULD warn, at the moment of acceptance, when the asset's name or symbol
/// matches one the user has already accepted for a different asset_id. That
/// collision is the attack; it is cheap to detect and there is no honest
/// reason for the user not to be told.`
String? nightjarCollisionWarningText({
  required List<NightjarNameCollision> collisions,
  String? name,
  String? symbol,
}) {
  if (collisions.isEmpty) return null;
  final matchesName = collisions.any((collision) => collision.matchesName);
  final matchesSymbol = collisions.any((collision) => collision.matchesSymbol);
  final subject = collisions.length == 1
      ? 'another asset you have already accepted'
      : '${collisions.length} other assets you have already accepted';

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
    ' Nothing in Nightjar makes a name unique and anyone may reuse one, so '
    'the asset ids are the only way to tell them apart.',
  );
  return buffer.toString();
}

/// The already-accepted ids a collision warning points at, truncated.
List<String> nightjarCollisionAssetIds(
  List<NightjarNameCollision> collisions,
) => [for (final collision in collisions) collision.existing.assetId];

/// Display label for a `rel` this wallet recognizes.
///
/// Section 4.3 defines no tokens and reserves none; these are the suggested
/// ones in current use. An unrecognized `rel` gets no label because it gets no
/// row — the same section says a wallet renders the ones it recognizes and
/// ignores the rest.
String nightjarLinkLabel(String rel) {
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
String nightjarLinkActionLabel(NightjarAssetLink link) =>
    '${nightjarLinkLabel(link.rel)} · ${nightjarUriOrigin(link.uri)}';

/// The same, for the top-level `website` member.
String nightjarWebsiteActionLabel(Uri website) =>
    'Website · ${nightjarUriOrigin(website)}';
