/// Mobile `/settings/nightjar` — the mobile half of the only surface that
/// can turn the Nightjar assets feature on.
///
/// Every user-facing string, the preset/custom enum, and the channel fact
/// rows come from `settings_nightjar_screen.dart`; this file owns the mobile
/// layout and nothing else, so the two form factors cannot say different
/// things about the same switch.
library;

import 'package:flutter/material.dart' show Scaffold, TextInputType;
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../main.dart' show log;
import '../../../../core/config/nightjar_config.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/mobile/mobile_list_row.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile_text_field.dart';
import '../../../../providers/nightjar_config_provider.dart';
import '../../../nightjar_assets/providers/nightjar_proving_key_provider.dart';
import '../../../nightjar_assets/services/nightjar_send_flow.dart';
import '../../../nightjar_assets/widgets/nightjar_asset_row_data.dart';
import '../../../nightjar_assets/widgets/nightjar_facts_card.dart';
import '../settings_nightjar_screen.dart';

class MobileNightjarScreen extends ConsumerStatefulWidget {
  const MobileNightjarScreen({super.key});

  @override
  ConsumerState<MobileNightjarScreen> createState() =>
      _MobileNightjarScreenState();
}

class _MobileNightjarScreenState extends ConsumerState<MobileNightjarScreen> {
  final _indexerController = TextEditingController();
  final _indexerFocusNode = FocusNode();
  final _provingKeyController = TextEditingController();
  final _provingKeyFocusNode = FocusNode();
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
    _indexerFocusNode.dispose();
    _provingKeyController.dispose();
    _provingKeyFocusNode.dispose();
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

  /// `normalizeNightjarIndexerUrl` already phrases its `FormatException`
  /// message for the user, so it is shown verbatim.
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
      log('MobileNightjarScreen._submit: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _submitError = kNightjarSettingsSaveFailed;
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
      log('MobileNightjarScreen._toggleEnabled: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        _toggleError = kNightjarSettingsToggleFailed;
        _isToggling = false;
      });
    }
  }

  /// Stores the folder, then lets [nightjarProvingKeyProvider] re-check it.
  /// Same rule as desktop: the path is a setting, the verdict is separate.
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
      log('MobileNightjarScreen._saveProvingKeyDir: ERROR: $e\n$st');
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
      log('MobileNightjarScreen._clearProvingKeyDir: ERROR: $e\n$st');
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
      log('MobileNightjarScreen._reset: ERROR: $e\n$st');
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

    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          children: [
            MobileTopNav.back(
              title: kNightjarSettingsTitle,
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
                    nightjarNetworkLabel(config.networkName),
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

  List<Widget> _unavailable(NightjarConfig config, AppColors colors) {
    return [
      MobileSurfaceCard(
        key: const ValueKey('mobile_nightjar_settings_unavailable'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              config.unconfiguredReason ?? kNightjarSettingsNotConfigured,
              style: AppTypography.bodyMedium.copyWith(
                color: colors.text.accent,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              nightjarSettingsUnavailableCopy(config.networkName),
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
    NightjarConfig config,
    NightjarConfigNotifier notifier,
    AppColors colors,
  ) {
    final indexerMessage = _indexerMessageText();
    final canReset = notifier.isCustomIndexer || notifier.isCustomChannel;

    return [
      MobileSurfaceCard(
        key: const ValueKey('mobile_nightjar_settings_enable_card'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            MobileListRow(
              key: const ValueKey('mobile_nightjar_settings_enabled_row'),
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
            if (_toggleError != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _toggleError!,
                key: const ValueKey('mobile_nightjar_settings_toggle_error'),
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.destructive,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                key: const ValueKey('mobile_nightjar_settings_enable_toggle'),
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
      NightjarFactsCard(
        key: const ValueKey('mobile_nightjar_settings_channel_card'),
        title: kNightjarSettingsChannelTitle,
        facts: nightjarChannelFacts(config),
        footnote: kNightjarSettingsChannelCopy,
      ),
      const SizedBox(height: AppSpacing.md),
      Row(
        children: [
          Expanded(
            child: AppButton(
              key: const ValueKey('mobile_nightjar_indexer_option_preset'),
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
              key: const ValueKey('mobile_nightjar_indexer_option_custom'),
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
        MobileSurfaceCard(
          child: MobileListRow(
            key: const ValueKey('mobile_nightjar_settings_indexer_row'),
            label: kNightjarSettingsIndexerFieldLabel,
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
          key: const ValueKey('mobile_nightjar_indexer_field_shell'),
          fieldKey: const ValueKey('mobile_nightjar_indexer_field'),
          hintText: kNightjarSettingsIndexerHint,
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
            key: const ValueKey('mobile_nightjar_indexer_message'),
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.destructive,
            ),
          ),
        ],
      ],
      const SizedBox(height: AppSpacing.sm),
      Text(
        kNightjarSettingsIndexerCopy,
        style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
      ),
      if (_submitError != null) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          _submitError!,
          key: const ValueKey('mobile_nightjar_settings_submit_error'),
          textAlign: TextAlign.center,
          style: AppTypography.bodySmall.copyWith(
            color: colors.text.destructive,
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.md),
      Center(
        child: AppButton(
          key: const ValueKey('mobile_nightjar_indexer_update'),
          minWidth: 226,
          onPressed: _canUpdate(config) ? _submit : null,
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
            key: const ValueKey('mobile_nightjar_settings_reset'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.ghost,
            onPressed: _isSubmitting ? null : _reset,
            child: const Text(kNightjarSettingsResetLabel),
          ),
        ),
      ],
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
        key: const ValueKey('mobile_nightjar_settings_proving_key_card'),
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
          key: const ValueKey('mobile_nightjar_settings_proving_key_status'),
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
          key: const ValueKey(
            'mobile_nightjar_settings_proving_key_unverified',
          ),
          style: AppTypography.bodySmall.copyWith(color: colors.text.warning),
        ),
      ],
      const SizedBox(height: AppSpacing.sm),
      MobileTextField(
        key: const ValueKey('mobile_nightjar_proving_key_field_shell'),
        fieldKey: const ValueKey('mobile_nightjar_proving_key_field'),
        hintText: kNightjarSettingsProvingKeyHint,
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
          key: const ValueKey('mobile_nightjar_proving_key_message'),
          style: AppTypography.bodySmall.copyWith(
            color: colors.text.destructive,
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.sm),
      Center(
        child: AppButton(
          key: const ValueKey('mobile_nightjar_proving_key_save'),
          minWidth: 226,
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
            key: const ValueKey('mobile_nightjar_proving_key_clear'),
            size: AppButtonSize.small,
            variant: AppButtonVariant.ghost,
            onPressed: _isSavingProvingKey ? null : _clearProvingKeyDir,
            child: const Text(kNightjarSettingsProvingKeyClearLabel),
          ),
        ),
      ],
    ];
  }
}
