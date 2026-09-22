import 'network_config.dart';
export 'network_config.dart';

/// Regtest devnet channel from the Nightjar repo's `infra/README.md`. This is
/// the only network the proof of concept ships a channel for; mainnet and
/// testnet stay unconfigured until a real channel exists.
const kNightjarRegtestIndexerUrl = 'http://127.0.0.1:8787';
/// The regtest devnet channel, overridable at build time.
///
/// These are `String.fromEnvironment` rather than plain constants because the
/// devnet is **disposable**: a channel is born from a wallet's `uivk`, so wiping
/// the regtest chain and running `zk-setup` again produces a different
/// `channel_id` and therefore a different channel — and, since `channel_id`
/// feeds `collection_id` and so `asset_id`, different asset identifiers too.
/// Before this was a define, every devnet rebuild needed an edit to this file
/// and a full application rebuild to follow it, and the symptom of forgetting
/// was the wallet reporting that its indexer serves a different channel, which
/// names the problem but not the fix. `scripts/build-macos-devnet.sh` now passes
/// all three, so re-pointing the wallet is a re-run of the build rather than a
/// source change.
///
/// The defaults below are the devnet as of 2026-09-22; they are kept so that a
/// plain `flutter run` still starts somewhere real.
const kNightjarRegtestBirthday = int.fromEnvironment(
  'NIGHTJAR_REGTEST_BIRTHDAY',
  defaultValue: 2,
);
const kNightjarRegtestChannelUivk = String.fromEnvironment(
  'NIGHTJAR_REGTEST_CHANNEL_UIVK',
  defaultValue:
      'uivkregtest1dvlwf76lznrp8pqpdt5mzfewm3znm5mvr4f87s4xffp8r5575vevcyrmdjf'
      '2mk6h0prkrlphrtzrs00gdzv856aa04lk9g0nazrca9v7fhkdv525kvrv2m28yjac92fmvc'
      'xpuzadm82zhfkzgl82mzlcfpww249nfk5wmalneptxu7xk7p89ah26lhudne2sc872yejv4'
      's2pt57erwgu078saevaug897e334uqrf0xhgdqgwsy',
);
const kNightjarRegtestChannelAddress = String.fromEnvironment(
  'NIGHTJAR_REGTEST_CHANNEL_ADDRESS',
  defaultValue:
      'uregtest1hs90vlca8ftf56w666t5k0e0vyccrdtwa9ptde7q3huw4q9kyccmu046gshp73'
      'xfqq758lgt0m2eeef77tt8h6gma8jvszp25y8kmm4c',
);

/// A Nightjar channel: the public UIVK that says *where to look*, the Zcash
/// unified address its memos are sent to, and the height below which the
/// channel carries nothing.
///
/// Both halves are needed: reading a channel takes the UIVK, writing to one
/// takes the address, and a config that has one without the other cannot do
/// either job.
class NightjarChannel {
  const NightjarChannel({
    required this.uivk,
    required this.address,
    required this.birthday,
  });

  final String uivk;
  final String address;
  final int birthday;

  @override
  bool operator ==(Object other) =>
      other is NightjarChannel &&
      other.uivk == uivk &&
      other.address == address &&
      other.birthday == birthday;

  @override
  int get hashCode => Object.hash(uivk, address, birthday);
}

/// The regtest devnet channel, or `null` on a network that has none.
///
/// Returning `null` rather than an invented channel is deliberate: a mainnet
/// build must be able to say "Nightjar is not configured here" instead of
/// pointing the replay at an address nobody publishes to.
NightjarChannel? defaultNightjarChannel(String networkName) {
  final network = zcashNetworkFromName(networkName);
  return switch (network) {
    ZcashNetwork.regtest => const NightjarChannel(
      uivk: kNightjarRegtestChannelUivk,
      address: kNightjarRegtestChannelAddress,
      birthday: kNightjarRegtestBirthday,
    ),
    ZcashNetwork.mainnet || ZcashNetwork.testnet => null,
  };
}

/// The default indexer origin, or `''` on a network that has none.
String defaultNightjarIndexerUrl(String networkName) {
  final network = zcashNetworkFromName(networkName);
  return switch (network) {
    ZcashNetwork.regtest => kNightjarRegtestIndexerUrl,
    ZcashNetwork.mainnet || ZcashNetwork.testnet => '',
  };
}

/// Everything the Nightjar feature needs before it can fetch and replay a
/// channel. Empty strings and a zero birthday mean "not configured"; the
/// getters below are the only place that judgement is made.
class NightjarConfig {
  const NightjarConfig({
    required this.networkName,
    this.indexerUrl = '',
    this.channelUivk = '',
    this.channelAddress = '',
    this.birthday = 0,
    this.enabled = kNightjarEnabledByDefault,
    this.provingKeyDir = '',
  });

  final String networkName;

  /// Normalized indexer origin, for example `http://127.0.0.1:8787`.
  final String indexerUrl;

  /// The channel's public incoming viewing key. Says where to look; it says
  /// nothing about what is ours.
  final String channelUivk;

  /// The Zcash unified address channel memos are sent to.
  final String channelAddress;

  /// First height the channel can carry a message at.
  final int birthday;

  /// Whether the user has turned the feature on. A configured channel the user
  /// has not opted into must not be fetched.
  final bool enabled;

  /// Folder holding the Nightjar proving key (`interpreter-v0.pk`, `.vk` and
  /// `.circuit`), or `''` when the user has not pointed at one.
  ///
  /// Empty is the normal state for a wallet that only reads: verifying is
  /// cheap and the 1.8 KiB verifying key arrives from the indexer, but the
  /// ~83 MiB proving key is served by nothing and is needed only to *send*.
  /// So this is the one setting that decides whether sending is offered at
  /// all, and [NightjarConfig.hasProvingKeyDir] being false is not a fault.
  final String provingKeyDir;

  ZcashNetwork get network => zcashNetworkFromName(networkName);

  bool get hasIndexer => indexerUrl.trim().isNotEmpty;

  bool get hasChannel =>
      channelUivk.trim().isNotEmpty && channelAddress.trim().isNotEmpty;

  /// Whether the feature has everything it needs. This is separate from
  /// [enabled] so the UI can tell "no channel on this network" apart from
  /// "the user left it off".
  bool get isConfigured => hasIndexer && hasChannel;

  /// Whether a proving-key folder has been named. Says nothing about whether
  /// the folder holds a usable key — only `nightjarCheckProvingKey` can say
  /// that, and only the channel's `vk_hash` can say it is the *right* key.
  bool get hasProvingKeyDir => provingKeyDir.trim().isNotEmpty;

  bool get isUsable => enabled && isConfigured;

  /// Sentence-case reason the feature cannot run, or `null` when it can.
  String? get unconfiguredReason {
    if (!hasChannel) {
      return 'Nightjar has no channel on this network yet.';
    }
    if (!hasIndexer) {
      return 'Add a Nightjar indexer before loading assets.';
    }
    return null;
  }

  /// The indexer origin as a [Uri].
  ///
  /// Throws a [FormatException] when [indexerUrl] is empty or malformed, so a
  /// caller that skipped [isConfigured] fails loudly instead of fetching from
  /// a nonsense origin.
  Uri get indexerBaseUri => Uri.parse(normalizeNightjarIndexerUrl(indexerUrl));

  NightjarChannel? get channel => hasChannel
      ? NightjarChannel(
          uivk: channelUivk,
          address: channelAddress,
          birthday: birthday,
        )
      : null;

  NightjarConfig copyWith({
    String? networkName,
    String? indexerUrl,
    String? channelUivk,
    String? channelAddress,
    int? birthday,
    bool? enabled,
    String? provingKeyDir,
  }) {
    return NightjarConfig(
      networkName: networkName ?? this.networkName,
      indexerUrl: indexerUrl ?? this.indexerUrl,
      channelUivk: channelUivk ?? this.channelUivk,
      channelAddress: channelAddress ?? this.channelAddress,
      birthday: birthday ?? this.birthday,
      enabled: enabled ?? this.enabled,
      provingKeyDir: provingKeyDir ?? this.provingKeyDir,
    );
  }

  NightjarConfig withChannel(NightjarChannel channel) => copyWith(
    channelUivk: channel.uivk,
    channelAddress: channel.address,
    birthday: channel.birthday,
  );

  @override
  bool operator ==(Object other) =>
      other is NightjarConfig &&
      other.networkName == networkName &&
      other.indexerUrl == indexerUrl &&
      other.channelUivk == channelUivk &&
      other.channelAddress == channelAddress &&
      other.birthday == birthday &&
      other.enabled == enabled &&
      other.provingKeyDir == provingKeyDir;

  @override
  int get hashCode => Object.hash(
    networkName,
    indexerUrl,
    channelUivk,
    channelAddress,
    birthday,
    enabled,
    provingKeyDir,
  );
}

/// Whether the feature is on when nothing has been stored for it.
///
/// Off: a configured channel is not consent to fetch one. [parseNightjarEnabled]
/// and [defaultNightjarConfig] both read this constant rather than each
/// spelling the policy out, so a stored `false` and a fresh install cannot
/// end up meaning different things.
const bool kNightjarEnabledByDefault = false;

/// Reads the stored opt-in flag. `null` when nothing was stored, so the caller
/// can fall back to [kNightjarEnabledByDefault] rather than guess.
///
/// Only the two values `NightjarConfigNotifier.setEnabled` writes are
/// recognised; anything else is treated as nothing stored.
bool? parseNightjarEnabled(String? stored) {
  return switch (stored?.trim()) {
    'true' => true,
    'false' => false,
    _ => null,
  };
}

/// The built-in config for [networkName], disabled until the user opts in.
NightjarConfig defaultNightjarConfig(String networkName) {
  final network = zcashNetworkFromName(networkName);
  final channel = defaultNightjarChannel(network.name);
  return NightjarConfig(
    networkName: network.name,
    indexerUrl: defaultNightjarIndexerUrl(network.name),
    channelUivk: channel?.uivk ?? '',
    channelAddress: channel?.address ?? '',
    birthday: channel?.birthday ?? 0,
    enabled: kNightjarEnabledByDefault,
    // Nothing ships a proving key: it is 83 MiB, it is not served over HTTP,
    // and a wallet that only reads never needs one.
    provingKeyDir: '',
  );
}

/// Folds stored settings over the built-in config for [networkName].
///
/// Anything stored that no longer parses is dropped back to the default rather
/// than propagated: a bad indexer URL must not stop the app from starting.
///
/// The channel is folded as **one value, not three**. `NightjarConfigNotifier
/// .setChannel` is careful to write the viewing key, the address and the
/// birthday together, because a key from one channel with an address from
/// another reads one channel and pays into a different one; resolving each
/// field against the defaults separately would hand that exact pair back on
/// the next launch. So a stored channel is used only when it is complete, and
/// a partial one is dropped whole.
NightjarConfig resolveStoredNightjarConfig({
  required String networkName,
  String? storedIndexerUrl,
  String? storedChannelUivk,
  String? storedChannelAddress,
  String? storedBirthday,
  String? storedEnabled,
  String? storedProvingKeyDir,
}) {
  final defaults = defaultNightjarConfig(
    zcashNetworkFromName(networkName).name,
  );

  var indexerUrl = defaults.indexerUrl;
  final rawIndexerUrl = storedIndexerUrl?.trim() ?? '';
  if (rawIndexerUrl.isNotEmpty) {
    try {
      indexerUrl = normalizeNightjarIndexerUrl(rawIndexerUrl);
    } on FormatException {
      indexerUrl = defaults.indexerUrl;
    }
  }

  final uivk = storedChannelUivk?.trim() ?? '';
  final address = storedChannelAddress?.trim() ?? '';
  final hasStoredChannel = uivk.isNotEmpty && address.isNotEmpty;
  // A custom channel's birthday is its own. Falling back to the built-in
  // devnet's height here would hand a channel that starts at block 40,000 a
  // birthday of 2 — harmless in the replay, which would simply read from the
  // beginning, but it is the built-in channel's number on somebody else's
  // channel, and the resolver has no business inventing it. Zero says
  // "from the beginning" without borrowing anything.
  final birthday = hasStoredChannel
      ? (parseNightjarBirthday(storedBirthday) ?? 0)
      : defaults.birthday;

  // A stored path that no longer normalizes is dropped rather than carried:
  // the settings screen re-validates the folder against the channel's key on
  // every open, and a value that cannot even be trimmed into a path would
  // only produce a confusing failure two screens later.
  var provingKeyDir = defaults.provingKeyDir;
  try {
    provingKeyDir = normalizeNightjarProvingKeyDir(storedProvingKeyDir ?? '');
  } on FormatException {
    provingKeyDir = defaults.provingKeyDir;
  }

  return NightjarConfig(
    networkName: defaults.networkName,
    indexerUrl: indexerUrl,
    channelUivk: hasStoredChannel ? uivk : defaults.channelUivk,
    channelAddress: hasStoredChannel ? address : defaults.channelAddress,
    birthday: birthday,
    enabled: parseNightjarEnabled(storedEnabled) ?? defaults.enabled,
    provingKeyDir: provingKeyDir,
  );
}

/// Normalizes user input into a stored proving-key folder path.
///
/// Trims, drops a trailing separator, and refuses anything that is not an
/// absolute path — POSIX (`/keys`) or Windows (`C:\keys`, `\\host\share`).
/// Relative is refused rather than resolved because there is no directory
/// this app is meaningfully "in": the same string would name a different
/// folder on a desktop launch than on a sandboxed one, and the failure would
/// arrive as "proving key not found" rather than as the typo it is.
///
/// An **empty** string is not an error — it is how the setting is cleared —
/// and comes back as `''`.
///
/// Throws a [FormatException] whose `.message` is user-facing sentence case.
String normalizeNightjarProvingKeyDir(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return '';
  final isAbsolute =
      trimmed.startsWith('/') ||
      trimmed.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(trimmed);
  if (!isAbsolute) {
    throw const FormatException('Enter the full path to the folder.');
  }
  var path = trimmed;
  while (path.length > 1 &&
      (path.endsWith('/') || path.endsWith('\\')) &&
      !RegExp(r'^[A-Za-z]:[\\/]$').hasMatch(path)) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

/// Parses a stored birthday height. Returns `null` for anything that is not a
/// non-negative integer, including `null` and the empty string.
int? parseNightjarBirthday(String? stored) {
  final raw = stored?.trim() ?? '';
  if (raw.isEmpty) return null;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 0) return null;
  return parsed;
}

/// Normalizes user input into a stored Nightjar indexer origin.
///
/// Accepts a bare host (`indexer.example`), a host and port
/// (`127.0.0.1:8787`), or a full origin with an optional path prefix. Returns
/// `scheme://host[:port][/path]` with no trailing slash, query, or fragment.
///
/// Throws a [FormatException] whose `.message` is user-facing sentence case.
String normalizeNightjarIndexerUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Enter an indexer URL.');
  }
  if (trimmed.contains(RegExp(r'\s'))) {
    throw const FormatException('Indexer URL cannot contain spaces.');
  }

  final lower = trimmed.toLowerCase();
  if (lower.startsWith('javascript:') ||
      lower.startsWith('data:') ||
      lower.startsWith('file:') ||
      lower.startsWith('vbscript:')) {
    throw const FormatException('Enter an http or https URL.');
  }

  final candidate = trimmed.contains('://')
      ? trimmed
      : '${_defaultSchemeForAuthority(trimmed)}://$trimmed';
  final uri = Uri.tryParse(candidate);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const FormatException('Enter a host, like indexer.example.');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const FormatException('Enter an http or https URL.');
  }
  // Plain http leaks the channel's fetch pattern to anything on the path, so
  // it is allowed only where there is no path: the loopback devnet indexer.
  if (uri.scheme == 'http' && !isNightjarLoopbackHost(uri.host)) {
    throw const FormatException('Use an https:// URL.');
  }
  if (uri.hasPort && (uri.port <= 0 || uri.port > 65535)) {
    throw const FormatException('Enter a valid port, for example 8787.');
  }

  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  final port = uri.hasPort && uri.port != _defaultPortForScheme(uri.scheme)
      ? ':${uri.port}'
      : '';
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }

  return '${uri.scheme}://$host$port$path';
}

/// Hosts that reach only this machine or the Android emulator's host loopback.
bool isNightjarLoopbackHost(String host) {
  final lower = host.toLowerCase();
  return lower == 'localhost' ||
      lower == '::1' ||
      lower == '10.0.2.2' ||
      lower.startsWith('127.');
}

/// Scheme to assume when the user typed no scheme at all.
///
/// A loopback authority gets `http` because the devnet indexer has no TLS and
/// there is no path to eavesdrop on; everything else gets `https`.
String _defaultSchemeForAuthority(String authority) {
  final hostPort = authority.split(RegExp(r'[/#?]')).first;
  final closingBracket = hostPort.indexOf(']');
  final host = hostPort.startsWith('[') && closingBracket > 0
      ? hostPort.substring(1, closingBracket)
      : hostPort.split(':').first;
  return isNightjarLoopbackHost(host) ? 'http' : 'https';
}

int _defaultPortForScheme(String scheme) => scheme == 'https' ? 443 : 80;

/// Human label for the network a Nightjar address belongs to.
///
/// The address prefix already says it (`njreg…` / `njtest…` / `nj…`), but the
/// prefix is three characters buried in a 200-character string, and sending a
/// regtest address to someone on mainnet fails silently — the payer's wallet
/// simply never finds the channel. So the receive surface says it in words.
String nightjarNetworkLabel(String networkName) {
  return switch (zcashNetworkFromName(networkName)) {
    ZcashNetwork.mainnet => 'Mainnet',
    ZcashNetwork.testnet => 'Testnet',
    ZcashNetwork.regtest => 'Regtest',
  };
}
