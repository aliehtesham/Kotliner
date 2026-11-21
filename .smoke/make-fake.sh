#!/usr/bin/env bash
# Rebuilds the throwaway "fake Kotlin Android project" + gradlew shim used by
# the E2E test (npm-run smoke uses mock data only; --e2e drives a real build
# through the shimmed wrapper). The signing keystore is generated with the
# machine's real keytool (JDK is a prerequisite of the app itself).
#   usage: bash .smoke/make-fake.sh
set -euo pipefail
cd "$(dirname "$0")"
rm -rf fake-project
mkdir -p fake-project/app/src/main fake-project/gradle/wrapper fake-project/scripts

cat > fake-project/settings.gradle <<'EOF'
rootProject.name = "Fake App"
include ':app'
EOF

cat > fake-project/gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx1024m
EOF

cat > fake-project/gradle/wrapper/gradle-wrapper.properties <<'EOF'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.9-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOF

cat > fake-project/app/build.gradle <<'EOF'
plugins {
    id 'com.android.application'
}

android {
    namespace 'com.example.fake'
    compileSdk 34

    defaultConfig {
        applicationId "com.example.fake"
        minSdk 24
        targetSdk 34
        versionName "1.0.2"
        versionCode 10002
    }
}
EOF

cat > fake-project/app/src/main/AndroidManifest.xml <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="Fake App" />
</manifest>
EOF

# The gradle shim: stands in for a full Android build. Honors the same env the
# real pipeline passes and produces split APKs (the injected ABI splits) or an
# AAB, so the collect phase sees realistic output names.
cat > fake-project/gradlew <<'GW'
#!/usr/bin/env bash
echo "Gradle shim"
echo "> Task :app:preBuild UP-TO-DATE"
echo "> Task :app:compileReleaseKotlin"
if [ "${FAIL_SHIM:-0}" = "1" ]; then
  echo "> Task :app:packageRelease FAILED"
  echo "FAILURE: Build failed with an exception."
  exit 1
fi
mkdir -p app/build/outputs/apk/release app/build/outputs/bundle/release
case "$*" in
  *bundleRelease*)
    echo "app-release.aab built" > app/build/outputs/bundle/release/app-release.aab
    ;;
  *)
    for a in $(echo "${ARCHS:-arm64-v8a}" | tr ',' ' '); do
      echo "app-$a-release.apk built" > "app/build/outputs/apk/release/app-$a-release.apk"
    done
    ;;
esac
echo "BUILD SUCCESSFUL in 3s"
GW
chmod +x fake-project/gradlew

# Persistent signing key with the e2e credentials (alias test.alias,
# keypass testpass123, storepass storepass123) so the keystore phase's
# keytool validation passes — and KEYFAIL runs (wrong passwords) fail.
if ! command -v keytool > /dev/null 2>&1; then
  echo "keytool not found — install a JDK (the app's own deps page offers one)."
  exit 1
fi
gen_key() {
  if [ ! -f "$1/android-key.jks" ]; then
    keytool -genkeypair -v -keystore "$1/android-key.jks" \
      -alias test.alias -keypass testpass123 -storepass storepass123 \
      -keyalg RSA -keysize 2048 -validity 10000 -deststoretype JKS \
      -dname "CN=Fake App, O=App, C=US" > /dev/null 2>&1
  fi
}
mkdir -p fake-project/android-key
gen_key fake-project/android-key

# ---------------------------------------------------------------------------
# Second fixture: a Compose Multiplatform-shaped project — the app module is
# composeApp/ (Kotlin DSL) and the Android plugin is applied through a
# version-catalog alias, with SDK levels read from the catalog too. Exercises
# the alias detection and catalog-ref parsing that plain app/ projects miss.
rm -rf fake-kmp
mkdir -p fake-kmp/composeApp/src/main fake-kmp/gradle/wrapper

cat > fake-kmp/settings.gradle.kts <<'EOF'
rootProject.name = "Fake KMP"
include(":composeApp")
EOF

cat > fake-kmp/gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx1024m
EOF

cat > fake-kmp/gradle/wrapper/gradle-wrapper.properties <<'EOF'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.9-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOF

cat > fake-kmp/gradle/libs.versions.toml <<'EOF'
[versions]
agp = "8.7.2"
kotlin = "2.0.21"
android-minSdk = "24"
android-targetSdk = "34"
android-compileSdk = "34"

[libraries]

[plugins]
kotlinMultiplatform = { id = "org.jetbrains.kotlin.multiplatform", version.ref = "kotlin" }
androidApplication = { id = "com.android.application", version.ref = "agp" }
EOF

cat > fake-kmp/composeApp/build.gradle.kts <<'EOF'
plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidApplication)
}

kotlin {
    androidTarget()
}

android {
    namespace = "com.example.fakekmp"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "com.example.fakekmp"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = 10002
        versionName = "1.0.2"
    }
}
EOF

cat > fake-kmp/composeApp/src/main/AndroidManifest.xml <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="Fake KMP" />
</manifest>
EOF

cat > fake-kmp/gradlew <<'GW'
#!/usr/bin/env bash
echo "Gradle shim (composeApp)"
echo "> Task :composeApp:preBuild UP-TO-DATE"
echo "> Task :composeApp:compileReleaseKotlin"
if [ "${FAIL_SHIM:-0}" = "1" ]; then
  echo "> Task :composeApp:packageRelease FAILED"
  echo "FAILURE: Build failed with an exception."
  exit 1
fi
mkdir -p composeApp/build/outputs/apk/release composeApp/build/outputs/bundle/release
case "$*" in
  *bundleRelease*)
    echo "app-release.aab built" > composeApp/build/outputs/bundle/release/app-release.aab
    ;;
  *)
    for a in $(echo "${ARCHS:-arm64-v8a}" | tr ',' ' '); do
      echo "app-$a-release.apk built" > "composeApp/build/outputs/apk/release/app-$a-release.apk"
    done
    ;;
esac
echo "BUILD SUCCESSFUL in 3s"
GW
chmod +x fake-kmp/gradlew

mkdir -p fake-kmp/android-key
gen_key fake-kmp/android-key

echo "fake projects + gradlew shims ready in .smoke/"
