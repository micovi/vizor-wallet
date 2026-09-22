/// What the Nightjar send flow is allowed to do, and what it must refuse.
///
/// The three rules that cost money if they are broken each have a test here:
/// every memo of one payment rides one transaction, a plan whose anchor has
/// aged out cannot be sent, and the proving key is checked against the key the
/// channel verifies with rather than against its own circuit string. The
/// fourth — the seed is zeroed before either long-running result is awaited —
/// is asserted while the call is still in flight.
///
/// Both FFI seams are faked, so none of this needs the native library; the
/// HTTP side is the real indexer client over captured devnet fixtures.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/nightjar_config.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_indexer_client.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/services/nightjar_send_flow.dart';
import 'package:zcash_wallet/src/features/nightjar_assets/widgets/nightjar_asset_row_mapper.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/nightjar.dart' as rust_nightjar;
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

import 'support/nightjar_fixtures.dart';

const _channelAddress = 'uregtestchanneladdress';
const _recipient = 'njreg1recipient';

class _FakePayBridge extends NightjarPayBridge {
  _FakePayBridge({rust_nightjar.NjPayPlan? plan, this.payError, this.keyError})
    : plan = plan ?? njPayPlanFixture();

  final rust_nightjar.NjPayPlan plan;
  final Object? payError;
  final Object? keyError;
  rust_nightjar.NjProvingKey key = njProvingKeyFixture();

  /// Completed by the test when it wants the build to return, so it can look
  /// at the seed buffer while the call is still in flight.
  final payGate = Completer<void>();
  var releasePay = true;

  var buildCalls = 0;
  var keyCalls = 0;
  Uint8List? seedSeenByBuild;
  int? chainTipSeen;
  String? keysDirSeen;
  BigInt? amountSeen;

  @override
  Future<rust_nightjar.NjProvingKey> checkProvingKey({
    required String keysDir,
  }) async {
    keyCalls++;
    keysDirSeen = keysDir;
    final error = keyError;
    if (error != null) throw error;
    return key;
  }

  @override
  Future<rust_nightjar.NjPayPlan> buildPay({
    required String network,
    required String channelUivk,
    required int birthday,
    required int chainTip,
    required Uint8List vk,
    required List<rust_nightjar.NjMessageInput> messages,
    required Uint8List seed,
    required String keysDir,
    required String assetId,
    required BigInt amount,
    required String recipient,
    required rust_nightjar.NjZecSources zecSources,
  }) async {
    buildCalls++;
    // The same buffer the caller handed over, not a copy: the zeroing this
    // test is about happens in place.
    seedSeenByBuild = seed;
    chainTipSeen = chainTip;
    keysDirSeen = keysDir;
    amountSeen = amount;
    if (!releasePay) await payGate.future;
    final error = payError;
    if (error != null) throw error;
    return plan;
  }
}

class _FakeSendBridge extends NightjarSendBridge {
  _FakeSendBridge({this.proposeError, this.execute});

  final Object? proposeError;
  final rust_sync.ExecuteProposalResult? execute;

  final executeGate = Completer<void>();
  var releaseExecute = true;

  var proposeCalls = 0;
  var executeCalls = 0;
  List<rust_sync.RawSendOutput>? outputsSeen;
  String? sendFlowIdSeen;
  Uint8List? seedSeenByExecute;

  @override
  Future<rust_sync.ProposalResult> proposeSendRaw({
    required String dbPath,
    required String network,
    required String accountUuid,
    required String sendFlowId,
    required List<rust_sync.RawSendOutput> outputs,
  }) async {
    proposeCalls++;
    outputsSeen = outputs;
    sendFlowIdSeen = sendFlowId;
    final error = proposeError;
    if (error != null) throw error;
    return rust_sync.ProposalResult(
      proposalId: BigInt.from(7),
      needsSaplingParams: false,
      feeZatoshi: BigInt.from(15000),
    );
  }

  @override
  Future<rust_sync.ExecuteProposalResult> executeProposal({
    required String dbPath,
    required String lightwalletdUrl,
    required BigInt proposalId,
    required String sendFlowId,
    required Uint8List mnemonicBytes,
  }) async {
    executeCalls++;
    seedSeenByExecute = mnemonicBytes;
    if (!releaseExecute) await executeGate.future;
    return execute ??
        const rust_sync.ExecuteProposalResult(
          txids: 'abc123',
          status: 'broadcasted',
          broadcastedCount: 1,
          totalCount: 1,
        );
  }
}

/// A sync notifier that lets the operation run and does no wallet work.
class _FakeSyncNotifier extends SyncNotifier {
  var refreshedAfterSend = 0;

  @override
  Future<SyncState> build() async => SyncState();

  @override
  Future<T> runWithAuthoritativeSpendable<T>({
    required String accountUuid,
    required Future<T> Function() operation,
  }) => operation();

  @override
  Future<void> refreshAfterSend() async {
    refreshedAfterSend++;
  }

  @override
  Future<void> refreshAfterProposalRelease(String accountUuid) async {}
}

NightjarSendReviewArgs _reviewArgs({
  int memoCount = 2,
  int anchorHeight = 6913,
  int chainTip = 6923,
  int anchorWindow = 200,
}) {
  final plan = njPayPlanFixture(
    memoCount: memoCount,
    anchorHeight: anchorHeight,
    chainTip: chainTip,
  );
  return NightjarSendReviewArgs(
    sendFlowId: 'flow-1',
    accountUuid: 'account-1',
    msgId: plan.msgId,
    assetId: plan.assetId,
    assetSymbol: plan.assetSymbol,
    assetName: 'Acre',
    assetDecimals: plan.assetDecimals,
    amount: plan.amount,
    change: plan.change,
    spent: plan.spent,
    inputs: plan.inputs,
    recipient: _recipient,
    channelAddress: _channelAddress,
    memos: plan.memos,
    memoValueZatoshi: plan.memoValueZatoshi,
    bodyBytes: plan.bodyBytes,
    anchorHeight: plan.anchorHeight,
    chainTip: plan.chainTip,
    anchorWindow: anchorWindow,
    vkHash: plan.vkHash,
    provedMs: plan.provedMs,
    builtAt: DateTime(2026, 9, 21),
  );
}

void main() {
  final baseUri = Uri.parse('http://127.0.0.1:8787');
  final config = defaultNightjarConfig(ZcashNetwork.regtest.name).copyWith(
    enabled: true,
    channelAddress: _channelAddress,
    provingKeyDir: '/keys',
  );

  late Uint8List seed;
  late int httpRequestsWhenSeedRead;

  setUp(() {
    seed = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    httpRequestsWhenSeedRead = -1;
  });

  FakeNightjarTorBridge httpBridge({String? status, String? vk}) {
    return FakeNightjarTorBridge([
      nightjarJsonResponse(status ?? nightjarFixtureText('status')),
      nightjarJsonResponse(vk ?? nightjarFixtureText('vk')),
      nightjarJsonResponse(
        nightjarMessagesFixtureWithCursor(
          'messages_page1',
          cursor: null,
          total: 2,
        ),
      ),
    ]);
  }

  Future<NightjarPayPlanResult> build(
    FakeNightjarTorBridge http,
    _FakePayBridge bridge, {
    NightjarConfig? withConfig,
    BigInt? amount,
    String recipient = _recipient,
    int? walletChainTip = 6923,
    void Function(NightjarBuildPhase)? onPhase,
  }) {
    final networkClient = nightjarTestNetworkClient(http);
    addTearDown(() => networkClient.close(force: true));
    return buildNightjarPayPlanWith(
      config: withConfig ?? config,
      client: NightjarIndexerClient(
        baseUri: baseUri,
        networkClient: networkClient,
      ),
      accountUuid: 'account-1',
      sendFlowId: 'flow-1',
      assetId: kNjFixtureAssetId,
      amount: amount ?? BigInt.from(500),
      recipient: recipient,
      walletChainTip: walletChainTip,
      onPhase: onPhase,
      bridge: bridge,
      readSeed: () async {
        httpRequestsWhenSeedRead = http.requests.length;
        return seed;
      },
    );
  }

  group('the proving-key gate', () {
    test('an unset folder is not a fault and says what to do', () async {
      final status = await checkNightjarProvingKey(keysDir: '  ');

      expect(status.state, NightjarProvingKeyState.notSet);
      expect(status.canSend, isFalse);
      expect(status.message, kNightjarProvingKeyNotSetText);
    });

    test("Rust's own sentence is shown, not a generic failure", () async {
      final bridge = _FakePayBridge(
        keyError:
            '/keys has no interpreter-v0.pk. Generate them with the '
            'Nightjar zk-setup tool.',
      );

      final status = await checkNightjarProvingKey(
        keysDir: '/keys',
        bridge: bridge,
      );

      expect(status.state, NightjarProvingKeyState.unreadable);
      expect(status.message, contains('has no interpreter-v0.pk'));
    });

    test('a key set the channel does not verify with is refused', () async {
      final bridge = _FakePayBridge()
        ..key = njProvingKeyFixture(vkHash: 'aa' * 32);

      final status = await checkNightjarProvingKey(
        keysDir: '/keys',
        channelVkHash: kNjFixtureVkHash,
        bridge: bridge,
      );

      expect(status.state, NightjarProvingKeyState.wrongKeySet);
      expect(status.canSend, isFalse);
      expect(status.message, contains(kNjFixtureVkHash));
      expect(status.message, contains('aa' * 32));
    });

    test('a matching key set is ready', () async {
      final status = await checkNightjarProvingKey(
        keysDir: '/keys',
        channelVkHash: kNjFixtureVkHash.toUpperCase(),
        bridge: _FakePayBridge(),
      );

      expect(status.state, NightjarProvingKeyState.ready);
      expect(status.canSend, isTrue);
      expect(status.isUnverifiedAgainstChannel, isFalse);
    });

    test('no channel hash leaves the comparison unmade, and says so', () async {
      final status = await checkNightjarProvingKey(
        keysDir: '/keys',
        bridge: _FakePayBridge(),
      );

      expect(status.state, NightjarProvingKeyState.ready);
      expect(status.isUnverifiedAgainstChannel, isTrue);
      expect(status.channelVkHash, isNull);
    });
  });

  group('how old a plan is allowed to be', () {
    test('an anchor inside the window is fresh and says nothing', () {
      expect(
        nightjarPlanFreshness(anchorHeight: 6913, chainTip: 6923),
        NightjarPlanFreshness.fresh,
      );
      expect(
        nightjarPlanFreshnessText(anchorHeight: 6913, chainTip: 6923),
        isNull,
      );
    });

    test('an anchor near the end of the window warns with blocks left', () {
      expect(
        nightjarPlanFreshness(anchorHeight: 6913, chainTip: 7100),
        NightjarPlanFreshness.aging,
      );
      expect(
        nightjarPlanFreshnessText(anchorHeight: 6913, chainTip: 7100),
        contains('13 more blocks'),
      );
    });

    test('an anchor past the window is expired and names the cost', () {
      expect(
        nightjarPlanFreshness(anchorHeight: 6913, chainTip: 7113),
        NightjarPlanFreshness.expired,
      );
      final text = nightjarPlanFreshnessText(
        anchorHeight: 6913,
        chainTip: 7113,
      );
      expect(text, contains('spend the ZEC'));
      expect(text, contains('Rebuild'));
    });

    test('a wallet with no tip of its own does not invent an age', () {
      expect(
        nightjarPlanFreshness(anchorHeight: 6913, chainTip: 0),
        NightjarPlanFreshness.fresh,
      );
      expect(nightjarPlanAnchorAge(anchorHeight: 6913, chainTip: 6900), 0);
    });

    test("the indexer's own anchor window is honoured", () {
      expect(
        nightjarPlanFreshness(
          anchorHeight: 6913,
          chainTip: 6963,
          anchorWindow: 50,
        ),
        NightjarPlanFreshness.expired,
      );
    });
  });

  group('building a plan', () {
    test('reports the fetch and the proof as separate steps', () async {
      final phases = <NightjarBuildPhase>[];
      final result = await build(
        httpBridge(),
        _FakePayBridge(),
        onPhase: phases.add,
      );

      expect(result.isReady, isTrue);
      expect(phases, [
        NightjarBuildPhase.readingChannel,
        NightjarBuildPhase.proving,
      ]);
    });

    test('reads the seed only after every byte of network I/O', () async {
      final http = httpBridge();
      await build(http, _FakePayBridge());

      expect(httpRequestsWhenSeedRead, http.requests.length);
      expect(http.requests, isNotEmpty);
    });

    test('zeroes the seed before the proof is awaited', () async {
      final bridge = _FakePayBridge()..releasePay = false;
      final pending = build(httpBridge(), bridge);

      await Future<void>.delayed(Duration.zero);
      expect(bridge.buildCalls, 1);
      // Still proving, and the plaintext seed is already gone.
      expect(bridge.seedSeenByBuild, everyElement(0));
      expect(seed, everyElement(0));

      bridge.payGate.complete();
      expect((await pending).isReady, isTrue);
    });

    test("builds against the wallet's own tip, not the indexer's", () async {
      final bridge = _FakePayBridge();
      await build(httpBridge(), bridge, walletChainTip: 7000);

      expect(bridge.chainTipSeen, 7000);
    });

    test('carries every field the transport needs', () async {
      final result = await build(httpBridge(), _FakePayBridge());
      final plan = result.plan!;

      expect(plan.memoCount, 2);
      expect(plan.memos.every((memo) => memo.length == 512), isTrue);
      expect(plan.memoValueZatoshi, BigInt.from(10000));
      expect(plan.channelZatoshi, BigInt.from(20000));
      expect(plan.channelAddress, _channelAddress);
      expect(plan.anchorWindow, 200);
      expect(plan.accountUuid, 'account-1');
    });

    test('refuses before any network call when no key folder is set', () async {
      final http = httpBridge();
      final result = await build(
        http,
        _FakePayBridge(),
        withConfig: config.copyWith(provingKeyDir: ''),
      );

      expect(result.isReady, isFalse);
      expect(result.error, kNightjarProvingKeyNotSetText);
      expect(http.requests, isEmpty);
    });

    test('refuses a zero amount without proving anything', () async {
      final bridge = _FakePayBridge();
      final result = await build(httpBridge(), bridge, amount: BigInt.zero);

      expect(result.isReady, isFalse);
      expect(result.error, 'Enter an amount greater than zero.');
      expect(bridge.buildCalls, 0);
    });

    test('refuses an empty recipient without proving anything', () async {
      final bridge = _FakePayBridge();
      final result = await build(httpBridge(), bridge, recipient: '   ');

      expect(result.isReady, isFalse);
      expect(result.error, 'Enter a Nightjar address to pay.');
      expect(bridge.buildCalls, 0);
    });

    test('will not prove against a key the indexer contradicts', () async {
      final bridge = _FakePayBridge();
      final result = await build(
        httpBridge(
          status: nightjarStatusFixtureWith(info: {'vk_hash': 'ff' * 32}),
        ),
        bridge,
      );

      expect(result.isReady, isFalse);
      expect(result.error, kNightjarVerifyingKeyMismatchText);
      expect(bridge.buildCalls, 0);
    });

    test("passes Rust's insufficient-funds sentence through intact", () async {
      const refusal =
          'Not enough of this asset can be spent right now: 300 available in '
          'at most 2 note(s), 500 needed (this wallet holds 900 of it in '
          'total).';
      final result = await build(
        httpBridge(),
        _FakePayBridge(payError: refusal),
      );

      expect(result.isReady, isFalse);
      // The shortfall, the total held and the two-note limit all survive.
      expect(result.error, refusal);
    });

    test('a locked wallet is told to unlock, not that it is broke', () async {
      final networkClient = nightjarTestNetworkClient(httpBridge());
      addTearDown(() => networkClient.close(force: true));
      final result = await buildNightjarPayPlanWith(
        config: config,
        client: NightjarIndexerClient(
          baseUri: baseUri,
          networkClient: networkClient,
        ),
        accountUuid: 'account-1',
        sendFlowId: 'flow-1',
        assetId: kNjFixtureAssetId,
        amount: BigInt.from(500),
        recipient: _recipient,
        bridge: _FakePayBridge(),
        readSeed: () async => null,
      );

      expect(result.isReady, isFalse);
      expect(result.error, contains('Unlock this wallet'));
    });
  });

  group('broadcasting a plan', () {
    Future<NightjarSendOutcome> send(
      _FakeSendBridge bridge, {
      NightjarSendReviewArgs? args,
      bool hardware = false,
      void Function(NightjarSendPhase)? onPhase,
      Future<bool> Function()? shouldAbort,
      _FakeSyncNotifier? sync,
    }) {
      return runNightjarSendBroadcastWith(
        args: args ?? _reviewArgs(),
        syncNotifier: sync ?? _FakeSyncNotifier(),
        readEndpoint: () => const RpcEndpointConfig(
          networkName: 'regtest',
          lightwalletdUrl: 'http://127.0.0.1:19067',
        ),
        readSeed: () async => seed,
        isHardwareAccount: () => hardware,
        onPhase: onPhase,
        shouldAbort: shouldAbort,
        loadDbPath: () async => '/tmp/wallet.db',
        bridge: bridge,
      );
    }

    test('puts every memo in one proposal, to the channel address', () async {
      final bridge = _FakeSendBridge();
      final args = _reviewArgs(memoCount: 5);

      final outcome = await send(bridge, args: args);

      expect(outcome.phase, NightjarSendOutcomePhase.succeeded);
      expect(bridge.proposeCalls, 1);
      final outputs = bridge.outputsSeen!;
      expect(outputs, hasLength(5));
      for (var i = 0; i < outputs.length; i++) {
        expect(outputs[i].toAddress, _channelAddress);
        expect(outputs[i].amountZatoshi, args.memoValueZatoshi);
        expect(outputs[i].memoBytes, args.memos[i]);
        expect(outputs[i].memoBytes, hasLength(512));
      }
    });

    test('never addresses an output to the Nightjar recipient', () async {
      final bridge = _FakeSendBridge();
      await send(bridge);

      expect(
        bridge.outputsSeen!.map((output) => output.toAddress),
        isNot(contains(_recipient)),
      );
    });

    test('reports proposing and broadcasting in order', () async {
      final phases = <NightjarSendPhase>[];
      await send(_FakeSendBridge(), onPhase: phases.add);

      expect(phases, [
        NightjarSendPhase.proposing,
        NightjarSendPhase.broadcasting,
      ]);
    });

    test('zeroes the seed before the broadcast is awaited', () async {
      final bridge = _FakeSendBridge()..releaseExecute = false;
      final pending = send(bridge);

      await Future<void>.delayed(Duration.zero);
      expect(bridge.executeCalls, 1);
      expect(bridge.seedSeenByExecute, everyElement(0));
      expect(seed, everyElement(0));

      bridge.executeGate.complete();
      expect((await pending).phase, NightjarSendOutcomePhase.succeeded);
    });

    test('refreshes the wallet after a successful send', () async {
      final sync = _FakeSyncNotifier();
      await send(_FakeSendBridge(), sync: sync);

      expect(sync.refreshedAfterSend, 1);
    });

    test('a broadcast that did not land is pending, not sent', () async {
      final bridge = _FakeSendBridge(
        execute: const rust_sync.ExecuteProposalResult(
          txids: 'abc123',
          status: 'created',
          broadcastedCount: 0,
          totalCount: 1,
          message: 'broadcast rejected',
        ),
      );

      final outcome = await send(bridge);

      expect(outcome.phase, NightjarSendOutcomePhase.pendingBroadcast);
      expect(outcome.txid, 'abc123');
      expect(outcome.statusMessage, isNotNull);
    });

    test('memos split across two transactions is a failure, loudly', () async {
      final bridge = _FakeSendBridge(
        execute: const rust_sync.ExecuteProposalResult(
          txids: 'abc123,def456',
          status: 'broadcasted',
          broadcastedCount: 2,
          totalCount: 2,
        ),
      );

      final outcome = await send(bridge);

      expect(outcome.phase, NightjarSendOutcomePhase.failed);
      expect(outcome.error, contains('cannot reassemble'));
      expect(outcome.error, contains('ZEC was spent'));
    });

    test('a hardware account is refused before anything is proposed', () async {
      final bridge = _FakeSendBridge();
      final outcome = await send(bridge, hardware: true);

      expect(outcome.phase, NightjarSendOutcomePhase.failed);
      expect(outcome.error, kNightjarHardwareAccountText);
      expect(bridge.proposeCalls, 0);
    });

    test('a failed proposal never reaches the broadcast', () async {
      final bridge = _FakeSendBridge(proposeError: 'Wallet must sync first.');
      final outcome = await send(bridge);

      expect(outcome.phase, NightjarSendOutcomePhase.failed);
      expect(outcome.error, 'Wallet must sync first.');
      expect(bridge.executeCalls, 0);
      expect(outcome.proposalConsumed, isFalse);
    });

    test('leaving before the proposal is made locks nothing', () async {
      final bridge = _FakeSendBridge();
      final outcome = await send(bridge, shouldAbort: () async => true);

      expect(outcome.phase, NightjarSendOutcomePhase.aborted);
      expect(bridge.proposeCalls, 0);
      expect(bridge.executeCalls, 0);
    });

    test(
      'leaving after the proposal releases it rather than broadcasting',
      () async {
        final bridge = _FakeSendBridge();
        var proposed = false;
        final outcome = await send(
          bridge,
          shouldAbort: () async {
            // False on the pre-proposal check, true on the one after it.
            final abort = proposed;
            proposed = true;
            return abort;
          },
        );

        expect(outcome.phase, NightjarSendOutcomePhase.aborted);
        expect(bridge.proposeCalls, 1);
        expect(bridge.executeCalls, 0);
        // Rust is unreachable in a unit test, so the release cannot be
        // confirmed here; what this pins is that the flow never reports a
        // consumed proposal it did not consume.
        expect(outcome.proposalConsumed, isFalse);
      },
    );

    test('a plan with no memos is refused', () async {
      final bridge = _FakeSendBridge();
      final args = _reviewArgs();
      final empty = NightjarSendReviewArgs(
        sendFlowId: args.sendFlowId,
        accountUuid: args.accountUuid,
        msgId: args.msgId,
        assetId: args.assetId,
        assetSymbol: args.assetSymbol,
        assetName: args.assetName,
        assetDecimals: args.assetDecimals,
        amount: args.amount,
        change: args.change,
        spent: args.spent,
        inputs: args.inputs,
        recipient: args.recipient,
        channelAddress: args.channelAddress,
        memos: const [],
        memoValueZatoshi: args.memoValueZatoshi,
        bodyBytes: args.bodyBytes,
        anchorHeight: args.anchorHeight,
        chainTip: args.chainTip,
        vkHash: args.vkHash,
        provedMs: args.provedMs,
        builtAt: args.builtAt,
      );

      final outcome = await send(bridge, args: empty);

      expect(outcome.phase, NightjarSendOutcomePhase.failed);
      expect(bridge.proposeCalls, 0);
    });
  });

  group('what a plan says about itself', () {
    test('the ZEC total is the per-memo value times the memo count', () {
      final args = _reviewArgs(memoCount: 3);

      expect(args.memoValueZatoshi, BigInt.from(10000));
      expect(args.channelZatoshi, BigInt.from(30000));
    });

    test('freshness is judged against the tip it is given', () {
      final args = _reviewArgs(anchorHeight: 6913);

      expect(args.freshnessAt(6923), NightjarPlanFreshness.fresh);
      expect(args.freshnessAt(7200), NightjarPlanFreshness.expired);
      // No tip falls back to the one the plan was built against, which is the
      // only honest answer a wallet with no sync of its own has.
      expect(args.freshnessAt(0), NightjarPlanFreshness.fresh);
    });
  });
}
