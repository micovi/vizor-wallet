/// Mobile `/settings/nyctis` — the mobile half of the only surface that
/// can turn the Nyctis assets feature on.
///
/// Every user-facing string, the preset/custom enum, and the channel fact
/// rows come from `settings_nyctis_screen.dart`; this file owns the mobile
/// layout and nothing else, so the two form factors cannot say different
/// things about the same switch.
library;

import 'package:flutter/material.dart' show Scaffold, TextInputType;
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../main.dart' show log;
import '../../../../core/config/nyctis_config.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/mobile/mobile_list_row.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile_text_field.dart';
import '../../../../providers/nyctis_config_provider.dart';
import '../../../nyctis_assets/providers/nyctis_proving_key_provider.dart';
import '../../../nyctis_assets/services/nyctis_send_flow.dart';
import '../../../nyctis_assets/widgets/nyctis_asset_row_data.dart';
import '../../../nyctis_assets/widgets/nyctis_facts_card.dart';
import '../settings_nyctis_screen.dart';

class MobileNyctisScreen extends ConsumerStatefulWidget {
  const MobileNyctisScreen({super.key});

  @override
  ConsumerState<MobileNyctisScreen> createState() =>
      _MobileNyctisScreenState();
}

class _MobileNyctisScreenState extends ConsumerState<MobileNyctisScreen> {
  final _indexerController = TextEditingController();
  final _indexerFocusNode = FocusNode();
  final _provingKeyController = TextEditingController();
  final _provingKeyFocusNode = FocusNode();
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
    _indexerFocusNode.dispose();
    _provingKeyController.dispose();
    _provingKeyFocusNode.dispose();
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

  /// `normalizeNyctisIndexerUrl` already phrases its `FormatException`
  /// message for the user, so it is shown verbatim.
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
      log('MobileNyctisScreen._submit: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _submitError = kNyctisSettingsSaveFailed;
        _isSubmitting = false;
      });
    }
  }

  /// Enabling an unconfigured network is refused by `setEnabled`, not by this
  /// screen — the control stays live so the refusal arrives as readable text.
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
      log('MobileNyctisScreen._toggleEnabled: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _toggleError = kNyctisSettingsToggleFailed;
        _isToggling = false;
      });
    }
  }

  /// Stores the folder, then lets [nyctisProvingKeyProvider] re-check it.
  /// Same rule as desktop: the path is a setting, the verdict is separate.
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
      log('MobileNyctisScreen._saveProvingKeyDir: ERROR: $e\n$st');
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
      log('MobileNyctisScreen._clearProvingKeyDir: ERROR: $e\n$st');
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
      log('MobileNyctisScreen._reset: ERROR: $e\n$st');
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

    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          children: [
            MobileTopNav.back(
              title: kNyctisSettingsTitle,
              onBack: _isSubmitting ? null : () => context.pop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.lg,
                ),
                children: [
                  Text(
                    nyctisNetworkLabel(config.networkName),
                    textAlign: TextAlign.center,
                    style: AppTypography.labelLarge.copyWith(
                      color: colors.text.secondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (!config.hasChannel)
                    ..._unavailable(config, colors)
                  else
                    ..._configurable(config, notifier, colors),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _unavailable(NyctisConfig config, AppColors colors) {
    return [
      MobileSurfaceCard(
        key: const ValueKey('mobile_nyctis_settings_unavailable'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              config.unconfiguredReason ?? kNyctisSettingsNotConfigured,
              style: AppTypography.bodyMedium.copyWith(
                color: colors.text.accent,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              nyctisSettingsUnavailableCopy(config.networkName),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
        ),
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
      MobileSurfaceCard(
        key: const ValueKey('mobile_nyctis_settings_enable_card'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            MobileListRow(
              key: const ValueKey('mobile_nyctis_settings_enabled_row'),
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
            if (_toggleError != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _toggleError!,
                key: const ValueKey('mobile_nyctis_settings_toggle_error'),
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.destructive,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                key: const ValueKey('mobile_nyctis_settings_enable_toggle'),
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
      ),
      const SizedBox(height: AppSpacing.md),
      NyctisFactsCard(
        key: const ValueKey('mobile_nyctis_settings_channel_card'),
        title: kNyctisSettingsChannelTitle,
        facts: nyctisChannelFacts(config),
        footnote: kNyctisSettingsChannelCopy,
      ),
      const SizedBox(height: AppSpacing.md),
      Row(
        children: [
          Expanded(
            child: AppButton(
              key: const ValueKey('mobile_nyctis_indexer_option_preset'),
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
              key: const ValueKey('mobile_nyctis_indexer_option_custom'),
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
        MobileSurfaceCard(
          child: MobileListRow(
            key: const ValueKey('mobile_nyctis_settings_indexer_row'),
            label: kNyctisSettingsIndexerFieldLabel,
            value: config.hasIndexer
                ? config.indexerUrl
                : 'None on this network',
            valueColor: config.hasIndexer
                ? colors.text.accent
                : colors.text.warning,
          ),
        )
      else ...[
        MobileTextField(
          key: const ValueKey('mobile_nyctis_indexer_field_shell'),
          fieldKey: const ValueKey('mobile_nyctis_indexer_field'),
          hintText: kNyctisSettingsIndexerHint,
          controller: _indexerController,
          focusNode: _indexerFocusNode,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() => _submitError = null),
          onSubmitted: (_) => _submit(),
        ),
        if (indexerMessage != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            indexerMessage,
            key: const ValueKey('mobile_nyctis_indexer_message'),
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.destructive,
            ),
          ),
        ],
      ],
      const SizedBox(height: AppSpacing.sm),
      Text(
        kNyctisSettingsIndexerCopy,
        style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
      ),
      if (_submitError != null) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          _submitError!,
          key: const ValueKey('mobile_nyctis_settings_submit_error'),
          textAlign: TextAlign.center,
          style: AppTypography.bodySmall.copyWith(
            color: colors.text.destructive,
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.md),
      Center(
        child: AppButton(
          key: const ValueKey('mobile_nyctis_indexer_update'),
          minWidth: 226,
          onPressed: _canUpdate(config) ? _submit : null,
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
            key: const ValueKey('mobile_nyctis_settings_reset'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.ghost,
            onPressed: _isSubmitting ? null : _reset,
            child: const Text(kNyctisSettingsResetLabel),
          ),
        ),
      ],
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
        key: const ValueKey('mobile_nyctis_settings_proving_key_card'),
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
          key: const ValueKey('mobile_nyctis_settings_proving_key_status'),
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
          key: const ValueKey(
            'mobile_nyctis_settings_proving_key_unverified',
          ),
          style: AppTypography.bodySmall.copyWith(color: colors.text.warning),
        ),
      ],
      const SizedBox(height: AppSpacing.sm),
      MobileTextField(
        key: const ValueKey('mobile_nyctis_proving_key_field_shell'),
        fieldKey: const ValueKey('mobile_nyctis_proving_key_field'),
        hintText: kNyctisSettingsProvingKeyHint,
        controller: _provingKeyController,
        focusNode: _provingKeyFocusNode,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() => _provingKeyError = null),
        onSubmitted: (_) => _saveProvingKeyDir(),
      ),
      if (_provingKeyError != null) ...[
        const SizedBox(height: AppSpacing.xs),
        Text(
          _provingKeyError!,
          key: const ValueKey('mobile_nyctis_proving_key_message'),
          style: AppTypography.bodySmall.copyWith(
            color: colors.text.destructive,
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.sm),
      Center(
        child: AppButton(
          key: const ValueKey('mobile_nyctis_proving_key_save'),
          minWidth: 226,
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
            key: const ValueKey('mobile_nyctis_proving_key_clear'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.ghost,
            onPressed: _isSavingProvingKey ? null : _clearProvingKeyDir,
            child: const Text(kNyctisSettingsProvingKeyClearLabel),
          ),
        ),
      ],
    ];
  }
}
