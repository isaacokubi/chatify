plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Production signing material belongs in the build environment, never in the repository.
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

// This opt-in is only for installable QA builds. The Android debug key is public and
// MUST NOT be used for Play Store or customer production distribution.
val allowDebugSignedRelease = System.getenv("CHATIFY_ALLOW_DEBUG_RELEASE_SIGNING") == "true"
val buildingRelease = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if (buildingRelease && !hasReleaseSigning && !allowDebugSignedRelease) {
    throw GradleException(
        "Release builds require production signing credentials, or explicitly set " +
            "CHATIFY_ALLOW_DEBUG_RELEASE_SIGNING=true for a test-only debug-key-signed build."
    )
}

android {
    namespace = "com.example.chatify"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Replace this sample ID with an organization-owned ID before publishing.
        applicationId = "com.example.chatify"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            when {
                hasReleaseSigning -> {
                    signingConfig = signingConfigs.create("release") {
                        storeFile = file(requireNotNull(releaseKeystorePath))
                        storePassword = releaseKeystorePassword
                        keyAlias = releaseKeyAlias
                        keyPassword = releaseKeyPassword
                    }
                }
                allowDebugSignedRelease -> signingConfig = signingConfigs.getByName("debug")
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
