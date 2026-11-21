'use strict';
// Pure Node helpers for validating a Kotlin Android (Gradle) project and
// applying version bumps. Usable both from the Electron main process and from
// plain node CLI tests.

import * as fs from 'fs';
import * as path from 'path';

/**
 * Marker comment wrapped around every block Kotliner appends to a build file.
 * Lets re-runs find and replace the managed block instead of stacking copies,
 * and tells the user which part of their build file is app-managed.
 */
const BLOCK_BEGIN = '// ── Kotliner managed block (auto-generated, edits here are overwritten) ──';
const BLOCK_END = '// ── end Kotliner managed block ──';

function readText(file: string): string | null {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }
}

/** Settings file of the Gradle root project (Groovy or Kotlin DSL). */
function findSettingsFile(dir: string): string | null {
  for (const name of ['settings.gradle.kts', 'settings.gradle']) {
    if (fs.existsSync(path.join(dir, name))) return name;
  }
  return null;
}

interface VersionCatalog {
  /** [versions] table: key -> value. */
  versions: Map<string, string>;
  /** [plugins] table: alias key -> plugin id. */
  plugins: Map<string, string>;
}

/**
 * Minimal reader for gradle/libs.versions.toml — just the [versions] and
 * [plugins] tables. Comments are stripped and entries flattened so multi-line
 * plugin declarations parse too.
 */
function parseVersionCatalog(dir: string): VersionCatalog {
  const catalog: VersionCatalog = { versions: new Map(), plugins: new Map() };
  const text = readText(path.join(dir, 'gradle', 'libs.versions.toml'));
  if (!text) return catalog;
  const sections = new Map<string, string>();
  let current = '';
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, '').trim();
    if (!line) continue;
    const header = /^\[([.\w-]+)\]$/.exec(line);
    if (header) {
      current = header[1];
      if (!sections.has(current)) sections.set(current, '');
      continue;
    }
    if (current) sections.set(current, `${sections.get(current)} ${line}`);
  }
  for (const m of (sections.get('versions') ?? '').matchAll(/([\w-]+)\s*=\s*"([^"]*)"/g)) {
    catalog.versions.set(m[1], m[2]);
  }
  for (const m of (sections.get('plugins') ?? '').matchAll(/([\w-]+)\s*=\s*\{([^}]*)\}/g)) {
    const id = /\bid\s*=\s*"([^"]+)"/.exec(m[2]);
    if (id) catalog.plugins.set(m[1], id[1]);
  }
  return catalog;
}

/** 'android.targetSdk' -> 'android-targetSdk' (catalog keys are dash-joined). */
function accessorToKey(p: string): string {
  return p.replace(/\./g, '-');
}

/**
 * Resolve a `libs.versions.android.targetSdk.get()` accessor against the
 * catalog. Returns null when the ref or key is not found.
 */
function resolveVersionRef(catalog: VersionCatalog, raw: string): string | null {
  const m = /libs\.versions\.([\w.]+?)\s*\.\s*get\s*\(\s*\)/.exec(raw);
  if (!m) return null;
  return catalog.versions.get(accessorToKey(m[1])) ?? null;
}

/** Plugin id the Android application module must apply. */
const ANDROID_APP_PLUGIN = 'com.android.application';
// Compose Multiplatform projects usually apply it through a version-catalog
// alias — accept the two common accessor spellings even without a catalog.
const ALIAS_FALLBACK = 'libs\\.plugins\\.android[.-]?[Aa]pplication\\b';

/**
 * Locate the module carrying the Android application plugin. Prefers the
 * conventional `app/` module; otherwise scans first-level folders. The plugin
 * may be applied by its literal id or through a version-catalog alias
 * (`alias(libs.plugins.androidApplication)` — Compose Multiplatform style).
 * Returns { module, buildFile, kts } or null.
 */
function findAppModule(dir: string): { module: string; buildFile: string; kts: boolean } | null {
  const candidates: Array<{ module: string; buildFile: string; kts: boolean }> = [];
  const catalog = parseVersionCatalog(dir);
  const aliasPatterns = [ALIAS_FALLBACK];
  for (const [aliasKey, pluginId] of catalog.plugins) {
    if (pluginId === ANDROID_APP_PLUGIN) {
      // 'android-application' -> libs.plugins.android.application ; the
      // key's own spelling is also accepted verbatim.
      aliasPatterns.push(`libs\\.plugins\\.${escapeRegExp(aliasKey)}\\b`);
      aliasPatterns.push(`libs\\.plugins\\.${aliasKey.split('-').map(escapeRegExp).join('\\.')}\\b`);
    }
  }
  const aliasRe = new RegExp(aliasPatterns.join('|'));
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const dirs = entries.filter((e) => e.isDirectory() && e.name !== 'build' && !e.name.startsWith('.'));
  const ordered = [
    ...dirs.filter((d) => d.name === 'app'),
    ...dirs.filter((d) => d.name !== 'app'),
  ];
  for (const d of ordered) {
    for (const bf of ['build.gradle.kts', 'build.gradle']) {
      const buildFile = path.join(dir, d.name, bf);
      const text = readText(buildFile);
      if (text === null) continue;
      if (new RegExp(`\\b${escapeRegExp(ANDROID_APP_PLUGIN)}\\b`).test(text) || aliasRe.test(text)) {
        return { module: d.name, buildFile, kts: bf.endsWith('.kts') };
      }
      // Remember plain modules as fallback candidates (unlikely used).
      candidates.push({ module: d.name, buildFile, kts: bf.endsWith('.kts') });
    }
  }
  return candidates.length ? candidates[0] : null;
}

interface SdkLevels {
  minSdk: number | null;
  targetSdk: number | null;
  compileSdk: number | null;
}

/**
 * Parse minSdk/targetSdk/compileSdk from a module build file (Groovy or KTS).
 * Literal numbers are read directly; catalog references like the Compose
 * Multiplatform template's `minSdk = libs.versions.android.minSdk.get().toInt()`
 * are resolved through the project's version catalog.
 */
function parseSdkLevels(text: string, catalog: VersionCatalog): SdkLevels {
  const num = (name: string): number | null => {
    const lit = new RegExp(`(?<![A-Za-z])${name}(?:Version)?\\s*=?\\s*(\\d+)`).exec(text);
    if (lit) return Number(lit[1]);
    const ref = new RegExp(`(?<![A-Za-z])${name}(?:Version)?\\s*=\\s*(libs\\.versions\\.[\\w.]+\\s*\\.\\s*get\\s*\\(\\s*\\))`).exec(text);
    if (ref) {
      const v = resolveVersionRef(catalog, ref[1]);
      if (v && /^\d+$/.test(v)) return Number(v);
    }
    return null;
  };
  return {
    minSdk: num('minSdk'),
    targetSdk: num('targetSdk'),
    compileSdk: num('compileSdk'),
  };
}

/** Gradle distribution version from gradle/wrapper/gradle-wrapper.properties. */
function parseGradleWrapperVersion(dir: string): string | null {
  const props = readText(path.join(dir, 'gradle', 'wrapper', 'gradle-wrapper.properties'));
  if (!props) return null;
  const m = /gradle-([\d.]+)-(?:bin|all)\.zip/.exec(props);
  return m ? m[1] : null;
}

/** AGP version from root build files / version catalog — best effort. */
function parseAgpVersion(dir: string): string | null {
  for (const name of ['build.gradle.kts', 'build.gradle', 'settings.gradle.kts', 'settings.gradle']) {
    const text = readText(path.join(dir, name));
    if (!text) continue;
    const m = /com\.android\.tools\.build:gradle:([\d.]+)/.exec(text);
    if (m) return m[1];
    const m2 = /id\(\s*["']com\.android\.application["']\s*\)\s*version\s+["']([\d.]+)["']/.exec(text);
    if (m2) return m2[1];
  }
  for (const toml of ['gradle/libs.versions.toml']) {
    const text = readText(path.join(dir, toml));
    if (!text) continue;
    const m = /^\s*agp\s*=\s*"([\d.]+)"/m.exec(text);
    if (m) return m[1];
  }
  return null;
}

/** Replace or append a managed block inside a build file. */
function upsertManagedBlock(file: string, kts: boolean, blockBody: string): void {
  const current = readText(file) ?? '';
  const block = `${BLOCK_BEGIN}\n${blockBody.trim()}\n${BLOCK_END}`;
  const re = new RegExp(`${escapeRegExp(BLOCK_BEGIN)}[\\s\\S]*?${escapeRegExp(BLOCK_END)}\\n?`, 'g');
  let updated: string;
  if (re.test(current)) {
    updated = current.replace(re, `${block}\n`);
  } else {
    updated = `${current.replace(/\s*$/, '')}\n\n${block}\n`;
  }
  fs.writeFileSync(file, updated);
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Remove previous Kotliner-managed property lines, then append fresh ones. */
function writeManagedProps(file: string, props: Record<string, string>): void {
  const current = readText(file) ?? '';
  const keys = Object.keys(props);
  const cleaned = current
    .split(/\r?\n/)
    .filter((line) => !keys.some((k) => line.trim().startsWith(`${k}=`)))
    .join('\n');
  const out = `${cleaned.replace(/\s*$/, '')}\n\n# Kotliner managed properties (auto-generated)\n${keys
    .map((k) => `${k}=${props[k]}`)
    .join('\n')}\n`;
  fs.writeFileSync(file, out);
}

/**
 * Validate that `dir` is a Kotlin Android (Gradle) project and collect the
 * info the UI pre-fills from. Returns { ok: true, info } or { ok: false, error }.
 */
function validateProject(dir: string): ValidateResult {
  try {
    const stat = fs.statSync(dir);
    if (!stat.isDirectory()) {
      return { ok: false, error: 'The selected path is not a directory.' };
    }
  } catch {
    return { ok: false, error: 'The selected path does not exist.' };
  }

  const settingsName = findSettingsFile(dir);
  if (!settingsName) {
    return { ok: false, error: 'No settings.gradle(.kts) found — this folder is not a Gradle project.' };
  }

  const appModule = findAppModule(dir);
  if (!appModule) {
    return {
      ok: false,
      error: 'No Android application module was found (a module whose build file applies com.android.application, directly or through a version-catalog alias).',
    };
  }

  const settingsText = readText(path.join(dir, settingsName)) ?? '';
  const buildText = readText(appModule.buildFile) ?? '';
  const catalog = parseVersionCatalog(dir);

  const nameMatch = /rootProject\.name\s*=?\s*"([^"]+)"/.exec(settingsText);
  const folderName = path.basename(dir);
  const name = nameMatch ? nameMatch[1] : folderName;

  // Literal strings first, then a version-catalog reference
  // (`applicationId = libs.versions.appId.get()`).
  const buildValue = (fieldName: string): string | null => {
    const q = new RegExp(`(?<![A-Za-z])${fieldName}\\s*=?\\s*"([^"]+)"`).exec(buildText);
    if (q) return q[1];
    const ref = new RegExp(`(?<![A-Za-z])${fieldName}\\s*=\\s*(libs\\.versions\\.[\\w.]+\\s*\\.\\s*get\\s*\\(\\s*\\))`).exec(buildText);
    return ref ? resolveVersionRef(catalog, ref[1]) : null;
  };

  const levels = parseSdkLevels(buildText, catalog);
  const version = buildValue('versionName') ?? '1.0.0';
  // versionCode can be a quoted value, a bare int, or a catalog reference.
  const codeLit = /(?<![A-Za-z])versionCode\s*=?\s*(\d+)/.exec(buildText);
  const versionCodeRaw = codeLit ? codeLit[1] : buildValue('versionCode');
  const computedCode = computeVersionCode(version);

  const hasGradleWrapper =
    fs.existsSync(path.join(dir, 'gradlew')) || fs.existsSync(path.join(dir, 'gradlew.bat'));

  return {
    ok: true,
    info: {
      dir,
      name,
      slug: name,
      version,
      versionCode: versionCodeRaw && /^\d+$/.test(versionCodeRaw) ? Number(versionCodeRaw) : computedCode,
      androidPackage: buildValue('applicationId') ?? '',
      module: appModule.module,
      gradleKts: appModule.kts,
      gradleVersion: parseGradleWrapperVersion(dir),
      agpVersion: parseAgpVersion(dir),
      minSdk: levels.minSdk,
      targetSdk: levels.targetSdk,
      compileSdk: levels.compileSdk,
      hasGradleWrapper,
      hasPersistentKey: fs.existsSync(path.join(dir, 'android-key')),
    },
  };
}

/** Mahameh-style scheme: 1.37.18 -> 13718 (major*10000 + minor*100 + patch). */
function computeVersionCode(version?: string | null): number {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(String(version || ''));
  if (!m) return 1;
  return Number(m[1]) * 10000 + Number(m[2]) * 100 + Number(m[3]);
}

/**
 * Write `version`/`versionCode` as managed override properties into the root
 * `gradle.properties` plus a managed block in the app module's build file.
 * The block re-assigns versionName/versionCode inside `defaultConfig` — later
 * assignments win in Gradle, so the override works without touching the
 * project's own declarations. Works for both Groovy and Kotlin DSL.
 */
function applyVersions(dir: string, { version, versionCode }: { version?: string; versionCode?: number }): {
  applied: { gradleProps: boolean; buildFile: boolean };
  notes: string[];
} {
  const notes: string[] = [];
  const applied = { gradleProps: false, buildFile: false };

  const settingsName = findSettingsFile(dir);
  if (!settingsName) {
    notes.push('settings.gradle(.kts) disappeared — version override not applied.');
    return { applied, notes };
  }
  const appModule = findAppModule(dir);
  if (!appModule) {
    notes.push('Android application module not found — version override not applied.');
    return { applied, notes };
  }

  const props: Record<string, string> = {};
  if (version) props.KT_VERSION_NAME = version;
  if (versionCode) props.KT_VERSION_CODE = String(versionCode);
  if (!Object.keys(props).length) return { applied, notes };

  writeManagedProps(path.join(dir, 'gradle.properties'), props);
  applied.gradleProps = true;

  const body = appModule.kts
    ? `if (hasProperty("KT_VERSION_NAME") || hasProperty("KT_VERSION_CODE")) {
    android {
        defaultConfig {
            if (hasProperty("KT_VERSION_NAME")) versionName = project.property("KT_VERSION_NAME") as String
            if (hasProperty("KT_VERSION_CODE")) versionCode = (project.property("KT_VERSION_CODE") as String).toInt()
        }
    }
}`
    : `if (hasProperty('KT_VERSION_NAME') || hasProperty('KT_VERSION_CODE')) {
    android {
        defaultConfig {
            if (hasProperty('KT_VERSION_NAME')) versionName KT_VERSION_NAME
            if (hasProperty('KT_VERSION_CODE')) versionCode KT_VERSION_CODE
        }
    }
}`;
  upsertManagedBlock(appModule.buildFile, appModule.kts, body);
  applied.buildFile = true;

  notes.push(
    `versionName=${version ?? '(unchanged)'} versionCode=${versionCode ?? '(unchanged)'} written as a managed override ` +
      `(${path.relative(dir, appModule.buildFile)} + gradle.properties).`
  );

  return { applied, notes };
}

export { validateProject, applyVersions, computeVersionCode, findAppModule };

if (require.main?.filename === __filename) {
  // CLI: node out/lib/project-info.js <dir>
  const target = process.argv[2];
  if (!target) {
    console.error('usage: node out/lib/project-info.js <projectDir>');
    process.exit(2);
  }
  console.log(JSON.stringify(validateProject(target), null, 2));
}
