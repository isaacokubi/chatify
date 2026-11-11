import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chatify/security/chatify_e2ee.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('encrypted recovery bundle restores the same account key on a new device', () async {
    const accountId = 'e2ee-transfer-test-account';
    const passphrase = 'correct horse battery staple 2026';
    final original = ChatifyE2EE.instance;
    final originalPublicKey = await original.publicKeyFor(accountId);
    final bundle = await original.exportRecoveryBundle(
      accountId,
      passphrase: passphrase,
    );

    // Simulate a second device with an empty secure-storage keychain.
    FlutterSecureStorage.setMockInitialValues({});
    final restoredPublicKey = await original.importRecoveryBundle(
      accountId,
      bundle,
      passphrase: passphrase,
      registeredPublicKey: originalPublicKey,
    );

    expect(restoredPublicKey, originalPublicKey);
    expect(
      await original.publicKeyFor(
        accountId,
        registeredPublicKey: originalPublicKey,
      ),
      originalPublicKey,
    );
  });

  test('wrong recovery passphrase does not write a key', () async {
    const accountId = 'e2ee-wrong-passphrase-test';
    final e2ee = ChatifyE2EE.instance;
    await e2ee.publicKeyFor(accountId);
    final bundle = await e2ee.exportRecoveryBundle(
      accountId,
      passphrase: 'correct horse battery staple',
    );
    FlutterSecureStorage.setMockInitialValues({});

    await expectLater(
      e2ee.importRecoveryBundle(
        accountId,
        bundle,
        passphrase: 'incorrect passphrase',
      ),
      throwsA(anything),
    );
    await expectLater(
      e2ee.publicKeyFor(accountId, registeredPublicKey: 'invalid'),
      throwsA(anything),
    );
  });

  test('recovery bundle cannot be imported into a different account', () async {
    const accountId = 'e2ee-original-account';
    final e2ee = ChatifyE2EE.instance;
    await e2ee.publicKeyFor(accountId);
    final bundle = await e2ee.exportRecoveryBundle(
      accountId,
      passphrase: 'account-bound recovery passphrase',
    );
    FlutterSecureStorage.setMockInitialValues({});

    await expectLater(
      e2ee.importRecoveryBundle(
        'some-other-account',
        bundle,
        passphrase: 'account-bound recovery passphrase',
      ),
      throwsA(anything),
    );
  });
}
