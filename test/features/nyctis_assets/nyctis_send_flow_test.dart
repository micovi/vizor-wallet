/// What the Nyctis send flow is allowed to do, and what it must refuse.
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
import 'package:zcash_wallet/src/core/config/nyctis_config.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_indexer_client.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_send_flow.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/widgets/nyctis_asset_row_mapper.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/nyctis.dart' as rust_nyctis;
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

import 'support/nyctis_fixtures.dart';

const _channelAddress = 'uregtestchanneladdress';
/// A real regtest Nyctis address (`rust/src/nyctis/keys.rs` demo seed).
const _recipient =
    'nyreg1qzxdgxkjg4vgjux6rw63t0akwkq03q5stfz9txpjcqx0mgcmpfrqk2per2w388qnr'
    'tc7t5mh9nux7ftrxq0xsc9gjv9shuymray29qq8yqcqxexsz2hwz2f6nmtmvgr46ja60dfg'
    'kasmf5tsg3a3jtq9hs9sxafxqq';

class _FakePayBridge extends NyctisPayBridge {
  _FakePayBridge({rust_nyctis.NyPayPlan? plan, this.payError, this.keyError})
    : plan = plan ?? nyPayPlanFixture();

  final rust_nyctis.NyPayPlan plan;
  final Object? payError;
  final Object? keyError;
  rust_nyctis.NyProvingKey key = nyProvingKeyFixture();

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
  Future<rust_nyctis.NyProvingKey> checkProvingKey({
    required String keysDir,
  }) async {
    keyCalls++;
    keysDirSeen = keysDir;
    final error = keyError;
    if (error != null) throw error;
    return key;
  }

  @override
  Future<rust_nyctis.NyPayPlan> buildPay({
    required String network,
    required String channelUivk,
    required String channelAddress,
    required int birthday,
    required int chainTip,
    required Uint8List vk,
    required String vkPin,
    required List<rust_nyctis.NyMessageInput> messages,
    required Uint8List mnemonic,
    required String keysDir,
    required String assetId,
    required BigInt amount,
    required String recipient,
    required rust_nyctis.NyZecSources zecSources,
  }) async {
    buildCalls++;
    // The same buffer the caller handed over, not a copy: the zeroing this
    // test is about happens in place.
    seedSeenByBuild = mnemonic;
    chainTipSeen = chainTip;
    keysDirSeen = keysDir;
    amountSeen = amount;
    if (!releasePay) await payGate.future;
    final error = payError;
    if (error != null) throw error;
    return plan;
  }
}

class _FakeSendBridge extends NyctisSendBridge {
  _FakeSendBridge({this.proposeError, this.execute, this.feeZatoshi});

  final Object? proposeError;
  final BigInt? feeZatoshi;
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
      feeZatoshi: feeZatoshi ?? BigInt.from(15000),
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

NyctisSendReviewArgs _reviewArgs({
  int memoCount = 2,
  int anchorHeight = 6913,
  int chainTip = 6923,
  int anchorWindow = 200,
  String channelAddress = _channelAddress,
  BigInt? quotedFeeZatoshi,
}) {
  final plan = nyPayPlanFixture(
    memoCount: memoCount,
    anchorHeight: anchorHeight,
    chainTip: chainTip,
  );
  return NyctisSendReviewArgs(
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
    channelAddress: channelAddress,
    memos: plan.memos,
    memoValueZatoshi: plan.memoValueZatoshi,
    bodyBytes: plan.bodyBytes,
    anchorHeight: plan.anchorHeight,
    chainTip: plan.chainTip,
    anchorWindow: anchorWindow,
    vkHash: plan.vkHash,
    provedMs: plan.provedMs,
    builtAt: DateTime(2026, 9, 21),
    quotedFeeZatoshi: quotedFeeZatoshi,
  );
}

void main() {
  final baseUri = Uri.parse('http://127.0.0.1:8787');
  final config = defaultNyctisConfig(ZcashNetwork.regtest.name).copyWith(
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

  FakeNyctisTorBridge httpBridge({String? status, String? vk}) {
    return FakeNyctisTorBridge([
      nyctisJsonResponse(status ?? nyctisFixtureText('status')),
      nyctisJsonResponse(vk ?? nyctisFixtureText('vk')),
      nyctisJsonResponse(
        nyctisMessagesFixtureWithCursor(
          'messages_page1',
          cursor: null,
          total: 2,
        ),
      ),
    ]);
  }

  Future<NyctisPayPlanResult> build(
    FakeNyctisTorBridge http,
    _FakePayBridge bridge, {
    NyctisConfig? withConfig,
    BigInt? amount,
    String recipient = _recipient,
    int? walletChainTip = 6923,
    void Function(NyctisBuildPhase)? onPhase,
  }) {
    final networkClient = nyctisTestNetworkClient(http);
    addTearDown(() => networkClient.close(force: true));
    return buildNyctisPayPlanWith(
      config: withConfig ?? config,
      client: NyctisIndexerClient(
        baseUri: baseUri,
        networkClient: networkClient,
      ),
      accountUuid: 'account-1',
      sendFlowId: 'flow-1',
      assetId: kNyFixtureAssetId,
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
      final status = await checkNyctisProvingKey(keysDir: '  ');

      expect(status.state, NyctisProvingKeyState.notSet);
      expect(status.canSend, isFalse);
      expect(status.message, kNyctisProvingKeyNotSetText);
    });

    test("Rust's own sentence is shown, not a generic failure", () async {
      final bridge = _FakePayBridge(
        keyError:
            '/keys has no interpreter-v0.pk. Generate them with the '
            'Nyctis zk-setup tool.',
      );

      final status = await checkNyctisProvingKey(
        keysDir: '/keys',
        bridge: bridge,
      );

      expect(status.state, NyctisProvingKeyState.unreadable);
      expect(status.message, contains('has no interpreter-v0.pk'));
    });

    test('a key set the channel does not verify with is refused', () async {
      final bridge = _FakePayBridge()
        ..key = nyProvingKeyFixture(vkHash: 'aa' * 32);

      final status = await checkNyctisProvingKey(
        keysDir: '/keys',
        channelVkHash: kNyFixtureVkHash,
        bridge: bridge,
      );

      expect(status.state, NyctisProvingKeyState.wrongKeySet);
      expect(status.canSend, isFalse);
      expect(status.message, contains(kNyFixtureVkHash));
      expect(status.message, contains('aa' * 32));
    });

    test('a matching key set is ready', () async {
      final status = await checkNyctisProvingKey(
        keysDir: '/keys',
        channelVkHash: kNyFixtureVkHash.toUpperCase(),
        bridge: _FakePayBridge(),
      );

      expect(status.state, NyctisProvingKeyState.ready);
      expect(status.canSend, isTrue);
      expect(status.isUnverifiedAgainstChannel, isFalse);
    });

    test('no channel hash leaves the comparison unmade, and says so', () async {
      final status = await checkNyctisProvingKey(
        keysDir: '/keys',
        bridge: _FakePayBridge(),
      );

      expect(status.state, NyctisProvingKeyState.ready);
      expect(status.isUnverifiedAgainstChannel, isTrue);
      expect(status.channelVkHash, isNull);
    });
  });

  group('how old a plan is allowed to be', () {
    test('an anchor inside the window is fresh and says nothing', () {
      expect(
        nyctisPlanFreshness(anchorHeight: 6913, chainTip: 6923),
        NyctisPlanFreshness.fresh,
      );
      expect(
        nyctisPlanFreshnessText(anchorHeight: 6913, chainTip: 6923),
        isNull,
      );
    });

    test('an anchor near the end of the window warns with blocks left', () {
      expect(
        nyctisPlanFreshness(anchorHeight: 6913, chainTip: 7100),
        NyctisPlanFreshness.aging,
      );
      expect(
        nyctisPlanFreshnessText(anchorHeight: 6913, chainTip: 7100),
        contains('13 more blocks'),
      );
    });

    test('an anchor past the window is expired and names the cost', () {
      expect(
        nyctisPlanFreshness(anchorHeight: 6913, chainTip: 7113),
        NyctisPlanFreshness.expired,
      );
      final text = nyctisPlanFreshnessText(
        anchorHeight: 6913,
        chainTip: 7113,
      );
      expect(text, contains('spend the ZEC'));
      expect(text, contains('Rebuild'));
    });

    test('a wallet with no tip of its own does not invent an age', () {
      expect(
        nyctisPlanFreshness(anchorHeight: 6913, chainTip: 0),
        NyctisPlanFreshness.fresh,
      );
      expect(nyctisPlanAnchorAge(anchorHeight: 6913, chainTip: 6900), 0);
    });

    test("the indexer's own anchor window is honoured", () {
      expect(
        nyctisPlanFreshness(
          anchorHeight: 6913,
          chainTip: 6963,
          anchorWindow: 50,
        ),
        NyctisPlanFreshness.expired,
      );
    });
  });

  group('building a plan', () {
    test('reports the fetch and the proof as separate steps', () async {
      final phases = <NyctisBuildPhase>[];
      final result = await build(
        httpBridge(),
        _FakePayBridge(),
        onPhase: phases.add,
      );

      expect(result.isReady, isTrue);
      expect(phases, [
        NyctisBuildPhase.readingChannel,
        NyctisBuildPhase.proving,
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
      expect(result.error, kNyctisProvingKeyNotSetText);
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
      expect(result.error, 'Enter a Nyctis address to pay.');
      expect(bridge.buildCalls, 0);
    });

    test('will not prove against a key the indexer contradicts', () async {
      final bridge = _FakePayBridge();
      final result = await build(
        httpBridge(
          status: nyctisStatusFixtureWith(info: {'vk_hash': 'ff' * 32}),
        ),
        bridge,
      );

      expect(result.isReady, isFalse);
      expect(result.error, kNyctisVerifyingKeyMismatchText);
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
      final networkClient = nyctisTestNetworkClient(httpBridge());
      addTearDown(() => networkClient.close(force: true));
      final result = await buildNyctisPayPlanWith(
        config: config,
        client: NyctisIndexerClient(
          baseUri: baseUri,
          networkClient: networkClient,
        ),
        accountUuid: 'account-1',
        sendFlowId: 'flow-1',
        assetId: kNyFixtureAssetId,
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
    Future<NyctisSendOutcome> send(
      _FakeSendBridge bridge, {
      NyctisSendReviewArgs? args,
      bool hardware = false,
      void Function(NyctisSendPhase)? onPhase,
      Future<bool> Function()? shouldAbort,
      _FakeSyncNotifier? sync,
    }) {
      return runNyctisSendBroadcastWith(
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

      expect(outcome.phase, NyctisSendOutcomePhase.succeeded);
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

    test('never addresses an output to the Nyctis recipient', () async {
      final bridge = _FakeSendBridge();
      await send(bridge);

      expect(
        bridge.outputsSeen!.map((output) => output.toAddress),
        isNot(contains(_recipient)),
      );
    });

    test('reports proposing and broadcasting in order', () async {
      final phases = <NyctisSendPhase>[];
      await send(_FakeSendBridge(), onPhase: phases.add);

      expect(phases, [
        NyctisSendPhase.proposing,
        NyctisSendPhase.broadcasting,
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
      expect((await pending).phase, NyctisSendOutcomePhase.succeeded);
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

      expect(outcome.phase, NyctisSendOutcomePhase.pendingBroadcast);
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

      expect(outcome.phase, NyctisSendOutcomePhase.failed);
      expect(outcome.error, contains('cannot reassemble'));
      expect(outcome.error, contains('ZEC was spent'));
    });

    test('a hardware account is refused before anything is proposed', () async {
      final bridge = _FakeSendBridge();
      final outcome = await send(bridge, hardware: true);

      expect(outcome.phase, NyctisSendOutcomePhase.failed);
      expect(outcome.error, kNyctisHardwareAccountText);
      expect(bridge.proposeCalls, 0);
    });

    test('a failed proposal never reaches the broadcast', () async {
      final bridge = _FakeSendBridge(proposeError: 'Wallet must sync first.');
      final outcome = await send(bridge);

      expect(outcome.phase, NyctisSendOutcomePhase.failed);
      expect(outcome.error, 'Wallet must sync first.');
      expect(bridge.executeCalls, 0);
      expect(outcome.proposalConsumed, isFalse);
    });

    test('leaving before the proposal is made locks nothing', () async {
      final bridge = _FakeSendBridge();
      final outcome = await send(bridge, shouldAbort: () async => true);

      expect(outcome.phase, NyctisSendOutcomePhase.aborted);
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

        expect(outcome.phase, NyctisSendOutcomePhase.aborted);
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
      final empty = NyctisSendReviewArgs(
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

      expect(outcome.phase, NyctisSendOutcomePhase.failed);
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

      expect(args.freshnessAt(6923), NyctisPlanFreshness.fresh);
      expect(args.freshnessAt(7200), NyctisPlanFreshness.expired);
      // No tip falls back to the one the plan was built against, which is the
      // only honest answer a wallet with no sync of its own has.
      expect(args.freshnessAt(0), NyctisPlanFreshness.fresh);
    });
  });

  group('checks made before a proof or a proposal', () {
    test('a malformed recipient is refused before any network call', () async {
      final http = httpBridge();
      final bridge = _FakePayBridge();
      final result = await build(http, bridge, recipient: 'nyreg1recipient');

      expect(result.isReady, isFalse);
      expect(result.error, contains('Check it for typos'));
      expect(http.requests, isEmpty);
      expect(bridge.buildCalls, 0);
    });

    test("a mainnet address on regtest names the network it is for", () async {
      final result = await build(
        httpBridge(),
        _FakePayBridge(),
        recipient: 'ny1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq',
      );
      expect(result.isReady, isFalse);
      expect(result.error, isNotNull);
    });

    test('the plan takes the protocol window, never a longer claim', () {
      expect(nyctisEffectiveAnchorWindow(0), kNyctisDefaultAnchorWindow);
      expect(nyctisEffectiveAnchorWindow(100000), 200);
      expect(nyctisEffectiveAnchorWindow(150), 150);
    });

    test('a TEX channel address is refused: it would split the memos', () {
      expect(nyctisChannelAddressError('uregtest1abc'), isNull);
      expect(
        nyctisChannelAddressError('texregtest1abc'),
        contains('two transactions'),
      );
      expect(nyctisChannelAddressError('  '), isNotNull);
    });

    test('the ZEC floor is one memo plus the ZIP 317 minimum fee', () {
      expect(kNyctisMinimumZecZatoshi, BigInt.from(20000));
      expect(nyctisZecShortfallText(BigInt.from(20000)), isNull);
      expect(
        nyctisZecShortfallText(BigInt.from(19999)),
        contains('0.0002 ZEC'),
      );
    });

    test('finality is minutes on mainnet and blocks on regtest', () {
      expect(nyctisFinalityEstimateText('main', 10), 'in about 13 minutes');
      expect(
        nyctisFinalityEstimateText('regtest', 10),
        'once 10 more blocks are mined',
      );
      expect(
        nyctisFinalityEstimateText('regtest', 1),
        'once 1 more block is mined',
      );
    });
  });

  group('quoting the ZEC cost (U3, C13)', () {
    Future<NyctisZecQuote> quote(
      _FakeSendBridge bridge, {
      NyctisSendReviewArgs? args,
      List<BigInt>? released,
      BigInt? spendable,
    }) {
      return quoteNyctisSendWith(
        plan: args ?? _reviewArgs(),
        syncNotifier: _FakeSyncNotifier(),
        readEndpoint: () => const RpcEndpointConfig(
          networkName: 'regtest',
          lightwalletdUrl: 'http://127.0.0.1:19067',
        ),
        spendableZatoshi: spendable,
        loadDbPath: () async => '/tmp/wallet.db',
        bridge: bridge,
        releaseProposal: (id, _) async => released?.add(id),
      );
    }

    test('proposes the exact outputs, reads the fee, releases it', () async {
      final bridge = _FakeSendBridge(feeZatoshi: BigInt.from(15000));
      final released = <BigInt>[];
      final result = await quote(
        bridge,
        args: _reviewArgs(memoCount: 3),
        released: released,
      );

      expect(result.isReady, isTrue);
      expect(result.feeZatoshi, BigInt.from(15000));
      expect(result.channelZatoshi, BigInt.from(30000));
      expect(result.totalZatoshi, BigInt.from(45000));
      expect(bridge.outputsSeen, hasLength(3));
      // Nothing is held while the user reads the review.
      expect(released, [BigInt.from(7)]);
      expect(bridge.executeCalls, 0);
      // Its own flow id, never the broadcast's.
      expect(bridge.sendFlowIdSeen, isNot('flow-1'));
    });

    test('too little ZEC is said plainly, with what is spendable', () async {
      final result = await quote(
        _FakeSendBridge(proposeError: 'Insufficient balance (have 5000)'),
        spendable: BigInt.from(5000),
      );

      expect(result.isReady, isFalse);
      expect(result.error, contains('does not have enough ZEC'));
      expect(result.error, contains('0.00005 ZEC spendable'));
    });

    test('a TEX channel is refused without proposing', () async {
      final bridge = _FakeSendBridge();
      final result = await quote(
        bridge,
        args: _reviewArgs(channelAddress: 'texregtest1abc'),
      );

      expect(result.isReady, isFalse);
      expect(bridge.proposeCalls, 0);
    });
  });

  group('the broadcast honours the review', () {
    Future<NyctisSendOutcome> send(
      _FakeSendBridge bridge,
      NyctisSendReviewArgs args,
    ) {
      final seed = Uint8List.fromList(List<int>.filled(32, 7));
      return runNyctisSendBroadcastWith(
        args: args,
        syncNotifier: _FakeSyncNotifier(),
        readEndpoint: () => const RpcEndpointConfig(
          networkName: 'regtest',
          lightwalletdUrl: 'http://127.0.0.1:19067',
        ),
        readSeed: () async => seed,
        loadDbPath: () async => '/tmp/wallet.db',
        bridge: bridge,
      );
    }

    test('a fee above the one confirmed is refused unsigned', () async {
      final bridge = _FakeSendBridge(feeZatoshi: BigInt.from(25000));
      final outcome = await send(
        bridge,
        _reviewArgs(quotedFeeZatoshi: BigInt.from(15000)),
      );

      expect(outcome.phase, NyctisSendOutcomePhase.failed);
      expect(outcome.proposalConsumed, isFalse);
      expect(outcome.error, contains('network fee changed'));
      expect(bridge.executeCalls, 0);
    });

    test('the fee confirmed, or less, goes through', () async {
      final bridge = _FakeSendBridge(feeZatoshi: BigInt.from(15000));
      final outcome = await send(
        bridge,
        _reviewArgs(quotedFeeZatoshi: BigInt.from(15000)),
      );

      expect(outcome.phase, NyctisSendOutcomePhase.succeeded);
    });

    test('a TEX channel is refused before anything is proposed', () async {
      final bridge = _FakeSendBridge();
      final outcome = await send(
        bridge,
        _reviewArgs(channelAddress: 'texregtest1abc'),
      );

      expect(outcome.phase, NyctisSendOutcomePhase.failed);
      expect(bridge.proposeCalls, 0);
    });
  });
}
