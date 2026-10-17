import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Client-side encryption for Chatify message bodies.
///
/// Private keys are device-local and never sent to the API. Each message gets a
/// fresh AES-GCM nonce. A separate envelope is encrypted for each participant,
/// allowing the server to relay ciphertext without seeing message text.
class ChatifyE2EE {
  ChatifyE2EE._();
  static final ChatifyE2EE instance = ChatifyE2EE._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const X25519 _agreement = X25519();
  static const AesGcm _aead = AesGcm.with256bits();
  static const Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  String _keyName(String accountId) => 'chatify_e2ee_private_v1_$accountId';

  Future<SimpleKeyPair> _loadKeyPair(String accountId) async {
    if (accountId.isEmpty) throw StateError('Sign in before enabling encryption.');
    final stored = await _storage.read(key: _keyName(accountId));
    if (stored != null) {
      final seed = base64Decode(stored);
      if (seed.length != 32) {
        throw StateError('The local encryption key is invalid. Do not delete app data; contact support before recovery.');
      }
      return _agreement.newKeyPairFromSeed(seed);
    }

    // A missing key may mean this is a new device. Never silently replace a
    // previously registered account key, because that would lock out history.
    final random = Random.secure();
    final seed = List<int>.generate(32, (_) => random.nextInt(256));
    final pair = await _agreement.newKeyPairFromSeed(seed);
    final publicKey = await pair.extractPublicKey();
    final remote = await _registeredPublicKey(accountId);
    if (remote != null && remote != base64Encode(publicKey.bytes)) {
      throw StateError('This account already has an encryption key on another device. Secure device transfer/recovery is required before this device can send encrypted messages.');
    }
    await _storage.write(key: _keyName(accountId), value: base64Encode(seed));
    if (remote == null) {
      await _registerPublicKey(accountId, base64Encode(publicKey.bytes));
    }
    return pair;
  }

  Future<String?> _registeredPublicKey(String accountId) async {
    // This callback-free helper is intentionally supplied by the app's API
    // integration through public-key sync methods below.
    return _remoteKeys[accountId];
  }

  final Map<String, String> _remoteKeys = <String, String>{};

  void cachePublicKey(String accountId, String publicKey) {
    _remoteKeys[accountId] = publicKey;
  }

  Future<void> _registerPublicKey(String accountId, String publicKey) async {
    // The UI layer performs the authenticated registration request. This cache
    // prevents repeated registration attempts within the current app session.
    _remoteKeys[accountId] = publicKey;
  }

  Future<String> publicKeyFor(String accountId) async {
    final pair = await _loadKeyPair(accountId);
    return base64Encode((await pair.extractPublicKey()).bytes);
  }

  Future<Map<String, dynamic>> encryptText({
    required String senderId,
    required String plaintext,
    required Map<String, String> participantPublicKeys,
  }) async {
    final senderPair = await _loadKeyPair(senderId);
    final envelopes = <String, dynamic>{};
    for (final entry in participantPublicKeys.entries) {
      final peerId = entry.key;
      final peerBytes = base64Decode(entry.value);
      if (peerBytes.length != 32) {
        throw StateError('A conversation member has an invalid encryption key.');
      }
      final peerPublic = SimplePublicKey(peerBytes, type: KeyPairType.x25519);
      final shared = await _agreement.sharedSecretKey(
        keyPair: senderPair,
        remotePublicKey: peerPublic,
      );
      final key = await _hkdf.deriveKey(
        secretKey: shared,
        nonce: utf8.encode('chatify-e2ee-v1'),
        info: utf8.encode('direct-and-group-message'),
      );
      final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
      final box = await _aead.encrypt(
        utf8.encode(plaintext),
        secretKey: key,
        nonce: nonce,
        aad: utf8.encode('chatify-v1:$peerId'),
      );
      envelopes[peerId] = <String, String>{
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      };
    }
    if (!envelopes.containsKey(senderId)) {
      throw StateError('Your own encryption key is missing from this conversation.');
    }
    return <String, dynamic>{
      'encryptionVersion': 1,
      'encryptedPayload': jsonEncode(envelopes),
    };
  }

  Future<String> decryptText({
    required String accountId,
    required String senderPublicKey,
    required String encryptedPayload,
  }) async {
    final allEnvelopes = jsonDecode(encryptedPayload);
    if (allEnvelopes is! Map || allEnvelopes[accountId] is! Map) {
      throw StateError('This message has no encrypted envelope for this device.');
    }
    final envelope = Map<String, dynamic>.from(allEnvelopes[accountId] as Map);
    final nonce = base64Decode(envelope['nonce'] as String);
    final cipherText = base64Decode(envelope['ciphertext'] as String);
    final mac = Mac(base64Decode(envelope['mac'] as String));
    if (nonce.length != 12 || mac.bytes.length != 16) {
      throw StateError('Encrypted message authentication data is invalid.');
    }
    final pair = await _loadKeyPair(accountId);
    final senderBytes = base64Decode(senderPublicKey);
    if (senderBytes.length != 32) {
      throw StateError('The sender encryption key is invalid.');
    }
    final shared = await _agreement.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(senderBytes, type: KeyPairType.x25519),
    );
    final key = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('chatify-e2ee-v1'),
      info: utf8.encode('direct-and-group-message'),
    );
    final clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
      aad: utf8.encode('chatify-v1:$accountId'),
    );
    return utf8.decode(clear);
  }
}
