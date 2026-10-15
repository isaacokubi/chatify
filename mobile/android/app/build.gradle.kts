plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material belongs in the build environment, never in the repository.
val releaseKeystorePath = System.getenv("CHATIFY_ANDROID_KEYSTORE_PATH")
val releaseKeystorePassword = System.getenv("CHATIFY_ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = System.getenv("CHATIFY_ANDROID_KEY_ALIAS")
val releaseKeyPassword = System.getenv("CHATIFY_ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseKeystorePath,
    releaseKeystorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }
val buildingRelease = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if (buildingRelease && !hasReleaseSigning) {
    throw GradleException(
        "Release builds require CHATIFY_ANDROID_KEYSTORE_PATH, " +
            "CHATIFY_ANDROID_KEYSTORE_PASSWORD, CHATIFY_ANDROID_KEY_ALIAS, and " +
            "CHATIFY_ANDROID_KEY_PASSWORD. Configure them in the build environment."
    )
}

android {
    namespace = "com.example.chatify"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Replace the sample ID with an organization-owned ID before publishing to an app store.
        applicationId = "com.example.chatify"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Never sign a release artifact with the publicly known Android debug key.
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.create("release") {
                    storeFile = file(requireNotNull(releaseKeystorePath))
                    storePassword = releaseKeystorePassword
                    keyAlias = releaseKeyAlias
                    keyPassword = releaseKeyPassword
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
