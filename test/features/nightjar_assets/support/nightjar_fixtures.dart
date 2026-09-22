import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/rust/api/nightjar.dart' as rust_nightjar;

const _fixtureDir = 'test/features/nightjar_assets/fixtures';

/// Path of a response captured verbatim from the regtest devnet indexer at
/// `http://127.0.0.1:8787`. Captured rather than hand-written so a change in
/// the API's real shape breaks these tests.
String nightjarFixturePath(String name) => '$_fixtureDir/$name.json';

Map<String, Object?> nightjarFixture(String name) {
  final raw = File(nightjarFixturePath(name)).readAsStringSync();
  return (jsonDecode(raw) as Map).cast<String, Object?>();
}

String nightjarFixtureText(String name) =>
    File(nightjarFixturePath(name)).readAsStringSync();

/// A `/api/messages` fixture with its paging fields rewritten, so a walk can
/// be assembled from captured pages.
///
/// [total] is how many messages the listing claims match the query, ignoring
/// the cursor. The client reconciles the walk against it, so a test that
/// assembles a short walk out of a capture from a 350-message channel has to
/// say how long the walk it is describing actually is.
String nightjarMessagesFixtureWithCursor(
  String name, {
  required int? cursor,
  int? total,
}) {
  final json = nightjarFixture(name);
  return jsonEncode({
    ...json,
    'total': ?total,
    'has_more': cursor != null,
    'next_cursor': cursor,
  });
}

NetworkHttpResponse nightjarJsonResponse(
  String body, {
  int statusCode = 200,
  Map<String, List<String>> headers = const {},
}) {
  return NetworkHttpResponse(
    statusCode: statusCode,
    bodyBytes: Uint8List.fromList(utf8.encode(body)),
    headers: headers,
  );
}

/// Serves canned GETs through the Tor bridge boundary.
///
/// Going through the bridge rather than a raw `HttpClient` is the point: it is
/// the same path the app takes once the process-wide route selects Tor, so a
/// client that bypassed [NetworkHttpClient] would fail these tests.
class FakeNightjarTorBridge implements TorHttpBridge {
  FakeNightjarTorBridge(this._responses);

  /// Each entry is either a [NetworkHttpResponse] or an [Object] to throw.
  final List<Object> _responses;

  final requests = <Uri>[];
  final timeouts = <Duration?>[];

  @override
  Future<NetworkHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) async {
    requests.add(uri);
    timeouts.add(timeout);
    if (requests.length > _responses.length) {
      throw StateError('Unexpected GET $uri');
    }
    final next = _responses[requests.length - 1];
    if (next is NetworkHttpResponse) return next;
    throw next;
  }

  @override
  Future<NetworkHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) => throw UnsupportedError('The indexer client never POSTs');

  @override
  Future<NetworkHttpResponse> download(
    Uri uri, {
    required Map<String, String> headers,
    required String destinationPath,
  }) => throw UnsupportedError('The indexer client never downloads');
}

/// A [NetworkHttpClient] pinned to the Tor route so no test touches the
/// network or the process-wide privacy state.
NetworkHttpClient nightjarTestNetworkClient(FakeNightjarTorBridge bridge) {
  return NetworkHttpClient(
    torDesired: () => true,
    torBootstrapping: () => false,
    torBridge: bridge,
  );
}

/// A `/api/status` fixture with `live` (and optionally `info`) fields
/// overridden, so a test can describe a mid-sync or stale indexer without
/// hand-writing the other thirty fields of a captured response.
String nightjarStatusFixtureWith({
  Map<String, Object?> live = const {},
  Map<String, Object?> info = const {},
}) {
  final json = nightjarFixture('status');
  return jsonEncode({
    ...json,
    'info': {...(json['info']! as Map).cast<String, Object?>(), ...info},
    'live': {...(json['live']! as Map).cast<String, Object?>(), ...live},
  });
}

/// A `/api/vk` fixture with fields overridden — used to serve a key whose
/// bytes do not hash to the value the same server publishes for them.
String nightjarVkFixtureWith(Map<String, Object?> overrides) {
  return jsonEncode({...nightjarFixture('vk'), ...overrides});
}

/// A `/api/messages` fixture with one item's field removed, so a test can
/// serve the broken row the wallet has to refuse rather than skip.
String nightjarMessagesFixtureWithout(
  String name,
  String field, {
  int itemIndex = 0,
  required int? cursor,
  int? total,
}) {
  final json = nightjarFixture(name);
  final items = [
    for (final item in json['items']! as List)
      (item as Map).cast<String, Object?>(),
  ];
  items[itemIndex] = {...items[itemIndex]}..remove(field);
  return jsonEncode({
    ...json,
    'items': items,
    'total': ?total,
    'has_more': cursor != null,
    'next_cursor': cursor,
  });
}

/// A replay result with every field defaulted, so a test states only the ones
/// its assertion is about.
///
/// One place to fix when `NjView` gains a field: this is generated code that
/// the Rust side owns, and every Nightjar test that needs a view comes
/// through here.
rust_nightjar.NjView njViewFixture({
  int height = 6913,
  int chainTip = 6923,
  String stateRoot = _fixtureStateRoot,
  String treeRoot = _fixtureTreeRoot,
  String vkHash = kNjFixtureVkHash,
  int applied = 6,
  int ignored = 343,
  List<String> ignoredReasons = const [],
  /// How many of `ignored` were ZEC claims the wallet could not check at all.
  /// Zero by default: the interesting case is the one a test states.
  int zecUnverifiable = 0,
  int previewMessages = 0,
  List<rust_nightjar.NjNote> notes = const [],
  List<rust_nightjar.NjAsset> assets = const [],
}) {
  return rust_nightjar.NjView(
    height: height,
    chainTip: chainTip,
    stateRoot: stateRoot,
    treeRoot: treeRoot,
    vkHash: vkHash,
    applied: applied,
    ignored: ignored,
    ignoredReasons: ignoredReasons,
    zecUnverifiable: zecUnverifiable,
    previewMessages: previewMessages,
    notes: notes,
    assets: assets,
  );
}

/// A built payment with every field defaulted, so a test states only the ones
/// its assertion is about.
///
/// One place to fix when `NjPayPlan` gains a field. The memo default is two
/// fragments of exactly 512 bytes, because "one payment, several memos, one
/// transaction" is the invariant most of these tests are about.
rust_nightjar.NjPayPlan njPayPlanFixture({
  String msgId =
      '82852615ac3c4e2f9a7d1b6c5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f',
  String assetId = kNjFixtureAssetId,
  String assetSymbol = 'ACRE',
  int assetDecimals = 2,
  BigInt? amount,
  BigInt? change,
  BigInt? spent,
  int inputs = 1,
  int memoCount = 2,
  BigInt? memoValueZatoshi,
  int bodyBytes = 812,
  int anchorHeight = 6913,
  int chainTip = 6923,
  String vkHash = kNjFixtureVkHash,
  int provedMs = 1300,
}) {
  return rust_nightjar.NjPayPlan(
    msgId: msgId,
    assetId: assetId,
    assetSymbol: assetSymbol,
    assetDecimals: assetDecimals,
    amount: amount ?? BigInt.from(500),
    change: change ?? BigInt.from(1500),
    spent: spent ?? BigInt.from(2000),
    inputs: inputs,
    memos: [
      for (var i = 0; i < memoCount; i++)
        Uint8List.fromList(List<int>.filled(512, 0xF0 + i)),
    ],
    memoValueZatoshi: memoValueZatoshi ?? BigInt.from(10000),
    bodyBytes: bodyBytes,
    anchorHeight: anchorHeight,
    chainTip: chainTip,
    vkHash: vkHash,
    provedMs: provedMs,
  );
}

/// A proving-key folder as `nightjar_check_proving_key` reports it.
rust_nightjar.NjProvingKey njProvingKeyFixture({
  String dir = '/keys',
  String circuit = 'constraints=136119;instances=30',
  String vkHash = kNjFixtureVkHash,
  int provingKeyBytes = 87000000,
}) {
  return rust_nightjar.NjProvingKey(
    dir: dir,
    circuit: circuit,
    vkHash: vkHash,
    provingKeyBytes: BigInt.from(provingKeyBytes),
  );
}

/// The verifying-key hash the captured `/api/status` and `/api/vk` both
/// publish. A replay that reports a different one was checking proofs against
/// a key other than the one the wallet pinned.
const kNjFixtureVkHash =
    '19efd525dc3cf96796bbb760ef38c03f244a51f04e528d85835c2f262496d37b';

/// The state and tree roots the captured `/api/status` publishes at height
/// 6913 — the height [njViewFixture] closes at by default, so the two agree
/// unless a test deliberately makes them disagree.
const _fixtureStateRoot =
    'b77b471803222e97f39dfb7027996bd2543cd4ec6aab5dd286b79298f03ddf63';
const _fixtureTreeRoot =
    '26d451eda2963ba67f01107f07cc8ce1461f8e5a71d6b709d60107fefc4eab00';

/// The asset id [njAssetFixture] and [njNoteFixture] share, so a note lands
/// on the asset a test built for it.
const kNjFixtureAssetId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/// One asset in a replayed view, with the fields a UI assertion needs.
rust_nightjar.NjAsset njAssetFixture({
  String assetId = kNjFixtureAssetId,
  String collectionId = '',

  /// The on-chain `index`, which the replay reports **together with**
  /// `collectionId` — both come out of the same applied public issuance, so a
  /// fixture that sets one and not the other describes a view the replay
  /// cannot produce. It is an explicit parameter because `NjAsset.index` is
  /// optional in the generated constructor: without it every fixture would
  /// silently carry `null` and no test could reach the loader's passthrough.
  int? index,
  bool public = true,
  String name = 'Harbour credit',
  String symbol = 'HBC',
  int decimals = 6,
  String uri = '',
  BigInt? issued,
  BigInt? maxSupply,
  BigInt? balance,
  int noteCount = 1,
}) {
  return rust_nightjar.NjAsset(
    assetId: assetId,
    collectionId: collectionId,
    index: index,
    public: public,
    name: name,
    symbol: symbol,
    decimals: decimals,
    uri: uri,
    issued: issued ?? BigInt.from(500000000000),
    maxSupply: maxSupply ?? BigInt.zero,
    balance: balance ?? BigInt.from(1250000),
    noteCount: noteCount,
  );
}

/// One note this wallet owns — or has owned — in a replayed view.
///
/// The provenance defaults describe the simplest honest note: created by a
/// message this wallet did not sign, still unspent. Pass [spentBy] and the
/// counts beside it to fixture the other side of a payment.
rust_nightjar.NjNote njNoteFixture({
  BigInt? position,
  int created = 6900,
  String assetId = kNjFixtureAssetId,
  BigInt? amount,
  String policy = '',
  String source = 'ciphertext',
  bool spent = false,
  String createdBy = kNjFixtureCreatedByMsgId,
  int createdInputs = 1,
  int createdOutputs = 1,
  String? spentBy,
  int? spentHeight,
  int? spentInputs,
  int? spentOutputs,
}) {
  return rust_nightjar.NjNote(
    position: position ?? BigInt.from(41),
    created: created,
    assetId: assetId,
    amount: amount ?? BigInt.from(1250000),
    policy: policy,
    source: source,
    spent: spent,
    createdBy: createdBy,
    createdInputs: createdInputs,
    createdOutputs: createdOutputs,
    spentBy: spentBy,
    spentHeight: spentHeight,
    spentInputs: spentInputs,
    spentOutputs: spentOutputs,
  );
}

/// The `msg_id` [njNoteFixture] says created its note by default.
const String kNjFixtureCreatedByMsgId =
    '82852615a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c';
