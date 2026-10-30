import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.archstudios.arch_player"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.archstudios.arch_player"
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
        // ABI splits are handled per-build invocation
        // (--split-per-abi); no static filter here (a static ndk
        // abiFilters block conflicts with splits and is ignored
        // for Cargokit-provided libs anyway).
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            } else if (System.getenv("ANDROID_KEYSTORE_PATH") != null) {
                // CI: secrets arrive as env (see release.yml), no file.
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
                storeFile = file(System.getenv("ANDROID_KEYSTORE_PATH"))
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    val hasReleaseKey = keystorePropertiesFile.exists() ||
        System.getenv("ANDROID_KEYSTORE_PATH") != null

    buildTypes {
        release {
            // Shared release key when key.properties exists (local) or the
            // CI env is present, otherwise the machine debug key so
            // `flutter run --release` works.
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
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

dependencies {
    // Spike ONLY: real OkHttp for the transport discrimination test
    // (transport_spike.dart). Nothing in playback touches this.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // PINNED (Scylla gate): NewPipeExtractor v0.26.5, TeamNewPipe,
    // GPLv3 (repo LICENSE is GPLv3, so this is compatible).
    // Record: com.github.TeamNewPipe:NewPipeExtractor:v0.26.5
    // (JitPack, August 2026). Stream-ticket backend for Archtube
    // video mode; the home-grown InnerTube client stays the default
    // until the extractor passes on-device. Do NOT bump without
    // recording the new version here and in ExtractorBridge.kt.
    implementation("com.github.TeamNewPipe:NewPipeExtractor:v0.26.5")
}
