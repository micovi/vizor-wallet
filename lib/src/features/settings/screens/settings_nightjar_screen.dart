/// Desktop `/settings/nightjar` — the only surface that can turn the
/// Nightjar assets feature on.
///
/// `NightjarConfig.enabled` defaults to false because switching it on has two
/// consequences the wallet must not take on its own: it derives a Nightjar
/// identity from the seed already in secure storage, and it starts talking to
/// a network service. This screen states both, then offers the switch.
///
/// The copy constants and the indexer-choice enum live here and are imported
/// by `mobile/mobile_nightjar_screen.dart` so the two form factors cannot
/// drift apart in wording or in what "custom indexer" means.
library;

import 'package:flutter/services.dart' show TextInputAction, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../main.dart' show log;
import '../../../core/config/nightjar_config.dart';
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
import '../../../providers/nightjar_config_provider.dart';
import '../../nightjar_assets/providers/nightjar_proving_key_provider.dart';
import '../../nightjar_assets/services/nightjar_send_flow.dart';
import '../../nightjar_assets/widgets/nightjar_asset_row_data.dart';
import '../../nightjar_assets/widgets/nightjar_facts_card.dart';

/// Which indexer origin the screen is about to save. Mirrors the
/// preset/custom pair `settings_explorer_screen.dart` uses.
enum NightjarIndexerChoice { preset, custom }

/// Sidebar/settings-row label and screen title.
const kNightjarSettingsTitle = 'Nightjar';

/// What the switch actually does, said before it is touched.
const kNightjarSettingsEnableCopy =
    'With this on, the wallet reads the channel from the Nightjar indexer '
    'below and derives a Nightjar identity from the seed it already holds. '
    'That identity needs no separate backup, and no key ever leaves this '
    'device.';

/// What the indexer is trusted for, and what it is not trusted for.
const kNightjarSettingsIndexerCopy =
    'The indexer supplies message data only. Vizor verifies every proof and '
    'replays the channel locally, so an indexer cannot invent a balance — it '
    'can only withhold a message.';

/// Why a public viewing key is safe to show here.
const kNightjarSettingsChannelCopy =
    'The channel viewing key is public and only says where to look. What is '
    'yours is decided on this device, by a key the channel never sees.';

const kNightjarSettingsEnabledLabel = 'Nightjar assets';
const kNightjarSettingsChannelTitle = 'Channel';
const kNightjarSettingsIndexerFieldLabel = 'Indexer URL';
const kNightjarSettingsIndexerHint = 'https://indexer.example';
const kNightjarSettingsUpdateLabel = 'Update indexer';
const kNightjarSettingsUpdatingLabel = 'Updating...';
const kNightjarSettingsResetLabel = 'Reset to defaults';
const kNightjarSettingsPresetOption = 'Default';
const kNightjarSettingsCustomOption = 'Custom';

/// Shown when [NightjarConfig.hasChannel] is false — mainnet and testnet ship
/// no channel, so there is nothing for a switch to turn on.
String nightjarSettingsUnavailableCopy(String networkName) =>
    'This build ships a Nightjar channel for regtest only, so there is '
    'nothing to read on '
    '${nightjarNetworkLabel(networkName).toLowerCase()} yet. Nightjar turns '
    'itself on here once a channel exists for this network.';

/// Fallback for a `setEnabled` refusal that carried no message.
const kNightjarSettingsNotConfigured = 'Nightjar is not configured yet.';

const kNightjarSettingsSaveFailed = "Couldn't save that indexer URL.";
const kNightjarSettingsToggleFailed = "Couldn't change that setting.";

/// Heading of the one card on this screen that is about *sending*.
const kNightjarSettingsProvingKeyTitle = 'Sending';

const kNightjarSettingsProvingKeyFieldLabel = 'Proving key folder';
const kNightjarSettingsProvingKeyHint = '/path/to/keys';
const kNightjarSettingsProvingKeySaveLabel = 'Save folder';
const kNightjarSettingsProvingKeyCheckingLabel = 'Checking...';
const kNightjarSettingsProvingKeyClearLabel = 'Forget folder';
const kNightjarSettingsProvingKeySaveFailed = "Couldn't save that folder.";

/// Why this setting exists at all, and what the wallet does with it.
const kNightjarSettingsProvingKeyCopy =
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
const kNightjarSettingsProvingKeyUnverifiedCopy =
    'This folder has not been compared with the channel yet, because this '
    'wallet has not replayed one. Sending checks it again before it proves '
    'anything.';

/// One-word verdict for the proving-key row.
String nightjarProvingKeyStatusLabel(NightjarProvingKeyStatus status) {
  return switch (status.state) {
    NightjarProvingKeyState.notSet => 'Not set',
    NightjarProvingKeyState.unreadable => 'Unusable',
    NightjarProvingKeyState.wrongKeySet => 'Wrong key set',
    NightjarProvingKeyState.ready => 'Ready',
  };
}

/// `83 MiB` — integer-only, like every other number in this feature.
String nightjarProvingKeySizeText(BigInt bytes) {
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
List<NightjarAssetFactData> nightjarProvingKeyFacts(
  NightjarProvingKeyStatus status,
) {
  final size = status.provingKeyBytes;
  return [
    NightjarAssetFactData(
      label: 'Status',
      value: nightjarProvingKeyStatusLabel(status),
    ),
    if (status.dir.isNotEmpty)
      NightjarAssetFactData(
        label: 'Folder',
        value: status.dir,
        copyText: status.dir,
      ),
    if (status.circuit != null)
      NightjarAssetFactData(label: 'Circuit', value: status.circuit!),
    if (status.vkHash != null)
      NightjarAssetFactData(
        label: 'Verifying key',
        value: truncateNightjarAssetId(status.vkHash!),
        copyText: status.vkHash,
      ),
    if (status.channelVkHash != null)
      NightjarAssetFactData(
        label: 'Channel key',
        value: truncateNightjarAssetId(status.channelVkHash!),
        copyText: status.channelVkHash,
      ),
    if (size != null)
      NightjarAssetFactData(
        label: 'Proving key',
        value: nightjarProvingKeySizeText(size),
      ),
  ];
}

/// The channel facts, in the order the screen shows them.
///
/// Public so the mobile screen renders the same three rows from the same
/// config rather than restating them.
List<NightjarAssetFactData> nightjarChannelFacts(NightjarConfig config) {
  return [
    NightjarAssetFactData(
      label: 'Viewing key',
      value: truncatedAddress(config.channelUivk),
      copyText: config.channelUivk,
    ),
    NightjarAssetFactData(
      label: 'Address',
      value: truncatedAddress(config.channelAddress),
      copyText: config.channelAddress,
    ),
    NightjarAssetFactData(
      label: 'Birthday height',
      value: '${config.birthday}',
    ),
  ];
}

class SettingsNightjarScreen extends ConsumerStatefulWidget {
  const SettingsNightjarScreen({super.key});

  @override
  ConsumerState<SettingsNightjarScreen> createState() =>
      _SettingsNightjarScreenState();
}

class _SettingsNightjarScreenState
    extends ConsumerState<SettingsNightjarScreen> {
  final _indexerController = TextEditingController();
  final _provingKeyController = TextEditingController();
  late NightjarIndexerChoice _choice;
  bool _isSubmitting = false;
  bool _isToggling = false;
  bool _isSavingProvingKey = false;
  String? _submitError;
  String? _toggleError;
  String? _provingKeyError;

  @override
  void initState() {
    super.initState();
    final config = ref.read(nightjarConfigProvider);
    // An empty indexer is "no default on this network", not a custom origin
    // the user typed, so it opens on the preset side with an honest label
    // rather than on an empty field.
    _choice =
        config.hasIndexer &&
            ref.read(nightjarConfigProvider.notifier).isCustomIndexer
        ? NightjarIndexerChoice.custom
        : NightjarIndexerChoice.preset;
    if (_choice == NightjarIndexerChoice.custom) {
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

  bool _canUpdate(NightjarConfig config) {
    if (_isSubmitting) return false;
    return switch (_choice) {
      NightjarIndexerChoice.preset =>
        config.indexerUrl != defaultNightjarIndexerUrl(config.networkName),
      NightjarIndexerChoice.custom => _customIndexerChanged(config),
    };
  }

  bool _customIndexerChanged(NightjarConfig config) {
    try {
      final normalized = normalizeNightjarIndexerUrl(_indexerController.text);
      return normalized != config.indexerUrl.trim();
    } on FormatException {
      return _indexerController.text.trim().isNotEmpty;
    }
  }

  /// The `FormatException.message` `normalizeNightjarIndexerUrl` throws is
  /// already user-facing sentence case, so it is shown verbatim.
  String? _indexerMessageText() {
    if (_choice != NightjarIndexerChoice.custom) return null;
    if (_indexerController.text.trim().isEmpty) return null;
    try {
      normalizeNightjarIndexerUrl(_indexerController.text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  Future<void> _submit() async {
    final config = ref.read(nightjarConfigProvider);
    if (!_canUpdate(config)) return;

    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });

    try {
      final notifier = ref.read(nightjarConfigProvider.notifier);
      if (_choice == NightjarIndexerChoice.preset) {
        await notifier.resetIndexerUrlToDefault();
      } else {
        await notifier.setIndexerUrl(_indexerController.text);
      }
      if (!mounted) return;
      final next = ref.read(nightjarConfigProvider);
      setState(() {
        if (_choice == NightjarIndexerChoice.custom) {
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
      log('SettingsNightjarScreen._submit: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _submitError = kNightjarSettingsSaveFailed;
        _isSubmitting = false;
      });
    }
  }

  /// `setEnabled` refuses to enable an unconfigured network by throwing a
  /// `FormatException` carrying [NightjarConfig.unconfiguredReason]. The
  /// button stays live so that refusal is readable instead of silent.
  Future<void> _toggleEnabled(bool next) async {
    setState(() {
      _isToggling = true;
      _toggleError = null;
    });
    try {
      await ref.read(nightjarConfigProvider.notifier).setEnabled(next);
      if (!mounted) return;
      setState(() => _isToggling = false);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _toggleError = e.message.isEmpty
            ? kNightjarSettingsNotConfigured
            : e.message;
        _isToggling = false;
      });
    } catch (e, st) {
      log('SettingsNightjarScreen._toggleEnabled: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _toggleError = kNightjarSettingsToggleFailed;
        _isToggling = false;
      });
    }
  }

  /// Stores the folder, then lets [nightjarProvingKeyProvider] re-check it.
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
          .read(nightjarConfigProvider.notifier)
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
      log('SettingsNightjarScreen._saveProvingKeyDir: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _provingKeyError = kNightjarSettingsProvingKeySaveFailed;
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
      await ref.read(nightjarConfigProvider.notifier).clearProvingKeyDir();
      if (!mounted) return;
      setState(() {
        _provingKeyController.clear();
        _isSavingProvingKey = false;
      });
    } catch (e, st) {
      log('SettingsNightjarScreen._clearProvingKeyDir: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _provingKeyError = kNightjarSettingsProvingKeySaveFailed;
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
      await ref.read(nightjarConfigProvider.notifier).resetToDefault();
      if (!mounted) return;
      setState(() {
        _choice = NightjarIndexerChoice.preset;
        _indexerController.clear();
        _provingKeyController.clear();
        _isSubmitting = false;
      });
    } catch (e, st) {
      log('SettingsNightjarScreen._reset: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _submitError = kNightjarSettingsSaveFailed;
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(nightjarConfigProvider);
    final notifier = ref.watch(nightjarConfigProvider.notifier);
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
                      kNightjarSettingsTitle,
                      textAlign: TextAlign.center,
                      style: AppTypography.headlineLarge.copyWith(
                        color: colors.text.accent,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s),
                    Text(
                      nightjarNetworkLabel(config.networkName),
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

  List<Widget> _unavailable(NightjarConfig config, AppColors colors) {
    return [
      ReviewWrapCard(
        key: const ValueKey('nightjar_settings_unavailable'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            config.unconfiguredReason ?? kNightjarSettingsNotConfigured,
            style: AppTypography.bodyMediumStrong.copyWith(
              color: colors.text.accent,
            ),
          ),
          Text(
            nightjarSettingsUnavailableCopy(config.networkName),
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _configurable(
    NightjarConfig config,
    NightjarConfigNotifier notifier,
    AppColors colors,
  ) {
    final indexerMessage = _indexerMessageText();
    final canReset = notifier.isCustomIndexer || notifier.isCustomChannel;

    return [
      ReviewWrapCard(
        key: const ValueKey('nightjar_settings_enable_card'),
        mainAxisSize: MainAxisSize.min,
        children: [
          ReviewListRow(
            key: const ValueKey('nightjar_settings_enabled_row'),
            label: kNightjarSettingsEnabledLabel,
            value: config.enabled ? 'On' : 'Off',
            valueColor: config.enabled
                ? colors.text.success
                : colors.text.secondary,
          ),
          Text(
            kNightjarSettingsEnableCopy,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          if (_toggleError != null)
            Text(
              _toggleError!,
              key: const ValueKey('nightjar_settings_toggle_error'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.destructive,
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              key: const ValueKey('nightjar_settings_enable_toggle'),
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
      NightjarFactsCard(
        key: const ValueKey('nightjar_settings_channel_card'),
        title: kNightjarSettingsChannelTitle,
        facts: nightjarChannelFacts(config),
        footnote: kNightjarSettingsChannelCopy,
      ),
      const SizedBox(height: AppSpacing.md),
      Row(
        children: [
          Expanded(
            child: AppButton(
              key: const ValueKey('nightjar_indexer_option_preset'),
              size: AppButtonSize.small,
              variant: _choice == NightjarIndexerChoice.preset
                  ? AppButtonVariant.primary
                  : AppButtonVariant.secondary,
              onPressed: _isSubmitting
                  ? null
                  : () => setState(() {
                      _choice = NightjarIndexerChoice.preset;
                      _submitError = null;
                    }),
              child: const Text(kNightjarSettingsPresetOption),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: AppButton(
              key: const ValueKey('nightjar_indexer_option_custom'),
              size: AppButtonSize.small,
              variant: _choice == NightjarIndexerChoice.custom
                  ? AppButtonVariant.primary
                  : AppButtonVariant.secondary,
              onPressed: _isSubmitting
                  ? null
                  : () => setState(() {
                      _choice = NightjarIndexerChoice.custom;
                      _submitError = null;
                      if (_indexerController.text.trim().isEmpty &&
                          config.indexerUrl.trim().isNotEmpty) {
                        _indexerController.text = config.indexerUrl;
                      }
                    }),
              child: const Text(kNightjarSettingsCustomOption),
            ),
          ),
        ],
      ),
      const SizedBox(height: AppSpacing.sm),
      if (_choice == NightjarIndexerChoice.preset)
        ReviewWrapCard(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReviewListRow(
              key: const ValueKey('nightjar_settings_indexer_row'),
              label: kNightjarSettingsIndexerFieldLabel,
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
          key: const ValueKey('nightjar_indexer_field'),
          label: kNightjarSettingsIndexerFieldLabel,
          hintText: kNightjarSettingsIndexerHint,
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
        kNightjarSettingsIndexerCopy,
        style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
      ),
      if (_submitError != null) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          _submitError!,
          key: const ValueKey('nightjar_settings_submit_error'),
          textAlign: TextAlign.center,
          style: AppTypography.bodyMedium.copyWith(
            color: colors.text.destructive,
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.md),
      Center(
        child: AppButton(
          key: const ValueKey('nightjar_indexer_update'),
          onPressed: _canUpdate(config) ? _submit : null,
          minWidth: 196,
          child: Text(
            _isSubmitting
                ? kNightjarSettingsUpdatingLabel
                : kNightjarSettingsUpdateLabel,
          ),
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      ..._provingKey(colors),
      if (canReset) ...[
        const SizedBox(height: AppSpacing.xs),
        Center(
          child: AppButton(
            key: const ValueKey('nightjar_settings_reset'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.ghost,
            onPressed: _isSubmitting ? null : _reset,
            child: const Text(kNightjarSettingsResetLabel),
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.md),
    ];
  }

  /// The proving-key folder: the one setting that decides whether this wallet
  /// can send at all.
  List<Widget> _provingKey(AppColors colors) {
    final status = ref.watch(nightjarProvingKeyProvider).value;
    final pathChanged =
        normalizeNightjarProvingKeyDirOrNull(_provingKeyController.text) !=
        ref.watch(nightjarConfigProvider).provingKeyDir;

    return [
      NightjarFactsCard(
        key: const ValueKey('nightjar_settings_proving_key_card'),
        title: kNightjarSettingsProvingKeyTitle,
        facts: status == null
            ? const [
                NightjarAssetFactData(
                  label: 'Status',
                  value: kNightjarSettingsProvingKeyCheckingLabel,
                ),
              ]
            : nightjarProvingKeyFacts(status),
        footnote: kNightjarSettingsProvingKeyCopy,
      ),
      if (status != null && status.message != null) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          status.message!,
          key: const ValueKey('nightjar_settings_proving_key_status'),
          style: AppTypography.bodySmall.copyWith(
            color: status.state == NightjarProvingKeyState.notSet
                ? colors.text.secondary
                : colors.text.destructive,
          ),
        ),
      ],
      if (status != null && status.isUnverifiedAgainstChannel) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          kNightjarSettingsProvingKeyUnverifiedCopy,
          key: const ValueKey('nightjar_settings_proving_key_unverified'),
          style: AppTypography.bodySmall.copyWith(color: colors.text.warning),
        ),
      ],
      const SizedBox(height: AppSpacing.sm),
      AppTextField(
        key: const ValueKey('nightjar_proving_key_field'),
        label: kNightjarSettingsProvingKeyFieldLabel,
        hintText: kNightjarSettingsProvingKeyHint,
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
          key: const ValueKey('nightjar_proving_key_save'),
          minWidth: 196,
          onPressed: _isSavingProvingKey || !pathChanged
              ? null
              : _saveProvingKeyDir,
          child: Text(
            _isSavingProvingKey
                ? kNightjarSettingsProvingKeyCheckingLabel
                : kNightjarSettingsProvingKeySaveLabel,
          ),
        ),
      ),
      if (ref.watch(nightjarConfigProvider).hasProvingKeyDir) ...[
        const SizedBox(height: AppSpacing.xs),
        Center(
          child: AppButton(
            key: const ValueKey('nightjar_proving_key_clear'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.ghost,
            onPressed: _isSavingProvingKey ? null : _clearProvingKeyDir,
            child: const Text(kNightjarSettingsProvingKeyClearLabel),
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.md),
    ];
  }
}

/// [normalizeNightjarProvingKeyDir] as a comparison helper: a path that does
/// not normalize is different from whatever is stored, which is exactly what
/// the Save button needs to know.
String? normalizeNightjarProvingKeyDirOrNull(String input) {
  try {
    return normalizeNightjarProvingKeyDir(input);
  } on FormatException {
    return null;
  }
}
