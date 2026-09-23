import 'network_config.dart';
export 'network_config.dart';

/// Build-time switch for the whole Nyctis feature, modelled on
/// `VIZOR_PAYMENT_LINK_REGTEST_ENABLED`.
///
/// Off by default, and off means the build behaves exactly like upstream: no
/// sidebar item, no settings rows, no `/nyctis` or `/settings/nyctis`
/// routes, no Nyctis reads at startup and no Nyctis rows in the home or
/// activity feeds. `scripts/build-macos-devnet.sh` turns it on with
/// `--dart-define=VIZOR_NYCTIS_ENABLED=true`.
///
/// Routes and startup reads branch on this const directly, so the dead branch
/// is tree-shaken. Widgets and providers read it through
/// `nyctisFeatureEnabledProvider` so widget tests can turn it on.
const kNyctisFeatureEnabledEnvKey = 'VIZOR_NYCTIS_ENABLED';
const kNyctisFeatureAvailable = bool.fromEnvironment(
  kNyctisFeatureEnabledEnvKey,
  defaultValue: false,
);

/// Regtest devnet channel from the Nyctis repo's `infra/README.md`. This is
/// the only network the proof of concept ships a channel for; mainnet and
/// testnet stay unconfigured until a real channel exists.
const kNyctisRegtestIndexerUrl = 'http://127.0.0.1:8787';

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
/// the channel pair and the verifying-key pin, so re-pointing the wallet is a
/// re-run of the build rather than a source change.
///
/// The defaults below are the devnet as of 2026-09-23; they are kept so that a
/// plain `flutter run` still starts somewhere real.
const kNyctisRegtestBirthday = int.fromEnvironment(
  'NYCTIS_REGTEST_BIRTHDAY',
  defaultValue: 2,
);
const kNyctisRegtestChannelUivk = String.fromEnvironment(
  'NYCTIS_REGTEST_CHANNEL_UIVK',
  defaultValue:
      'uivkregtest12vmc8wdh0dnsmek0nn4u52zg2tn6k68ez5pcamfm2lnldmzq8f6p5468ayu'
      'n5p60l696h2hjvdyy268ur6z785m8x6s2y9y8z9vpaxpwr8wmd8gutrwwd2pndq7klueeyr'
      '03x6dcj7qx52kuttj647c3tq5zjrase2thjtwvshld2zameshgv34p6w7vhvg8janrytj5r'
      'z26hh72tacg7gqf64s5s5sety36vzt5ecjsygk3vgh',
);
const kNyctisRegtestChannelAddress = String.fromEnvironment(
  'NYCTIS_REGTEST_CHANNEL_ADDRESS',
  defaultValue:
      'uregtest1xrkjeptr37z2mdv2xnuljxju4rje80xc4lg2x3huemj9a07dkprhpe4363g6hq'
      '7yv4dd0qs7m2wdm3uzj7zluwtr7rykjv776vad9xfp',
);

/// `BLAKE2b-256` of the devnet's compressed Groth16 verifying key, lowercase
/// hex — the `vk_hash=` in `.devnet/keys/interpreter-v0.circuit`.
///
/// The replay and the pay path refuse any key from `/api/vk` that does not
/// hash to this, whatever `/api/status` says: the indexer serving the key and
/// the hash together pins nothing. A new `zk-setup` makes a new key, so this
/// is a define for the same reason the channel is.
const kNyctisRegtestVkPin = String.fromEnvironment(
  'NYCTIS_REGTEST_VK_PIN',
  defaultValue:
      'a8600f3032389c0ea927b88b2814631b0880619ce38ec13f590495526373a51a',
);

/// A Nyctis channel: the public UIVK that says *where to look*, the Zcash
/// unified address its memos are sent to, and the height below which the
/// channel carries nothing.
///
/// Both halves are needed: reading a channel takes the UIVK, writing to one
/// takes the address, and a config that has one without the other cannot do
/// either job.
class NyctisChannel {
  const NyctisChannel({
    required this.uivk,
    required this.address,
    required this.birthday,
  });

  final String uivk;
  final String address;
  final int birthday;

  @override
  bool operator ==(Object other) =>
      other is NyctisChannel &&
      other.uivk == uivk &&
      other.address == address &&
      other.birthday == birthday;

  @override
  int get hashCode => Object.hash(uivk, address, birthday);
}

/// The regtest devnet channel, or `null` on a network that has none.
///
/// Returning `null` rather than an invented channel is deliberate: a mainnet
/// build must be able to say "Nyctis is not configured here" instead of
/// pointing the replay at an address nobody publishes to.
NyctisChannel? defaultNyctisChannel(String networkName) {
  final network = zcashNetworkFromName(networkName);
  return switch (network) {
    ZcashNetwork.regtest => const NyctisChannel(
      uivk: kNyctisRegtestChannelUivk,
      address: kNyctisRegtestChannelAddress,
      birthday: kNyctisRegtestBirthday,
    ),
    ZcashNetwork.mainnet || ZcashNetwork.testnet => null,
  };
}

/// The pinned verifying-key hash, or `''` on a network that has none.
///
/// Empty is not a wildcard: Rust refuses every key against an empty pin, so a
/// network without one verifies nothing rather than everything.
String defaultNyctisVkPin(String networkName) {
  final network = zcashNetworkFromName(networkName);
  return switch (network) {
    ZcashNetwork.regtest => kNyctisRegtestVkPin,
    ZcashNetwork.mainnet || ZcashNetwork.testnet => '',
  };
}

/// The default indexer origin, or `''` on a network that has none.
String defaultNyctisIndexerUrl(String networkName) {
  final network = zcashNetworkFromName(networkName);
  return switch (network) {
    ZcashNetwork.regtest => kNyctisRegtestIndexerUrl,
    ZcashNetwork.mainnet || ZcashNetwork.testnet => '',
  };
}

/// Everything the Nyctis feature needs before it can fetch and replay a
/// channel. Empty strings and a zero birthday mean "not configured"; the
/// getters below are the only place that judgement is made.
class NyctisConfig {
  const NyctisConfig({
    required this.networkName,
    this.indexerUrl = '',
    this.channelUivk = '',
    this.channelAddress = '',
    this.birthday = 0,
    this.enabled = kNyctisEnabledByDefault,
    this.provingKeyDir = '',
    this.vkPin = '',
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

  /// Folder holding the Nyctis proving key (`interpreter-v0.pk`, `.vk` and
  /// `.circuit`), or `''` when the user has not pointed at one.
  ///
  /// Empty is the normal state for a wallet that only reads: verifying is
  /// cheap and the 1.8 KiB verifying key arrives from the indexer, but the
  /// ~83 MiB proving key is served by nothing and is needed only to *send*.
  /// So this is the one setting that decides whether sending is offered at
  /// all, and [NyctisConfig.hasProvingKeyDir] being false is not a fault.
  final String provingKeyDir;

  /// The channel's pinned verifying-key hash (`BLAKE2b-256`, lowercase hex).
  ///
  /// Handed to `nyctisReplay` and `nyctisBuildPay`, which refuse the
  /// indexer's `/api/vk` unless it hashes to this. It is the one input on the
  /// read path the indexer does not supply.
  final String vkPin;

  ZcashNetwork get network => zcashNetworkFromName(networkName);

  bool get hasIndexer => indexerUrl.trim().isNotEmpty;

  bool get hasChannel =>
      channelUivk.trim().isNotEmpty && channelAddress.trim().isNotEmpty;

  /// Whether the feature has everything it needs. This is separate from
  /// [enabled] so the UI can tell "no channel on this network" apart from
  /// "the user left it off".
  bool get isConfigured => hasIndexer && hasChannel;

  /// Whether a proving-key folder has been named. Says nothing about whether
  /// the folder holds a usable key — only `nyctisCheckProvingKey` can say
  /// that, and only the channel's `vk_hash` can say it is the *right* key.
  bool get hasProvingKeyDir => provingKeyDir.trim().isNotEmpty;

  bool get isUsable => enabled && isConfigured;

  /// Sentence-case reason the feature cannot run, or `null` when it can.
  String? get unconfiguredReason {
    if (!hasChannel) {
      return 'Nyctis has no channel on this network yet.';
    }
    if (!hasIndexer) {
      return 'Add a Nyctis indexer before loading assets.';
    }
    return null;
  }

  /// The indexer origin as a [Uri].
  ///
  /// Throws a [FormatException] when [indexerUrl] is empty or malformed, so a
  /// caller that skipped [isConfigured] fails loudly instead of fetching from
  /// a nonsense origin.
  Uri get indexerBaseUri => Uri.parse(normalizeNyctisIndexerUrl(indexerUrl));

  NyctisChannel? get channel => hasChannel
      ? NyctisChannel(
          uivk: channelUivk,
          address: channelAddress,
          birthday: birthday,
        )
      : null;

  NyctisConfig copyWith({
    String? networkName,
    String? indexerUrl,
    String? channelUivk,
    String? channelAddress,
    int? birthday,
    bool? enabled,
    String? provingKeyDir,
    String? vkPin,
  }) {
    return NyctisConfig(
      networkName: networkName ?? this.networkName,
      indexerUrl: indexerUrl ?? this.indexerUrl,
      channelUivk: channelUivk ?? this.channelUivk,
      channelAddress: channelAddress ?? this.channelAddress,
      birthday: birthday ?? this.birthday,
      enabled: enabled ?? this.enabled,
      provingKeyDir: provingKeyDir ?? this.provingKeyDir,
      vkPin: vkPin ?? this.vkPin,
    );
  }

  NyctisConfig withChannel(NyctisChannel channel) => copyWith(
    channelUivk: channel.uivk,
    channelAddress: channel.address,
    birthday: channel.birthday,
  );

  @override
  bool operator ==(Object other) =>
      other is NyctisConfig &&
      other.networkName == networkName &&
      other.indexerUrl == indexerUrl &&
      other.channelUivk == channelUivk &&
      other.channelAddress == channelAddress &&
      other.birthday == birthday &&
      other.enabled == enabled &&
      other.provingKeyDir == provingKeyDir &&
      other.vkPin == vkPin;

  @override
  int get hashCode => Object.hash(
    networkName,
    indexerUrl,
    channelUivk,
    channelAddress,
    birthday,
    enabled,
    provingKeyDir,
    vkPin,
  );
}

/// Whether the feature is on when nothing has been stored for it.
///
/// Off: a configured channel is not consent to fetch one. [parseNyctisEnabled]
/// and [defaultNyctisConfig] both read this constant rather than each
/// spelling the policy out, so a stored `false` and a fresh install cannot
/// end up meaning different things.
const bool kNyctisEnabledByDefault = false;

/// Reads the stored opt-in flag. `null` when nothing was stored, so the caller
/// can fall back to [kNyctisEnabledByDefault] rather than guess.
///
/// Only the two values `NyctisConfigNotifier.setEnabled` writes are
/// recognised; anything else is treated as nothing stored.
bool? parseNyctisEnabled(String? stored) {
  return switch (stored?.trim()) {
    'true' => true,
    'false' => false,
    _ => null,
  };
}

/// The built-in config for [networkName], disabled until the user opts in.
NyctisConfig defaultNyctisConfig(String networkName) {
  final network = zcashNetworkFromName(networkName);
  final channel = defaultNyctisChannel(network.name);
  return NyctisConfig(
    networkName: network.name,
    indexerUrl: defaultNyctisIndexerUrl(network.name),
    channelUivk: channel?.uivk ?? '',
    channelAddress: channel?.address ?? '',
    birthday: channel?.birthday ?? 0,
    enabled: kNyctisEnabledByDefault,
    // Nothing ships a proving key: it is 83 MiB, it is not served over HTTP,
    // and a wallet that only reads never needs one.
    provingKeyDir: '',
    vkPin: defaultNyctisVkPin(network.name),
  );
}

/// Folds stored settings over the built-in config for [networkName].
///
/// Anything stored that no longer parses is dropped back to the default rather
/// than propagated: a bad indexer URL must not stop the app from starting.
///
/// The channel is folded as **one value, not three**. `NyctisConfigNotifier
/// .setChannel` is careful to write the viewing key, the address and the
/// birthday together, because a key from one channel with an address from
/// another reads one channel and pays into a different one; resolving each
/// field against the defaults separately would hand that exact pair back on
/// the next launch. So a stored channel is used only when it is complete, and
/// a partial one is dropped whole.
NyctisConfig resolveStoredNyctisConfig({
  required String networkName,
  String? storedIndexerUrl,
  String? storedChannelUivk,
  String? storedChannelAddress,
  String? storedBirthday,
  String? storedEnabled,
  String? storedProvingKeyDir,
  String? storedVkPin,
}) {
  final defaults = defaultNyctisConfig(
    zcashNetworkFromName(networkName).name,
  );

  var indexerUrl = defaults.indexerUrl;
  final rawIndexerUrl = storedIndexerUrl?.trim() ?? '';
  if (rawIndexerUrl.isNotEmpty) {
    try {
      indexerUrl = normalizeNyctisIndexerUrl(rawIndexerUrl);
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
      ? (parseNyctisBirthday(storedBirthday) ?? 0)
      : defaults.birthday;

  // A stored path that no longer normalizes is dropped rather than carried:
  // the settings screen re-validates the folder against the channel's key on
  // every open, and a value that cannot even be trimmed into a path would
  // only produce a confusing failure two screens later.
  var provingKeyDir = defaults.provingKeyDir;
  try {
    provingKeyDir = normalizeNyctisProvingKeyDir(storedProvingKeyDir ?? '');
  } on FormatException {
    provingKeyDir = defaults.provingKeyDir;
  }

  // Same rule as the indexer URL: a stored pin that no longer normalizes falls
  // back to the built-in one rather than to nothing, because an empty pin
  // verifies nothing and a wrong-looking one would only fail later, in Rust.
  var vkPin = defaults.vkPin;
  final rawVkPin = storedVkPin?.trim() ?? '';
  if (rawVkPin.isNotEmpty) {
    try {
      vkPin = normalizeNyctisVkPin(rawVkPin);
    } on FormatException {
      vkPin = defaults.vkPin;
    }
  }

  return NyctisConfig(
    networkName: defaults.networkName,
    indexerUrl: indexerUrl,
    channelUivk: hasStoredChannel ? uivk : defaults.channelUivk,
    channelAddress: hasStoredChannel ? address : defaults.channelAddress,
    birthday: birthday,
    enabled: parseNyctisEnabled(storedEnabled) ?? defaults.enabled,
    provingKeyDir: provingKeyDir,
    vkPin: vkPin,
  );
}

/// Normalizes user input into a stored verifying-key pin: 64 hex characters,
/// lowercased.
///
/// Throws a [FormatException] whose `.message` is user-facing sentence case.
String normalizeNyctisVkPin(String input) {
  final trimmed = input.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(trimmed)) {
    throw const FormatException(
      'Enter the verifying-key hash as 64 hex characters.',
    );
  }
  return trimmed;
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
String normalizeNyctisProvingKeyDir(String input) {
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
int? parseNyctisBirthday(String? stored) {
  final raw = stored?.trim() ?? '';
  if (raw.isEmpty) return null;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 0) return null;
  return parsed;
}

/// Normalizes user input into a stored Nyctis indexer origin.
///
/// Accepts a bare host (`indexer.example`), a host and port
/// (`127.0.0.1:8787`), or a full origin with an optional path prefix. Returns
/// `scheme://host[:port][/path]` with no trailing slash, query, or fragment.
///
/// Throws a [FormatException] whose `.message` is user-facing sentence case.
String normalizeNyctisIndexerUrl(String input) {
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
  if (uri.scheme == 'http' && !isNyctisLoopbackHost(uri.host)) {
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
bool isNyctisLoopbackHost(String host) {
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
  return isNyctisLoopbackHost(host) ? 'http' : 'https';
}

int _defaultPortForScheme(String scheme) => scheme == 'https' ? 443 : 80;

/// Human label for the network a Nyctis address belongs to.
///
/// The address prefix already says it (`nyreg…` / `nytest…` / `ny…`), but the
/// prefix is three characters buried in a 200-character string, and sending a
/// regtest address to someone on mainnet fails silently — the payer's wallet
/// simply never finds the channel. So the receive surface says it in words.
String nyctisNetworkLabel(String networkName) {
  return switch (zcashNetworkFromName(networkName)) {
    ZcashNetwork.mainnet => 'Mainnet',
    ZcashNetwork.testnet => 'Testnet',
    ZcashNetwork.regtest => 'Regtest',
  };
}
