/// What the loader is allowed to believe, and what it has to say when it
/// cannot.
///
/// Every test here is about a way the indexer can be wrong while answering
/// perfectly: a different channel, a key that does not match its own hash, a
/// half-synced view served as complete, a message quietly missing its body.
/// None of those are network faults, and the wallet used to render all of
/// them as "can't reach the Nyctis indexer".
///
/// The three Rust calls go through [NyctisReplayBridge] so these run
/// without the native library; the HTTP side is the real client over captured
/// devnet fixtures.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/nyctis_config.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_indexer_client.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_view_loader.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_data.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_mapper.dart';
import 'package:zcash_wallet/src/rust/api/nyctis.dart' as rust_nyctis;

import 'support/nyctis_fixtures.dart';

/// The channel id the captured `/api/status` says it serves.
const _channelId =
    '0af7fb3a6f2271860ec827c5fcab38485175519f3e2bd1fe8eb19db8182ba95f';

class _FakeBridge extends NyctisReplayBridge {
  _FakeBridge({
    this.channel = _channelId,
    rust_nyctis.NyView? view,
    this.channelIdThrows = false,
  }) : view = view ?? nyViewFixture();

  final String channel;
  final rust_nyctis.NyView view;
  final bool channelIdThrows;

  /// Completed by the test when it wants the replay to return, so it can
  /// inspect the loader while the replay is still in flight.
  final replayGate = Completer<void>();
  var releaseReplay = true;

  var channelIdCalls = 0;
  var viewingKeyCalls = 0;
  var replayCalls = 0;

  /// A copy of the secret the viewing-key derivation received, taken before
  /// the caller zeroes its buffer.
  Uint8List? secretSeenByDerivation;

  /// What the loader offered the replay as places to look for the Zcash
  /// transaction behind a ZEC claim.
  rust_nyctis.NyZecSources? zecSourcesSeen;
  int? replayChainTip;
  int? replayMessageCount;
  Uint8List? viewingKeySeenByReplay;
  String? vkPinSeenByReplay;
  String? channelAddressSeen;

  @override
  Future<String> channelId({
    required String network,
    required String channelUivk,
    required String channelAddress,
  }) async {
    channelIdCalls++;
    channelAddressSeen = channelAddress;
    if (channelIdThrows) throw StateError('not a channel key');
    return channel;
  }

  @override
  Future<rust_nyctis.NyViewingKey> viewingKey({
    required Uint8List mnemonic,
    required String network,
  }) {
    viewingKeyCalls++;
    secretSeenByDerivation = Uint8List.fromList(mnemonic);
    return Future.value(_viewingKey());
  }

  @override
  Future<rust_nyctis.NyView> replay({
    required String network,
    required String channelUivk,
    required int birthday,
    required int chainTip,
    required Uint8List vk,
    required String vkPin,
    required List<rust_nyctis.NyMessageInput> messages,
    required Uint8List viewingKey,
    required rust_nyctis.NyZecSources zecSources,
  }) {
    replayCalls++;
    zecSourcesSeen = zecSources;
    replayChainTip = chainTip;
    replayMessageCount = messages.length;
    viewingKeySeenByReplay = viewingKey;
    vkPinSeenByReplay = vkPin;
    if (releaseReplay) return Future.value(view);
    return replayGate.future.then((_) => view);
  }
}

/// A viewing key as `nyctisViewingKey` hands it over: 96 bytes and the
/// address they render.
rust_nyctis.NyViewingKey _viewingKey() => rust_nyctis.NyViewingKey(
  address: 'nyreg1testaddress',
  ak: 'ak',
  nkc: 'nkc',
  key: Uint8List.fromList(List<int>.generate(96, (i) => i + 1)),
);

/// A client whose first call fails with something that is not a
/// [NyctisIndexerException] — the case that used to escape the loader's
/// `try` and surface as the provider's generic error.
class _ExplodingClient extends NyctisIndexerClient {
  _ExplodingClient({required super.baseUri, required super.networkClient});

  @override
  Future<Never> fetchStatus() async => throw StateError('boom');
}

void main() {
  final baseUri = Uri.parse('http://127.0.0.1:8787');

  final config = defaultNyctisConfig(
    ZcashNetwork.regtest.name,
  ).copyWith(enabled: true);

  late rust_nyctis.NyViewingKey viewingKey;
  late int httpRequestsWhenKeyRead;
  late int viewingKeyReads;

  setUp(() {
    viewingKey = _viewingKey();
    httpRequestsWhenKeyRead = -1;
    viewingKeyReads = 0;
  });

  /// Serves `/api/status`, `/api/vk` and one page of `/api/messages`, in the
  /// order the loader asks for them.
  FakeNyctisTorBridge httpBridge({
    String? status,
    String? vk,
    String? messages,
  }) {
    return FakeNyctisTorBridge([
      nyctisJsonResponse(status ?? nyctisFixtureText('status')),
      nyctisJsonResponse(vk ?? nyctisFixtureText('vk')),
      nyctisJsonResponse(
        messages ??
            nyctisMessagesFixtureWithCursor(
              'messages_page1',
              cursor: null,
              total: 2,
            ),
      ),
    ]);
  }

  Future<NyctisViewData> load(
    FakeNyctisTorBridge http,
    _FakeBridge bridge, {
    int? walletChainTip = 6923,
    bool explodingClient = false,
  }) {
    final networkClient = nyctisTestNetworkClient(http);
    addTearDown(() => networkClient.close(force: true));
    final client = explodingClient
        ? _ExplodingClient(baseUri: baseUri, networkClient: networkClient)
        : NyctisIndexerClient(baseUri: baseUri, networkClient: networkClient);
    return loadNyctisView(
      config: config,
      client: client,
      walletChainTip: walletChainTip,
      bridge: bridge,
      readViewingKey: () async {
        viewingKeyReads++;
        if (httpRequestsWhenKeyRead < 0) {
          httpRequestsWhenKeyRead = http.requests.length;
        }
        return viewingKey;
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
      expect(view.chainTipSource, NyctisChainTipSource.wallet);
      expect(view.borrowedChainTip, isFalse);
      expect(
        bridge.replayMessageCount,
        2,
        reason: 'every message the listing served reaches the replay',
      );
      expect(
        nyctisNoticeLines(view),
        isNot(contains(kNyctisBorrowedChainTipText)),
      );
    });

    test('falls back to the indexer tip only with a visible caveat', () async {
      final bridge = _FakeBridge();
      final view = await load(httpBridge(), bridge, walletChainTip: 0);

      expect(bridge.replayChainTip, 6923, reason: "the fixture's live.tip");
      expect(view.chainTipSource, NyctisChainTipSource.indexer);
      expect(
        nyctisNoticeLines(view),
        contains(kNyctisBorrowedChainTipText),
        reason: 'borrowing the cut-off from the indexer has to be disclosed',
      );
    });
  });

  group('the indexer is not taken at its word', () {
    test('a channel mismatch points at settings, not at the network', () async {
      final bridge = _FakeBridge(channel: 'ff' * 32);
      final view = await load(httpBridge(), bridge);

      expect(view.status, NyctisViewStatus.unverified);
      expect(nyctisListErrorText(view), kNyctisChannelMismatchText);
      expect(
        nyctisListErrorText(view),
        isNot(kNyctisUnreachableText),
        reason: 'the fix is in settings; the network is working fine',
      );
      expect(view.statusDetail, contains(_channelId));
      expect(bridge.replayCalls, 0);
      expect(
        view.identity?.address,
        'nyreg1testaddress',
        reason: 'the receive address does not depend on the channel',
      );
    });

    test('a channel key the wallet cannot read says so', () async {
      final bridge = _FakeBridge(channelIdThrows: true);
      final view = await load(httpBridge(), bridge);

      expect(view.status, NyctisViewStatus.unverified);
      expect(view.statusMessage, contains('channel key'));
      expect(view.statusDetail, contains('Could not derive the channel id'));
    });

    test(
      'a verifying key that does not match its own hash is refused',
      () async {
        final view = await load(
          httpBridge(vk: nyctisVkFixtureWith({'vk_hash': 'ab' * 32})),
          _FakeBridge(),
        );

        expect(view.status, NyctisViewStatus.unverified);
        expect(nyctisListErrorText(view), kNyctisVerifyingKeyMismatchText);
        expect(view.statusDetail, contains('ab' * 32));
      },
    );

    test('the key is not used at all when the hashes disagree', () async {
      final bridge = _FakeBridge();
      await load(
        httpBridge(vk: nyctisVkFixtureWith({'vk_hash': 'ab' * 32})),
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
          messages: nyctisMessagesFixtureWithout(
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

      expect(view.status, NyctisViewStatus.unreachable);
      expect(view.statusDetail, contains('boom'));
    });

    test('the real reason reaches the screen, not one generic line', () async {
      final http = FakeNyctisTorBridge([
        nyctisJsonResponse('{"error":"nope"}', statusCode: 404),
      ]);
      final view = await load(http, _FakeBridge());

      expect(
        nyctisListErrorText(view),
        'The Nyctis indexer does not have what this wallet asked for.',
      );
      expect(view.statusDetail, contains('nope'));
    });
  });

  group('what the replay reports back', () {
    test('a channel where nothing verified is not an empty wallet', () async {
      final bridge = _FakeBridge(
        view: nyViewFixture(
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

      expect(view.status, NyctisViewStatus.unverified);
      expect(nyctisListErrorText(view), kNyctisNothingVerifiedText);
      expect(
        nyctisListErrorText(view),
        isNot(kNyctisEmptyText),
        reason:
            'a wrong verifying key and an empty channel must not render the '
            'same confident sentence',
      );
      expect(view.statusDetail, contains('proof verification failed'));
      expect(view.statusDetail, contains('+1 more'));
      expect(view.ignoredMessageCount, 343);
      expect(view.appliedMessageCount, 0);
    });

    test(
      'a disclosed collection cap crosses the FFI; anything else is null',
      () async {
        // `collection_max_supply` is `0` for "uncapped" and for "not disclosed"
        // alike, and only a public asset discloses it. Only a real cap may reach
        // the UI, which presents a capped count as verified.
        final view = await load(
          httpBridge(),
          _FakeBridge(
            view: nyViewFixture(
              assets: [
                nyAssetFixture(
                  assetId: '11' * 32,
                  collectionId: 'cc' * 32,
                  index: 3,
                  collectionMaxSupply: BigInt.from(100),
                ),
                nyAssetFixture(
                  assetId: '22' * 32,
                  collectionId: 'dd' * 32,
                  index: 0,
                ),
                nyAssetFixture(
                  assetId: '33' * 32,
                  public: false,
                  collectionMaxSupply: BigInt.from(100),
                ),
                nyAssetFixture(
                  assetId: '44' * 32,
                  collectionId: 'ee' * 32,
                  index: 1,
                  collectionMaxSupply: BigInt.parse('18446744073709551615'),
                ),
              ],
            ),
          ),
        );

        expect(view.assetById('11' * 32)!.collectionMaxSupply, 100);
        expect(
          view.assetById('22' * 32)!.collectionMaxSupply,
          isNull,
          reason: 'uncapped',
        );
        expect(
          view.assetById('33' * 32)!.collectionMaxSupply,
          isNull,
          reason: 'not disclosed',
        );
        expect(
          view.assetById('44' * 32)!.collectionMaxSupply,
          isNull,
          reason: 'larger than a Dart int is not shown truncated',
        );
      },
    );

    test('the on-chain index crosses the FFI verbatim', () async {
      // The passthrough nothing else covers. `NyAsset.index` is optional in
      // the generated constructor, so a loader that dropped it would leave
      // every member un-indexed and every collection tile blank, and no
      // existing fixture would have said so.
      final view = await load(
        httpBridge(),
        _FakeBridge(
          view: nyViewFixture(
            assets: [
              nyAssetFixture(
                assetId: '11' * 32,
                collectionId: 'cc' * 32,
                index: 7,
              ),
              // No public issuance disclosed either, which is the only shape
              // the replay produces for a null index: `collection_id` is
              // empty in the same breath.
              nyAssetFixture(assetId: '22' * 32, public: false),
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
        _FakeBridge(view: nyViewFixture(applied: 0, ignored: 0)),
      );

      expect(view.status, NyctisViewStatus.ready);
      expect(nyctisListErrorText(view), isNull);
      expect(view.assets, isEmpty);
    });

    test('spam beside applied messages is still a ready channel', () async {
      final view = await load(
        httpBridge(),
        _FakeBridge(
          view: nyViewFixture(
            applied: 6,
            ignored: 343,
            assets: [nyAssetFixture()],
            notes: [nyNoteFixture()],
          ),
        ),
      );

      expect(
        view.status,
        NyctisViewStatus.ready,
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
        _FakeBridge(view: nyViewFixture(vkHash: 'ee' * 32)),
      );

      expect(view.status, NyctisViewStatus.unverified);
      expect(nyctisListErrorText(view), kNyctisVerifyingKeyMismatchText);
      expect(view.statusDetail, contains('ee' * 32));
      expect(view.statusDetail, contains(kNyFixtureVkHash));
    });

    test('a state root the indexer disagrees with is refused', () async {
      final view = await load(
        httpBridge(),
        _FakeBridge(view: nyViewFixture(stateRoot: 'cc' * 32)),
      );

      expect(view.status, NyctisViewStatus.unverified);
      expect(nyctisListErrorText(view), kNyctisStateRootMismatchText);
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
        _FakeBridge(view: nyViewFixture(treeRoot: 'dd' * 32)),
      );

      expect(view.status, NyctisViewStatus.unverified);
      expect(view.statusDetail, contains('tree root'));
    });

    test('roots at a different height are not compared', () async {
      // The wallet's own tip is ahead of the indexer's, so the view closes
      // above the height the indexer settled its root at. Two roots for two
      // heights say nothing about each other.
      final view = await load(
        httpBridge(),
        _FakeBridge(view: nyViewFixture(height: 6950, stateRoot: 'cc' * 32)),
        walletChainTip: 6960,
      );

      expect(view.status, isNot(NyctisViewStatus.unverified));
    });

    test('a mid-sync indexer is not a ready view', () async {
      final view = await load(
        httpBridge(
          status: nyctisStatusFixtureWith(
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
          view: nyViewFixture(
            height: 7128,
            chainTip: 7138,
            assets: [nyAssetFixture()],
            notes: [nyNoteFixture()],
          ),
        ),
        walletChainTip: 7138,
      );

      expect(
        view.status,
        NyctisViewStatus.stale,
        reason:
            'the indexer read to 6900 and the view closes at 7128; every '
            'message in between is simply absent',
      );
      expect(
        nyctisNoticeLines(view),
        contains(kNyctisIndexerBehindText),
        reason: 'a list that is missing 228 blocks of messages has to say so',
      );
      expect(view.statusDetail, contains('6900'));
      expect(view.indexerHeight, BigInt.from(6900));
      expect(view.viewHeight, BigInt.from(7128));
    });

    test('a stale indexer that covers the view still warns', () async {
      final view = await load(
        httpBridge(
          status: nyctisStatusFixtureWith(
            live: const {'stale': true, 'status': 'stopped'},
          ),
        ),
        _FakeBridge(),
      );

      expect(view.status, NyctisViewStatus.stale);
      expect(view.statusMessage, kNyctisStaleText);
      expect(view.statusDetail, 'stopped');
    });

    test('the pending count is of channel messages, not our notes', () async {
      final view = await load(
        httpBridge(),
        _FakeBridge(view: nyViewFixture(previewMessages: 6)),
      );

      expect(view.pendingMessageCount, 6);
      final notice = nyctisNoticeText(view)!;
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

  group('the viewing key', () {
    test('is not read until the network round trip is done', () async {
      final http = httpBridge();
      await load(http, _FakeBridge());

      expect(
        httpRequestsWhenKeyRead,
        3,
        reason:
            'status, vk and the message walk all complete before the key is '
            'asked for at all',
      );
    });

    test(
      'is what the replay receives, with the pin and the channel address',
      () async {
        final bridge = _FakeBridge()..releaseReplay = false;
        final future = load(httpBridge(), bridge);
        await pumpEventQueue();

        expect(bridge.replayCalls, 1, reason: 'the replay is in flight');
        expect(
          bridge.viewingKeySeenByReplay,
          viewingKey.key,
          reason: 'the replay reads with the viewing key; it never sees a seed',
        );
        expect(bridge.vkPinSeenByReplay, config.vkPin);
        expect(bridge.vkPinSeenByReplay, kNyctisRegtestVkPin);
        expect(bridge.channelAddressSeen, config.channelAddress);
        expect(
          bridge.viewingKeyCalls,
          0,
          reason: 'the loader is handed a key; it does not derive one',
        );

        bridge.replayGate.complete();
        final view = await future;
        expect(view.status, NyctisViewStatus.ready);
        expect(view.identity?.address, viewingKey.address);
      },
    );

    test('a locked wallet is not configured, not unreachable', () async {
      final http = httpBridge();
      final networkClient = nyctisTestNetworkClient(http);
      addTearDown(() => networkClient.close(force: true));
      final view = await loadNyctisView(
        config: config,
        client: NyctisIndexerClient(
          baseUri: baseUri,
          networkClient: networkClient,
        ),
        walletChainTip: 6923,
        bridge: _FakeBridge(),
        readViewingKey: () async => null,
      );

      expect(view.status, NyctisViewStatus.notConfigured);
      expect(view.statusDetail, 'The wallet is locked.');
    });
  });

  group('the viewing-key cache', () {
    Uint8List secret() =>
        Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

    test('reads the secret once per unlock and zeroes it', () async {
      final bridge = _FakeBridge();
      final cache = NyctisViewingKeyCache(bridge: bridge);
      final buffers = <Uint8List>[];
      Future<Uint8List?> readSecret() async {
        final buffer = secret();
        buffers.add(buffer);
        return buffer;
      }

      final first = await cache.read(
        accountUuid: 'a',
        network: 'regtest',
        readSecret: readSecret,
      );
      final second = await cache.read(
        accountUuid: 'a',
        network: 'regtest',
        readSecret: readSecret,
      );

      expect(first?.address, 'nyreg1testaddress');
      expect(identical(first, second), isTrue);
      expect(bridge.viewingKeyCalls, 1);
      expect(buffers, hasLength(1), reason: 'the secret is read once');
      expect(
        buffers.single,
        everyElement(0),
        reason: 'zeroed as soon as the derivation call is issued',
      );
      expect(
        bridge.secretSeenByDerivation,
        isNot(everyElement(0)),
        reason: 'the derivation still received the real secret',
      );
    });

    test('a locked wallet is not remembered as locked', () async {
      final bridge = _FakeBridge();
      final cache = NyctisViewingKeyCache(bridge: bridge);

      final locked = await cache.read(
        accountUuid: 'a',
        network: 'regtest',
        readSecret: () async => null,
      );
      final unlocked = await cache.read(
        accountUuid: 'a',
        network: 'regtest',
        readSecret: () async => secret(),
      );

      expect(locked, isNull);
      expect(unlocked, isNotNull);
      expect(bridge.viewingKeyCalls, 1);
    });

    test('clearing zeroes every key it held', () async {
      final cache = NyctisViewingKeyCache(bridge: _FakeBridge());
      final key = await cache.read(
        accountUuid: 'a',
        network: 'regtest',
        readSecret: () async => secret(),
      );

      cache.clear();

      expect(key!.key, everyElement(0));
    });
  });

  test('a disabled config never touches the network', () async {
    final http = httpBridge();
    final networkClient = nyctisTestNetworkClient(http);
    addTearDown(() => networkClient.close(force: true));
    final view = await loadNyctisView(
      config: defaultNyctisConfig(ZcashNetwork.regtest.name),
      client: NyctisIndexerClient(
        baseUri: baseUri,
        networkClient: networkClient,
      ),
      bridge: _FakeBridge(),
      readViewingKey: () async {
        viewingKeyReads++;
        return viewingKey;
      },
    );

    expect(view.status, NyctisViewStatus.notConfigured);
    expect(http.requests, isEmpty);
    expect(viewingKeyReads, 0, reason: 'never asked for a key');
  });
}
