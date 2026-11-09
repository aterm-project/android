plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Package only the ABIs Flutter actually compiled the engine and AOT code for.
// Flutter's Gradle plugin (FlutterPlugin.configureAbiWithoutSplits) resets
// defaultConfig.ndk.abiFilters to every supported ABI during plugin apply,
// whatever -Ptarget-platform was. Plugins that ship their own .so files
// (jni, datastore, flutter_pty) then add an armeabi-v7a directory without
// libflutter.so/libapp.so to `--target-platform android-arm64,android-x64`
// APKs, so 32-bit ARM devices could install an app that cannot start.
// This block runs after the plugin's apply(), so its filters take precedence.
// Mirrors FlutterPluginUtils.getTargetPlatforms / PLATFORM_ARCH_MAP and the
// split-per-abi and disable-abi-filtering properties of the Flutter SDK in use;
// without -Ptarget-platform (plain Gradle/IDE builds) Flutter's default of all
// supported ABIs is left unchanged.
val flutterPlatformAbis = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x64" to "x86_64",
)
val flutterTargetAbis: List<String>? =
    project.findProperty("target-platform")?.toString()?.split(",")?.map { platform ->
        flutterPlatformAbis[platform] ?: throw GradleException("Invalid platform: $platform")
    }
val flutterSplitPerAbi = project.findProperty("split-per-abi")?.toString()?.toBoolean() ?: false
val flutterDisableAbiFiltering =
    project.findProperty("disable-abi-filtering")?.toString()?.toBoolean() ?: false
// Split-per-ABI builds already include only the target ABIs (and AGP rejects
// abiFilters combined with ABI splits); disable-abi-filtering is Flutter's
// explicit opt-out.
val flutterAbiFilters: List<String>? =
    if (flutterSplitPerAbi || flutterDisableAbiFiltering) null else flutterTargetAbis

// Embedded RDP engine built from source by
// apps/client/native/desktop/android/build_engine.sh (FreeRDP + OpenSSL linked
// into one libatermius_rdp.so per ABI). -Patermius.rdpEngineDir=<OUT> (or
// ATERMIUS_ANDROID_RDP_ENGINE_DIR) packages OUT/jniLibs/<abi>/libatermius_rdp.so
// and its licenses. Without it the APK has no RDP engine and Android RDP
// reports that the engine is unavailable; it never falls back to a local
// guacd. -Patermius.requireRdpEngine=true turns a missing engine into a build
// failure. The engine is built for arm64-v8a and x86_64 only.
val rdpEngineSupportedAbis = listOf("arm64-v8a", "x86_64")
val rdpEngineDir: File? =
    (project.findProperty("atermius.rdpEngineDir")?.toString()
        ?: System.getenv("ATERMIUS_ANDROID_RDP_ENGINE_DIR"))
        ?.takeIf { it.isNotBlank() }
        ?.let { file(it) }
val requireRdpEngine =
    project.findProperty("atermius.requireRdpEngine")?.toString()?.toBoolean() ?: false
if (rdpEngineDir != null || requireRdpEngine) {
    val dir = rdpEngineDir
        ?: throw GradleException("atermius.requireRdpEngine=true needs -Patermius.rdpEngineDir")
    val abis = flutterTargetAbis?.filter { it in rdpEngineSupportedAbis } ?: rdpEngineSupportedAbis
    val missing = abis.filter { !File(dir, "jniLibs/$it/libatermius_rdp.so").isFile }
    if (missing.isNotEmpty()) {
        throw GradleException("RDP engine missing for $missing in $dir (run build_engine.sh)")
    }
}

android {
    namespace = "com.atermius.aterm_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.atermius.aterm_client"
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
        flutterAbiFilters?.let { abis ->
            ndk {
                abiFilters.clear()
                abiFilters.addAll(abis)
            }
        }
    }

    rdpEngineDir?.let { dir ->
        sourceSets.getByName("main") {
            jniLibs.srcDir(File(dir, "jniLibs"))
            // Apache-2.0 notices for FreeRDP and OpenSSL ship with the engine.
            assets.srcDir(File(dir, "assets"))
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
