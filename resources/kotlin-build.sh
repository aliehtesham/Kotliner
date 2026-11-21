#!/usr/bin/env bash
# Kotliner - generalized local release builder for any Kotlin Android (Gradle)
# project. Same pipeline contract as upstream Expo Builder's expo-build.sh.
#
# Invoked by the Electron app (main.js) as:
#   bash kotlin-build.sh <PROJECT_DIR>
#
# Configuration arrives via environment variables:
#   APP_NAME            display name (artifact names + certificate CN)
#   APP_VERSION         semver (already written as KT_VERSION_* overrides by the app)
#   SIGNED              1 = generate/reuse keystore & sign, 0 = unsigned build
#   KEY_ALIAS           keystore alias
#   KEY_PASSWORD        key password
#   KEYSTORE_PASSWORD   keystore password
#   KEY_COUNTRY         2-letter country code for the certificate dname
#   FORMAT              apk | aab
#   ARCHS               comma list of ABIs for the injected splits block (apk)
#   RELOCATE            1 = move heavy gradle dirs to RELOCATE_ROOT (default 1)
#   RELOCATE_ROOT       msys path on a big disk, default /c/KotlinerBuilds
#   TARGET_SDK          optional targetSdk (API level) pin for this build
#   DEBUG               1 = set -x + gradle --stacktrace --info
#   ALLOW_DEBUG_SIGNED  passthrough guard for a project's verify-signing.sh
#   KEYSTORE_BASE64     optional base64 of an existing keystore to reuse
#
# Progress protocol printed to stdout (parsed by main.js, never shown raw):
#   @@PHASE <id>        build phase changed
#   @@ARTIFACT <path>   produced output file (path relative to project root)
#   @@KEYSTORE <path>   persistent keystore that was used/created
#   @@DONE              success
set -euo pipefail

PROJECT_DIR="${1:?missing PROJECT_DIR argument}"
cd "$PROJECT_DIR"

if [ "${DEBUG:-0}" = "1" ]; then set -x; fi

APP_NAME="${APP_NAME:?APP_NAME required}"
APP_VERSION="${APP_VERSION:?APP_VERSION required}"
FORMAT="${FORMAT:-apk}"
ARCHS="${ARCHS:-arm64-v8a,armeabi-v7a,x86,x86_64}"
SIGNED="${SIGNED:-1}"
RELOCATE="${RELOCATE:-1}"
RELOCATE_ROOT="${RELOCATE_ROOT:-/c/KotlinerBuilds}"
ALLOW_DEBUG_SIGNED="${ALLOW_DEBUG_SIGNED:-0}"

# Strip characters that are unsafe in Windows filenames / gradle property values.
SAFE_NAME=$(printf '%s' "$APP_NAME" | tr -d '/\\:*?"<>|' | tr ' ' '_')

export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
export GRADLE_OPTS="-Dorg.gradle.jvmargs=-Xmx4096m -XX:MaxMetaspaceSize=1024m -Dkotlin.compiler.execution.strategy=in-process"

say()   { printf '%s\n' "$*"; }
phase() { printf '@@PHASE %s\n' "$1"; }
artifact() { printf '@@ARTIFACT %s\n' "$1"; }

# ----------------------------------------------------------------------- module
# Locate the Android application module: the conventional app/ first, else the
# first top-level module whose build file applies com.android.application —
# directly or through a version-catalog alias, e.g. Compose Multiplatform's
# alias(libs.plugins.androidApplication). Alias keys are resolved from
# gradle/libs.versions.toml; the two common spellings are always accepted.
android_app_module_pattern() {
  local f="gradle/libs.versions.toml" keys k
  local pat='com\.android\.application|libs\.plugins\.android[.-]?[Aa]pplication\b'
  if [ -f "$f" ]; then
    keys=$(awk '/^\[/{p=($0=="[plugins]");next} p{print}' "$f" | tr '\n' ' ' \
      | grep -oE '[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*\{[^{}]*com\.android\.application' \
      | sed -E 's/[[:space:]]*=.*//' || true)
    for k in $keys; do
      pat="$pat|libs\\.plugins\\.$(printf '%s' "$k" | sed -E 's/-/[.-]/g')\\b"
    done
  fi
  printf '%s' "$pat"
}

find_module() {
  local d bf pat
  pat=$(android_app_module_pattern)
  for d in app $(ls -d */ 2>/dev/null | tr -d '/' | grep -vE '^(app|build|gradle|scripts|android-key.*|\.|src)$' || true); do
    [ -d "$d" ] || continue
    for bf in build.gradle.kts build.gradle; do
      if [ -f "$d/$bf" ] && grep -qE "$pat" "$d/$bf"; then
        MODULE="$d"
        MOD_BUILD="$d/$bf"
        return 0
      fi
    done
  done
  return 1
}

MODULE=""
MOD_BUILD=""
if ! find_module; then
  say "ERROR: no Android application module found (a build file applying com.android.application, directly or via a version-catalog alias)."
  exit 1
fi
say "Android application module: $MODULE ($(basename "$MOD_BUILD"))"
KTS=0
case "$MOD_BUILD" in *.kts) KTS=1 ;; esac

# ----------------------------------------------------------------------- wrapper
phase dependencies
# A Kotlin/Gradle project needs no dependency fetch here — Gradle resolves its
# own dependencies during the build. Only the runner is established: the
# project's wrapper (preferred, pins the Gradle version) or a system gradle.
RUNNER=""
if [ -x ./gradlew ] || [ -f ./gradlew ]; then
  chmod +x ./gradlew
  RUNNER="./gradlew"
  say "Using the project's Gradle wrapper."
elif command -v gradle > /dev/null 2>&1; then
  RUNNER="gradle"
  say "No Gradle wrapper found - falling back to system gradle ($(gradle --version 2>/dev/null | grep -m1 '^Gradle ' || echo 'unknown version'))."
  say "  Adding a wrapper (gradle wrapper) is recommended so builds are reproducible."
else
  say "ERROR: neither gradlew nor a system gradle was found."
  say "  Open the project in Android Studio once (it installs the wrapper) or run 'gradle wrapper'."
  exit 1
fi

# ----------------------------------------------------------------------- prepare
# Redirect heavy Gradle output to another (bigger) disk via NTFS junctions so
# builds don't fill the project drive.
is_junction() {
  powershell -NoProfile -Command "(Get-Item -LiteralPath '$(cygpath -w "$1")' -Force -ErrorAction SilentlyContinue).LinkType" 2>/dev/null
}

ensure_junction() {
  local link="$1" target="$2" linktype
  linktype=$(is_junction "$link")
  if [ -d "$link" ] && [ -z "$linktype" ]; then
    say "Relocating $link to $target (drive protection)..."
    rm -rf "$target"
    # mv does not create intermediate dirs - the target chain
    # (e.g. <RELOCATE_ROOT>/<project>/build) must exist first.
    if mkdir -p "$(dirname "$target")" && mv "$link" "$target"; then
      :
    else
      say "WARNING: could not relocate $link (locked or unwritable target) - keeping it in the project and continuing without this redirect."
      return 0
    fi
  fi
  if [ ! -d "$target" ]; then
    if ! mkdir -p "$target"; then
      say "WARNING: could not create $target - continuing without this redirect."
      return 0
    fi
  fi
  if [ ! -d "$link" ]; then
    if ! cmd //c mklink //J "$(cygpath -w "$link")" "$(cygpath -w "$target")" > /dev/null; then
      say "WARNING: could not create the junction at $link - continuing without this redirect."
      return 0
    fi
  fi
}

if [ "$RELOCATE" = "1" ]; then
  phase prepare
  PROJ_ID=$(grep -m1 -E 'rootProject\.name' settings.gradle* 2>/dev/null | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true)
  [ -n "${PROJ_ID:-}" ] || PROJ_ID=$(basename "$PWD")
  PROJ_ID=$(printf '%s' "$PROJ_ID" | tr -d '/\\:*?"<>| ')
  say "Redirecting heavy Gradle output to $RELOCATE_ROOT/$PROJ_ID ..."
  ensure_junction "build"          "$RELOCATE_ROOT/$PROJ_ID/build"
  ensure_junction ".gradle"        "$RELOCATE_ROOT/$PROJ_ID/.gradle"
  ensure_junction "$MODULE/build"  "$RELOCATE_ROOT/$PROJ_ID/$MODULE--build"
  ensure_junction "$MODULE/.cxx"   "$RELOCATE_ROOT/$PROJ_ID/$MODULE--.cxx"
fi

# --------------------------------------------------------------------- keystore
JKS_PATH="$MODULE/${SAFE_NAME}.v${APP_VERSION}.jks"
KEY_DIR="android-key"
KEY_ALIAS="${KEY_ALIAS:-}"
KEY_PASSWORD="${KEY_PASSWORD:-}"
KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-}"
DNAME="CN=${APP_NAME}, O=App, C=${KEY_COUNTRY:-US}"

validate_keystore() {
  keytool -list -keystore "$1" -alias "$SAFE_ALIAS" -storepass "$SAFE_STORE_PASS" -keypass "$SAFE_KEY_PASS" > /dev/null 2>&1
}

generate_keystore() {
  keytool -genkeypair -v -keystore "$1" -alias "$SAFE_ALIAS" -keypass "$SAFE_KEY_PASS" -storepass "$SAFE_STORE_PASS" \
    -keyalg RSA -keysize 2048 -validity 10000 -deststoretype JKS -dname "$DNAME"
}

SIGNED_FROM=""
KEYSTORE_REPORT=""
TARGET_SDK="${TARGET_SDK:-}"
if [ "$SIGNED" = "1" ]; then
  phase keystore
  SAFE_ALIAS="$KEY_ALIAS"
  SAFE_KEY_PASS="$KEY_PASSWORD"
  SAFE_STORE_PASS="$KEYSTORE_PASSWORD"

  if [ -n "${KEYSTORE_BASE64:-}" ]; then
    say "Found KEYSTORE_BASE64. Decoding to $JKS_PATH..."
    echo "$KEYSTORE_BASE64" | tr -d '\n\r ' | base64 -d > "$JKS_PATH"
    if validate_keystore "$JKS_PATH"; then
      say "Keystore from KEYSTORE_BASE64 is VALID. Proceeding..."
      SIGNED_FROM="$JKS_PATH (from KEYSTORE_BASE64)"
    else
      say "Keystore from KEYSTORE_BASE64 is INVALID! Removing it and generating a new one..."
      rm -f "$JKS_PATH"
      generate_keystore "$JKS_PATH"
      SIGNED_FROM="$JKS_PATH (regenerated)"
    fi
    KEYSTORE_REPORT="$JKS_PATH"
  else
    # Persistent signing key: the 'android-key/' folder at the project root.
    # If it contains a .jks file it is reused for every build (commit it so the
    # key is never lost); otherwise a new one is generated there once.
    mkdir -p "$KEY_DIR"
    keyfile=$(ls "$KEY_DIR"/*.jks 2>/dev/null | sort | head -n 1 || true)
    if [ -n "$keyfile" ]; then
      keycount=$(ls "$KEY_DIR"/*.jks 2>/dev/null | wc -l)
      if [ "$keycount" -gt 1 ]; then
        say "WARNING: Multiple .jks files in '$KEY_DIR/' - using '$keyfile'. Remove the extras to avoid ambiguity."
      fi
      say "Using keystore '$keyfile'..."
      cp "$keyfile" "$JKS_PATH"
      if validate_keystore "$JKS_PATH"; then
        say "Keystore is VALID and matches the credentials. Proceeding..."
      else
        say "Keystore '$keyfile' is INVALID for alias '$SAFE_ALIAS' with the configured passwords. Build aborted."
        say "  The file was NOT modified. Options:"
        say "    - pass matching key alias / passwords in the form, or"
        say "    - archive '$KEY_DIR/' and rebuild to generate a fresh key."
        # Machine-readable marker: the renderer offers to archive the old key.
        printf '@@KEYFAIL %s\n' "$keyfile"
        exit 1
      fi
      SIGNED_FROM="$keyfile"
      KEYSTORE_REPORT="$keyfile"
    else
      say "No .jks found in '$KEY_DIR/'. Generating a NEW one at '$KEY_DIR/android-key.jks'..."
      say "  Keep / commit this file so the signing key is never lost."
      generate_keystore "$KEY_DIR/android-key.jks"
      cp "$KEY_DIR/android-key.jks" "$JKS_PATH"
      SIGNED_FROM="$KEY_DIR/android-key.jks (newly generated)"
      KEYSTORE_REPORT="$KEY_DIR/android-key.jks"
    fi
  fi
  printf '@@KEYSTORE %s\n' "$KEYSTORE_REPORT"
fi

# ---------------------------------------------------------------- gradle config
# Kotliner's overrides live in two managed places, re-created on every build:
#   gradle.properties   build-scoped properties (signing credentials, ABI
#                       splits, target-SDK pin). KT_VERSION_* written earlier
#                       by the app are left untouched.
#   <module>/build.gradle(.kts)   a single "Kotliner build block" wiring those
#                       properties into the Android plugin. Re-created every
#                       run, so nothing leaks into the project's own files.
[ -f gradle.properties ] || touch gradle.properties
# NOTE: this sed must run BEFORE the append group below - an in-place rewrite
# inside a redirected group orphans the group's remaining output on Windows
# (sed -i replaces the file inode).
sed -i -e '/^MYAPP_UPLOAD_/d' -e '/^KT_ABIS/d' -e '/^KT_TARGET_SDK/d' -e '/^KT_COMPILE_SDK/d' -e '/^# Kotliner build properties/d' gradle.properties
{
  echo ""
  echo "# Kotliner build properties (auto-generated, re-created every build)"
  if [ "$SIGNED" = "1" ]; then
    echo "MYAPP_UPLOAD_STORE_FILE=${SAFE_NAME}.v${APP_VERSION}.jks"
    echo "MYAPP_UPLOAD_STORE_PASSWORD=$KEYSTORE_PASSWORD"
    echo "MYAPP_UPLOAD_KEY_ALIAS=$KEY_ALIAS"
    echo "MYAPP_UPLOAD_KEY_PASSWORD=$KEY_PASSWORD"
  fi
  if [ "$FORMAT" = "apk" ]; then
    echo "KT_ABIS=$ARCHS"
  fi
  if [ -n "$TARGET_SDK" ]; then
    echo "KT_TARGET_SDK=$TARGET_SDK"
  fi
} >> gradle.properties

# AGP rejects targetSdk > compileSdk; raise compileSdk to match when the
# module's own declaration is lower. A literal compileSdk is read directly; a
# catalog reference (Compose Multiplatform style:
# compileSdk = libs.versions.android.compileSdk.get().toInt()) is resolved
# through the [versions] table of gradle/libs.versions.toml.
toml_version_value() {
  local k="$1" f="gradle/libs.versions.toml"
  [ -f "$f" ] || return 0
  awk -v key="$k" '
    /^\[/{p=($0=="[versions]");next}
    p && /=/ {
      line=$0; sub(/^[[:space:]]*/, "", line)
      eq=index(line, "="); lk=substr(line, 1, eq-1)
      gsub(/[[:space:]]/, "", lk)
      if (lk==key) { v=substr(line, eq+1); gsub(/["[:space:]]/, "", v); print v; exit }
    }' "$f"
}

if [ -n "$TARGET_SDK" ]; then
  say "Pinning Android targetSdk=$TARGET_SDK for this build..."
  COMPILE_CURRENT=$(grep -m1 -P '(?<![A-Za-z])compileSdk(Version)?\s*=?\s*[0-9]+' "$MOD_BUILD" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)
  if [ -z "$COMPILE_CURRENT" ]; then
    ref=$(grep -m1 -oP '(?<![A-Za-z])compileSdk\s*=\s*libs\.versions\.[A-Za-z0-9_.]+\s*\.\s*get\(\)' "$MOD_BUILD" 2>/dev/null || true)
    if [ -n "$ref" ]; then
      key=$(printf '%s' "$ref" | sed -E 's/.*libs\.versions\.([A-Za-z0-9_.]+)\s*\.\s*get\(\).*/\1/' | tr '.' '-')
      COMPILE_CURRENT=$(toml_version_value "$key")
      [ -n "$COMPILE_CURRENT" ] && say "compileSdk comes from the version catalog ($key = $COMPILE_CURRENT)."
    fi
  fi
  if [ -z "$COMPILE_CURRENT" ] || [ "$TARGET_SDK" -gt "$COMPILE_CURRENT" ]; then
    say "compileSdk is ${COMPILE_CURRENT:-undeclared} - raising it to $TARGET_SDK (targetSdk must not exceed compileSdk)."
    echo "KT_COMPILE_SDK=$TARGET_SDK" >> gradle.properties
  fi
  if [ -n "$ANDROID_HOME" ] && [ ! -d "$ANDROID_HOME/platforms/android-$TARGET_SDK" ]; then
    say "NOTE: platform android-$TARGET_SDK is not installed - install it via the Dependencies page if the gradle build fails to find it."
  fi
fi

# Drop the previous build block, then append a fresh one (Groovy or Kotlin DSL
# to match the module's build file). The version-override block written by the
# app uses a different marker and is preserved.
sed -i '/Kotliner build block (auto-generated/,/end Kotliner build block/d' "$MOD_BUILD"

if [ "$KTS" = "1" ]; then
  {
    echo ""
    echo "// ── Kotliner build block (auto-generated, re-created every build) ──"
    if [ "$SIGNED" = "1" ]; then
      cat <<'EOB'
if (project.hasProperty("MYAPP_UPLOAD_STORE_FILE")) {
    android {
        signingConfigs {
            create("ktUpload") {
                storeFile = file(project.property("MYAPP_UPLOAD_STORE_FILE") as String)
                storePassword = project.property("MYAPP_UPLOAD_STORE_PASSWORD") as String
                keyAlias = project.property("MYAPP_UPLOAD_KEY_ALIAS") as String
                keyPassword = project.property("MYAPP_UPLOAD_KEY_PASSWORD") as String
            }
        }
        buildTypes {
            getByName("release") {
                signingConfig = signingConfigs.getByName("ktUpload")
            }
        }
    }
}
EOB
    fi
    if [ "$FORMAT" = "apk" ]; then
      cat <<'EOB'
if (project.hasProperty("KT_ABIS")) {
    android {
        splits {
            abi {
                isEnable = true
                reset()
                include(*project.property("KT_ABIS").toString().split(",").map { it.trim() }.filter { it.isNotEmpty() }.toTypedArray())
                isUniversalApk = false
            }
        }
    }
}
EOB
    fi
    if [ -n "$TARGET_SDK" ]; then
      cat <<'EOB'
if (project.hasProperty("KT_TARGET_SDK")) {
    android {
        if (project.hasProperty("KT_COMPILE_SDK")) {
            compileSdk = (project.property("KT_COMPILE_SDK") as String).toInt()
        }
        defaultConfig {
            targetSdk = (project.property("KT_TARGET_SDK") as String).toInt()
        }
    }
}
EOB
    fi
    echo "// ── end Kotliner build block ──"
  } >> "$MOD_BUILD"
else
  {
    echo ""
    echo "// ── Kotliner build block (auto-generated, re-created every build) ──"
    if [ "$SIGNED" = "1" ]; then
      cat <<'EOB'
if (project.hasProperty('MYAPP_UPLOAD_STORE_FILE')) {
    android {
        signingConfigs {
            ktUpload {
                storeFile file(MYAPP_UPLOAD_STORE_FILE)
                storePassword MYAPP_UPLOAD_STORE_PASSWORD
                keyAlias MYAPP_UPLOAD_KEY_ALIAS
                keyPassword MYAPP_UPLOAD_KEY_PASSWORD
            }
        }
        buildTypes {
            release {
                signingConfig signingConfigs.ktUpload
            }
        }
    }
}
EOB
    fi
    if [ "$FORMAT" = "apk" ]; then
      cat <<'EOB'
if (project.hasProperty('KT_ABIS')) {
    android {
        splits {
            abi {
                enable true
                reset()
                include(*(project.property('KT_ABIS').split(',').collect { it.trim() }.findAll { it != '' } as String[]))
                universalApk false
            }
        }
    }
}
EOB
    fi
    if [ -n "$TARGET_SDK" ]; then
      cat <<'EOB'
if (project.hasProperty('KT_TARGET_SDK')) {
    android {
        if (project.hasProperty('KT_COMPILE_SDK')) {
            compileSdk KT_COMPILE_SDK.toInteger()
        }
        defaultConfig {
            targetSdk KT_TARGET_SDK.toInteger()
        }
    }
}
EOB
    fi
    echo "// ── end Kotliner build block ──"
  } >> "$MOD_BUILD"
fi

# ----------------------------------------------------------------------- gradle
phase gradle

TASK="assembleRelease"
[ "$FORMAT" = "aab" ] && TASK="bundleRelease"
TASK=":$MODULE:$TASK"

GRADLE_FLAGS="--no-daemon --console=plain -x lint -x lintVitalRelease -x test"
if [ "${DEBUG:-0}" = "1" ]; then
  GRADLE_FLAGS="$GRADLE_FLAGS --stacktrace --info"
fi

say "Running: $RUNNER $TASK $GRADLE_FLAGS"
$RUNNER $TASK $GRADLE_FLAGS

# ---------------------------------------------------------------------- collect
phase collect
shopt -s nullglob
MADE=()
if [ "$FORMAT" = "aab" ]; then
  OUT_DIR="$MODULE/build/outputs/bundle/release"
  for f in "$OUT_DIR"/*.aab; do
    dest="${SAFE_NAME}.v${APP_VERSION}.aab"
    mv "$f" "$dest"
    artifact "$dest"
    MADE+=("$dest")
  done
else
  OUT_DIR="$MODULE/build/outputs/apk/release"
  for f in "$OUT_DIR"/*.apk; do
    b=$(basename "$f")
    abi=""
    case "$b" in
      *arm64-v8a*)   abi="arm64-v8a" ;;
      *armeabi-v7a*) abi="armeabi-v7a" ;;
      *x86_64*)      abi="x86_64" ;;
      *x86*)         abi="x86" ;;
    esac
    dest="${SAFE_NAME}.v${APP_VERSION}${abi:+.$abi}.apk"
    mv "$f" "$dest"
    artifact "$dest"
    MADE+=("$dest")
  done
fi

if [ "${#MADE[@]}" -eq 0 ]; then
  say "ERROR: no output files were produced in $OUT_DIR."
  exit 1
fi

# Optional project-provided signature guard: some projects keep a
# scripts/verify-signing.sh that rejects debug-signed APKs.
if [ "$SIGNED" = "1" ] && [ "$FORMAT" = "apk" ] && [ -f "scripts/verify-signing.sh" ]; then
  phase verify
  if [ "$ALLOW_DEBUG_SIGNED" = "1" ]; then
    say "ALLOW_DEBUG_SIGNED=1 - skipping the debug-signature guard."
  else
    say "Verifying APK signature with scripts/verify-signing.sh..."
    bash scripts/verify-signing.sh "${MADE[0]}"
  fi
fi

for f in "${MADE[@]}"; do
  say "Built: $f"
done
if [ -n "$SIGNED_FROM" ]; then
  say "Signing key: $SIGNED_FROM (persistent in '$KEY_DIR/' - safe to commit)"
fi

phase done
printf '@@DONE\n'
