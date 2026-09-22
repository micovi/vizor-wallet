/// The Nightjar receive block: QR, full address, copy action, and the one
/// sentence about where the address comes from.
///
/// The QR is the existing scan-reliable [RequestQrSurface] — black squares
/// on white with a real quiet zone, no embedded badge. That is deliberate:
/// the decorative `ReceiveQrSurface` punches a pool badge through the middle
/// of the code and drops the quiet zone, which is survivable for a short
/// Zcash address but not for something a stranger's camera has to read. No
/// new QR dependency is added — `pretty_qr_code` is already in `pubspec`.
library;

import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/full_address_viewer.dart';
import '../../receive/widgets/request/request_qr_surface.dart';
import 'nightjar_asset_row_mapper.dart';
import 'nightjar_assets_feed.dart';

class NightjarReceivePanel extends StatelessWidget {
  const NightjarReceivePanel({
    required this.address,
    this.networkLabel,
    this.qrSize = 220,
    this.maxWidth = kNightjarCardWidth,
    super.key,
  });

  /// The wallet's bech32m Nightjar address, or null when the wallet has not
  /// derived its Nightjar identity yet.
  final String? address;

  /// Network the address belongs to, e.g. `Regtest`. Shown so a devnet
  /// address is never mistaken for a mainnet one.
  final String? networkLabel;

  final double qrSize;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final address = this.address?.trim();
    if (address == null || address.isEmpty) {
      return const NightjarMessageCard(
        key: ValueKey('nightjar_receive_no_identity'),
        text: kNightjarNoIdentityText,
        width: kNightjarCardWidth,
      );
    }
    final networkLabel = this.networkLabel?.trim();

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          RequestQrSurface(
            key: const ValueKey('nightjar_receive_qr'),
            data: address,
            size: qrSize,
          ),
          if (networkLabel != null && networkLabel.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s),
            Text(
              networkLabel,
              style: AppTypography.labelLarge.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          // The whole address, wrapped rather than elided — the shared
          // full-address viewer, so the value copied is byte-for-byte the
          // value shown.
          FullAddressText(address: address, color: colors.text.accent),
          const SizedBox(height: AppSpacing.sm),
          FullAddressCopyButton(address: address),
          const SizedBox(height: AppSpacing.sm),
          Text(
            kNightjarAddressDerivationNote,
            textAlign: TextAlign.center,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
        ],
      ),
    );
  }
}
