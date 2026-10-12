import 'package:flutter_test/flutter_test.dart';
import 'package:chatify/main.dart';

void main() {
  group('findReplyTarget', () {
    final original = <String, dynamic>{
      '_id': 'message-123',
      'senderId': 'sender-1',
      'text': 'Please send the report',
    };

    test('resolves a reply reference by message ID', () {
      expect(findReplyTarget([original], 'message-123'), original);
    });

    test('supports populated reply references from API payloads', () {
      expect(
        findReplyTarget([original], {'_id': 'message-123'}),
        original,
      );
    });

    test('returns null when the original is not in this conversation', () {
      expect(findReplyTarget([original], 'message-from-another-chat'), isNull);
      expect(findReplyTarget([], 'message-123'), isNull);
      expect(findReplyTarget([original], null), isNull);
    });

    test('returns a safe map copy of the matched original', () {
      final resolved = findReplyTarget([original], 'message-123')!;
      resolved['text'] = 'changed preview';
      expect(original['text'], 'Please send the report');
    });
  });
}
