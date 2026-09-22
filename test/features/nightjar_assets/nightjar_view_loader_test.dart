/// What the loader is allowed to believe, and what it has to say when it
/// cannot.
///
/// Every test here is about a way the indexer can be wrong while answering
/// perfectly: a different channel, a key that does not match its own hash, a
/// half-synced view served as complete, a message quietly missing its body.
/// None of those are network faults, and the wallet used to render all of
/// them as "can't reach the Nightjar indexer".
///
/// The three Rust calls go through [NightjarReplayBridge] so these run
/// without the native library; the HTTP side is the real client over captured
/// devnet fixtures.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/nightjar_config.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_indexer_client.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_view_loader.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_mapper.dart';
import 'package:zcash_wallet/src/rust/api/nightjar.dart' as rust_nightjar;

import 'support/nightjar_fixtures.dart';

/// The channel id the captured `/api/status` says it serves.
const _channelId =
    '0af7fb3a6f2271860ec827c5fcab38485175519f3e2bd1fe8eb19db8182ba95f';

class _FakeBridge extends NightjarReplayBridge {
  _FakeBridge({
    this.channel = _channelId,
    rust_nightjar.NjView? view,
    this.channelIdThrows = false,
  }) : view = view ?? njViewFixture();

  final String channel;
  final rust_nightjar.NjView view;
  final bool channelIdThrows;

  /// Completed by the test when it wants the replay to return, so it can
  /// inspect the seed buffer while the replay is still in flight.
  final replayGate = Completer<void>();
  var releaseReplay = true;

  var channelIdCalls = 0;
  var identityCalls = 0;
  var replayCalls = 0;

  /// What the loader offered the replay as places to look for the Zcash
  /// transaction behind a ZEC claim.
  rust_nightjar.NjZecSources? zecSourcesSeen;
  int? replayChainTip;
  int? replayMessageCount;
  Uint8List? seedSeenByReplay;

  @override
  Future<String> channelId({
    required String network,
    required String channelUivk,
  }) async {
    channelIdCalls++;
    if (channelIdThrows) throw StateError('not a channel key');
    return channel;
  }

  @override
  Future<rust_nightjar.NjIdentity> identity({
    required Uint8List seed,
    required String network,
  }) {
    identityCalls++;
    return Future.value(
      const rust_nightjar.NjIdentity(
        address: 'njreg1testaddress',
        ak: 'ak',
        nkc: 'nkc',
      ),
    );
  }

  @override
  Future<rust_nightjar.NjView> replay({
    required String network,
    required String channelUivk,
    required int birthday,
    required int chainTip,
    required Uint8List vk,
    required List<rust_nightjar.NjMessageInput> messages,
    required Uint8List seed,
    required rust_nightjar.NjZecSources zecSources,
  }) {
    replayCalls++;
    zecSourcesSeen = zecSources;
    replayChainTip = chainTip;
    replayMessageCount = messages.length;
    // A copy, because the loader is about to zero the caller's buffer — which
    // is the whole point of the test that reads this back.
    seedSeenByReplay = Uint8List.fromList(seed);
    if (releaseReplay) return Future.value(view);
    return replayGate.future.then((_) => view);
  }
}

/// A client whose first call fails with something that is not a
/// [NightjarIndexerException] — the case that used to escape the loader's
/// `try` and surface as the provider's generic error.
class _ExplodingClient extends NightjarIndexerClient {
  _ExplodingClient({required super.baseUri, required super.networkClient});

  @override
  Future<Never> fetchStatus() async => throw StateError('boom');
}

void main() {
  final baseUri = Uri.parse('http://127.0.0.1:8787');

  final config = defaultNightjarConfig(
    ZcashNetwork.regtest.name,
  ).copyWith(enabled: true);

  late Uint8List seed;
  late int httpRequestsWhenSeedRead;

  setUp(() {
    seed = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    httpRequestsWhenSeedRead = -1;
  });

  /// Serves `/api/status`, `/api/vk` and one page of `/api/messages`, in the
  /// order the loader asks for them.
  FakeNightjarTorBridge httpBridge({
    String? status,
    String? vk,
    String? messages,
  }) {
    return FakeNightjarTorBridge([
      nightjarJsonResponse(status ?? nightjarFixtureText('status')),
      nightjarJsonResponse(vk ?? nightjarFixtureText('vk')),
      nightjarJsonResponse(
        messages ??
            nightjarMessagesFixtureWithCursor(
              'messages_page1',
              cursor: null,
              total: 2,
            ),
      ),
    ]);
  }

  Future<NightjarViewData> load(
    FakeNightjarTorBridge http,
    _FakeBridge bridge, {
    int? walletChainTip = 6923,
    bool explodingClient = false,
  }) {
    final networkClient = nightjarTestNetworkClient(http);
    addTearDown(() => networkClient.close(force: true));
    final client = explodingClient
        ? _ExplodingClient(baseUri: baseUri, networkClient: networkClient)
        : NightjarIndexerClient(baseUri: baseUri, networkClient: networkClient);
    return loadNightjarView(
      config: config,
      client: client,
      walletChainTip: walletChainTip,
      bridge: bridge,
      readSeed: () async {
        httpRequestsWhenSeedRead = http.requests.length;
        return seed;
      },
    );
  }

  group('what the view is closed against', () {
    test("uses the wallet's own chain tip, not the indexer's", () async {
      final bridge = _FakeBridge();
      final view = await load(httpBridge(), bridge, walletChainTip: 7000);

      expect(
        bridge.replayChainTip,
        7000,
        reason:
            'the indexer serves the messages; it does not also get to choose '
            'which of them are final',
      );
      expect(view.chainTipSource, NightjarChainTipSource.wallet);
      expect(view.borrowedChainTip, isFalse);
      expect(
        bridge.replayMessageCount,
        2,
        reason: 'every message the listing served reaches the replay',
      );
      expect(
        nightjarNoticeLines(view),
        isNot(contains(kNightjarBorrowedChainTipText)),
      );
    });

    test('falls back to the indexer tip only with a visible caveat', () async {
      final bridge = _FakeBridge();
      final view = await load(httpBridge(), bridge, walletChainTip: 0);

      expect(bridge.replayChainTip, 6923, reason: "the fixture's live.tip");
      expect(view.chainTipSource, NightjarChainTipSource.indexer);
      expect(
        nightjarNoticeLines(view),
        contains(kNightjarBorrowedChainTipText),
        reason: 'borrowing the cut-off from the indexer has to be disclosed',
      );
    });
  });

  group('the indexer is not taken at its word', () {
    test('a channel mismatch points at settings, not at the network', () async {
      final bridge = _FakeBridge(channel: 'ff' * 32);
      final view = await load(httpBridge(), bridge);

      expect(view.status, NightjarViewStatus.unverified);
      expect(nightjarListErrorText(view), kNightjarChannelMismatchText);
      expect(
        nightjarListErrorText(view),
        isNot(kNightjarUnreachableText),
        reason: 'the fix is in settings; the network is working fine',
      );
      expect(view.statusDetail, contains(_channelId));
      expect(bridge.replayCalls, 0);
      expect(
        view.identity?.address,
        'njreg1testaddress',
        reason: 'the receive address does not depend on the channel',
      );
    });

    test('a channel key the wallet cannot read says so', () async {
      final bridge = _FakeBridge(channelIdThrows: true);
      final view = await load(httpBridge(), bridge);

      expect(view.status, NightjarViewStatus.unverified);
      expect(view.statusMessage, contains('channel key'));
      expect(view.statusDetail, contains('Could not derive the channel id'));
    });

    test(
      'a verifying key that does not match its own hash is refused',
      () async {
        final view = await load(
          httpBridge(vk: nightjarVkFixtureWith({'vk_hash': 'ab' * 32})),
          _FakeBridge(),
        );

        expect(view.status, NightjarViewStatus.unverified);
        expect(nightjarListErrorText(view), kNightjarVerifyingKeyMismatchText);
        expect(view.statusDetail, contains('ab' * 32));
      },
    );

    test('the key is not used at all when the hashes disagree', () async {
      final bridge = _FakeBridge();
      await load(
        httpBridge(vk: nightjarVkFixtureWith({'vk_hash': 'ab' * 32})),
        bridge,
      );

      expect(
        bridge.replayCalls,
        0,
        reason: 'proofs checked against an unpinned key prove nothing',
      );
    });

    test('a message served without its body is a hard error', () async {
      final bridge = _FakeBridge();
      final view = await load(
        httpBridge(
          messages: nightjarMessagesFixtureWithout(
            'messages_page1',
            'body',
            cursor: null,
            total: 2,
          ),
        ),
        bridge,
      );

      expect(bridge.replayCalls, 0, reason: 'never replay a partial channel');
      expect(view.assets, isEmpty);
      expect(view.statusMessage, contains('without its body'));
    });

    test('a failure that is not an indexer exception still renders', () async {
      final view = await load(
        httpBridge(),
        _FakeBridge(),
        explodingClient: true,
      );

      expect(view.status, NightjarViewStatus.unreachable);
      expect(view.statusDetail, contains('boom'));
    });

    test('the real reason reaches the screen, not one generic line', () async {
      final http = FakeNightjarTorBridge([
        nightjarJsonResponse('{"error":"nope"}', statusCode: 404),
      ]);
      final view = await load(http, _FakeBridge());

      expect(
        nightjarListErrorText(view),
        'The Nightjar indexer does not have what this wallet asked for.',
      );
      expect(view.statusDetail, contains('nope'));
    });
  });

  group('what the replay reports back', () {
    test('a channel where nothing verified is not an empty wallet', () async {
      final bridge = _FakeBridge(
        view: njViewFixture(
          applied: 0,
          ignored: 343,
          ignoredReasons: const [
            'aa11 proof verification failed',
            'bb22 proof verification failed',
            'cc33 proof verification failed',
            'dd44 proof verification failed',
          ],
        ),
      );
      final view = await load(httpBridge(), bridge);

      expect(view.status, NightjarViewStatus.unverified);
      expect(nightjarListErrorText(view), kNightjarNothingVerifiedText);
      expect(
        nightjarListErrorText(view),
        isNot(kNightjarEmptyText),
        reason:
            'a wrong verifying key and an empty channel must not render the '
            'same confident sentence',
      );
      expect(view.statusDetail, contains('proof verification failed'));
      expect(view.statusDetail, contains('+1 more'));
      expect(view.ignoredMessageCount, 343);
      expect(view.appliedMessageCount, 0);
    });

    test('the on-chain index crosses the FFI verbatim', () async {
      // The passthrough nothing else covers. `NjAsset.index` is optional in
      // the generated constructor, so a loader that dropped it would leave
      // every member un-indexed and every collection tile blank, and no
      // existing fixture would have said so.
      final view = await load(
        httpBridge(),
        _FakeBridge(
          view: njViewFixture(
            assets: [
              njAssetFixture(
                assetId: '11' * 32,
                collectionId: 'cc' * 32,
                index: 7,
              ),
              // No public issuance disclosed either, which is the only shape
              // the replay produces for a null index: `collection_id` is
              // empty in the same breath.
              njAssetFixture(assetId: '22' * 32, public: false),
            ],
          ),
        ),
      );

      final indexed = view.assetById('11' * 32)!;
      expect(indexed.index, 7);
      expect(indexed.collection, 'cc' * 32);
      // Not the position in the list, which is what a wallet that invented an
      // index would have produced here.
      expect(indexed.index, isNot(0));

      final undisclosed = view.assetById('22' * 32)!;
      expect(undisclosed.index, isNull);
      expect(undisclosed.collection, isNull);
    });

    test('an empty channel is ready and empty', () async {
      final view = await load(
        httpBridge(),
        _FakeBridge(view: njViewFixture(applied: 0, ignored: 0)),
      );

      expect(view.status, NightjarViewStatus.ready);
      expect(nightjarListErrorText(view), isNull);
      expect(view.assets, isEmpty);
    });

    test('spam beside applied messages is still a ready channel', () async {
      final view = await load(
        httpBridge(),
        _FakeBridge(
          view: njViewFixture(
            applied: 6,
            ignored: 343,
            assets: [njAssetFixture()],
            notes: [njNoteFixture()],
          ),
        ),
      );

      expect(
        view.status,
        NightjarViewStatus.ready,
        reason: 'anyone may write junk to a public channel',
      );
      expect(view.assets.single.notes, hasLength(1));
      expect(view.ignoredMessageCount, 343);
    });

    test('a replay against another key is refused, not rendered', () async {
      // What the replay actually checked the proofs against, reported by the
      // replay itself. Without it the wallet could only say which key it
      // meant to hand over.
      final view = await load(
        httpBridge(),
        _FakeBridge(view: njViewFixture(vkHash: 'ee' * 32)),
      );

      expect(view.status, NightjarViewStatus.unverified);
      expect(nightjarListErrorText(view), kNightjarVerifyingKeyMismatchText);
      expect(view.statusDetail, contains('ee' * 32));
      expect(view.statusDetail, contains(kNjFixtureVkHash));
    });

    test('a state root the indexer disagrees with is refused', () async {
      final view = await load(
        httpBridge(),
        _FakeBridge(view: njViewFixture(stateRoot: 'cc' * 32)),
      );

      expect(view.status, NightjarViewStatus.unverified);
      expect(nightjarListErrorText(view), kNightjarStateRootMismatchText);
      expect(view.statusDetail, contains('cc' * 32));
      expect(
        view.assets,
        isEmpty,
        reason:
            'balances from a channel that is missing messages are not '
            'balances to render',
      );
    });

    test('a tree root the indexer disagrees with is refused', () async {
      final view = await load(
        httpBridge(),
        _FakeBridge(view: njViewFixture(treeRoot: 'dd' * 32)),
      );

      expect(view.status, NightjarViewStatus.unverified);
      expect(view.statusDetail, contains('tree root'));
    });

    test('roots at a different height are not compared', () async {
      // The wallet's own tip is ahead of the indexer's, so the view closes
      // above the height the indexer settled its root at. Two roots for two
      // heights say nothing about each other.
      final view = await load(
        httpBridge(),
        _FakeBridge(view: njViewFixture(height: 6950, stateRoot: 'cc' * 32)),
        walletChainTip: 6960,
      );

      expect(view.status, isNot(NightjarViewStatus.unverified));
    });

    test('a mid-sync indexer is not a ready view', () async {
      final view = await load(
        httpBridge(
          status: nightjarStatusFixtureWith(
            live: const {
              'status': 'syncing',
              'stale': false,
              'syncing': true,
              'tip': 7138,
              'height': 6900,
              'canonical_height': 6890,
              'state_root_height': 6890,
            },
          ),
        ),
        _FakeBridge(
          view: njViewFixture(
            height: 7128,
            chainTip: 7138,
            assets: [njAssetFixture()],
            notes: [njNoteFixture()],
          ),
        ),
        walletChainTip: 7138,
      );

      expect(
        view.status,
        NightjarViewStatus.stale,
        reason:
            'the indexer read to 6900 and the view closes at 7128; every '
            'message in between is simply absent',
      );
      expect(
        nightjarNoticeLines(view),
        contains(kNightjarIndexerBehindText),
        reason: 'a list that is missing 228 blocks of messages has to say so',
      );
      expect(view.statusDetail, contains('6900'));
      expect(view.indexerHeight, BigInt.from(6900));
      expect(view.viewHeight, BigInt.from(7128));
    });

    test('a stale indexer that covers the view still warns', () async {
      final view = await load(
        httpBridge(
          status: nightjarStatusFixtureWith(
            live: const {'stale': true, 'status': 'stopped'},
          ),
        ),
        _FakeBridge(),
      );

      expect(view.status, NightjarViewStatus.stale);
      expect(view.statusMessage, kNightjarStaleText);
      expect(view.statusDetail, 'stopped');
    });

    test('the pending count is of channel messages, not our notes', () async {
      final view = await load(
        httpBridge(),
        _FakeBridge(view: njViewFixture(previewMessages: 6)),
      );

      expect(view.pendingMessageCount, 6);
      final notice = nightjarNoticeText(view)!;
      expect(notice, contains('6 channel messages are waiting'));
      expect(
        notice,
        isNot(contains('notes are waiting')),
        reason:
            'previewMessages counts everything anyone wrote above the cut-off; '
            'calling it "your incoming notes" is the claim that is usually '
            'false',
      );
      expect(view.finalityDepth, 10, reason: 'from the indexer info');
    });
  });

  group('the seed', () {
    test('is not read until the network round trip is done', () async {
      final http = httpBridge();
      await load(http, _FakeBridge());

      expect(
        httpRequestsWhenSeedRead,
        3,
        reason:
            'status, vk and the message walk all complete before the seed is '
            'in memory at all',
      );
    });

    test('is zeroed before the replay result is awaited', () async {
      final bridge = _FakeBridge()..releaseReplay = false;
      final future = load(httpBridge(), bridge);
      await pumpEventQueue();

      expect(bridge.replayCalls, 1, reason: 'the replay is in flight');
      expect(
        seed,
        everyElement(0),
        reason:
            'the seed is zeroed between issuing the call and collecting its '
            'result, the same discipline send_flow.dart follows',
      );
      expect(
        bridge.seedSeenByReplay,
        isNot(everyElement(0)),
        reason: 'the replay still received the real seed',
      );

      bridge.replayGate.complete();
      final view = await future;
      expect(view.status, NightjarViewStatus.ready);
    });

    test('a locked wallet is not configured, not unreachable', () async {
      final http = httpBridge();
      final networkClient = nightjarTestNetworkClient(http);
      addTearDown(() => networkClient.close(force: true));
      final view = await loadNightjarView(
        config: config,
        client: NightjarIndexerClient(
          baseUri: baseUri,
          networkClient: networkClient,
        ),
        walletChainTip: 6923,
        bridge: _FakeBridge(),
        readSeed: () async => null,
      );

      expect(view.status, NightjarViewStatus.notConfigured);
      expect(view.statusDetail, 'The wallet is locked.');
    });
  });

  test('a disabled config never touches the network', () async {
    final http = httpBridge();
    final networkClient = nightjarTestNetworkClient(http);
    addTearDown(() => networkClient.close(force: true));
    final view = await loadNightjarView(
      config: defaultNightjarConfig(ZcashNetwork.regtest.name),
      client: NightjarIndexerClient(
        baseUri: baseUri,
        networkClient: networkClient,
      ),
      bridge: _FakeBridge(),
      readSeed: () async => seed,
    );

    expect(view.status, NightjarViewStatus.notConfigured);
    expect(http.requests, isEmpty);
    expect(seed, isNot(everyElement(0)), reason: 'never read, never zeroed');
  });
}
