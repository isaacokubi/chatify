# Android APK builds and installation troubleshooting

Chatify's Android project lives in this directory. Use an ABI-specific **release** APK for direct distribution; do not distribute a debug APK as a production build.

## Build locally

From the repository root:

```sh
cd mobile
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build apk --release --split-per-abi \
  --dart-define=CHATIFY_API=https://chatify-api-c1eh.onrender.com
```

The release build requires signing variables because `android/app/build.gradle.kts` deliberately refuses unsigned or debug-key-signed release artifacts. Set these variables in your shell or CI secret store:

- `CHATIFY_ANDROID_KEYSTORE_PATH`: path to your existing release keystore
- `CHATIFY_ANDROID_KEYSTORE_PASSWORD`
- `CHATIFY_ANDROID_KEY_ALIAS`
- `CHATIFY_ANDROID_KEY_PASSWORD`

**Keep the same keystore and alias used for any installed release.** If the signing certificate changes, Android may reject an update with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Never commit the keystore or passwords to Git.

The output directory is `build/app/outputs/flutter-apk/`. The split build creates architecture-specific APKs such as `app-arm64-v8a-release.apk` and `app-armeabi-v7a-release.apk`. Share only the APK matching the target phone's supported ABI. Keep the generated `build/symbols` directory safe when obfuscation is enabled.

## Size analysis

Start by identifying what is large rather than removing dependencies blindly:

```sh
flutter build apk --release --target-platform android-arm64 --analyze-size \
  --dart-define=CHATIFY_API=https://chatify-api-c1eh.onrender.com
```

Inspect the resulting size-analysis report and the repository's assets. Compress large images and audio, avoid shipping videos or documents that can be downloaded when needed, and remove assets/dependencies only after verifying that app features do not use them. ABI splitting removes native libraries for other CPU architectures from each APK; it does not remove large assets shared by every build.

For a smaller obfuscated ABI-specific release, after confirming the app works:

```sh
flutter build apk --release --split-per-abi --obfuscate \
  --split-debug-info=build/symbols \
  --dart-define=CHATIFY_API=https://chatify-api-c1eh.onrender.com
```

Obfuscation is not a guaranteed large size reduction. Back up the symbol files for each release so crash traces can be decoded later.

## Diagnose "App not installed" on a Samsung Galaxy A03

1. Check the phone's supported ABI:

   ```sh
   adb shell getprop ro.product.cpu.abilist
   ```

2. Check free internal storage and make sure the APK download completed.
3. If an older Chatify installation exists, **do not uninstall it until its local data is backed up**. An APK signed with a different key cannot update that installation.
4. Connect the phone with USB debugging enabled and capture the precise package-manager error:

   ```sh
   adb devices
   adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
   ```

   Choose the output APK that matches the ABI reported by the phone. The error code helps distinguish signing conflicts, ABI mismatch, version downgrade, storage exhaustion, and malformed APKs. Do not lower `minSdk` or change the application ID without evidence that it is needed.

## GitHub Actions release builds

The `.github/workflows/android-apk.yml` workflow runs analysis and tests, then builds signed, split release APKs when the repository variable `CHATIFY_RELEASE_SIGNING_ENABLED` is set to `true` and the required repository secrets are configured:

- `CHATIFY_ANDROID_KEYSTORE_BASE64` — base64-encoded existing keystore
- `CHATIFY_ANDROID_KEYSTORE_PASSWORD`
- `CHATIFY_ANDROID_KEY_ALIAS`
- `CHATIFY_ANDROID_KEY_PASSWORD`

The workflow uploads ABI-specific release APKs and obfuscation symbols as separate artifacts. Without release signing configured, it uploads an ARM64 debug APK clearly marked for testing only. Configure the repository variable and secrets under **Settings → Secrets and variables → Actions**. Never replace an existing production keystore with a new one merely to make the workflow pass.
