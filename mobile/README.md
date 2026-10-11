# Chatify mobile

Flutter client for the existing Chatify Express API. From this directory:

```sh
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=CHATIFY_API=http://10.0.2.2:5000
```

The default API address is for the Android emulator. For a physical device use a reachable development host; for a deployed API pass its HTTPS origin with `--dart-define=CHATIFY_API=https://your-api.example`.

Firebase platform configuration is optional for local development. Without it, chat works while push notifications remain unavailable. See the repository [development guide](../docs/DEVELOPMENT.md) and [demo guide](../docs/DEMO.md) for backend setup, mock payments, and Daraja sandbox configuration.
