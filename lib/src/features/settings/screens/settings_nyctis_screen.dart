/// Desktop `/settings/nyctis` — the only surface that can turn the
/// Nyctis assets feature on.
///
/// `NyctisConfig.enabled` defaults to false because switching it on has two
/// consequences the wallet must not take on its own: it derives a Nyctis
/// identity from the seed already in secure storage, and it starts talking to
/// a network service. This screen states both, then offers the switch.
///
/// The copy constants and the indexer-choice enum live here and are imported
/// by `mobile/mobile_nyctis_screen.dart` so the two form factors cannot
/// drift apart in wording or in what "custom indexer" means.
library;

import 'package:flutter/services.dart' show TextInputAction, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../main.dart' show log;
import '../../../core/config/nyctis_config.dart';
import '../../../core/formatting/address_display.dart';
import '../../../core/formatting/number_format.dart';
import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/review_list_row.dart';
import '../../../core/widgets/review_wrap_card.dart';
import '../../../providers/nyctis_config_provider.dart';
import '../../nyctis_assets/providers/nyctis_proving_key_provider.dart';
import '../../nyctis_assets/services/nyctis_send_flow.dart';
import '../../nyctis_assets/widgets/nyctis_asset_row_data.dart';
import '../../nyctis_assets/widgets/nyctis_facts_card.dart';

/// Which indexer origin the screen is about to save. Mirrors the
/// preset/custom pair `settings_explorer_screen.dart` uses.
enum NyctisIndexerChoice { preset, custom }

/// Sidebar/settings-row label and screen title.
const kNyctisSettingsTitle = 'Nyctis';

/// What the switch actually does, said before it is touched.
const kNyctisSettingsEnableCopy =
    'With this on, the wallet reads the channel from the Nyctis indexer '
    'below and derives a Nyctis identity from the seed it already holds. '
    'That identity needs no separate backup, and no key ever leaves this '
    'device.';

/// What the indexer is trusted for, and what it is not trusted for.
const kNyctisSettingsIndexerCopy =
    'The indexer supplies message data only. Vizor verifies every proof and '
    'replays the channel locally, so an indexer cannot invent a balance — it '
    'can only withhold a message.';

/// Why a public viewing key is safe to show here.
const kNyctisSettingsChannelCopy =
    'The channel viewing key is public and only says where to look. What is '
    'yours is decided on this device, by a key the channel never sees.';

const kNyctisSettingsEnabledLabel = 'Nyctis assets';
const kNyctisSettingsChannelTitle = 'Channel';
const kNyctisSettingsIndexerFieldLabel = 'Indexer URL';
const kNyctisSettingsIndexerHint = 'https://indexer.example';
const kNyctisSettingsUpdateLabel = 'Update indexer';
const kNyctisSettingsUpdatingLabel = 'Updating...';
const kNyctisSettingsResetLabel = 'Reset to defaults';
const kNyctisSettingsPresetOption = 'Default';
const kNyctisSettingsCustomOption = 'Custom';

/// Shown when [NyctisConfig.hasChannel] is false — mainnet and testnet ship
/// no channel, so there is nothing for a switch to turn on.
String nyctisSettingsUnavailableCopy(String networkName) =>
    'This build ships a Nyctis channel for regtest only, so there is '
    'nothing to read on '
    '${nyctisNetworkLabel(networkName).toLowerCase()} yet. Nyctis turns '
    'itself on here once a channel exists for this network.';

/// Fallback for a `setEnabled` refusal that carried no message.
const kNyctisSettingsNotConfigured = 'Nyctis is not configured yet.';

const kNyctisSettingsSaveFailed = "Couldn't save that indexer URL.";
const kNyctisSettingsToggleFailed = "Couldn't change that setting.";

/// Heading of the one card on this screen that is about *sending*.
const kNyctisSettingsProvingKeyTitle = 'Sending';

const kNyctisSettingsProvingKeyFieldLabel = 'Proving key folder';
const kNyctisSettingsProvingKeyHint = '/path/to/keys';
const kNyctisSettingsProvingKeySaveLabel = 'Save folder';
const kNyctisSettingsProvingKeyCheckingLabel = 'Checking...';
const kNyctisSettingsProvingKeyClearLabel = 'Forget folder';
const kNyctisSettingsProvingKeySaveFailed = "Couldn't save that folder.";

/// Why this setting exists at all, and what the wallet does with it.
const kNyctisSettingsProvingKeyCopy =
    'Reading a channel needs only the small verifying key, which the indexer '
    'serves. Making a payment needs the proving key: about 83 MiB, served by '
    'nothing, and read only while a proof is being made. Point this at the '
    'folder holding interpreter-v0.pk, and the wallet checks it against the '
    'key this channel verifies with.';

/// What a valid folder that could not be compared with the channel means.
///
/// Said out loud rather than shown as a green tick: two key sets can share a
/// circuit fingerprint and be mutually unusable, and the only value that
/// separates them is a hash a replay produces.
const kNyctisSettingsProvingKeyUnverifiedCopy =
    'This folder has not been compared with the channel yet, because this '
    'wallet has not replayed one. Sending checks it again before it proves '
    'anything.';

/// One-word verdict for the proving-key row.
String nyctisProvingKeyStatusLabel(NyctisProvingKeyStatus status) {
  return switch (status.state) {
    NyctisProvingKeyState.notSet => 'Not set',
    NyctisProvingKeyState.unreadable => 'Unusable',
    NyctisProvingKeyState.wrongKeySet => 'Wrong key set',
    NyctisProvingKeyState.ready => 'Ready',
  };
}

/// `83 MiB` — integer-only, like every other number in this feature.
String nyctisProvingKeySizeText(BigInt bytes) {
  const mib = 1024 * 1024;
  if (bytes < BigInt.from(mib)) {
    return '${formatGroupedInteger(bytes.toInt())} bytes';
  }
  final tenths = (bytes * BigInt.from(10)) ~/ BigInt.from(mib);
  final whole = tenths ~/ BigInt.from(10);
  final fraction = tenths % BigInt.from(10);
  return fraction == BigInt.zero ? '$whole MiB' : '$whole.$fraction MiB';
}

/// What the screen shows about the configured folder.
///
/// The verifying-key row is the one that matters: a key set from another
/// ceremony shares the circuit fingerprint above it and produces proofs every
/// verifier on the channel rejects.
List<NyctisAssetFactData> nyctisProvingKeyFacts(
  NyctisProvingKeyStatus status,
) {
  final size = status.provingKeyBytes;
  return [
    NyctisAssetFactData(
      label: 'Status',
      value: nyctisProvingKeyStatusLabel(status),
    ),
    if (status.dir.isNotEmpty)
      NyctisAssetFactData(
        label: 'Folder',
        value: status.dir,
        copyText: status.dir,
      ),
    if (status.circuit != null)
      NyctisAssetFactData(label: 'Circuit', value: status.circuit!),
    if (status.vkHash != null)
      NyctisAssetFactData(
        label: 'Verifying key',
        value: truncateNyctisAssetId(status.vkHash!),
        copyText: status.vkHash,
      ),
    if (status.channelVkHash != null)
      NyctisAssetFactData(
        label: 'Channel key',
        value: truncateNyctisAssetId(status.channelVkHash!),
        copyText: status.channelVkHash,
      ),
    if (size != null)
      NyctisAssetFactData(
        label: 'Proving key',
        value: nyctisProvingKeySizeText(size),
      ),
  ];
}

/// The channel facts, in the order the screen shows them.
///
/// Public so the mobile screen renders the same three rows from the same
/// config rather than restating them.
List<NyctisAssetFactData> nyctisChannelFacts(NyctisConfig config) {
  return [
    NyctisAssetFactData(
      label: 'Viewing key',
      value: truncatedAddress(config.channelUivk),
      copyText: config.channelUivk,
    ),
    NyctisAssetFactData(
      label: 'Address',
      value: truncatedAddress(config.channelAddress),
      copyText: config.channelAddress,
    ),
    NyctisAssetFactData(
      label: 'Birthday height',
      value: '${config.birthday}',
    ),
  ];
}

class SettingsNyctisScreen extends ConsumerStatefulWidget {
  const SettingsNyctisScreen({super.key});

  @override
  ConsumerState<SettingsNyctisScreen> createState() =>
      _SettingsNyctisScreenState();
}

class _SettingsNyctisScreenState
    extends ConsumerState<SettingsNyctisScreen> {
  final _indexerController = TextEditingController();
  final _provingKeyController = TextEditingController();
  late NyctisIndexerChoice _choice;
  bool _isSubmitting = false;
  bool _isToggling = false;
  bool _isSavingProvingKey = false;
  String? _submitError;
  String? _toggleError;
  String? _provingKeyError;

  @override
  void initState() {
    super.initState();
    final config = ref.read(nyctisConfigProvider);
    // An empty indexer is "no default on this network", not a custom origin
    // the user typed, so it opens on the preset side with an honest label
    // rather than on an empty field.
    _choice =
        config.hasIndexer &&
            ref.read(nyctisConfigProvider.notifier).isCustomIndexer
        ? NyctisIndexerChoice.custom
        : NyctisIndexerChoice.preset;
    if (_choice == NyctisIndexerChoice.custom) {
      _indexerController.text = config.indexerUrl;
    }
    _provingKeyController.text = config.provingKeyDir;
  }

  @override
  void dispose() {
    _indexerController.dispose();
    _provingKeyController.dispose();
    super.dispose();
  }

  bool _canUpdate(NyctisConfig config) {
    if (_isSubmitting) return false;
    return switch (_choice) {
      NyctisIndexerChoice.preset =>
        config.indexerUrl != defaultNyctisIndexerUrl(config.networkName),
      NyctisIndexerChoice.custom => _customIndexerChanged(config),
    };
  }

  bool _customIndexerChanged(NyctisConfig config) {
    try {
      final normalized = normalizeNyctisIndexerUrl(_indexerController.text);
      return normalized != config.indexerUrl.trim();
    } on FormatException {
      return _indexerController.text.trim().isNotEmpty;
    }
  }

  /// The `FormatException.message` `normalizeNyctisIndexerUrl` throws is
  /// already user-facing sentence case, so it is shown verbatim.
  String? _indexerMessageText() {
    if (_choice != NyctisIndexerChoice.custom) return null;
    if (_indexerController.text.trim().isEmpty) return null;
    try {
      normalizeNyctisIndexerUrl(_indexerController.text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  Future<void> _submit() async {
    final config = ref.read(nyctisConfigProvider);
    if (!_canUpdate(config)) return;

    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });

    try {
      final notifier = ref.read(nyctisConfigProvider.notifier);
      if (_choice == NyctisIndexerChoice.preset) {
        await notifier.resetIndexerUrlToDefault();
      } else {
        await notifier.setIndexerUrl(_indexerController.text);
      }
      if (!mounted) return;
      final next = ref.read(nyctisConfigProvider);
      setState(() {
        if (_choice == NyctisIndexerChoice.custom) {
          _indexerController.text = next.indexerUrl;
        }
        _isSubmitting = false;
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitError = e.message;
        _isSubmitting = false;
      });
    } catch (e, st) {
      log('SettingsNyctisScreen._submit: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _submitError = kNyctisSettingsSaveFailed;
        _isSubmitting = false;
      });
    }
  }

  /// `setEnabled` refuses to enable an unconfigured network by throwing a
  /// `FormatException` carrying [NyctisConfig.unconfiguredReason]. The
  /// button stays live so that refusal is readable instead of silent.
  Future<void> _toggleEnabled(bool next) async {
    setState(() {
      _isToggling = true;
      _toggleError = null;
    });
    try {
      await ref.read(nyctisConfigProvider.notifier).setEnabled(next);
      if (!mounted) return;
      setState(() => _isToggling = false);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _toggleError = e.message.isEmpty
            ? kNyctisSettingsNotConfigured
            : e.message;
        _isToggling = false;
      });
    } catch (e, st) {
      log('SettingsNyctisScreen._toggleEnabled: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _toggleError = kNyctisSettingsToggleFailed;
        _isToggling = false;
      });
    }
  }

  /// Stores the folder, then lets [nyctisProvingKeyProvider] re-check it.
  ///
  /// The path is saved even when the folder turns out to be unusable: what
  /// the user typed is a setting, not a verdict, and dropping it on a drive
  /// that is not mounted yet loses work for no reason. The verdict is shown
  /// beside it either way.
  Future<void> _saveProvingKeyDir() async {
    setState(() {
      _isSavingProvingKey = true;
      _provingKeyError = null;
    });
    try {
      await ref
          .read(nyctisConfigProvider.notifier)
          .setProvingKeyDir(_provingKeyController.text);
      if (!mounted) return;
      setState(() => _isSavingProvingKey = false);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _provingKeyError = e.message;
        _isSavingProvingKey = false;
      });
    } catch (e, st) {
      log('SettingsNyctisScreen._saveProvingKeyDir: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _provingKeyError = kNyctisSettingsProvingKeySaveFailed;
        _isSavingProvingKey = false;
      });
    }
  }

  Future<void> _clearProvingKeyDir() async {
    setState(() {
      _isSavingProvingKey = true;
      _provingKeyError = null;
    });
    try {
      await ref.read(nyctisConfigProvider.notifier).clearProvingKeyDir();
      if (!mounted) return;
      setState(() {
        _provingKeyController.clear();
        _isSavingProvingKey = false;
      });
    } catch (e, st) {
      log('SettingsNyctisScreen._clearProvingKeyDir: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _provingKeyError = kNyctisSettingsProvingKeySaveFailed;
        _isSavingProvingKey = false;
      });
    }
  }

  Future<void> _reset() async {
    setState(() {
      _isSubmitting = true;
      _submitError = null;
      _toggleError = null;
    });
    try {
      await ref.read(nyctisConfigProvider.notifier).resetToDefault();
      if (!mounted) return;
      setState(() {
        _choice = NyctisIndexerChoice.preset;
        _indexerController.clear();
        _provingKeyController.clear();
        _isSubmitting = false;
      });
    } catch (e, st) {
      log('SettingsNyctisScreen._reset: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _submitError = kNyctisSettingsSaveFailed;
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(nyctisConfigProvider);
    final notifier = ref.watch(nyctisConfigProvider.notifier);
    final colors = context.colors;

    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: AppPaneScrollScaffold(
          toolbar: const AppPaneToolbar(backLinkMinWidth: 60),
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 420,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s,
                  vertical: AppSpacing.sm,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      kNyctisSettingsTitle,
                      textAlign: TextAlign.center,
                      style: AppTypography.headlineLarge.copyWith(
                        color: colors.text.accent,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s),
                    Text(
                      nyctisNetworkLabel(config.networkName),
                      textAlign: TextAlign.center,
                      style: AppTypography.labelLarge.copyWith(
                        color: colors.text.secondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.base),
                    if (!config.hasChannel)
                      ..._unavailable(config, colors)
                    else
                      ..._configurable(config, notifier, colors),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _unavailable(NyctisConfig config, AppColors colors) {
    return [
      ReviewWrapCard(
        key: const ValueKey('nyctis_settings_unavailable'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            config.unconfiguredReason ?? kNyctisSettingsNotConfigured,
            style: AppTypography.bodyMediumStrong.copyWith(
              color: colors.text.accent,
            ),
          ),
          Text(
            nyctisSettingsUnavailableCopy(config.networkName),
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _configurable(
    NyctisConfig config,
    NyctisConfigNotifier notifier,
    AppColors colors,
  ) {
    final indexerMessage = _indexerMessageText();
    final canReset = notifier.isCustomIndexer || notifier.isCustomChannel;

    return [
      ReviewWrapCard(
        key: const ValueKey('nyctis_settings_enable_card'),
        mainAxisSize: MainAxisSize.min,
        children: [
          ReviewListRow(
            key: const ValueKey('nyctis_settings_enabled_row'),
            label: kNyctisSettingsEnabledLabel,
            value: config.enabled ? 'On' : 'Off',
            valueColor: config.enabled
                ? colors.text.success
                : colors.text.secondary,
          ),
          Text(
            kNyctisSettingsEnableCopy,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          if (_toggleError != null)
            Text(
              _toggleError!,
              key: const ValueKey('nyctis_settings_toggle_error'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.destructive,
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              key: const ValueKey('nyctis_settings_enable_toggle'),
              size: AppButtonSize.small,
              variant: config.enabled
                  ? AppButtonVariant.secondary
                  : AppButtonVariant.primary,
              onPressed: _isToggling
                  ? null
                  : () => _toggleEnabled(!config.enabled),
              child: Text(config.enabled ? 'Turn off' : 'Turn on'),
            ),
          ),
        ],
      ),
      const SizedBox(height: AppSpacing.md),
      NyctisFactsCard(
        key: const ValueKey('nyctis_settings_channel_card'),
        title: kNyctisSettingsChannelTitle,
        facts: nyctisChannelFacts(config),
        footnote: kNyctisSettingsChannelCopy,
      ),
      const SizedBox(height: AppSpacing.md),
      Row(
        children: [
          Expanded(
            child: AppButton(
              key: const ValueKey('nyctis_indexer_option_preset'),
              size: AppButtonSize.small,
              variant: _choice == NyctisIndexerChoice.preset
                  ? AppButtonVariant.primary
                  : AppButtonVariant.secondary,
              onPressed: _isSubmitting
                  ? null
                  : () => setState(() {
                      _choice = NyctisIndexerChoice.preset;
                      _submitError = null;
                    }),
              child: const Text(kNyctisSettingsPresetOption),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: AppButton(
              key: const ValueKey('nyctis_indexer_option_custom'),
              size: AppButtonSize.small,
              variant: _choice == NyctisIndexerChoice.custom
                  ? AppButtonVariant.primary
                  : AppButtonVariant.secondary,
              onPressed: _isSubmitting
                  ? null
                  : () => setState(() {
                      _choice = NyctisIndexerChoice.custom;
                      _submitError = null;
                      if (_indexerController.text.trim().isEmpty &&
                          config.indexerUrl.trim().isNotEmpty) {
                        _indexerController.text = config.indexerUrl;
                      }
                    }),
              child: const Text(kNyctisSettingsCustomOption),
            ),
          ),
        ],
      ),
      const SizedBox(height: AppSpacing.sm),
      if (_choice == NyctisIndexerChoice.preset)
        ReviewWrapCard(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReviewListRow(
              key: const ValueKey('nyctis_settings_indexer_row'),
              label: kNyctisSettingsIndexerFieldLabel,
              value: config.hasIndexer
                  ? config.indexerUrl
                  : 'None on this network',
              valueColor: config.hasIndexer
                  ? colors.text.accent
                  : colors.text.warning,
              copyText: config.hasIndexer ? config.indexerUrl : null,
            ),
          ],
        )
      else
        AppTextField(
          key: const ValueKey('nyctis_indexer_field'),
          label: kNyctisSettingsIndexerFieldLabel,
          hintText: kNyctisSettingsIndexerHint,
          controller: _indexerController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          messageText: indexerMessage,
          tone: indexerMessage == null
              ? AppTextFieldTone.neutral
              : AppTextFieldTone.destructive,
          onChanged: (_) => setState(() => _submitError = null),
          onSubmitted: (_) => _submit(),
        ),
      const SizedBox(height: AppSpacing.sm),
      Text(
        kNyctisSettingsIndexerCopy,
        style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
      ),
      if (_submitError != null) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          _submitError!,
          key: const ValueKey('nyctis_settings_submit_error'),
          textAlign: TextAlign.center,
          style: AppTypography.bodyMedium.copyWith(
            color: colors.text.destructive,
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.md),
      Center(
        child: AppButton(
          key: const ValueKey('nyctis_indexer_update'),
          onPressed: _canUpdate(config) ? _submit : null,
          minWidth: 196,
          child: Text(
            _isSubmitting
                ? kNyctisSettingsUpdatingLabel
                : kNyctisSettingsUpdateLabel,
          ),
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      ..._provingKey(colors),
      if (canReset) ...[
        const SizedBox(height: AppSpacing.xs),
        Center(
          child: AppButton(
            key: const ValueKey('nyctis_settings_reset'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.ghost,
            onPressed: _isSubmitting ? null : _reset,
            child: const Text(kNyctisSettingsResetLabel),
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.md),
    ];
  }

  /// The proving-key folder: the one setting that decides whether this wallet
  /// can send at all.
  List<Widget> _provingKey(AppColors colors) {
    final status = ref.watch(nyctisProvingKeyProvider).value;
    final pathChanged =
        normalizeNyctisProvingKeyDirOrNull(_provingKeyController.text) !=
        ref.watch(nyctisConfigProvider).provingKeyDir;

    return [
      NyctisFactsCard(
        key: const ValueKey('nyctis_settings_proving_key_card'),
        title: kNyctisSettingsProvingKeyTitle,
        facts: status == null
            ? const [
                NyctisAssetFactData(
                  label: 'Status',
                  value: kNyctisSettingsProvingKeyCheckingLabel,
                ),
              ]
            : nyctisProvingKeyFacts(status),
        footnote: kNyctisSettingsProvingKeyCopy,
      ),
      if (status != null && status.message != null) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          status.message!,
          key: const ValueKey('nyctis_settings_proving_key_status'),
          style: AppTypography.bodySmall.copyWith(
            color: status.state == NyctisProvingKeyState.notSet
                ? colors.text.secondary
                : colors.text.destructive,
          ),
        ),
      ],
      if (status != null && status.isUnverifiedAgainstChannel) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          kNyctisSettingsProvingKeyUnverifiedCopy,
          key: const ValueKey('nyctis_settings_proving_key_unverified'),
          style: AppTypography.bodySmall.copyWith(color: colors.text.warning),
        ),
      ],
      const SizedBox(height: AppSpacing.sm),
      AppTextField(
        key: const ValueKey('nyctis_proving_key_field'),
        label: kNyctisSettingsProvingKeyFieldLabel,
        hintText: kNyctisSettingsProvingKeyHint,
        controller: _provingKeyController,
        textInputAction: TextInputAction.done,
        messageText: _provingKeyError,
        tone: _provingKeyError == null
            ? AppTextFieldTone.neutral
            : AppTextFieldTone.destructive,
        onChanged: (_) => setState(() => _provingKeyError = null),
        onSubmitted: (_) => _saveProvingKeyDir(),
      ),
      const SizedBox(height: AppSpacing.sm),
      Center(
        child: AppButton(
          key: const ValueKey('nyctis_proving_key_save'),
          minWidth: 196,
          onPressed: _isSavingProvingKey || !pathChanged
              ? null
              : _saveProvingKeyDir,
          child: Text(
            _isSavingProvingKey
                ? kNyctisSettingsProvingKeyCheckingLabel
                : kNyctisSettingsProvingKeySaveLabel,
          ),
        ),
      ),
      if (ref.watch(nyctisConfigProvider).hasProvingKeyDir) ...[
        const SizedBox(height: AppSpacing.xs),
        Center(
          child: AppButton(
            key: const ValueKey('nyctis_proving_key_clear'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.ghost,
            onPressed: _isSavingProvingKey ? null : _clearProvingKeyDir,
            child: const Text(kNyctisSettingsProvingKeyClearLabel),
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.md),
    ];
  }
}

/// [normalizeNyctisProvingKeyDir] as a comparison helper: a path that does
/// not normalize is different from whatever is stored, which is exactly what
/// the Save button needs to know.
String? normalizeNyctisProvingKeyDirOrNull(String input) {
  try {
    return normalizeNyctisProvingKeyDir(input);
  } on FormatException {
    return null;
  }
}
