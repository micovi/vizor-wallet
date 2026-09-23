/// The recipient check the composer makes before anything is read or proved.
///
/// The vectors are real Nyctis addresses: the first is the one the demo seed
/// of `rust/src/nyctis/testdata.rs` derives, the second the one
/// `rust/src/nyctis/keys.rs` derives from its demo seed. (The keys.rs vector
/// already has an `x` at index 20, which the one-character typo test below
/// writes, so it cannot be the first.)
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/crypto/bech32.dart';
import 'package:zcash_wallet/src/features/nyctis_assets/services/nyctis_address.dart';

const kRegtestNyctisAddress =
    'nyreg1qptwrens9mn27sa8z9xjx3d2n43ng7jupk6wupha6rju2wjldrgpq9d9nhdrxaxrs'
    'gmnfcdtke3rw5tjtf22gc3gszk7tmsnk0fmmkgdkef99r66a3qpsnce7ytnupp42g8ym08a'
    's7ew0retmhy0afhtkszq0qhnk2';

const _otherRegtestAddress =
    'nyreg1qzxdgxkjg4vgjux6rw63t0akwkq03q5stfz9txpjcqx0mgcmpfrqk2per2w388qnr'
    'tc7t5mh9nux7ftrxq0xsc9gjv9shuymray29qq8yqcqxexsz2hwz2f6nmtmvgr46ja60dfg'
    'kasmf5tsg3a3jtq9hs9sxafxqq';

void main() {
  group('the network prefix', () {
    test('each network has its own, and the hint uses it', () {
      expect(nyctisAddressHrp('main'), 'ny');
      expect(nyctisAddressHrp('test'), 'nytest');
      expect(nyctisAddressHrp('regtest'), 'nyreg');
      expect(nyctisAddressHint('regtest'), 'nyreg1…');
      expect(nyctisAddressHint('main'), 'ny1…');
    });
  });

  group('a recipient', () {
    test('a real regtest address passes on regtest', () {
      expect(
        nyctisRecipientError(kRegtestNyctisAddress, networkName: 'regtest'),
        isNull,
      );
      expect(
        nyctisRecipientError(_otherRegtestAddress, networkName: 'regtest'),
        isNull,
      );
      // Longer than BIP-173's 90 characters, which is a SegWit rule only.
      expect(kRegtestNyctisAddress.length, greaterThan(90));
      expect(decodeBech32m(kRegtestNyctisAddress)?.hrp, 'nyreg');
    });

    test('empty is not an error yet', () {
      expect(nyctisRecipientError('  ', networkName: 'regtest'), isNull);
    });

    test('one changed character fails the checksum', () {
      final typo = kRegtestNyctisAddress.replaceRange(20, 21, 'x');
      expect(typo, isNot(kRegtestNyctisAddress));
      expect(
        nyctisRecipientError(typo, networkName: 'regtest'),
        contains('Check it for typos'),
      );
    });

    test('an address for another network names that network', () {
      expect(
        nyctisRecipientError(kRegtestNyctisAddress, networkName: 'main'),
        allOf(contains('Regtest Nyctis address'), contains('ny1…')),
      );
    });

    test('a Zcash address is called one, not a typo', () {
      expect(
        nyctisRecipientError(
          't1Rv4exT7bqhZqi2j7xz8bUHDMxwosrjADU',
          networkName: 'main',
        ),
        contains('This is a Zcash address'),
      );
    });

    test('a placeholder is not an address', () {
      expect(
        nyctisRecipientError('nyreg1recipient', networkName: 'regtest'),
        isNotNull,
      );
    });
  });
}
