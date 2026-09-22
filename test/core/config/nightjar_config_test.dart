import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/nightjar_config.dart';

void main() {
  group('normalizeNightjarIndexerUrl', () {
    test('accepts the regtest devnet indexer unchanged', () {
      expect(
        normalizeNightjarIndexerUrl(kNightjarRegtestIndexerUrl),
        'http://127.0.0.1:8787',
      );
    });

    test('assumes http for a bare loopback host and port', () {
      expect(
        normalizeNightjarIndexerUrl('127.0.0.1:8787'),
        'http://127.0.0.1:8787',
      );
      expect(
        normalizeNightjarIndexerUrl('localhost:8787'),
        'http://localhost:8787',
      );
    });

    test('assumes https for a bare public host', () {
      expect(
        normalizeNightjarIndexerUrl('indexer.example'),
        'https://indexer.example',
      );
    });

    test('drops a trailing slash', () {
      expect(
        normalizeNightjarIndexerUrl('http://127.0.0.1:8787/'),
        'http://127.0.0.1:8787',
      );
      expect(
        normalizeNightjarIndexerUrl('https://indexer.example///'),
        'https://indexer.example',
      );
    });

    test('keeps a path prefix but drops the default port', () {
      expect(
        normalizeNightjarIndexerUrl('https://indexer.example:443/nightjar/'),
        'https://indexer.example/nightjar',
      );
      expect(
        normalizeNightjarIndexerUrl('http://localhost:80'),
        'http://localhost',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        normalizeNightjarIndexerUrl('  http://127.0.0.1:8787  '),
        'http://127.0.0.1:8787',
      );
    });

    test('rejects an empty input with a user-facing message', () {
      expect(
        () => normalizeNightjarIndexerUrl('   '),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Enter an indexer URL.',
          ),
        ),
      );
    });

    test('rejects embedded whitespace', () {
      expect(
        () => normalizeNightjarIndexerUrl('http://127.0.0.1:8787 /api'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Indexer URL cannot contain spaces.',
          ),
        ),
      );
    });

    test('rejects a non-http scheme', () {
      for (final input in const [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'ftp://indexer.example',
      ]) {
        expect(
          () => normalizeNightjarIndexerUrl(input),
          throwsA(isA<FormatException>()),
          reason: input,
        );
      }
    });

    test('rejects plain http to a host that is not loopback', () {
      expect(
        () => normalizeNightjarIndexerUrl('http://indexer.example'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Use an https:// URL.',
          ),
        ),
      );
    });

    test('rejects input with no host', () {
      expect(
        () => normalizeNightjarIndexerUrl('https://'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('defaults', () {
    test('regtest carries the devnet channel and indexer', () {
      final config = defaultNightjarConfig(ZcashNetwork.regtest.name);
      expect(config.indexerUrl, 'http://127.0.0.1:8787');
      expect(config.channelUivk, startsWith('uivkregtest1'));
      expect(config.channelAddress, startsWith('uregtest1'));
      expect(config.birthday, 2);
      expect(config.isConfigured, isTrue);
      expect(config.unconfiguredReason, isNull);
    });

    test('regtest stays off until the user opts in', () {
      final config = defaultNightjarConfig(ZcashNetwork.regtest.name);
      expect(config.enabled, isFalse);
      expect(config.isUsable, isFalse);
    });

    test('mainnet and testnet have no channel and say so', () {
      for (final network in const [
        ZcashNetwork.mainnet,
        ZcashNetwork.testnet,
      ]) {
        final config = defaultNightjarConfig(network.name);
        expect(
          defaultNightjarChannel(network.name),
          isNull,
          reason: network.name,
        );
        expect(config.channel, isNull, reason: network.name);
        expect(config.hasChannel, isFalse, reason: network.name);
        expect(config.isConfigured, isFalse, reason: network.name);
        expect(
          config.unconfiguredReason,
          'Nightjar has no channel on this network yet.',
          reason: network.name,
        );
      }
    });

    test('indexerBaseUri parses the default origin', () {
      final config = defaultNightjarConfig(ZcashNetwork.regtest.name);
      expect(config.indexerBaseUri, Uri.parse('http://127.0.0.1:8787'));
    });

    test('indexerBaseUri throws rather than fetching from nowhere', () {
      final config = defaultNightjarConfig(ZcashNetwork.mainnet.name);
      expect(() => config.indexerBaseUri, throwsFormatException);
    });
  });

  group('resolveStoredNightjarConfig', () {
    test('falls back to the network default when nothing is stored', () {
      expect(
        resolveStoredNightjarConfig(networkName: ZcashNetwork.regtest.name),
        defaultNightjarConfig(ZcashNetwork.regtest.name),
      );
    });

    test('normalizes a stored indexer URL', () {
      final config = resolveStoredNightjarConfig(
        networkName: ZcashNetwork.regtest.name,
        storedIndexerUrl: '  127.0.0.1:9999/  ',
      );
      expect(config.indexerUrl, 'http://127.0.0.1:9999');
    });

    test('drops an unparseable stored indexer URL back to the default', () {
      final config = resolveStoredNightjarConfig(
        networkName: ZcashNetwork.regtest.name,
        storedIndexerUrl: 'javascript:alert(1)',
      );
      expect(config.indexerUrl, kNightjarRegtestIndexerUrl);
    });

    test('applies a stored channel over the default', () {
      final config = resolveStoredNightjarConfig(
        networkName: ZcashNetwork.regtest.name,
        storedChannelUivk: 'uivkregtest1other',
        storedChannelAddress: 'uregtest1other',
        storedBirthday: '1234',
        storedEnabled: 'true',
      );
      expect(config.channelUivk, 'uivkregtest1other');
      expect(config.channelAddress, 'uregtest1other');
      expect(config.birthday, 1234);
      expect(config.enabled, isTrue);
      expect(config.isUsable, isTrue);
    });

    test('a stored channel is all-or-nothing', () {
      // Storing a viewing key without the address it belongs to used to read
      // one channel and pay into another: `setChannel` moves all three
      // together precisely so that pair cannot exist, and resolving each
      // field against the defaults separately handed it back on next launch.
      final halfStored = resolveStoredNightjarConfig(
        networkName: ZcashNetwork.regtest.name,
        storedChannelUivk: 'uivkregtest1someotherchannel',
        storedEnabled: 'true',
      );

      expect(halfStored.channelUivk, kNightjarRegtestChannelUivk);
      expect(halfStored.channelAddress, kNightjarRegtestChannelAddress);
      expect(
        halfStored.channel,
        defaultNightjarChannel(ZcashNetwork.regtest.name),
        reason: 'a partial channel is dropped whole, never blended',
      );

      final addressOnly = resolveStoredNightjarConfig(
        networkName: ZcashNetwork.regtest.name,
        storedChannelAddress: 'uregtest1someotherchannel',
      );
      expect(
        addressOnly.channel,
        defaultNightjarChannel(ZcashNetwork.regtest.name),
      );
    });

    test('a stored channel does not inherit the devnet birthday', () {
      final config = resolveStoredNightjarConfig(
        networkName: ZcashNetwork.regtest.name,
        storedChannelUivk: 'uivkregtest1other',
        storedChannelAddress: 'uregtest1other',
      );

      expect(config.channelUivk, 'uivkregtest1other');
      expect(
        config.birthday,
        0,
        reason:
            "a channel of its own has a birthday of its own; the built-in "
            "devnet's 2 is not it",
      );
    });

    test('a stored birthday alone does not move the built-in channel', () {
      final config = resolveStoredNightjarConfig(
        networkName: ZcashNetwork.regtest.name,
        storedBirthday: '9000',
      );

      expect(config.birthday, kNightjarRegtestBirthday);
      expect(config.channel, defaultNightjarChannel(ZcashNetwork.regtest.name));
    });

    test('the enabled flag survives a bootstrap round trip', () {
      // What the settings screen writes through `setEnabled` is exactly what
      // the next launch reads back, in both directions.
      for (final enabled in const [true, false]) {
        final stored = enabled ? 'true' : 'false';
        expect(
          resolveStoredNightjarConfig(
            networkName: ZcashNetwork.regtest.name,
            storedEnabled: stored,
          ).enabled,
          enabled,
          reason: stored,
        );
      }
    });

    test('nothing stored means the same thing as the default', () {
      expect(
        resolveStoredNightjarConfig(
          networkName: ZcashNetwork.regtest.name,
        ).enabled,
        defaultNightjarConfig(ZcashNetwork.regtest.name).enabled,
      );
      expect(kNightjarEnabledByDefault, isFalse);
      expect(parseNightjarEnabled(null), isNull);
      expect(parseNightjarEnabled('yes'), isNull);
      expect(parseNightjarEnabled(' true '), isTrue);
      expect(parseNightjarEnabled('false'), isFalse);
    });

    test('a non-numeric stored birthday falls back to the default', () {
      final config = resolveStoredNightjarConfig(
        networkName: ZcashNetwork.regtest.name,
        storedBirthday: 'not-a-height',
      );
      expect(config.birthday, kNightjarRegtestBirthday);
    });

    test('only the literal "true" enables the feature', () {
      for (final stored in const [null, '', 'false', '1', 'TRUE']) {
        expect(
          resolveStoredNightjarConfig(
            networkName: ZcashNetwork.regtest.name,
            storedEnabled: stored,
          ).enabled,
          isFalse,
          reason: '$stored',
        );
      }
    });
  });

  group('normalizeNightjarProvingKeyDir', () {
    test('an empty value clears the setting rather than failing', () {
      expect(normalizeNightjarProvingKeyDir(''), '');
      expect(normalizeNightjarProvingKeyDir('   '), '');
    });

    test('keeps an absolute POSIX path and drops a trailing separator', () {
      expect(normalizeNightjarProvingKeyDir('/keys'), '/keys');
      expect(normalizeNightjarProvingKeyDir('  /a/b/keys/  '), '/a/b/keys');
      expect(normalizeNightjarProvingKeyDir('/'), '/');
    });

    test('keeps an absolute Windows path', () {
      expect(normalizeNightjarProvingKeyDir(r'C:\keys\'), r'C:\keys');
      expect(normalizeNightjarProvingKeyDir(r'\\host\share'), r'\\host\share');
    });

    test('refuses a relative path with a sentence a user can act on', () {
      // Resolved rather than refused, the same string would name a different
      // folder in a sandbox than on a desktop launch, and the failure would
      // arrive as "proving key not found".
      expect(
        () => normalizeNightjarProvingKeyDir('keys'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Enter the full path to the folder.',
          ),
        ),
      );
      expect(
        () => normalizeNightjarProvingKeyDir('../keys'),
        throwsFormatException,
      );
    });
  });

  group('the proving-key folder on a config', () {
    test('is empty by default, on every network', () {
      for (final network in ['main', 'test', 'regtest']) {
        final config = defaultNightjarConfig(network);
        expect(config.provingKeyDir, '');
        expect(config.hasProvingKeyDir, isFalse);
      }
    });

    test('a stored path is folded over the defaults', () {
      final config = resolveStoredNightjarConfig(
        networkName: 'regtest',
        storedProvingKeyDir: '/devnet/keys/',
      );

      expect(config.provingKeyDir, '/devnet/keys');
      expect(config.hasProvingKeyDir, isTrue);
    });

    test('a stored path that no longer normalizes is dropped, not carried', () {
      final config = resolveStoredNightjarConfig(
        networkName: 'regtest',
        storedProvingKeyDir: 'keys',
      );

      expect(config.provingKeyDir, '');
    });

    test('it takes part in equality, so a change rebuilds the screens', () {
      final base = defaultNightjarConfig('regtest');

      expect(base.copyWith(provingKeyDir: '/keys'), isNot(base));
      expect(
        base.copyWith(provingKeyDir: '/keys'),
        base.copyWith(provingKeyDir: '/keys'),
      );
    });
  });

  group('parseNightjarBirthday', () {
    test('parses a non-negative height', () {
      expect(parseNightjarBirthday('0'), 0);
      expect(parseNightjarBirthday(' 2 '), 2);
    });

    test('rejects empty, negative, and non-numeric input', () {
      expect(parseNightjarBirthday(null), isNull);
      expect(parseNightjarBirthday(''), isNull);
      expect(parseNightjarBirthday('-1'), isNull);
      expect(parseNightjarBirthday('2.5'), isNull);
      expect(parseNightjarBirthday('two'), isNull);
    });
  });
}
