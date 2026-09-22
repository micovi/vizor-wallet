/// The seam between the Nightjar UI and whatever eventually produces a
/// Nightjar view.
///
/// The screens in this feature watch [nightjarAssetsViewProvider] and nothing
/// else. What fills it is an injectable [NightjarViewLoader], in the style of
/// `ActivityHistoryLoader` (`lib/src/features/activity/screens/
/// activity_screen.dart`): a test overrides [nightjarViewLoaderProvider] with
/// a fixture, and the real wiring overrides it with the call that fetches the
/// channel from the indexer, verifies every proof, replays the state, and
/// decrypts with the account's `ivk`.
///
/// An unconfigured wallet gets [NightjarViewData.notConfigured] rather than
/// sample data: it must say so, because a placeholder balance in a wallet is a
/// lie with consequences.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/account_provider.dart';
import '../../../providers/nightjar_config_provider.dart';
import '../services/nightjar_view_loader.dart';
import '../widgets/nightjar_asset_row_data.dart';

/// Produces the whole Nightjar view for the active wallet.
///
/// Implementations own their own error handling: a failure to reach or read
/// the indexer should come back as a [NightjarViewData] with
/// [NightjarViewStatus.unreachable] or [NightjarViewStatus.stale], not as a
/// thrown exception, so the UI can keep its own copy for each case. A thrown
/// exception still renders — as the generic unreachable state — but loses the
/// distinction.
typedef NightjarViewLoader = Future<NightjarViewData> Function();

/// The default loader: Nightjar is not configured, so there is nothing to
/// read and nothing to show.
Future<NightjarViewData> loadNotConfiguredNightjarView() async {
  return const NightjarViewData.notConfigured();
}

/// Override this to supply a fixture Nightjar view.
///
/// The shipped implementation is the real one: it reads the configured
/// indexer, verifies every proof locally and decrypts with the wallet's own
/// key. It still degrades to [loadNotConfiguredNightjarView]'s answer when
/// nothing is configured, so a wallet that has never been pointed at a channel
/// costs nothing and says so.
final nightjarViewLoaderProvider = Provider<NightjarViewLoader>(
  (ref) =>
      () => loadNightjarViewFor(ref),
);

/// The Nightjar view every screen in this feature reads.
///
/// This watches the two inputs that decide *what* gets read, even though it
/// does not use either value here. The loader reads them with `ref.read` on
/// purpose — it wants one consistent snapshot for the whole load rather than a
/// rebuild in the middle of a paged network walk — and `ref.read` creates no
/// dependency. Without these two lines, turning the feature on in settings
/// changed the configuration and invalidated nothing, so this future kept
/// handing back its first answer, "Nightjar is not set up yet", until the app
/// was restarted.
final nightjarAssetsViewProvider = FutureProvider<NightjarViewData>((
  ref,
) async {
  // Registering the dependency is the point; the value is not used here and a
  // failure to produce one is not this provider's to report. `loadNightjarViewFor`
  // already turns an unreadable configuration into a rendered state, and a
  // widget test that stubs only the loader leaves `appBootstrapProvider`
  // throwing by design — letting that escape here would fail the screen rather
  // than the setting it is watching.
  try {
    ref.watch(nightjarConfigProvider);
    ref.watch(
      accountProvider.select(
        (state) => state.hasValue ? state.requireValue.activeAccountUuid : null,
      ),
    );
  } catch (_) {}
  final loader = ref.watch(nightjarViewLoaderProvider);
  return loader();
});

/// The view as plain values, with a load failure folded into the
/// unreachable state so screens never have to branch on [AsyncValue] shape.
///
/// Returns null while the first load is still in flight; the screens render
/// their loading state for that.
NightjarViewData? resolveNightjarView(AsyncValue<NightjarViewData> async) {
  return async.when(
    data: (view) => view,
    loading: () => async.hasValue ? async.requireValue : null,
    error: (error, _) => NightjarViewData(
      status: NightjarViewStatus.unreachable,
      statusDetail: error.toString(),
    ),
  );
}
