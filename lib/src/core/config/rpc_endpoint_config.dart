import 'package:flutter/foundation.dart' show kDebugMode;

import 'network_config.dart';
export 'network_config.dart';

const kDefaultRpcEndpointPresetId = 'default-mainnet';
const kCustomRpcEndpointPresetId = 'custom';
const kIronwoodMasqueradeRpcEndpointPresetId = 'ironwood-masquerade';
const kNightjarDevnetRpcEndpointPresetId = 'nightjar-devnet';
const kRegtestSlowRpcEndpointPresetId = 'slow-regtest';
const kRegtestUnavailableRpcEndpointPresetId = 'unavailable-regtest';

class RpcEndpointConfig {
  const RpcEndpointConfig({
    required this.networkName,
    required this.lightwalletdUrl,
    this.presetId,
  });

  final String networkName;
  final String lightwalletdUrl;
  final String? presetId;

  ZcashNetwork get network => zcashNetworkFromName(networkName);

  String get normalizedLightwalletdUrl =>
      normalizeRpcEndpointUrl(lightwalletdUrl, allowDefaultPort: true);

  String get hostPort => rpcEndpointHostPort(lightwalletdUrl);

  String get effectivePresetId =>
      explicitRpcEndpointPresetFor(this)?.id ?? kCustomRpcEndpointPresetId;

  RpcEndpointConfig copyWith({
    String? networkName,
    String? lightwalletdUrl,
    String? presetId,
  }) {
    return RpcEndpointConfig(
      networkName: networkName ?? this.networkName,
      lightwalletdUrl: lightwalletdUrl ?? this.lightwalletdUrl,
      presetId: presetId ?? this.presetId,
    );
  }
}

class RpcEndpointPreset {
  const RpcEndpointPreset({
    required this.id,
    required this.region,
    required this.label,
    required this.url,
    this.isDefault = false,
  });

  final String id;
  final String region;
  final String label;
  final String url;
  final bool isDefault;

  String get hostPort => rpcEndpointHostPort(url);
}

// Public lightwalletd presets. Keep the mainnet default aligned with Zodl's
// default endpoint while preserving zec.rocks as a selectable fallback.
const kIronwoodMasqueradeRpcEndpointPreset = RpcEndpointPreset(
  id: kIronwoodMasqueradeRpcEndpointPresetId,
  region: 'Ironwood',
  label: 'Ironwood Masquerade',
  url: 'https://lwd.157.245.208.35.sslip.io:443',
  isDefault: true,
);

final kMainnetRpcEndpointPresets = List<RpcEndpointPreset>.unmodifiable([
  RpcEndpointPreset(
    id: kDefaultRpcEndpointPresetId,
    region: 'Default',
    label: 'Stardust US',
    url: ZcashNetwork.mainnet.lightwalletdUrl,
    isDefault: true,
  ),
  const RpcEndpointPreset(
    id: 'eu-zec-stardust',
    region: 'Europe',
    label: 'Stardust Europe',
    url: 'https://eu.zec.stardust.rest:443',
  ),
  const RpcEndpointPreset(
    id: 'eu2-zec-stardust',
    region: 'Europe',
    label: 'Stardust Europe 2',
    url: 'https://eu2.zec.stardust.rest:443',
  ),
  const RpcEndpointPreset(
    id: 'jp-zec-stardust',
    region: 'Asia Pacific',
    label: 'Stardust Japan',
    url: 'https://jp.zec.stardust.rest:443',
  ),
  const RpcEndpointPreset(
    id: 'zec-rocks',
    region: 'Global',
    label: 'Zec Rocks',
    url: 'https://zec.rocks:443',
  ),
  const RpcEndpointPreset(
    id: 'na-zec-rocks',
    region: 'Americas',
    label: 'Zec Rocks North America',
    url: 'https://na.zec.rocks:443',
  ),
  const RpcEndpointPreset(
    id: 'sa-zec-rocks',
    region: 'Americas',
    label: 'Zec Rocks South America',
    url: 'https://sa.zec.rocks:443',
  ),
  const RpcEndpointPreset(
    id: 'eu-zec-rocks',
    region: 'Europe',
    label: 'Zec Rocks Europe',
    url: 'https://eu.zec.rocks:443',
  ),
  const RpcEndpointPreset(
    id: 'ap-zec-rocks',
    region: 'Asia Pacific',
    label: 'Zec Rocks Asia Pacific',
    url: 'https://ap.zec.rocks:443',
  ),
  const RpcEndpointPreset(
    id: 'z3-deepikaw',
    region: 'Community',
    label: 'Deepikaw Z3',
    url: 'https://z3.deepikaw.xyz:443',
  ),
  const RpcEndpointPreset(
    id: 'zprivacy',
    region: 'Community',
    label: 'ZPrivacy',
    url: 'https://zprivacy.online:443',
  ),
  const RpcEndpointPreset(
    id: 'zcash-explorer',
    region: 'Community',
    label: 'Zcash Explorer',
    url: 'https://lwd.zcashexplorer.app:9067',
  ),
]);

final kTestnetRpcEndpointPresets = List<RpcEndpointPreset>.unmodifiable([
  const RpcEndpointPreset(
    id: 'default-testnet',
    region: 'Testnet',
    label: 'Zec Rocks Testnet',
    url: 'https://testnet.zec.rocks:443',
    isDefault: true,
  ),
  const RpcEndpointPreset(
    id: 'mysideoftheweb-testnet',
    region: 'Community',
    label: 'My Side of the Web Testnet',
    url: 'https://zcash.mysideoftheweb.com:19067',
  ),
]);

final kRegtestRpcEndpointPresets = List<RpcEndpointPreset>.unmodifiable([
  RpcEndpointPreset(
    id: 'default-regtest',
    region: 'Regtest',
    label: 'Local Regtest',
    url: ZcashNetwork.regtest.lightwalletdUrl,
    isDefault: true,
  ),
  // The Nightjar devnet (infra/README.md in the Nightjar repo), on 19067 rather
  // than the regtest default of 9067, so it cannot reuse `default-regtest`. It is
  // a preset rather than a note in the docs because every Nightjar PoC session
  // starts by pointing the wallet here.
  //
  // **It must be lightwalletd, not Zaino, and that is the whole reason this
  // comment is long.** The devnet runs both: Zaino on 28137 and upstream
  // lightwalletd v0.5.4 on 19067, against the same Zebra. This preset pointed at
  // Zaino until it was found to make Ironwood sync die at about 5 % every time —
  // Zaino 0.6.0's `ShieldedProtocol` enum stops at Orchard, so `GetSubtreeRoots`
  // for Ironwood comes back `invalid_argument` and the scan cannot proceed. The
  // symptom is a progress bar that stalls and then reports a failure with nothing
  // in it naming a protocol version, which is why it cost a second diagnosis
  // after the first. Ironwood landed in upstream lightwalletd (PR 567) and ships
  // in v0.5.4; Zaino 0.9.0 adds it too, but 0.7→0.9 is a large refactor needing a
  // volume wipe, so the devnet runs the second reader instead and Zaino is left
  // alone for the indexer.
  const RpcEndpointPreset(
    id: kNightjarDevnetRpcEndpointPresetId,
    region: 'Regtest',
    label: 'Nightjar devnet',
    url: 'http://127.0.0.1:19067',
  ),
  const RpcEndpointPreset(
    id: kRegtestSlowRpcEndpointPresetId,
    region: 'Regtest',
    label: 'Slow Regtest',
    url: 'http://127.0.0.1:19068',
  ),
  // A port nothing listens on, on purpose: this preset exists to exercise the
  // unreachable-endpoint path. It used to be 19067, which became the Nightjar
  // devnet's lightwalletd — so the one endpoint that actually worked was sitting
  // behind a label saying it did not, and the one labelled for the devnet led
  // into the Zaino/Ironwood failure above. Keep this on a port no service in
  // `infra/` binds.
  const RpcEndpointPreset(
    id: kRegtestUnavailableRpcEndpointPresetId,
    region: 'Regtest',
    label: 'Unavailable Regtest',
    url: 'http://127.0.0.1:19070',
  ),
]);

List<RpcEndpointPreset> rpcEndpointPresetsForNetwork(String networkName) {
  final network = zcashNetworkFromName(networkName);
  return switch (network) {
    ZcashNetwork.mainnet =>
      kZcashIronwoodMasquerade
          ? const [kIronwoodMasqueradeRpcEndpointPreset]
          : kMainnetRpcEndpointPresets,
    ZcashNetwork.testnet => kTestnetRpcEndpointPresets,
    ZcashNetwork.regtest => kRegtestRpcEndpointPresets,
  };
}

RpcEndpointConfig defaultRpcEndpointConfig(String networkName) {
  final network = zcashNetworkFromName(networkName);
  final presets = rpcEndpointPresetsForNetwork(network.name);
  final preset = presets.firstWhere(
    (preset) => preset.isDefault,
    orElse: () => presets.first,
  );
  return RpcEndpointConfig(
    networkName: network.name,
    lightwalletdUrl: preset.url,
    presetId: preset.id,
  );
}

bool isCustomRpcEndpointConfig(RpcEndpointConfig config) {
  return config.presetId == kCustomRpcEndpointPresetId;
}

bool isRpcEndpointAllowedForBuild(String lightwalletdUrl) {
  if (!kZcashIronwoodMasquerade) return true;
  return normalizeRpcEndpointUrl(lightwalletdUrl, allowDefaultPort: true) ==
      normalizeRpcEndpointUrl(
        kIronwoodMasqueradeRpcEndpointPreset.url,
        allowDefaultPort: true,
      );
}

RpcEndpointPreset? explicitRpcEndpointPresetFor(RpcEndpointConfig config) {
  final presetId = config.presetId?.trim();
  if (presetId == null ||
      presetId.isEmpty ||
      presetId == kCustomRpcEndpointPresetId) {
    return null;
  }

  return findRpcEndpointPresetById(config.networkName, presetId);
}

List<RpcEndpointConfig> fallbackRpcEndpointCandidatesFor(
  RpcEndpointConfig primary,
) {
  final primaryPreset = _selectedFallbackPrimaryPreset(primary);
  if (primaryPreset == null) return const [];

  final primaryNormalized = primary.normalizedLightwalletdUrl;
  final seenUrls = <String>{};
  final candidates = <RpcEndpointConfig>[];

  for (final preset in rpcEndpointPresetsForNetwork(primary.networkName)) {
    final normalized = normalizeRpcEndpointUrl(
      preset.url,
      allowDefaultPort: true,
    );
    if (preset.id == primaryPreset.id || normalized == primaryNormalized) {
      continue;
    }
    if (!seenUrls.add(normalized)) continue;

    candidates.add(
      RpcEndpointConfig(
        networkName: primary.networkName,
        lightwalletdUrl: preset.url,
        presetId: preset.id,
      ),
    );
  }

  return List.unmodifiable(candidates);
}

RpcEndpointConfig? fallbackRpcEndpointConfigFor(RpcEndpointConfig primary) {
  final candidates = fallbackRpcEndpointCandidatesFor(primary);
  return candidates.isEmpty ? null : candidates.first;
}

RpcEndpointPreset? _selectedFallbackPrimaryPreset(RpcEndpointConfig primary) {
  return explicitRpcEndpointPresetFor(primary);
}

RpcEndpointConfig resolveStoredRpcEndpointConfig({
  required String networkName,
  required String? storedUrl,
  required String? storedPresetId,
}) {
  if (kZcashIronwoodMasquerade) {
    return defaultRpcEndpointConfig(ZcashNetwork.mainnet.name);
  }

  final network = zcashNetworkFromName(networkName);
  final presetId = storedPresetId?.trim();
  if (presetId != null &&
      presetId.isNotEmpty &&
      presetId != kCustomRpcEndpointPresetId) {
    final preset = findRpcEndpointPresetById(network.name, presetId);
    if (preset != null) {
      return RpcEndpointConfig(
        networkName: network.name,
        lightwalletdUrl: preset.url,
        presetId: preset.id,
      );
    }
  }

  final url = storedUrl?.trim();
  if (url == null || url.isEmpty) {
    return defaultRpcEndpointConfig(network.name);
  }

  return RpcEndpointConfig(
    networkName: network.name,
    lightwalletdUrl: normalizeRpcEndpointUrl(url, allowDefaultPort: true),
    presetId: kCustomRpcEndpointPresetId,
  );
}

RpcEndpointPreset? findRpcEndpointPresetById(
  String networkName,
  String presetId,
) {
  for (final preset in rpcEndpointPresetsForNetwork(networkName)) {
    if (preset.id == presetId) return preset;
  }
  return null;
}

RpcEndpointPreset? findRpcEndpointPresetByUrl(
  String url, {
  String? networkName,
}) {
  final normalized = normalizeRpcEndpointUrl(url, allowDefaultPort: true);
  final presets = networkName == null
      ? [
          ...rpcEndpointPresetsForNetwork(ZcashNetwork.mainnet.name),
          ...kTestnetRpcEndpointPresets,
        ]
      : rpcEndpointPresetsForNetwork(networkName);
  for (final preset in presets) {
    if (normalizeRpcEndpointUrl(preset.url, allowDefaultPort: true) ==
        normalized) {
      return preset;
    }
  }
  return null;
}

String normalizeRpcEndpointUrl(
  String input, {
  bool allowDefaultPort = false,
  bool allowLocalHttp = kDebugMode,
}) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Enter an endpoint.');
  }
  if (trimmed.contains(RegExp(r'\s'))) {
    throw const FormatException('Endpoint cannot contain spaces.');
  }

  final candidate = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) {
    throw const FormatException('Enter a valid hostname and port.');
  }
  if (uri.scheme != 'https' && uri.scheme != 'http') {
    throw const FormatException('Use an https:// endpoint.');
  }
  if (uri.scheme == 'http' && !(allowLocalHttp && _isLocalhost(uri.host))) {
    throw const FormatException('Use an https:// endpoint.');
  }
  final hasExplicitPort = _hasExplicitPort(candidate);
  if (!hasExplicitPort && !allowDefaultPort) {
    throw const FormatException(
      'Include a valid port, for example us.zec.stardust.rest:443.',
    );
  }
  final port = hasExplicitPort ? uri.port : _defaultPortForScheme(uri.scheme);
  if (port <= 0 || port > 65535) {
    throw const FormatException(
      'Include a valid port, for example us.zec.stardust.rest:443.',
    );
  }

  return '${uri.scheme}://${_formatRpcHost(uri.host)}:$port';
}

bool _isLocalhost(String host) {
  final lower = host.toLowerCase();
  return lower == 'localhost' ||
      lower == '::1' ||
      lower == '10.0.2.2' ||
      lower.startsWith('127.');
}

bool _hasExplicitPort(String url) {
  final schemeIndex = url.indexOf('://');
  if (schemeIndex < 0) return false;

  final afterScheme = url.substring(schemeIndex + 3);
  final authorityEnd = afterScheme.indexOf(RegExp(r'[/#?]'));
  final authority = authorityEnd < 0
      ? afterScheme
      : afterScheme.substring(0, authorityEnd);
  final hostPort = authority.contains('@')
      ? authority.substring(authority.lastIndexOf('@') + 1)
      : authority;

  if (hostPort.startsWith('[')) {
    final closeBracket = hostPort.indexOf(']');
    return closeBracket >= 0 &&
        closeBracket + 1 < hostPort.length &&
        hostPort[closeBracket + 1] == ':';
  }

  return hostPort.lastIndexOf(':') > 0;
}

String rpcEndpointHostPort(String url) {
  final uri = Uri.parse(normalizeRpcEndpointUrl(url, allowDefaultPort: true));
  return '${_formatRpcHost(uri.host)}:${uri.port}';
}

String rpcEndpointInputText(String url) {
  final normalized = normalizeRpcEndpointUrl(url, allowDefaultPort: true);
  final uri = Uri.parse(normalized);
  if (uri.scheme == 'https') {
    return rpcEndpointHostPort(normalized);
  }
  return normalized;
}

int _defaultPortForScheme(String scheme) {
  return switch (scheme) {
    'https' => 443,
    'http' => 80,
    _ => 0,
  };
}

String _formatRpcHost(String host) {
  if (host.contains(':') && !host.startsWith('[')) {
    return '[$host]';
  }
  return host;
}
