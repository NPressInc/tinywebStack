#!/usr/bin/env python3
"""Check TinyWeb store metadata, privacy scaffolding, and signing config.

This does not build the app and does not contact Apple or Google.
"""

from __future__ import annotations

import plistlib
import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
FASTLANE = ROOT / "app" / "fastlane"
METADATA = FASTLANE / "metadata"
LOCALE = METADATA / "en-US"
ANDROID = METADATA / "android" / "en-US"

# PEM markers are split so this file does not contain a real header.
_PEM_CERTIFICATE = "-----BEGIN " + "CERTIFICATE-----"
_PEM_PRIVATE_KEY = re.compile("-----BEGIN " + r"[A-Z0-9 ]*PRIVATE KEY-----")
_GOOGLE_API_KEY = re.compile(r"\bAIza[0-9A-Za-z\-_]{20,}")
_AWS_ACCESS_KEY = re.compile(r"\bAKIA[0-9A-Z]{16}\b")
_NONEMPTY_KEY_PASSWORD = re.compile(r"^(storePassword|keyPassword)=.+$", re.M)

APPLE_LIMITS = {
    "name.txt": 30,
    "subtitle.txt": 30,
    "keywords.txt": 100,
    "promotional_text.txt": 170,
    "description.txt": 4000,
    "release_notes.txt": 4000,
}
PLAY_LIMITS = {
    "title.txt": 30,
    "short_description.txt": 80,
    "full_description.txt": 4000,
}
CHANGELOG_LIMIT = 500
SINGLE_LINE = {
    "name.txt",
    "subtitle.txt",
    "keywords.txt",
    "privacy_url.txt",
    "support_url.txt",
    "marketing_url.txt",
    "title.txt",
    "short_description.txt",
}
FORBIDDEN_LISTING = (
    "available on the app store",
    "available on google play",
    "download on the app store",
    "get it on google play",
)
FORBIDDEN_FASTLANE = (
    "upload_to_app_store",
    "upload_to_play_store",
    "lane :upload",
    "deliver(",
    "supply(",
    "pilot(",
)
TRACKED_SECRET_SUFFIXES = (
    ".p12",
    ".pfx",
    ".mobileprovision",
    ".jks",
    ".keystore",
    ".p8",
)


def length_error(label: str, text: str, limit: int) -> str | None:
    size = len(text.strip())
    if size == 0:
        return f"{label} is empty"
    if size > limit:
        return f"{label} is {size} characters; limit is {limit}"
    return None


def keyword_errors(text: str, app_name: str) -> list[str]:
    errors = []
    keywords = text.strip()
    if not keywords:
        return ["keywords.txt is empty"]
    if len(keywords) > 100:
        errors.append(f"keywords.txt is {len(keywords)} characters; limit is 100")
    if app_name.lower() in keywords.lower():
        errors.append("keywords.txt must not repeat the app name")
    if not re.fullmatch(r"[a-z]+(?:,[a-z]+)*", keywords):
        errors.append(
            "keywords.txt must be lowercase words separated by commas, with no spaces"
        )
    return errors


def secret_errors(label: str, text: str) -> list[str]:
    errors = []
    if _PEM_CERTIFICATE in text or _PEM_PRIVATE_KEY.search(text):
        errors.append(f"{label} contains a certificate or private key")
    if _GOOGLE_API_KEY.search(text) or _AWS_ACCESS_KEY.search(text):
        errors.append(f"{label} contains an API key")
    if _NONEMPTY_KEY_PASSWORD.search(text):
        errors.append(f"{label} contains a keystore password")
    return errors


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _load_yaml(path: Path) -> dict:
    data = yaml.safe_load(_read(path))
    if not isinstance(data, dict):
        raise TypeError(f"{path} is not a mapping")
    return data


def _pubspec_version(text: str) -> tuple[str, str]:
    match = re.search(r"^version:\s+(\d+\.\d+\.\d+)\+(\d+)\s*$", text, re.M)
    if not match:
        raise ValueError("pubspec.yaml has no version: name+code line")
    return match.group(1), match.group(2)


def check_repo(root: Path = ROOT) -> list[str]:
    errors: list[str] = []

    def add(message: str | None) -> None:
        if message:
            errors.append(message)

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    identity_path = root / "app" / "fastlane" / "store_identity.yaml"
    require(identity_path.is_file(), "missing app/fastlane/store_identity.yaml")
    if not identity_path.is_file():
        return errors
    identity = _load_yaml(identity_path)
    app_name = identity.get("app_name")
    bundle_id = identity.get("bundle_id")
    team_id = identity.get("apple_team_id")
    require(app_name == "TinyWeb", "store identity app_name must stay TinyWeb")
    require(bundle_id == "win.tinyweb.tinyweb", "store identity bundle_id drifted")
    require(team_id == "RC44X9237L", "store identity apple_team_id drifted")
    require(
        identity.get("privacy_policy_published") is False,
        "privacy_policy_published must stay false until the policy URL is live",
    )
    for key in ("privacy_policy_url", "support_url", "marketing_url"):
        value = identity.get(key)
        require(
            isinstance(value, str) and value.startswith("https://"),
            f"{key} must be an https URL",
        )

    locale = root / "app" / "fastlane" / "metadata" / identity["locale"]
    android = root / "app" / "fastlane" / "metadata" / "android" / identity["locale"]
    listing_bits = {
        "name.txt": app_name,
        "privacy_url.txt": identity["privacy_policy_url"],
        "support_url.txt": identity["support_url"],
        "marketing_url.txt": identity["marketing_url"],
    }
    for name, expected in listing_bits.items():
        path = locale / name
        require(path.is_file(), f"missing {path.relative_to(root)}")
        if path.is_file():
            require(
                _read(path).strip() == expected,
                f"{name} does not match store_identity.yaml",
            )
    title = android / "title.txt"
    require(title.is_file() and _read(title).strip() == app_name, "Play title drifted")

    copyright_path = root / "app" / "fastlane" / "metadata" / "copyright.txt"
    primary = root / "app" / "fastlane" / "metadata" / "primary_category.txt"
    secondary = root / "app" / "fastlane" / "metadata" / "secondary_category.txt"
    require(
        copyright_path.is_file()
        and _read(copyright_path).strip() == identity["copyright"],
        "copyright.txt does not match store_identity.yaml",
    )
    require(
        primary.is_file()
        and _read(primary).strip() == identity["apple_primary_category"],
        "primary_category.txt drifted",
    )
    require(
        secondary.is_file()
        and _read(secondary).strip() == identity["apple_secondary_category"],
        "secondary_category.txt drifted",
    )

    for name, limit in APPLE_LIMITS.items():
        path = locale / name
        if path.is_file():
            add(length_error(name, _read(path), limit))
    for name, limit in PLAY_LIMITS.items():
        path = android / name
        if path.is_file():
            add(length_error(name, _read(path), limit))
    keywords = locale / "keywords.txt"
    if keywords.is_file():
        errors.extend(keyword_errors(_read(keywords), str(app_name)))

    for path in (
        locale / "description.txt",
        android / "full_description.txt",
        locale / "promotional_text.txt",
        android / "short_description.txt",
    ):
        if not path.is_file():
            errors.append(f"missing {path.relative_to(root)}")
            continue
        text = _read(path)
        lowered = text.lower()
        require("home box" in lowered, f"{path.name} must mention the home box")
        require("no ads" in lowered, f"{path.name} must say there are no ads")
        for phrase in FORBIDDEN_LISTING:
            require(phrase not in lowered, f"{path.name} claims the app is already listed")

    for path in (locale / "description.txt", android / "full_description.txt"):
        if path.is_file():
            require(
                "control plane" in _read(path).lower(),
                f"{path.name} must describe the control plane",
            )

    for folder, names in ((locale, APPLE_LIMITS), (android, PLAY_LIMITS)):
        for name in list(names) + [
            "privacy_url.txt",
            "support_url.txt",
            "marketing_url.txt",
            "title.txt",
        ]:
            path = folder / name
            if path.is_file() and name in SINGLE_LINE and "\n" in _read(path).strip():
                errors.append(f"{name} must be a single line")

    version_name, version_code = _pubspec_version(_read(root / "app" / "pubspec.yaml"))
    require(version_name, "missing pubspec version")
    changelogs = android / "changelogs"
    changelog_files = sorted(p.name for p in changelogs.glob("*.txt")) if changelogs.is_dir() else []
    expected_changelog = f"{version_code}.txt"
    require(
        changelog_files == [expected_changelog],
        f"Play changelogs must be exactly {expected_changelog} for version code {version_code}",
    )
    changelog = changelogs / expected_changelog
    if changelog.is_file():
        add(length_error(expected_changelog, _read(changelog), CHANGELOG_LIMIT))
    notes = locale / "release_notes.txt"
    if notes.is_file():
        add(length_error("release_notes.txt", _read(notes), 4000))

    gradle = _read(root / "app" / "android" / "app" / "build.gradle.kts")
    require(
        f'applicationId = "{bundle_id}"' in gradle,
        "Android applicationId does not match the store bundle id",
    )
    require(
        f'namespace = "{bundle_id}"' in gradle,
        "Android namespace does not match the store bundle id",
    )
    pbx = _read(root / "app" / "ios" / "Runner.xcodeproj" / "project.pbxproj")
    require(
        pbx.count(f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};") == 3,
        "iOS app bundle id must appear on Debug, Release, and Profile only",
    )
    require(
        pbx.count(f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id}.RunnerTests;") == 3,
        "iOS test bundle id drifted",
    )
    require(
        "PrivacyInfo.xcprivacy in Resources" in pbx,
        "PrivacyInfo.xcprivacy is not in the Runner resources build phase",
    )
    require(
        pbx.count("CODE_SIGN_ENTITLEMENTS = Runner/Runner-Release.entitlements;") == 1,
        "Release must be the only config on production push entitlements",
    )
    require(
        pbx.count("CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;") == 2,
        "Debug and Profile must keep the development push entitlements",
    )

    for name in ("Debug.xcconfig", "Release.xcconfig"):
        xcconfig = _read(root / "app" / "ios" / "Flutter" / name)
        require(
            f"DEVELOPMENT_TEAM = {team_id}" in xcconfig,
            f"{name} is missing DEVELOPMENT_TEAM {team_id}",
        )
        require("CODE_SIGN_STYLE = Automatic" in xcconfig, f"{name} is missing automatic signing")

    export_plist = plistlib.loads(
        (root / "app" / "ios" / "ExportOptions.plist").read_bytes()
    )
    require(export_plist.get("teamID") == team_id, "ExportOptions.plist teamID drifted")
    require(
        export_plist.get("method") == "app-store-connect",
        "ExportOptions.plist method must be app-store-connect",
    )
    require(
        export_plist.get("signingStyle") == "automatic",
        "ExportOptions.plist signingStyle must be automatic",
    )
    info = plistlib.loads((root / "app" / "ios" / "Runner" / "Info.plist").read_bytes())
    require(
        info.get("ITSAppUsesNonExemptEncryption") is False,
        "Info.plist must set ITSAppUsesNonExemptEncryption to false",
    )
    debug_ent = plistlib.loads(
        (root / "app" / "ios" / "Runner" / "Runner.entitlements").read_bytes()
    )
    release_ent = plistlib.loads(
        (root / "app" / "ios" / "Runner" / "Runner-Release.entitlements").read_bytes()
    )
    require(
        debug_ent.get("aps-environment") == "development",
        "Debug entitlements must stay on the development APNs environment",
    )
    require(
        release_ent.get("aps-environment") == "production",
        "Release entitlements must use the production APNs environment",
    )

    privacy_manifest = plistlib.loads(
        (root / "app" / "ios" / "Runner" / "PrivacyInfo.xcprivacy").read_bytes()
    )
    nutrition = _load_yaml(root / "app" / "fastlane" / "privacy" / "apple-privacy-nutrition.yaml")
    require(nutrition.get("status") == "draft", "Apple privacy nutrition must stay status: draft")
    require(nutrition.get("bundle_id") == bundle_id, "Apple nutrition bundle id drifted")
    require(nutrition.get("team_id") == team_id, "Apple nutrition team id drifted")
    require(nutrition.get("tracking") is False, "Apple nutrition must set tracking false")
    require(nutrition.get("advertising") is False, "Apple nutrition must set advertising false")
    require(nutrition.get("tracking_domains") == [], "Apple nutrition tracking domains must be empty")
    require(nutrition.get("linked") is True, "Apple nutrition data must be linked to the family account")
    require(
        nutrition.get("manifest_purposes")
        == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
        "Apple nutrition purposes must be app functionality only",
    )
    manifest_types = nutrition.get("manifest_types")
    require(
        isinstance(manifest_types, list) and len(manifest_types) == len(set(manifest_types)),
        "Apple nutrition manifest_types must be a list without duplicates",
    )
    linked_types = [
        item.get("manifest_type")
        for item in nutrition.get("data_linked_to_you", [])
        if isinstance(item, dict)
    ]
    require(
        linked_types == manifest_types,
        "Apple nutrition labels and manifest_types are out of order or incomplete",
    )
    require(privacy_manifest.get("NSPrivacyTracking") is False, "Privacy manifest tracking must be false")
    require(
        privacy_manifest.get("NSPrivacyTrackingDomains") == [],
        "Privacy manifest tracking domains must be empty",
    )
    collected = privacy_manifest.get("NSPrivacyCollectedDataTypes")
    require(isinstance(collected, list), "Privacy manifest is missing collected data types")
    if isinstance(collected, list):
        found = []
        for item in collected:
            found.append(item.get("NSPrivacyCollectedDataType"))
            require(
                item.get("NSPrivacyCollectedDataTypeLinked") is True,
                "Privacy manifest data must be linked",
            )
            require(
                item.get("NSPrivacyCollectedDataTypeTracking") is False,
                "Privacy manifest data must not be marked for tracking",
            )
            require(
                item.get("NSPrivacyCollectedDataTypePurposes")
                == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
                "Privacy manifest purposes must be app functionality only",
            )
        require(found == manifest_types, "Privacy manifest types do not match the nutrition file")
    not_collected = " ".join(nutrition.get("not_collected") or [])
    for label in ("Contacts", "Email Address", "Phone Number", "Crash Data", "Advertising Data"):
        require(label in not_collected, f"Apple nutrition must keep {label} in not_collected")

    play = _load_yaml(root / "app" / "fastlane" / "privacy" / "play-data-safety.yaml")
    require(play.get("status") == "draft", "Play data safety must stay status: draft")
    require(play.get("package_name") == bundle_id, "Play package name drifted")
    for flag in ("ads", "tracking", "sold", "third_party_sharing"):
        require(play.get(flag) is False, f"Play data safety {flag} must be false")
    require(play.get("encrypted_in_transit") is True, "Play data safety must say transit encryption is on")
    deletion = play.get("deletion") or {}
    require(
        deletion.get("play_data_deletion_url") == "not_set",
        "Play deletion URL must stay not_set until a real page exists",
    )
    service = " ".join(play.get("service_also_processes") or []).lower()
    for phrase in ("family name", "dns", "certificate", "tunnel"):
        require(phrase in service, f"Play scaffold must mention control-plane {phrase}")
    play_not_collected = " ".join(play.get("not_collected") or [])
    for label in (
        "Email address",
        "Phone number",
        "Contacts",
        "Advertising ID",
        "Crash logs",
        "Web browsing history",
    ):
        require(label in play_not_collected, f"Play scaffold must keep {label} out of collection")
    data_types = play.get("data_types")
    require(isinstance(data_types, list) and data_types, "Play data types are missing")
    if isinstance(data_types, list):
        for item in data_types:
            label = item.get("type")
            require(item.get("collected") is True, f"Play type {label} should be collected")
            require(item.get("shared") is False, f"Play type {label} must not be marked shared")
            require(
                item.get("purposes") == ["App functionality"],
                f"Play type {label} must be app functionality only",
            )

    policy = _read(root / "docs" / "PRIVACY.md")
    policy_l = policy.lower()
    for phrase in (
        "draft",
        "not published",
        "not legal advice",
        "control plane",
        "dns",
        "certificate",
        "tunnel",
        "does not show ads",
        "does not sell",
        "location",
        "encrypted",
        "home box",
        "before publishing",
    ):
        require(phrase in policy_l, f"privacy draft is missing {phrase!r}")

    guide = _read(root / "docs" / "APP_STORES.md")
    guide_l = guide.lower()
    for phrase in (
        "not submitted",
        "not listed",
        "win.tinyweb.tinyweb",
        "rc44x9237l",
        "screenshots",
        "key.properties",
        "transporter",
        "does not upload",
        "status: draft",
        "not_set",
        "privacy_policy_published` is false",
    ):
        require(phrase in guide_l, f"APP_STORES.md is missing {phrase!r}")

    fastfile = _read(root / "app" / "fastlane" / "Fastfile")
    appfile = _read(root / "app" / "fastlane" / "Appfile")
    gemfile = _read(root / "app" / "Gemfile")
    require(bundle_id in fastfile and team_id in fastfile, "Fastfile is missing the bundle id or team id")
    require("did not upload" in fastfile, "Fastfile must say the build lanes do not upload")
    for token in FORBIDDEN_FASTLANE:
        require(token not in fastfile, f"Fastfile must not call {token}")
    require(
        f'app_identifier("{bundle_id}")' in appfile and f'team_id("{team_id}")' in appfile,
        "Appfile identifiers drifted",
    )
    require(f'package_name("{bundle_id}")' in appfile, "Appfile package name drifted")
    require('gem "fastlane"' in gemfile, "Gemfile must pin fastlane")

    example = _read(root / "app" / "android" / "key.properties.example")
    values = {}
    for line in example.splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    require(values.get("storePassword") == "", "example storePassword must be empty")
    require(values.get("keyPassword") == "", "example keyPassword must be empty")
    require(values.get("keyAlias") == "upload", "example key alias should be upload")
    require(bool(values.get("storeFile")), "example storeFile must name the keystore path")

    for script_name, needle in (
        ("build-ios-release.sh", "does not upload"),
        ("build-android-release.sh", "does not upload"),
    ):
        script = root / "scripts" / "store" / script_name
        require(script.is_file(), f"missing {script_name}")
        if script.is_file():
            body = _read(script)
            require(needle in body, f"{script_name} must say it does not upload")
            require("TINYWEB_STORE_UPLOAD" not in body, f"{script_name} must not grow an upload switch")
    ios_script = root / "scripts" / "store" / "build-ios-release.sh"
    if ios_script.is_file():
        require("Darwin" in _read(ios_script), "iOS build script must require a Mac")
    android_script = root / "scripts" / "store" / "build-android-release.sh"
    if android_script.is_file():
        require(
            "key.properties" in _read(android_script),
            "Android build script must require key.properties",
        )

    tracked = subprocess.check_output(
        ["git", "ls-files"], cwd=root, text=True
    ).splitlines()
    for path in tracked:
        if Path(path).name == "key.properties":
            errors.append(f"tracked signing file {path}")
        if path.endswith(TRACKED_SECRET_SUFFIXES):
            errors.append(f"tracked secret {path}")
        if "fastlane/screenshots/" in path:
            errors.append(f"tracked screenshot {path}")

    scan_roots = [
        root / "app" / "fastlane",
        root / "docs" / "PRIVACY.md",
        root / "docs" / "APP_STORES.md",
        root / "scripts" / "store",
        root / "app" / "ios" / "ExportOptions.plist",
        root / "app" / "ios" / "Runner" / "PrivacyInfo.xcprivacy",
        root / "app" / "ios" / "Runner" / "Runner-Release.entitlements",
        root / "app" / "ios" / "Flutter" / "Debug.xcconfig",
        root / "app" / "ios" / "Flutter" / "Release.xcconfig",
        root / "app" / "android" / "key.properties.example",
        root / "app" / "Gemfile",
    ]
    for scan_root in scan_roots:
        for path in _text_files(scan_root):
            errors.extend(secret_errors(str(path.relative_to(root)), _read(path)))
    return errors


def _text_files(scan_root: Path) -> list[Path]:
    """Packaging files only. Skip bytecode the test import writes beside this script."""
    allowed_suffixes = {
        ".py",
        ".md",
        ".yml",
        ".yaml",
        ".txt",
        ".plist",
        ".entitlements",
        ".xcconfig",
        ".rb",
        ".sh",
        ".example",
    }
    allowed_names = {"Appfile", "Fastfile", "Gemfile", "Pluginfile"}
    candidates = [scan_root] if scan_root.is_file() else sorted(scan_root.rglob("*"))
    found = []
    for path in candidates:
        if not path.is_file() or "__pycache__" in path.parts:
            continue
        if path.suffix in allowed_suffixes or path.name in allowed_names:
            found.append(path)
    return found


def main() -> int:
    errors = check_repo()
    if errors:
        for error in errors:
            print(f"store metadata: {error}", file=sys.stderr)
        return 1
    print("store metadata OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
