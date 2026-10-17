import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Client-side encryption for Chatify message bodies.
///
/// Private keys are device-local and never sent to the API. Each message gets a
/// fresh AES-GCM nonce and a recipient-specific envelope. The server relays only
/// ciphertext for new text messages.
class ChatifyE2EE {
  ChatifyE2EE._();
  static final ChatifyE2EE instance = ChatifyE2EE._();

  static final FlutterSecureStorage _storage = FlutterSecureStorage();
  static final X25519 _agreement = X25519();
  static final AesGcm _aead = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  String _keyName(String accountId) => 'chatify_e2ee_private_v1_$accountId';

  Future<SimpleKeyPair> _loadKeyPair(
    String accountId, {
    String? registeredPublicKey,
  }) async {
    if (accountId.isEmpty) throw StateError('Sign in before enabling encryption.');
    final stored = await _storage.read(key: _keyName(accountId));
    if (stored != null) {
      final seed = base64Decode(stored);
      if (seed.length != 32) {
        throw StateError('The local encryption key is invalid. Secure recovery is required.');
      }
      final pair = await _agreement.newKeyPairFromSeed(seed);
      final localPublicKey = base64Encode((await pair.extractPublicKey()).bytes);
      if (registeredPublicKey != null && registeredPublicKey != localPublicKey) {
        throw StateError('This device encryption key does not match the account key. Do not overwrite either key; secure recovery is required.');
      }
      return pair;
    }

    // A missing local key may mean a new device. Never replace an account's
    // existing public key automatically, because doing so strands old messages.
    if (registeredPublicKey != null && registeredPublicKey.isNotEmpty) {
      throw StateError('This account already has an encryption key on another device. Secure device transfer/recovery is required before this device can decrypt messages.');
    }
    final random = Random.secure();
    final seed = List<int>.generate(32, (_) => random.nextInt(256));
    final pair = await _agreement.newKeyPairFromSeed(seed);
    await _storage.write(key: _keyName(accountId), value: base64Encode(seed));
    return pair;
  }

  Future<String> publicKeyFor(
    String accountId, {
    String? registeredPublicKey,
  }) async {
    final pair = await _loadKeyPair(
      accountId,
      registeredPublicKey: registeredPublicKey,
    );
    return base64Encode((await pair.extractPublicKey()).bytes);
  }

  Future<Map<String, dynamic>> encryptText({
    required String senderId,
    required String conversationId,
    required String plaintext,
    required Map<String, String> participantPublicKeys,
    String? registeredSenderPublicKey,
  }) async {
    final senderPair = await _loadKeyPair(
      senderId,
      registeredPublicKey: registeredSenderPublicKey,
    );
    final envelopes = <String, dynamic>{};
    for (final entry in participantPublicKeys.entries) {
      final peerId = entry.key;
      final peerBytes = base64Decode(entry.value);
      if (peerBytes.length != 32) {
        throw StateError('A conversation member has an invalid encryption key.');
      }
      final shared = await _agreement.sharedSecretKey(
        keyPair: senderPair,
        remotePublicKey: SimplePublicKey(peerBytes, type: KeyPairType.x25519),
      );
      final key = await _hkdf.deriveKey(
        secretKey: shared,
        nonce: utf8.encode('chatify-e2ee-v1'),
        info: utf8.encode('chatify-message-v1'),
      );
      final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
      final box = await _aead.encrypt(
        utf8.encode(plaintext),
        secretKey: key,
        nonce: nonce,
        aad: utf8.encode('chatify-v1:$conversationId:$peerId'),
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
    required String conversationId,
    required String senderPublicKey,
    required String encryptedPayload,
    String? registeredAccountPublicKey,
  }) async {
    final allEnvelopes = jsonDecode(encryptedPayload);
    if (allEnvelopes is! Map || allEnvelopes[accountId] is! Map) {
      throw StateError('This message has no encrypted envelope for this account.');
    }
    final envelope = Map<String, dynamic>.from(allEnvelopes[accountId] as Map);
    final nonce = base64Decode(envelope['nonce'] as String);
    final cipherText = base64Decode(envelope['ciphertext'] as String);
    final mac = Mac(base64Decode(envelope['mac'] as String));
    if (nonce.length != 12 || mac.bytes.length != 16) {
      throw StateError('Encrypted message authentication data is invalid.');
    }
    final pair = await _loadKeyPair(
      accountId,
      registeredPublicKey: registeredAccountPublicKey,
    );
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
      info: utf8.encode('chatify-message-v1'),
    );
    final clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
      aad: utf8.encode('chatify-v1:$conversationId:$accountId'),
    );
    return utf8.decode(clear);
  }
}
