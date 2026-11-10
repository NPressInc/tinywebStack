# App Store and Play Store packaging

TinyWeb is **not submitted** and **not listed** on the App Store or Google Play. Nothing in this repository uploads a build, listing text, or screenshots to Apple or Google. Do not treat a green CI run as a store release.

The phone app's bundle id and Android application id are already `win.tinyweb.tinyweb`. Use that id on both stores. Apple Developer team ID: `RC44X9237L`.

The first-run setup flow (find the box, name the family, add phones) is a separate change. Re-read the listing text against that flow before you submit. A packaging change should not edit that wizard.

## What is already in the repo

| Piece | Where |
| --- | --- |
| Listing text (English, U.S.) | `app/fastlane/metadata/` |
| Identifiers and the intended privacy URL | `app/fastlane/store_identity.yaml` |
| Fastlane build lanes (no upload lane) | `app/fastlane/Fastfile` |
| Privacy policy draft | [PRIVACY.md](PRIVACY.md) |
| Apple privacy nutrition draft, and the app privacy manifest | `app/fastlane/privacy/apple-privacy-nutrition.yaml`, `app/ios/Runner/PrivacyInfo.xcprivacy` |
| Play data-safety draft | `app/fastlane/privacy/play-data-safety.yaml` |
| iOS export options for team `RC44X9237L` | `app/ios/ExportOptions.plist` |
| Upload-key template (empty passwords) | `app/android/key.properties.example` |
| Local release builds that stop after the artifact | `scripts/store/build-ios-release.sh`, `scripts/store/build-android-release.sh` |

Version and build number come from `app/pubspec.yaml` (`1.0.0+1` at the time of this packaging). The Play changelog file is `app/fastlane/metadata/android/en-US/changelogs/1.txt` because the version code is 1. Bump that file's name when the version code changes.

The intended public URLs are not live yet:

- Privacy policy: `https://tinyweb.win/privacy` (publish [PRIVACY.md](PRIVACY.md) here after counsel reviews it)
- Support and marketing: `https://tinyweb.win`

`privacy_policy_published` is false. Leave it false until that page is actually up. The privacy nutrition and data-safety files are `status: draft`. They are not confirmed console answers.

Copyright on the listing is `2026 NPress, Inc.`, from the brand assets. Confirm the seller name on team `RC44X9237L` before you submit. The Apple Distribution certificate is the one that signs the iOS app. A Developer ID certificate is for Mac software outside the App Store; do not pick it for this IPA.

## What CI does

`.github/workflows/app.yml` already builds, on changes under `app/`:

- an Android App Bundle and split release APKs
- an **unsigned** iOS IPA

The Android job uses the upload keystore only when the GitHub Actions secrets below are set. Without them, Gradle signs the release build with the debug key. Play will reject that artifact. The iOS job does not read Apple secrets and does not sign.

CI does not install Fastlane, does not need a signing secret to pass, and does not upload.

`scripts/store/check_store_metadata.py` checks listing limits, the bundle id, the team id, the privacy manifest, and that no certificate or private key is tracked. `scripts/validate.sh` runs it, and so does `scripts/tests/test_store_metadata.py`. That check does not compile Flutter.

## Signing

### iOS (on the Mac)

Team `RC44X9237L` already has Apple Distribution and Developer ID certificates in the keychain. They stay there. Do not export them into git. `DEVELOPMENT_TEAM` is set in `app/ios/Flutter/Debug.xcconfig` and `Release.xcconfig`.

Release archives use `app/ios/Runner/Runner-Release.entitlements` (`aps-environment` = `production`) so TestFlight and the App Store match production push. Debug and Profile stay on `Runner.entitlements` (`development`) so a local sandbox build still signs. A `flutter run --release` on a device needs a profile whose push entitlement is production; day-to-day device runs should stay on debug.

On the Mac, from a checkout with Flutter and Xcode:

```bash
scripts/store/build-ios-release.sh
```

That is `flutter build ipa --release --export-options-plist=ios/ExportOptions.plist`. The IPA lands under `app/build/ios/ipa/`. The script does not upload. From `app/`, `bundle install` once and then `bundle exec fastlane ios build` is the same build. Fastlane is optional. The shell script does not need Ruby.

If export fails on an older Xcode, the `method` key in `ExportOptions.plist` is `app-store-connect`, which current Xcode expects.

Upload the IPA with Apple Transporter or the Xcode Organizer when you mean to. CI will not.

Before the first archive, in the Apple Developer account for team `RC44X9237L`:

1. Register the App ID `win.tinyweb.tinyweb` if it is not registered.
2. Enable Push Notifications on that App ID. The app already uses APNs. Production keys for the box are the operator steps in [PUSH.md](PUSH.md). Do not commit the `.p8` file.
3. Let automatic signing create the App Store profile, or create one yourself. `ExportOptions.plist` uses automatic signing and does not name a profile file.

### Android

Use Play App Signing. Google holds the app signing key. You hold an upload key.

Create the upload key once, on a machine you control. This command is the shape of the key; run it yourself and choose the passwords there. Do not paste the passwords into the repo, CI logs, or chat:

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Copy `app/android/key.properties.example` to `app/android/key.properties`. Fill the passwords locally. `storeFile` is relative to `app/android/app/` (the same place CI writes `upload-keystore.jks`). Both `key.properties` and `*.jks` are gitignored.

Keep a copy of the keystore offline. After Play App Signing is enrolled, Google can reset a lost upload key. Before that enrollment, a lost keystore blocks updates.

```bash
scripts/store/build-android-release.sh
```

That builds `app/build/app/outputs/bundle/release/app-release.aab` and does not upload. It refuses to run if `key.properties` is missing or a password is empty, so it will not silently produce a debug-signed bundle. `cd app && bundle exec fastlane android build` is the same build.

Optional CI secrets, if you want the GitHub Android artifact signed with the upload key (Settings, Secrets and variables, Actions):

| Secret | What it is |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0` of `upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | The store password |
| `ANDROID_KEY_ALIAS` | `upload`, if you used the command above |
| `ANDROID_KEY_PASSWORD` | The key password |

The iOS job does not use `APPLE_TEAM_ID`, a `.p12`, or an App Store Connect API key. Those were sketched earlier and are still not wired. The team id in the project is `RC44X9237L`.

## Listing text

Edit the files under `app/fastlane/metadata/`. The checker enforces the current store limits (Apple name and subtitle 30, keywords 100, promotional text 170, description 4000; Play title 30, short description 80, full description 4000, changelog 500). Keywords must not repeat the name TinyWeb.

Suggested Play category when you create the app: Communication. Apple primary category in metadata is Lifestyle, secondary Productivity. Change the metadata files and `store_identity.yaml` together if you pick something else.

Screenshots are not in git. `app/fastlane/screenshots/` is gitignored so a capture of a real household does not get committed by accident. Upload screenshots yourself.

## Privacy answers

Both console forms are drafts. Read them against [PRIVACY.md](PRIVACY.md) and confirm them in the consoles. Do not mark them confirmed in git until you have.

- No ads, nothing sold, no tracking.
- Data that leaves the phone is collected. The family's box is the destination for chat, calendar, photos, and location. That is not third-party sharing.
- The control plane additionally holds the family name, DNS, certificates, and tunnel credentials.
- The phone address book is not read. Do not declare device Contacts.
- Apple's list and Google's list are not the same. iOS does not declare coarse location. Play declares precise and approximate location because the manifest requests both, and DNS stores the box's public address.
- There is no crash or analytics SDK in the app today. Leave those types off unless you add one.
- `play_data_deletion_url` is `not_set`. A parent can remove a member on the box. Confirm how a family releases its `tinyweb.win` name before you answer the deletion questions "yes".

`app/ios/Runner/Info.plist` sets `ITSAppUsesNonExemptEncryption` to false so export compliance does not prompt on every upload. The app uses ordinary HTTPS and the platform's common cryptography. Confirm that exemption in App Store Connect the first time it asks. This is not a claim about a custom cipher.

## Remaining human steps

The repo cannot do these. Do them before the first submission, and submit yourself. Do not submit from CI.

### Both stores

1. Have counsel read [PRIVACY.md](PRIVACY.md). Publish it at `https://tinyweb.win/privacy`. Only then set `privacy_policy_published` to true.
2. Confirm `https://tinyweb.win` is the support page you want, or change `support_url` and `marketing_url` in `store_identity.yaml` and the metadata URL files together.
3. Replace the contact placeholder in the privacy draft before the page goes live.
4. Capture screenshots on a real install: home, chat, calendar, and the parent household screen. Use a demo family, not a private one. App Store Connect will mark the required sizes; the iOS target includes iPhone and iPad, so plan on both. Play needs phone screenshots, and tablet screenshots if you leave tablet support on. Also prepare the feature graphic Play asks for.
5. Check the app icon against the current store rules (Android is picky about an icon that is not a full-bleed square).
6. Stand up a demo box and a parent account for review. Type the credentials into App Store Connect review information and the Play Console review instructions. Do not commit them. `app/fastlane/metadata/review_information/notes.txt` explains the path and does not contain a login.
7. Confirm a parent can delete a member account, and decide how the family name and its DNS, certificates, and tunnel credentials are released. Apple's account-deletion rule and Play's deletion question both need an honest answer.
8. Re-read the listing against the first-run wizard before you submit, so the steps you describe are the steps the build actually has.

### App Store Connect (team RC44X9237L)

1. Agreements, tax, and banking.
2. Create the app. Bundle ID `win.tinyweb.tinyweb`. Name TinyWeb. Primary language English (U.S.). SKU can be `win.tinyweb.tinyweb`.
3. Paste the listing from `app/fastlane/metadata/en-US/`, or upload that text later yourself. This Fastfile has no upload lane.
4. Set the privacy policy URL. Complete App Privacy from `apple-privacy-nutrition.yaml`. Tracking: No.
5. Complete the age-rating questionnaire from the product. Chat and photos are content inside the family. A public event page is public. Do not tick a kids category unless you intend to meet that program's rules.
6. Export compliance: standard encryption, matching the Info.plist flag. Confirm it once in the console.
7. Upload the IPA with Transporter or Xcode. Attach the build. Add screenshots and the demo account.
8. Submit for review only after the build, screenshots, privacy URL, and demo account are all in place.

### Play Console

1. Create the developer account if you do not already have one. This repo does not record one. Create the app. Package name `win.tinyweb.tinyweb`. App, free, default language English (United States).
2. Turn on Play App Signing and enroll it with the upload key from the first AAB.
3. Store listing text from `app/fastlane/metadata/android/en-US/`. Suggested category: Communication.
4. Privacy policy URL, the same page as Apple.
5. Data safety from `play-data-safety.yaml`. Ads: No.
6. Content rating (the IARC questionnaire), target audience, and the ads declaration. Parents set the app up. Children use phones a parent enrolled. Do not opt into Designed for Families unless you mean to meet that policy. News and government apps: No.
7. Choose the countries you will actually support.
8. Put the first AAB on the internal testing track. Add testers. Do not promote that build to production in the same step.
9. Release notes for version code 1 are `changelogs/1.txt`.

## Checks

```bash
python3 scripts/store/check_store_metadata.py
```

A passing check means the packaging files agree with each other. It does not mean the app is in either store.
