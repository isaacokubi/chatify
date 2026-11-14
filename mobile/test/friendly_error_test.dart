import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:chatify/main.dart';

void main() {
  group('friendlyErrorMessage', () {
    test('network and timeout failures give a clear connection instruction', () {
      expect(
        friendlyErrorMessage(Exception('SocketException: Failed host lookup')),
        'Connect to the internet or Wi-Fi to continue.',
      );
      expect(
        friendlyErrorMessage(TimeoutException('request timed out')),
        'Connect to the internet or Wi-Fi to continue.',
      );
      expect(
        friendlyErrorMessage(Exception('XMLHttpRequest error')),
        'Connect to the internet or Wi-Fi to continue.',
      );
    });

    test('HTTP authorization and service errors are user friendly', () {
      expect(friendlyErrorMessage(const ApiException(401, 'Unauthorized')),
          'Your session has expired. Please sign in again.');
      expect(friendlyErrorMessage(const ApiException(403, 'Forbidden')),
          'You don’t have permission to do that.');
      expect(friendlyErrorMessage(const ApiException(503, 'Unavailable')),
          'Service is temporarily unavailable. Please try again shortly.');
    });

    test('technical response details are never shown to users', () {
      expect(
        friendlyErrorMessage(
          const ApiException(502, 'Chatify API returned invalid JSON for /api/users'),
        ),
        'Service is temporarily unavailable. Please try again shortly.',
      );
      expect(
        friendlyErrorMessage(Exception('FormatException: Unexpected token')),
        'Something went wrong. Please try again.',
      );
    });

    test('clear validation messages remain actionable', () {
      expect(
        friendlyErrorMessage(const ApiException(400, 'Enter a valid phone number.')),
        'Enter a valid phone number.',
      );
    });
  });
}
