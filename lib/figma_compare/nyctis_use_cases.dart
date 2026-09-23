// ignore_for_file: depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
// Figma comparison tooling is dev-only. The status screens' broadcast runner
// is a test seam, and a capture is the one non-test caller that needs it: it
// is how a deterministic "sending", "sent" or "failed" frame is reached
// without the Rust bridge.

/// Deterministic captures of every Nyctis screen and its meaningful states.
///
/// Each scenario renders the **production** screen widget — the desktop
/// screen with its real `AppMainSidebar`, or the mobile screen — inside a
/// `ProviderScope` whose every Nyctis seam is a fixture: the replayed view,
/// the acceptance set, the artwork fetch, the proving-key check, the chain
/// tip, the block-time loader and the broadcast runner. Nothing reaches Rust,
/// secure storage or the network, so two runs produce the same pixels.
///
/// The ids are all `nyctis-*`; `scripts/nyctis-screenshots.sh` renders
/// every one of them in both themes and both form factors.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';

import '../src/app_bootstrap.dart';
import '../src/core/config/nyctis_config.dart';
import '../src/core/config/rpc_endpoint_config.dart';
import '../src/core/widgets/app_icon.dart';
import '../src/core/layout/app_form_factor.dart';
import '../src/core/layout/mobile/app_mobile_shell.dart';
import '../src/core/layout/mobile/app_mobile_tab_bar.dart';
import '../src/core/profile_pictures.dart';
import '../src/core/theme/app_theme.dart';
import '../src/features/activity/gift_card_activity_index.dart';
import '../src/features/activity/nyctis_activity_message.dart';
import '../src/features/activity/nyctis_activity_provider.dart';
import '../src/features/activity/screens/activity_screen.dart';
import '../src/features/activity/screens/mobile/mobile_activity_screen.dart';
import '../src/features/activity/screens/mobile/mobile_nyctis_activity_detail_screen.dart';
import '../src/features/activity/screens/nyctis_activity_detail_screen.dart';
import '../src/features/activity/swap_activity_row_items_provider.dart';
import '../src/features/nyctis_assets/models/nyctis_asset_acceptance.dart';
import '../src/features/nyctis_assets/models/nyctis_asset_metadata.dart';
import '../src/features/nyctis_assets/models/nyctis_collection_metadata.dart';
import '../src/features/nyctis_assets/providers/nyctis_asset_acceptance_provider.dart';
import '../src/features/nyctis_assets/providers/nyctis_asset_metadata_provider.dart';
import '../src/features/nyctis_assets/providers/nyctis_assets_view_provider.dart';
import '../src/features/nyctis_assets/providers/nyctis_collection_artwork_provider.dart';
import '../src/features/nyctis_assets/providers/nyctis_proving_key_provider.dart';
import '../src/features/nyctis_assets/screens/mobile/mobile_nyctis_asset_detail_screen.dart';
import '../src/features/nyctis_assets/screens/mobile/mobile_nyctis_assets_screen.dart';
import '../src/features/nyctis_assets/screens/mobile/mobile_nyctis_collection_screen.dart';
import '../src/features/nyctis_assets/screens/mobile/mobile_nyctis_receive_screen.dart';
import '../src/features/nyctis_assets/screens/mobile/mobile_nyctis_send_review_screen.dart';
import '../src/features/nyctis_assets/screens/mobile/mobile_nyctis_send_screen.dart';
import '../src/features/nyctis_assets/screens/mobile/mobile_nyctis_send_status_screen.dart';
import '../src/features/nyctis_assets/screens/nyctis_asset_detail_screen.dart';
import '../src/features/nyctis_assets/screens/nyctis_assets_screen.dart';
import '../src/features/nyctis_assets/screens/nyctis_collection_screen.dart';
import '../src/features/nyctis_assets/screens/nyctis_receive_screen.dart';
import '../src/features/nyctis_assets/screens/nyctis_send_review_screen.dart';
import '../src/features/nyctis_assets/screens/nyctis_send_screen.dart';
import '../src/features/nyctis_assets/screens/nyctis_send_status_screen.dart';
import '../src/features/nyctis_assets/services/nyctis_metadata_fetcher.dart';
import '../src/features/nyctis_assets/services/nyctis_send_flow.dart';
import '../src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import '../src/features/settings/screens/mobile/mobile_nyctis_screen.dart';
import '../src/features/settings/screens/settings_nyctis_screen.dart';
import '../src/providers/account_provider.dart';
import '../src/providers/nyctis_config_provider.dart';
import '../src/providers/sync_provider.dart';
import '../src/rust/api/sync.dart' as rust_sync;
import 'figma_compare_scenarios.dart' show FigmaCompareScenario;
import 'nyctis_capture_artwork.dart';

// ---------------------------------------------------------------------------
// Scenario registry
// ---------------------------------------------------------------------------

/// Every Nyctis scenario. Each one renders on desktop and on mobile; the
/// builder picks the screen for the compiled form factor.
const nyctisFigmaCompareScenarios = <FigmaCompareScenario>[
  // Assets list
  FigmaCompareScenario(
    id: 'nyctis-assets',
    description: 'Nyctis assets: tokens, two collections, pending notice',
    builder: _assets,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-assets-empty',
    description: 'Nyctis assets: channel read, nothing held',
    builder: _assetsEmpty,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-assets-loading',
    description: 'Nyctis assets: first replay still running',
    builder: _assetsLoading,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-assets-not-configured',
    description: 'Nyctis assets: no channel configured',
    builder: _assetsNotConfigured,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-assets-unreachable',
    description: 'Nyctis assets: indexer unreachable',
    builder: _assetsUnreachable,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-assets-stale',
    description: 'Nyctis assets: indexer behind the chain',
    builder: _assetsStale,
    mobile: true,
  ),
  // Fungible asset detail
  FigmaCompareScenario(
    id: 'nyctis-asset-public',
    description: 'Public asset, metadata offered but not accepted',
    builder: _assetPublic,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-asset-public-accepted',
    description: 'Public asset with accepted metadata and logo',
    builder: _assetPublicAccepted,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-asset-public-metadata-loading',
    description: 'Public asset, accepted, metadata fetch in flight',
    builder: _assetPublicMetadataLoading,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-asset-public-metadata-refused',
    description: 'Public asset, accepted, metadata refused (digest)',
    builder: _assetPublicMetadataRefused,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-asset-unnamed',
    description: 'Public asset nobody named, no metadata pointer',
    builder: _assetUnnamed,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-asset-private',
    description: 'Private asset: no supply figure, non-transferable note',
    builder: _assetPrivate,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-asset-no-proving-key',
    description: 'Public asset with Send disabled: no proving key',
    builder: _assetNoProvingKey,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-asset-missing',
    description: 'Asset detail for an id the view does not hold',
    builder: _assetMissing,
    mobile: true,
  ),
  // Collections
  FigmaCompareScenario(
    id: 'nyctis-collection-capped',
    description: 'Capped collection, 10 of 100 issued, artwork loaded',
    builder: _collectionCapped,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-collection-not-accepted',
    description: 'Capped collection before any piece is accepted',
    builder: _collectionNotAccepted,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-collection-artwork-pending',
    description: 'Accepted collection, every artwork fetch in flight',
    builder: _collectionPending,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-collection-artwork-failed',
    description: 'Accepted collection, every artwork refused',
    builder: _collectionFailed,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-collection-artwork-mixed',
    description: 'Verified, unpinned, refused and pending tiles together',
    builder: _collectionMixed,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-collection-partial',
    description: 'Collection with one piece accepted and the rest not',
    builder: _collectionPartial,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-collection-cap-mismatch',
    description: 'Document max_supply disagrees with the on-chain cap',
    builder: _collectionCapMismatch,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-collection-uncapped',
    description: 'Uncapped collection with a derived face',
    builder: _collectionUncapped,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-collection-item',
    description: 'One owned piece of a collection, artwork loaded',
    builder: _collectionItem,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-collection-item-not-owned',
    description: 'A piece this wallet does not hold, not accepted',
    builder: _collectionItemNotOwned,
    mobile: true,
  ),
  // Receive
  FigmaCompareScenario(
    id: 'nyctis-receive',
    description: 'Receive: Nyctis address and QR',
    builder: _receive,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-receive-not-configured',
    description: 'Receive with no channel configured',
    builder: _receiveNotConfigured,
    mobile: true,
  ),
  // Send
  FigmaCompareScenario(
    id: 'nyctis-send-empty',
    description: 'Send composer, nothing entered',
    builder: _sendEmpty,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-filled',
    description: 'Send composer with recipient and amount, Review enabled',
    builder: _sendFilled,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-over-balance',
    description: 'Send composer: amount above the held balance',
    builder: _sendOverBalance,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-too-many-decimals',
    description: 'Send composer: more decimals than the asset has',
    builder: _sendTooManyDecimals,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-no-proving-key',
    description: 'Send composer with no proving key configured',
    builder: _sendNoProvingKey,
    mobile: true,
  ),
  // Review
  FigmaCompareScenario(
    id: 'nyctis-send-review',
    description: 'Review: fresh plan, ZEC cost stated',
    builder: _review,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-review-aging',
    description: 'Review: plan close to leaving the anchor window',
    builder: _reviewAging,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-review-expired',
    description: 'Review: plan expired, Send disabled',
    builder: _reviewExpired,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-review-channel-changed',
    description: 'Review: channel changed since the plan was built',
    builder: _reviewChannelChanged,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-review-no-plan',
    description: 'Review reached without a plan',
    builder: _reviewNoPlan,
    mobile: true,
  ),
  // Status
  FigmaCompareScenario(
    id: 'nyctis-send-status-sending',
    description: 'Status: signing and broadcasting',
    builder: _statusSending,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-status-sent',
    description: 'Status: broadcast, waiting for finality',
    builder: _statusSent,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-status-pending',
    description: 'Status: created but not on the network yet',
    builder: _statusPending,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-status-failed',
    description: 'Status: failed after the ZEC was spent',
    builder: _statusFailed,
    mobile: true,
  ),
  // Activity
  FigmaCompareScenario(
    id: 'nyctis-activity',
    description: 'Activity feed with Nyctis rows beside ZEC',
    builder: _activity,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-activity-detail-sent',
    description: 'Nyctis receipt: a send with an unreadable output',
    builder: _activityDetailSent,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-activity-detail-received',
    description: 'Nyctis receipt: an unnamed asset arriving',
    builder: _activityDetailReceived,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-activity-detail-net',
    description: 'Nyctis receipt: a part-funded message (net change)',
    builder: _activityDetailNet,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-activity-detail-settling',
    description: 'Nyctis receipt: below the finality depth',
    builder: _activityDetailSettling,
    mobile: true,
  ),
  // Settings
  FigmaCompareScenario(
    id: 'nyctis-settings',
    description: 'Nyctis settings: channel configured, proving key ready',
    builder: _settings,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-settings-key-not-set',
    description: 'Nyctis settings: no proving key folder',
    builder: _settingsKeyNotSet,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-settings-wrong-key',
    description: 'Nyctis settings: proving key from another ceremony',
    builder: _settingsWrongKey,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-settings-unavailable',
    description: 'Nyctis settings on a network with no channel',
    builder: _settingsUnavailable,
    mobile: true,
  ),
  // Large text (mobile only): the densest screens at 1.8x.
  FigmaCompareScenario(
    id: 'nyctis-assets-large-text',
    description: 'Mobile Nyctis assets at 1.8x text',
    builder: _assetsLargeText,
    desktop: false,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-asset-public-accepted-large-text',
    description: 'Mobile public asset detail at 1.8x text',
    builder: _assetPublicAcceptedLargeText,
    desktop: false,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-collection-capped-large-text',
    description: 'Mobile capped collection at 1.8x text',
    builder: _collectionCappedLargeText,
    desktop: false,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-filled-large-text',
    description: 'Mobile send composer at 1.8x text',
    builder: _sendFilledLargeText,
    desktop: false,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-send-review-large-text',
    description: 'Mobile send review at 1.8x text',
    builder: _reviewLargeText,
    desktop: false,
    mobile: true,
  ),
  FigmaCompareScenario(
    id: 'nyctis-activity-detail-sent-large-text',
    description: 'Mobile Nyctis receipt at 1.8x text',
    builder: _activityDetailSentLargeText,
    desktop: false,
    mobile: true,
  ),
];

/// Text scale used by every `*-large-text` scenario.
const double kNyctisLargeTextScale = 1.8;

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

bool get _mobile => kAppFormFactor == AppFormFactor.mobile;

Widget _assets(BuildContext context) => _capture(
  context,
  fixture: _listFixture(_readyView()),
  route: const _Route('/nyctis'),
  desktop: () => const NyctisAssetsScreen(),
  mobile: () => const MobileNyctisAssetsScreen(),
);

Widget _assetsLargeText(BuildContext context) => _capture(
  context,
  fixture: _listFixture(_readyView()),
  route: const _Route('/nyctis'),
  desktop: () => const NyctisAssetsScreen(),
  mobile: () => const MobileNyctisAssetsScreen(),
  textScale: kNyctisLargeTextScale,
);

Widget _assetsEmpty(BuildContext context) =>
    _assetsWith(context, _readyView(assets: const [], pendingMessageCount: 0));

Widget _assetsLoading(BuildContext context) => _assetsWith(context, null);

Widget _assetsNotConfigured(BuildContext context) =>
    _assetsWith(context, const NyctisViewData.notConfigured());

Widget _assetsUnreachable(BuildContext context) => _assetsWith(
  context,
  const NyctisViewData(
    status: NyctisViewStatus.unreachable,
    statusDetail: 'Connection refused (os error 61), address = 127.0.0.1:8080',
  ),
);

Widget _assetsStale(BuildContext context) => _assetsWith(
  context,
  _readyView(
    status: NyctisViewStatus.stale,
    indexerHeight: 1180,
    pendingMessageCount: 0,
  ),
);

Widget _assetsWith(BuildContext context, NyctisViewData? view) => _capture(
  context,
  fixture: _listFixture(view),
  route: const _Route('/nyctis'),
  desktop: () => const NyctisAssetsScreen(),
  mobile: () => const MobileNyctisAssetsScreen(),
);

/// The list as a user who accepted Harbour credit and the moon collection
/// sees it: one logo, one collection face, one collection still unaccepted.
_Fixture _listFixture(NyctisViewData? view) => _Fixture(
  view: view,
  acceptance: _acceptHarbourAndPhases,
  art: {
    _harbourId: _Art.harbourMetadata,
    for (var i = 0; i < _phasesIssued; i++)
      _phasesMemberId(i): _Art.moonVerified,
  },
);

Widget _assetDetail(
  BuildContext context,
  String assetId, {
  NyctisAssetAcceptance acceptance = const NyctisAssetAcceptance.empty(),
  Map<String, _Art> art = const {},
  NyctisProvingKeyStatus? provingKey,
  double? textScale,
  NyctisViewData? view,
}) => _capture(
  context,
  fixture: _Fixture(
    view: view ?? _readyView(pendingMessageCount: 0),
    acceptance: acceptance,
    art: art,
    provingKey: provingKey,
  ),
  route: _Route('/nyctis/$assetId', parent: '/nyctis'),
  desktop: () => NyctisAssetDetailScreen(assetId: assetId),
  mobile: () => MobileNyctisAssetDetailScreen(assetId: assetId),
  textScale: textScale,
);

Widget _assetPublic(BuildContext context) => _assetDetail(context, _harbourId);

Widget _assetPublicAccepted(BuildContext context) => _assetDetail(
  context,
  _harbourId,
  acceptance: _acceptHarbour,
  art: const {_harbourId: _Art.harbourMetadata},
);

Widget _assetPublicAcceptedLargeText(BuildContext context) => _assetDetail(
  context,
  _harbourId,
  acceptance: _acceptHarbour,
  art: const {_harbourId: _Art.harbourMetadata},
  textScale: kNyctisLargeTextScale,
);

Widget _assetPublicMetadataLoading(BuildContext context) => _assetDetail(
  context,
  _harbourId,
  acceptance: _acceptHarbour,
  art: const {_harbourId: _Art.pending},
);

Widget _assetPublicMetadataRefused(BuildContext context) => _assetDetail(
  context,
  _harbourId,
  acceptance: _acceptHarbour,
  art: const {_harbourId: _Art.refusedDigest},
);

Widget _assetUnnamed(BuildContext context) => _assetDetail(context, _unnamedId);

Widget _assetPrivate(BuildContext context) =>
    _assetDetail(context, _crewPassId);

Widget _assetNoProvingKey(BuildContext context) =>
    _assetDetail(context, _harbourId, provingKey: _notSetProvingKey);

Widget _assetMissing(BuildContext context) => _assetDetail(
  context,
  'ffee00112233445566778899aabbccddeeff00112233445566778899aabbccdd',
);

Widget _collection(
  BuildContext context,
  String collectionId, {
  required NyctisAssetAcceptance acceptance,
  _Art Function(int index)? artFor,
  int? documentMaxSupply,
  double? textScale,
}) {
  final view = _readyView(pendingMessageCount: 0);
  final art = <String, _Art>{
    if (artFor != null)
      for (final asset in view.assets)
        if (asset.collection == collectionId && asset.index != null)
          asset.assetId: artFor(asset.index!),
  };
  return _capture(
    context,
    fixture: _Fixture(
      view: view,
      acceptance: acceptance,
      art: art,
      documentMaxSupply: documentMaxSupply,
    ),
    route: _Route('/nyctis/collection/$collectionId', parent: '/nyctis'),
    desktop: () => NyctisCollectionScreen(collectionId: collectionId),
    mobile: () => MobileNyctisCollectionScreen(collectionId: collectionId),
    textScale: textScale,
  );
}

Widget _collectionCapped(BuildContext context) => _collection(
  context,
  _phasesId,
  acceptance: _acceptPhases,
  artFor: (_) => _Art.moonVerified,
);

Widget _collectionCappedLargeText(BuildContext context) => _collection(
  context,
  _phasesId,
  acceptance: _acceptPhases,
  artFor: (_) => _Art.moonVerified,
  textScale: kNyctisLargeTextScale,
);

Widget _collectionNotAccepted(BuildContext context) => _collection(
  context,
  _phasesId,
  acceptance: const NyctisAssetAcceptance.empty(),
);

Widget _collectionPending(BuildContext context) => _collection(
  context,
  _phasesId,
  acceptance: _acceptPhases,
  artFor: (_) => _Art.pending,
);

Widget _collectionFailed(BuildContext context) => _collection(
  context,
  _phasesId,
  acceptance: _acceptPhases,
  artFor: (_) => _Art.refusedHttp,
);

Widget _collectionMixed(BuildContext context) => _collection(
  context,
  _phasesId,
  acceptance: _acceptPhases,
  artFor: (index) => switch (index) {
    < 5 => _Art.moonVerified,
    5 || 6 => _Art.moonUnpinned,
    7 => _Art.moonRefusedDigest,
    _ => _Art.pending,
  },
);

Widget _collectionPartial(BuildContext context) => _collection(
  context,
  _phasesId,
  acceptance: NyctisAssetAcceptance([
    NyctisAcceptedAsset(
      assetId: _phasesMemberId(4),
      name: 'PHASES #4',
      symbol: 'PHASE',
    ),
  ]),
  artFor: (_) => _Art.moonVerified,
);

Widget _collectionCapMismatch(BuildContext context) => _collection(
  context,
  _phasesId,
  acceptance: _acceptPhases,
  artFor: (_) => _Art.moonVerified,
  documentMaxSupply: 120,
);

Widget _collectionUncapped(BuildContext context) => _collection(
  context,
  _ticketsId,
  acceptance: _acceptTickets,
  artFor: (_) => _Art.ticketUnpinned,
);

Widget _collectionItem(BuildContext context) => _assetDetail(
  context,
  _phasesMemberId(4),
  acceptance: _acceptPhases,
  art: {
    for (var i = 0; i < _phasesIssued; i++)
      _phasesMemberId(i): _Art.moonVerified,
  },
);

Widget _collectionItemNotOwned(BuildContext context) =>
    _assetDetail(context, _phasesMemberId(8));

Widget _receive(BuildContext context) => _capture(
  context,
  fixture: _Fixture(view: _readyView()),
  route: const _Route('/nyctis/receive', parent: '/nyctis'),
  desktop: () => const NyctisReceiveScreen(),
  mobile: () => const MobileNyctisReceiveScreen(),
);

Widget _receiveNotConfigured(BuildContext context) => _capture(
  context,
  fixture: const _Fixture(view: NyctisViewData.notConfigured()),
  route: const _Route('/nyctis/receive', parent: '/nyctis'),
  desktop: () => const NyctisReceiveScreen(),
  mobile: () => const MobileNyctisReceiveScreen(),
);

Widget _send(
  BuildContext context, {
  Map<String, String> prefill = const {},
  NyctisProvingKeyStatus? provingKey,
  double? textScale,
}) => _capture(
  context,
  fixture: _Fixture(
    view: _readyView(pendingMessageCount: 0),
    provingKey: provingKey,
    prefill: prefill,
  ),
  route: const _Route(
    '/nyctis/$_harbourId/send',
    parent: '/nyctis/$_harbourId',
  ),
  desktop: () => const NyctisSendScreen(assetId: _harbourId),
  mobile: () => const MobileNyctisSendScreen(assetId: _harbourId),
  textScale: textScale,
);

Widget _sendEmpty(BuildContext context) => _send(context);

Widget _sendFilled(BuildContext context) => _send(
  context,
  prefill: const {
    'nyctis_send_recipient_field': _recipientAddress,
    'nyctis_send_amount_field': '0.5',
  },
);

Widget _sendFilledLargeText(BuildContext context) => _send(
  context,
  prefill: const {
    'nyctis_send_recipient_field': _recipientAddress,
    'nyctis_send_amount_field': '0.5',
  },
  textScale: kNyctisLargeTextScale,
);

Widget _sendOverBalance(BuildContext context) => _send(
  context,
  prefill: const {
    'nyctis_send_recipient_field': _recipientAddress,
    'nyctis_send_amount_field': '4',
  },
);

Widget _sendTooManyDecimals(BuildContext context) => _send(
  context,
  prefill: const {
    'nyctis_send_recipient_field': _recipientAddress,
    'nyctis_send_amount_field': '0.1234567',
  },
);

Widget _sendNoProvingKey(BuildContext context) =>
    _send(context, provingKey: _notSetProvingKey);

Widget _reviewWith(
  BuildContext context, {
  NyctisSendReviewArgs? args,
  int chainTip = _chainTip,
  NyctisConfig? config,
  double? textScale,
}) => _capture(
  context,
  fixture: _Fixture(
    view: _readyView(pendingMessageCount: 0),
    chainTip: chainTip,
    config: config ?? _configuredConfig,
  ),
  // Production pushes review over the composer; nesting under the shared
  // `/nyctis/send` prefix gives the same two-entry stack and back label.
  route: const _Route(nyctisSendReviewRoute, parent: '/nyctis/send'),
  desktop: () => NyctisSendReviewScreen(args: args),
  mobile: () => MobileNyctisSendReviewScreen(args: args),
  textScale: textScale,
);

Widget _review(BuildContext context) =>
    _reviewWith(context, args: _reviewArgs());

Widget _reviewLargeText(BuildContext context) => _reviewWith(
  context,
  args: _reviewArgs(),
  textScale: kNyctisLargeTextScale,
);

Widget _reviewAging(BuildContext context) =>
    _reviewWith(context, args: _reviewArgs(), chainTip: _anchorHeight + 172);

Widget _reviewExpired(BuildContext context) =>
    _reviewWith(context, args: _reviewArgs(), chainTip: _anchorHeight + 240);

Widget _reviewChannelChanged(BuildContext context) => _reviewWith(
  context,
  args: _reviewArgs(),
  config: _configuredConfig.copyWith(
    channelAddress: 'uregtest1otherchannelq2w3e4r5t6y7u8i9o0pasdfghjkl',
  ),
);

Widget _reviewNoPlan(BuildContext context) => _reviewWith(context);

Widget _status(BuildContext context, NyctisSendOutcome? outcome) {
  final args = _reviewArgs();
  final runner = _runner(outcome);
  return _capture(
    context,
    fixture: _Fixture(view: _readyView(pendingMessageCount: 0)),
    route: const _Route(nyctisSendStatusRoute, parent: '/nyctis/send'),
    desktop: () =>
        NyctisSendStatusScreen(args: args, broadcastRunner: runner),
    mobile: () =>
        MobileNyctisSendStatusScreen(args: args, broadcastRunner: runner),
  );
}

Widget _statusSending(BuildContext context) => _status(context, null);

Widget _statusSent(BuildContext context) => _status(
  context,
  const NyctisSendOutcome(
    phase: NyctisSendOutcomePhase.succeeded,
    proposalConsumed: true,
    txid: _txid,
  ),
);

Widget _statusPending(BuildContext context) => _status(
  context,
  const NyctisSendOutcome(
    phase: NyctisSendOutcomePhase.pendingBroadcast,
    proposalConsumed: true,
    txid: _txid,
    statusMessage:
        'The transaction was created locally but has not reached the '
        'network yet. It will retry automatically. Do not send this payment '
        'again unless it expires.',
  ),
);

Widget _statusFailed(BuildContext context) => _status(
  context,
  const NyctisSendOutcome(
    phase: NyctisSendOutcomePhase.failed,
    proposalConsumed: true,
    txid: _txid,
    error:
        'This payment was split across 2 transactions, so the channel '
        'cannot reassemble it. The ZEC was spent and the asset did not move. '
        'Report this before trying again.',
  ),
);

Widget _activity(BuildContext context) => _capture(
  context,
  fixture: _Fixture(
    view: _readyView(),
    acceptance: _acceptHarbour,
    art: const {_harbourId: _Art.harbourMetadata},
  ),
  route: const _Route('/activity'),
  desktop: () => ActivityScreen(historyLoader: _zecHistory),
  mobile: () => AppMobileShell(
    body: MobileActivityScreen(historyLoader: _zecHistory),
    tabBar: AppMobileTabBar(
      items: const [
        AppMobileTabItem(iconName: AppIcons.home, label: 'Home'),
        AppMobileTabItem(iconName: AppIcons.swapArrows, label: 'Swap'),
        AppMobileTabItem(iconName: AppIcons.history, label: 'Activity'),
        AppMobileTabItem(iconName: AppIcons.cog, label: 'Settings'),
      ],
      currentIndex: 2,
      onSelect: (_) {},
    ),
  ),
);

Widget _activityDetail(
  BuildContext context,
  NyctisActivityDetailArgs args, {
  double? textScale,
}) => _capture(
  context,
  fixture: _Fixture(view: _readyView()),
  route: _Route('/activity/nyctis/${args.item.msgId}', parent: '/activity'),
  desktop: () => NyctisActivityDetailScreen(args: args),
  mobile: () => MobileNyctisActivityDetailScreen(args: args),
  textScale: textScale,
);

Widget _activityDetailSent(BuildContext context) =>
    _activityDetail(context, _sentArgs());

Widget _activityDetailSentLargeText(BuildContext context) =>
    _activityDetail(context, _sentArgs(), textScale: kNyctisLargeTextScale);

Widget _activityDetailReceived(BuildContext context) =>
    _activityDetail(context, _receivedArgs());

Widget _activityDetailNet(BuildContext context) =>
    _activityDetail(context, _netArgs());

Widget _activityDetailSettling(BuildContext context) => _activityDetail(
  context,
  _receivedArgs(state: NyctisActivityMessageState.belowFinality),
);

Widget _settingsWith(
  BuildContext context, {
  required NyctisConfig config,
  required NyctisProvingKeyStatus provingKey,
}) => _capture(
  context,
  fixture: _Fixture(
    view: _readyView(),
    config: config,
    provingKey: provingKey,
    network: config.networkName,
  ),
  route: const _Route('/settings/nyctis', parent: '/settings'),
  desktop: () => const SettingsNyctisScreen(),
  mobile: () => const MobileNyctisScreen(),
);

Widget _settings(BuildContext context) => _settingsWith(
  context,
  config: _configuredConfig,
  provingKey: _readyProvingKey,
);

Widget _settingsKeyNotSet(BuildContext context) => _settingsWith(
  context,
  config: _configuredConfig.copyWith(provingKeyDir: ''),
  provingKey: _notSetProvingKey,
);

Widget _settingsWrongKey(BuildContext context) => _settingsWith(
  context,
  config: _configuredConfig,
  provingKey: const NyctisProvingKeyStatus(
    state: NyctisProvingKeyState.wrongKeySet,
    dir: _provingKeyDir,
    circuit: 'constraints=136119;instances=30',
    vkHash: '0a41c6d5e2f3b4a59687f8e9d0c1b2a3948576a6b5c4d3e2f1a0b9c8d7e6f5a4',
    channelVkHash: _vkHash,
    message:
        'This proving key was made by a different setup than the one this '
        'channel verifies with. Proofs made with it would be rejected by '
        'every verifier.',
  ),
);

Widget _settingsUnavailable(BuildContext context) => _settingsWith(
  context,
  config: defaultNyctisConfig('main'),
  provingKey: _notSetProvingKey,
);

// ---------------------------------------------------------------------------
// Capture host
// ---------------------------------------------------------------------------

/// Where the screen sits in the router, so the sidebar highlights the right
/// item and the back link resolves the way it does after a real push.
///
/// [parent], when given, must be a path prefix of [location].
class _Route {
  const _Route(this.location, {this.parent});

  final String location;
  final String? parent;
}

Widget _capture(
  BuildContext context, {
  required _Fixture fixture,
  required _Route route,
  required Widget Function() desktop,
  required Widget Function() mobile,
  double? textScale,
}) {
  Widget screen = _NyctisRouterHost(
    route: route,
    builder: _mobile ? mobile : desktop,
  );
  if (_mobile) {
    // The mobile Nyctis screens return a bare `SafeArea` where their
    // siblings (receive, seed phrase, Nyctis settings) return a `Scaffold`
    // with the window colour, so they paint no background of their own and
    // the capture would come out transparent. Paint the colour every sibling
    // screen uses, so what is reviewed is the intended screen.
    screen = ColoredBox(color: context.colors.background.window, child: screen);
  }
  if (fixture.prefill.isNotEmpty) {
    screen = _NyctisPrefill(values: fixture.prefill, child: screen);
  }
  if (textScale != null) {
    screen = MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: screen,
    );
  }
  return ProviderScope(overrides: _overrides(fixture), child: screen);
}

class _NyctisRouterHost extends StatefulWidget {
  const _NyctisRouterHost({required this.route, required this.builder});

  final _Route route;
  final Widget Function() builder;

  @override
  State<_NyctisRouterHost> createState() => _NyctisRouterHostState();
}

class _NyctisRouterHostState extends State<_NyctisRouterHost> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    final route = widget.route;
    final parent = route.parent;
    final screen = GoRoute(
      path: parent == null
          ? route.location
          : route.location.substring(parent.length + 1),
      builder: (_, _) => widget.builder(),
    );
    _router = GoRouter(
      initialLocation: route.location,
      routes: [
        if (parent == null)
          screen
        else
          GoRoute(
            path: parent,
            builder: (_, _) => const SizedBox.shrink(),
            routes: [screen],
          ),
      ],
    );
  }

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Router.withConfig(config: _router);
}

/// Types into the text fields keyed in [values] once they exist.
///
/// It goes through [EditableTextState.userUpdateTextEditingValue], which is
/// what a keystroke does, so the screen's own `onChanged` runs and its
/// validation renders exactly as it would for a user. The fields appear only
/// after the view future resolves, so it retries for a few frames.
class _NyctisPrefill extends StatefulWidget {
  const _NyctisPrefill({required this.values, required this.child});

  final Map<String, String> values;
  final Widget child;

  @override
  State<_NyctisPrefill> createState() => _NyctisPrefillState();
}

class _NyctisPrefillState extends State<_NyctisPrefill> {
  var _attempts = 0;
  final _done = <String>{};

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
    WidgetsBinding.instance.scheduleFrame();
  }

  void _apply() {
    if (!mounted) return;
    for (final entry in widget.values.entries) {
      if (_done.contains(entry.key)) continue;
      final state = _editableFor(ValueKey(entry.key));
      if (state == null) continue;
      state.userUpdateTextEditingValue(
        TextEditingValue(
          text: entry.value,
          selection: TextSelection.collapsed(offset: entry.value.length),
        ),
        SelectionChangedCause.keyboard,
      );
      _done.add(entry.key);
    }
    if (_done.length < widget.values.length && ++_attempts < 30) _schedule();
  }

  EditableTextState? _editableFor(Key key) {
    Element? field;
    void findField(Element element) {
      if (field != null) return;
      if (element.widget.key == key) {
        field = element;
        return;
      }
      element.visitChildElements(findField);
    }

    (context as Element).visitChildElements(findField);
    final found = field;
    if (found == null) return null;

    EditableTextState? editable;
    void findEditable(Element element) {
      if (editable != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        editable = element.state as EditableTextState;
        return;
      }
      element.visitChildElements(findEditable);
    }

    findEditable(found);
    return editable;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ---------------------------------------------------------------------------
// Provider overrides
// ---------------------------------------------------------------------------

/// Everything one capture decides.
class _Fixture {
  const _Fixture({
    required this.view,
    this.acceptance = const NyctisAssetAcceptance.empty(),
    this.art = const {},
    this.provingKey,
    this.chainTip = _chainTip,
    this.config,
    this.network = 'regtest',
    this.prefill = const {},
    this.documentMaxSupply,
  });

  /// Null keeps the first load in flight forever.
  final NyctisViewData? view;
  final NyctisAssetAcceptance acceptance;
  final Map<String, _Art> art;

  /// Null is a proving key that matches the channel.
  final NyctisProvingKeyStatus? provingKey;
  final int chainTip;
  final NyctisConfig? config;
  final String network;
  final Map<String, String> prefill;

  /// Overrides the `max_supply` the collection document declares.
  final int? documentMaxSupply;
}

List<Override> _overrides(_Fixture fixture) {
  final config = fixture.config ?? _configuredConfig;
  return [
    appBootstrapProvider.overrideWithValue(
      AppBootstrapState(
        initialLocation: '/nyctis',
        initialAccountState: _accountState,
        initialSyncSnapshot: AppSyncSnapshot.empty,
        network: fixture.network,
        rpcEndpointConfig: defaultRpcEndpointConfig(fixture.network),
        themeMode: ThemeMode.system,
        privacyModeEnabled: false,
        isPasswordConfigured: true,
        isUnlocked: true,
        passwordRotationRecoveryFailed: false,
        nyctisConfig: config,
        nyctisAcceptedAssets: fixture.acceptance,
      ),
    ),
    syncProvider.overrideWith(() => _CaptureSyncNotifier(fixture.chainTip)),
    // The feature is a build-time switch that is off by default; a capture
    // always shows it on, whatever the test binary was compiled with.
    nyctisFeatureEnabledProvider.overrideWithValue(true),
    nyctisConfigProvider.overrideWith(() => _CaptureConfigNotifier(config)),
    nyctisAssetsViewProvider.overrideWith((ref) {
      final view = fixture.view;
      return view == null
          ? Completer<NyctisViewData>().future
          : Future.value(view);
    }),
    nyctisProvingKeyProvider.overrideWith(
      (ref) async => fixture.provingKey ?? _readyProvingKey,
    ),
    nyctisAcceptanceStoreProvider.overrideWithValue(_NoopAcceptanceStore()),
    nyctisAssetArtworkFetchProvider.overrideWith((ref, assetId) {
      // The acceptance gate stays first, as it is in the real provider.
      final accepted = ref.watch(
        nyctisAssetAcceptanceProvider.select(
          (acceptance) => acceptance.isAccepted(assetId),
        ),
      );
      if (!accepted) return Future.value(null);
      final art = fixture.art[assetId];
      if (art == null) return Future.value(null);
      if (art == _Art.pending) {
        return Completer<NyctisArtworkFetchOutcome?>().future;
      }
      return Future.value(
        _outcomeFor(assetId, art, fixture.view, fixture.documentMaxSupply),
      );
    }),
    nyctisCollectionArtworkWarmupProvider.overrideWith(
      (ref, collectionId) async => const NyctisCollectionWarmup(
        requested: 1,
        bytes: 0,
        complete: true,
        documents: 1,
      ),
    ),
    nyctisBlockTimeLoaderProvider.overrideWithValue(
      (heights) async => {for (final h in heights) h: _blockTime(h)},
    ),
    giftCardActivityIndexProvider.overrideWith(
      (ref, accountUuid) async => GiftCardActivityIndex.empty,
    ),
    swapActivityRowItemsProvider.overrideWith(
      (ref, accountUuid) async => const [],
    ),
  ];
}

class _CaptureSyncNotifier extends SyncNotifier {
  _CaptureSyncNotifier(this.chainTip);

  final int chainTip;

  @override
  Future<SyncState> build() async => SyncState(
    accountUuid: _accountUuid,
    hasAccountScopedData: true,
    isSyncComplete: true,
    percentage: 1,
    scannedHeight: chainTip,
    chainTipHeight: chainTip,
    orchardBalance: BigInt.from(142230000),
    spendableBalance: BigInt.from(142230000),
    displaySpendableBalance: BigInt.from(142230000),
    displayOrchardBalance: BigInt.from(142230000),
    totalBalance: BigInt.from(142230000),
    displayTotalBalance: BigInt.from(142230000),
    displayShieldedBalance: BigInt.from(142230000),
    lastSyncCompletedAt: DateTime(2026, 9, 14, 9, 30),
  );

  @override
  void startSync({int? latestTipHeight}) {}

  @override
  Future<void> refreshAfterSend() async {}

  @override
  Future<void> refreshAfterProposalRelease(String accountUuid) async {}

  @override
  Future<void> refreshAfterAccountSwitch() async {}
}

class _CaptureConfigNotifier extends NyctisConfigNotifier {
  _CaptureConfigNotifier(this.initial);

  final NyctisConfig initial;

  @override
  NyctisConfig build() => initial;
}

class _NoopAcceptanceStore implements NyctisAcceptanceStore {
  @override
  Future<void> write(String encoded) async {}

  @override
  Future<void> clear() async {}
}

NyctisSendBroadcastRunner _runner(NyctisSendOutcome? outcome) {
  return ({
    required WidgetRef ref,
    required NyctisSendReviewArgs args,
    void Function(NyctisSendPhase phase)? onPhase,
    Future<bool> Function()? shouldAbort,
  }) {
    onPhase?.call(NyctisSendPhase.broadcasting);
    if (outcome == null) return Completer<NyctisSendOutcome>().future;
    return Future.value(outcome);
  };
}

// ---------------------------------------------------------------------------
// Artwork and metadata outcomes
// ---------------------------------------------------------------------------

enum _Art {
  /// Accepted, fetch still in flight.
  pending,

  /// The fungible asset's document, with its logo.
  harbourMetadata,

  /// The document was refused: the bytes did not match the pinned digest.
  refusedDigest,

  /// A collection piece, verified against `digests`.
  moonVerified,

  /// A collection piece with no `digests` entry.
  moonUnpinned,

  /// A collection piece whose image did not match its digest.
  moonRefusedDigest,

  /// A collection piece whose host answered with an error.
  refusedHttp,

  /// A ticket piece: an uncapped collection, no digests at all.
  ticketUnpinned,
}

NyctisArtworkFetchOutcome _outcomeFor(
  String assetId,
  _Art art,
  NyctisViewData? view,
  int? documentMaxSupply,
) {
  final asset = view?.assetById(assetId);
  final index = asset?.index ?? 0;
  switch (art) {
    case _Art.pending:
      throw StateError('pending has no outcome');
    case _Art.harbourMetadata:
      return NyctisArtworkFetchOutcome.asset(
        NyctisAssetMetadataView(
          assetId: assetId,
          metadata: NyctisAssetMetadata(
            description:
                'Harbour credit settles berth and mooring fees between the '
                'member ports of the Harbour cooperative. One credit is one '
                'hour of berth at any member quay.',
            logo: NyctisAssetLogoRef(
              uri: Uri.parse('https://harbour.example/hbc/logo.png'),
              digestB2: 'bm1nG0tMWxZ1b2Nv3aJ7Xh0s9aJ7Xh0s9aJ7Xh0s9aI',
            ),
            website: Uri.parse('https://harbour.example'),
            links: [
              NyctisAssetLink(
                rel: 'docs',
                uri: Uri.parse('https://harbour.example/docs/credit'),
              ),
              NyctisAssetLink(
                rel: 'github',
                uri: Uri.parse('https://github.com/harbour-example/credit'),
              ),
            ],
          ),
          documentPinned: true,
          sourceOrigin: 'harbour.example',
          logoBytes: kNyctisCaptureHarbourLogoPng,
          logoPinned: true,
        ),
      );
    case _Art.refusedDigest:
      return const NyctisArtworkFetchOutcome.abandoned(
        NyctisMetadataAbandonReason.digestMismatch,
      );
    case _Art.refusedHttp:
      return NyctisArtworkFetchOutcome.collectionMember(
        _member(
          assetId,
          index,
          image: null,
          reason: NyctisMetadataAbandonReason.httpStatus,
          documentMaxSupply: documentMaxSupply,
        ),
      );
    case _Art.moonVerified:
      return NyctisArtworkFetchOutcome.collectionMember(
        _member(
          assetId,
          index,
          image: nyctisCaptureMoonPng(index),
          documentMaxSupply: documentMaxSupply,
        ),
      );
    case _Art.moonUnpinned:
      return NyctisArtworkFetchOutcome.collectionMember(
        _member(
          assetId,
          index,
          image: nyctisCaptureMoonPng(index),
          pinned: false,
          documentMaxSupply: documentMaxSupply,
        ),
      );
    case _Art.moonRefusedDigest:
      return NyctisArtworkFetchOutcome.collectionMember(
        _member(
          assetId,
          index,
          image: null,
          reason: NyctisMetadataAbandonReason.digestMismatch,
          documentMaxSupply: documentMaxSupply,
        ),
      );
    case _Art.ticketUnpinned:
      return NyctisArtworkFetchOutcome.collectionMember(
        NyctisCollectionMemberView(
          assetId: assetId,
          index: index,
          collection: const NyctisCollectionMetadata(
            name: 'Harbour ticket',
            description: 'Single-crossing ferry tickets. Issued as needed.',
            item: NyctisCollectionItemTemplate(
              name: 'Harbour ticket #{index}',
              image: 'https://harbour.example/tickets/{index}.png',
            ),
          ),
          member: NyctisCollectionMember(
            index: index,
            name: 'Harbour ticket #$index',
            description: null,
            image: Uri.parse('https://harbour.example/tickets/$index.png'),
            digestB2: null,
            imageRejection: null,
            attributes: const [],
          ),
          documentPinned: false,
          sourceOrigin: 'harbour.example',
          imageBytes: nyctisCaptureTicketPng(index),
        ),
      );
  }
}

NyctisCollectionMemberView _member(
  String assetId,
  int index, {
  required Uint8List? image,
  NyctisMetadataAbandonReason? reason,
  bool pinned = true,
  int? documentMaxSupply,
}) {
  return NyctisCollectionMemberView(
    assetId: assetId,
    index: index,
    collection: NyctisCollectionMetadata(
      name: 'PHASES',
      description:
          'One hundred moons, one for each night the channel was watched.',
      maxSupply: documentMaxSupply ?? _phasesCap,
      logo: NyctisAssetLogoRef(
        uri: Uri.parse('https://phases.example/logo.png'),
        digestB2: 'cGhhc2VzLWxvZ28tZGlnZXN0LXBsYWNlaG9sZGVyMDA',
      ),
      item: const NyctisCollectionItemTemplate(
        name: 'PHASES #{index}',
        image: 'https://phases.example/{index}.png',
      ),
    ),
    member: NyctisCollectionMember(
      index: index,
      name: 'PHASES #$index',
      description: 'Night $index of the watch.',
      image: Uri.parse('https://phases.example/$index.png'),
      digestB2: pinned ? 'cGhhc2VzLW1vb24tZGlnZXN0LXBsYWNlaG9sZGVyMDA' : null,
      imageRejection: null,
      attributes: [
        NyctisItemAttribute(trait: 'Phase', value: _phaseName(index)),
        const NyctisItemAttribute(trait: 'Sky', value: 'Clear'),
      ],
    ),
    documentPinned: true,
    sourceOrigin: 'phases.example',
    imageBytes: image,
    imageReason: reason,
    collectionLogoBytes: kNyctisCaptureCollectionLogoPng,
    collectionLogoPinned: true,
  );
}

String _phaseName(int index) => const [
  'Waxing crescent',
  'First quarter',
  'Waxing gibbous',
  'Full',
  'Waning gibbous',
  'Last quarter',
  'Waning crescent',
  'New',
][index % 8];

// ---------------------------------------------------------------------------
// Fixture data
// ---------------------------------------------------------------------------

const _accountUuid = 'account-1';
const _chainTip = 1290;
const _anchorHeight = 1280;
const _provingKeyDir = '/Users/reviewer/Nyctis/proving-key';
const _vkHash =
    '19efd525dc3cf96796bbb760ef38c03f244a51f04e528d85835c2f262496d37b';

const _accountState = AccountState(
  accounts: [
    AccountInfo(
      uuid: _accountUuid,
      name: 'Main account',
      order: 0,
      profilePictureId: kDefaultProfilePictureId,
    ),
  ],
  activeAccountUuid: _accountUuid,
  activeAddress:
      'uregtest1q7h6xw0k3jz9m2v5c8r4t1y6u3i0o9p2a5s8d1f4g7h0j3k6l9z2x5c8v1b4n',
);

final NyctisConfig _configuredConfig = defaultNyctisConfig(
  'regtest',
).copyWith(enabled: true, provingKeyDir: _provingKeyDir);

final _readyProvingKey = NyctisProvingKeyStatus(
  state: NyctisProvingKeyState.ready,
  dir: _provingKeyDir,
  circuit: 'constraints=136119;instances=30',
  vkHash: _vkHash,
  channelVkHash: _vkHash,
  provingKeyBytes: BigInt.from(87031808),
);

const _notSetProvingKey = NyctisProvingKeyStatus(
  state: NyctisProvingKeyState.notSet,
  message: kNyctisProvingKeyNotSetText,
);

const _nyctisAddress =
    'nyreg1qqxvz8k3m7ph2j6ldu4cwesa9r0tg5y7n2q4v8xz3m6k9p2r5t8w1c4f7h0j3l6';
const _recipientAddress =
    'nyreg1q9d4w7x2m5k8p3r6t9y2u5i8o1a4s7d0f3g6h9j2k5l8z1x4c7v0b3n6m9q2w5';
const _txid =
    '9f8e7d6c5b4a39281716059483726150f1e2d3c4b5a69788796a5b4c3d2e1f0a';

const _harbourId =
    'b2c1f7a90e4d3c5b6a8f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f401';
const _nightcashId =
    'a3f1c0d29b8e47a5f6031d8c2b7e4906aa11bb22cc33dd44ee55ff6600778899';
const _unnamedId =
    '0f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6e5f4030201009f8e7d6c5b4a';
const _crewPassId =
    '77aa11bb22cc33dd44ee55ff6600778899aabbccddeeff001122334455667788';
const _phasesId =
    'c0113c710490aaaabbbbccccddddeeeeffff0000111122223333444455556666';
const _ticketsId =
    'd1c3e5f7a9b0c2d4e6f8a0b1c3d5e7f9a1b3c5d7e9f0a2b4c6d8e0f1a3b5c7d9';

const _msgHarbourIn =
    'ea47c855f0e1d2c3b4a596877869504132231415f6e7d8c9bab1a29384756617';
const _msgHarbourOut =
    '82852615a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c';
const _msgUnnamedIn =
    '5d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e';
const _msgCrewIn =
    '3e2d1c0b9a8f7e6d5c4b3a291807f6e5d4c3b2a1908f7e6d5c4b3a291807f6e5';
const _msgNightcashIn =
    '6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b';

const _phasesCap = 100;
const _phasesIssued = 10;
const _phasesOwned = {1, 4, 7};

String _phasesMemberId(int index) =>
    'a0${index.toString().padLeft(2, '0')}'
    'f00d5eed0f7a1e5c0113c710490aaaabbbbccccddddeeeeffff000011112';

String _ticketMemberId(int index) =>
    'b1${index.toString().padLeft(2, '0')}'
    '71c7e75eed0f7a1ed1c3e5f7a9b0c2d4e6f8a0b1c3d5e7f9a1b3c5d7e9f0';

final _acceptHarbour = const NyctisAssetAcceptance([
  NyctisAcceptedAsset(
    assetId: _harbourId,
    name: 'Harbour credit',
    symbol: 'HBC',
  ),
]);

final _acceptPhases = NyctisAssetAcceptance([
  for (var i = 0; i < _phasesIssued; i++)
    NyctisAcceptedAsset(
      assetId: _phasesMemberId(i),
      name: 'PHASES #$i',
      symbol: 'PHASE',
    ),
]);

final _acceptTickets = NyctisAssetAcceptance([
  for (var i = 1; i <= 4; i++)
    NyctisAcceptedAsset(
      assetId: _ticketMemberId(i),
      name: 'Harbour ticket #$i',
      symbol: 'TIX',
    ),
]);

final _acceptHarbourAndPhases = NyctisAssetAcceptance([
  ..._acceptHarbour.accepted,
  ..._acceptPhases.accepted,
]);

NyctisViewData _readyView({
  List<NyctisAssetDetailData>? assets,
  NyctisViewStatus status = NyctisViewStatus.ready,
  int pendingMessageCount = 2,
  int indexerHeight = _chainTip,
}) {
  return NyctisViewData(
    status: status,
    identity: const NyctisIdentityData(
      address: _nyctisAddress,
      networkLabel: 'Regtest',
    ),
    assets: assets ?? _fixtureAssets(),
    pendingMessageCount: pendingMessageCount,
    appliedMessageCount: 31,
    ignoredMessageCount: 343,
    viewHeight: BigInt.from(indexerHeight - 10),
    indexerHeight: BigInt.from(indexerHeight),
    chainTipHeight: BigInt.from(_chainTip),
    vkHash: _vkHash,
  );
}

List<NyctisAssetDetailData> _fixtureAssets() => [
  NyctisAssetDetailData(
    assetId: _harbourId,
    name: 'Harbour credit',
    symbol: 'HBC',
    isPublic: true,
    balance: BigInt.from(1250000),
    decimals: 6,
    issuedSupply: BigInt.from(500000000000),
    maxSupply: BigInt.from(1000000000000),
    metadataUri:
        'https://harbour.example/hbc.json'
        '#b2=Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0s9aJ7Xh0',
    declaredMetadata: const [
      NyctisAssetFactData(label: 'Issuer note', value: 'Port of call credit'),
    ],
    notes: [
      NyctisNoteRowData(
        position: BigInt.from(41),
        amount: BigInt.from(2000000),
        decimals: 6,
        createdHeight: BigInt.from(1180),
        spent: true,
        createdBy: _msgHarbourIn,
        createdInputs: 1,
        createdOutputs: 2,
        spentBy: _msgHarbourOut,
        spentHeight: BigInt.from(1240),
        spentInputs: 1,
        spentOutputs: 2,
      ),
      NyctisNoteRowData(
        position: BigInt.from(58),
        amount: BigInt.from(1250000),
        decimals: 6,
        createdHeight: BigInt.from(1240),
        createdBy: _msgHarbourOut,
        createdInputs: 1,
        createdOutputs: 2,
        policyText: 'Spendable after height 1,300',
      ),
    ],
  ),
  NyctisAssetDetailData(
    assetId: _nightcashId,
    name: 'Nightcash',
    symbol: 'NC',
    isPublic: true,
    balance: BigInt.from(988),
    decimals: 0,
    issuedSupply: BigInt.from(21000000),
    metadataUri: 'https://nyctis.example/nc.json',
    notes: [
      NyctisNoteRowData(
        position: BigInt.from(90),
        amount: BigInt.from(988),
        decimals: 0,
        createdHeight: BigInt.from(1262),
        createdBy: _msgNightcashIn,
        createdInputs: 2,
        createdOutputs: 3,
      ),
    ],
  ),
  NyctisAssetDetailData(
    assetId: _unnamedId,
    isPublic: true,
    balance: BigInt.from(3),
    decimals: 0,
    issuedSupply: BigInt.from(21),
    notes: [
      NyctisNoteRowData(
        position: BigInt.from(7),
        amount: BigInt.from(3),
        decimals: 0,
        createdHeight: BigInt.from(1199),
        createdBy: _msgUnnamedIn,
        createdInputs: 1,
        createdOutputs: 1,
      ),
    ],
  ),
  NyctisAssetDetailData(
    assetId: _crewPassId,
    name: 'Crew pass',
    balance: BigInt.one,
    decimals: 0,
    notes: [
      NyctisNoteRowData(
        position: BigInt.from(2),
        amount: BigInt.one,
        decimals: 0,
        createdHeight: BigInt.from(1010),
        createdBy: _msgCrewIn,
        createdInputs: 1,
        createdOutputs: 1,
        policyText: 'Non-transferable',
      ),
    ],
  ),
  for (var i = 0; i < _phasesIssued; i++)
    NyctisAssetDetailData(
      assetId: _phasesMemberId(i),
      name: 'PHASES #$i',
      symbol: 'PHASE',
      collection: _phasesId,
      index: i,
      collectionMaxSupply: _phasesCap,
      isPublic: true,
      balance: _phasesOwned.contains(i) ? BigInt.one : BigInt.zero,
      decimals: 0,
      issuedSupply: BigInt.one,
      maxSupply: BigInt.one,
      metadataUri:
          'https://phases.example/collection.json'
          '#b2=cGhhc2VzLWRvY3VtZW50LWRpZ2VzdC1wbGFjZWhvbGQ',
      notes: [
        if (_phasesOwned.contains(i))
          NyctisNoteRowData(
            position: BigInt.from(100 + i),
            amount: BigInt.one,
            decimals: 0,
            createdHeight: BigInt.from(1100 + i),
          ),
      ],
    ),
  for (var i = 1; i <= 4; i++)
    NyctisAssetDetailData(
      assetId: _ticketMemberId(i),
      name: 'Harbour ticket #$i',
      symbol: 'TIX',
      collection: _ticketsId,
      index: i,
      isPublic: true,
      balance: i.isOdd ? BigInt.one : BigInt.zero,
      decimals: 0,
      issuedSupply: BigInt.one,
      maxSupply: BigInt.one,
      metadataUri: 'https://harbour.example/tickets.json',
      notes: [
        if (i.isOdd)
          NyctisNoteRowData(
            position: BigInt.from(200 + i),
            amount: BigInt.one,
            decimals: 0,
            createdHeight: BigInt.from(1150 + i),
          ),
      ],
    ),
];

/// A fixed wall-clock time for each block height, a few minutes apart.
DateTime _blockTime(int height) =>
    DateTime(2026, 9, 12, 8).add(Duration(minutes: (height - 1000) * 11));

/// Two ordinary ZEC transactions, so the Nyctis rows sit among real ones.
Future<List<rust_sync.TransactionInfo>> _zecHistory(String accountUuid) async {
  BigInt seconds(DateTime time) =>
      BigInt.from(time.millisecondsSinceEpoch ~/ 1000);
  final received = seconds(DateTime(2026, 9, 13, 18, 5));
  final sent = seconds(DateTime(2026, 9, 12, 9, 40));
  return [
    rust_sync.TransactionInfo(
      txidHex: 'aa11',
      minedHeight: BigInt.from(1250),
      expiredUnmined: false,
      accountBalanceDelta: 125000000,
      fee: BigInt.zero,
      blockTime: received,
      isTransparent: false,
      txKind: 'received',
      displayAmount: BigInt.from(125000000),
      displayPool: 'shielded',
      createdTime: received,
    ),
    rust_sync.TransactionInfo(
      txidHex: 'bb22',
      minedHeight: BigInt.from(1005),
      expiredUnmined: false,
      accountBalanceDelta: -30010000,
      fee: BigInt.from(10000),
      blockTime: sent,
      isTransparent: false,
      txKind: 'sent',
      displayAmount: BigInt.from(30000000),
      displayPool: 'shielded',
      createdTime: sent,
    ),
  ];
}

NyctisSendReviewArgs _reviewArgs() => NyctisSendReviewArgs(
  sendFlowId: 'capture-flow',
  accountUuid: _accountUuid,
  msgId: '82852615ac3c4e2f9a7d1b6c5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f',
  assetId: _harbourId,
  assetSymbol: 'HBC',
  assetName: 'Harbour credit',
  assetDecimals: 6,
  amount: BigInt.from(500000),
  change: BigInt.from(750000),
  spent: BigInt.from(1250000),
  inputs: 1,
  recipient: _recipientAddress,
  channelAddress: _configuredConfig.channelAddress,
  memos: [
    for (var i = 0; i < 2; i++)
      Uint8List.fromList(List<int>.filled(512, 0xF0 + i)),
  ],
  memoValueZatoshi: BigInt.from(10000),
  bodyBytes: 812,
  anchorHeight: _anchorHeight,
  chainTip: _chainTip,
  vkHash: _vkHash,
  provedMs: 1300,
  builtAt: DateTime(2026, 9, 14, 9, 30),
);

NyctisActivityDetailArgs _sentArgs() => NyctisActivityDetailArgs(
  item: NyctisActivityItem(
    msgId: _msgHarbourOut,
    assetId: _harbourId,
    kind: NyctisActivityKind.sent,
    delta: -BigInt.from(750000),
    moved: BigInt.from(2000000),
    decimals: 6,
    height: BigInt.from(1240),
    name: 'Harbour credit',
    symbol: 'HBC',
    timestamp: _blockTime(1240),
    ownedInputs: 1,
    totalInputs: 1,
    ownedOutputs: 1,
    totalOutputs: 2,
  ),
  txidHex: _txid,
  carrierZatoshi: BigInt.from(20000),
  notes: [
    NyctisActivityDetailNote(
      role: NyctisActivityNoteRole.spent,
      position: BigInt.from(41),
      amount: BigInt.from(2000000),
      decimals: 6,
      createdHeight: BigInt.from(1180),
      spentByMessageId: _msgHarbourOut,
      spentHeight: BigInt.from(1240),
      policyText: 'pk(ak) && before(1300)',
    ),
    NyctisActivityDetailNote(
      role: NyctisActivityNoteRole.created,
      position: BigInt.from(58),
      amount: BigInt.from(1250000),
      decimals: 6,
      createdHeight: BigInt.from(1240),
    ),
  ],
);

NyctisActivityDetailArgs _receivedArgs({
  NyctisActivityMessageState state = NyctisActivityMessageState.applied,
}) => NyctisActivityDetailArgs(
  item: NyctisActivityItem(
    msgId: _msgUnnamedIn,
    assetId: _unnamedId,
    kind: NyctisActivityKind.received,
    delta: BigInt.from(3),
    moved: BigInt.zero,
    decimals: 0,
    height: BigInt.from(1199),
    timestamp: _blockTime(1199),
    ownedInputs: 0,
    totalInputs: 1,
    ownedOutputs: 1,
    totalOutputs: 1,
  ),
  state: state,
  notes: [
    NyctisActivityDetailNote(
      role: NyctisActivityNoteRole.created,
      position: BigInt.from(7),
      amount: BigInt.from(3),
      decimals: 0,
      createdHeight: BigInt.from(1199),
    ),
  ],
);

NyctisActivityDetailArgs _netArgs() => NyctisActivityDetailArgs(
  item: NyctisActivityItem(
    msgId: _msgNightcashIn,
    assetId: _nightcashId,
    kind: NyctisActivityKind.netChange,
    delta: BigInt.from(488),
    moved: BigInt.from(500),
    decimals: 0,
    height: BigInt.from(1262),
    name: 'Nightcash',
    symbol: 'NC',
    timestamp: _blockTime(1262),
    ownedInputs: 1,
    totalInputs: 2,
    ownedOutputs: 1,
    totalOutputs: 3,
  ),
  notes: [
    NyctisActivityDetailNote(
      role: NyctisActivityNoteRole.spent,
      position: BigInt.from(61),
      amount: BigInt.from(500),
      decimals: 0,
      createdHeight: BigInt.from(1205),
      spentByMessageId: _msgNightcashIn,
      spentHeight: BigInt.from(1262),
    ),
    NyctisActivityDetailNote(
      role: NyctisActivityNoteRole.created,
      position: BigInt.from(90),
      amount: BigInt.from(988),
      decimals: 0,
      createdHeight: BigInt.from(1262),
    ),
  ],
);
