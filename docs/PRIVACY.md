# TinyWeb privacy policy (draft)

**Status: draft. Not published. Not in effect. Not legal advice.**

This text is the draft to host at `https://tinyweb.win/privacy` before the first App Store or Play Store submission. It is not on that URL yet. Counsel should review it, and the contact line below has to be replaced, before anyone treats it as the live policy. The store listing must not ship while `privacy_policy_published` in `app/fastlane/store_identity.yaml` is false.

Operator of the `tinyweb.win` names: NPress, Inc., the name on the TinyWeb brand assets. Confirm that this is the legal entity on Apple Developer team `RC44X9237L` and on the Play Console account before you publish.

## The short version

Family data lives on the family's own home box. TinyWeb does not show ads and does not sell personal information.

TinyWeb's service is a control plane for the family name, DNS, certificates, and the tunnel credentials that connect the box. It is not a copy of the family's chat, photos, calendars, or location.

## What this covers

- The TinyWeb phone app for iOS and Android (bundle id and application id `win.tinyweb.tinyweb`).
- The control plane a family uses when the home box takes a `tinyweb.win` name.

A family can point the app at their own domain. In that case the control plane described here may not hold their name. The box still holds the family data.

## What stays on the family's box

The home box is a computer the family keeps. These stay there:

- Accounts a parent creates, including children's accounts, and the passwords for those accounts.
- Chat. Message contents are encrypted on the phone. The box can see metadata such as who talks to whom and when. It does not get a readable copy of encrypted messages. There is no parent back door into that ciphertext.
- Calendars on the box.
- Events. An event marked public can be a public web page. That is how those events are shared between households. Private household data is not the same thing as a public event page.
- Location from a phone that is enrolled to share it. Parents on that box can see it. Other people cannot.
- Photos and videos someone chooses to send in family chat.
- The list of people in the household. The app does not read the phone's address book.

Push wakes the phone without putting the message text in the notification payload. The phone then loads the message from the box. Apple or Google may see a device token, the timing, and a generic alert. They do not get the message body from TinyWeb's payload.

## What the control plane holds

For a family name on `tinyweb.win`, TinyWeb's service holds:

- The family name the parent chooses.
- DNS so phones can find that box, including the box's public network address. That address can suggest an approximate location of the home.
- Certificates for that name, so phones can connect securely, and the material used to issue and renew them.
- Tunnel credentials that keep the box connected. Those credentials are for the connection. They are not a copy of messages, photos, or location.

The control plane does not run ads, and it is not a place where family chat is stored.

## What the phone app collects, and why

The app collects the following so the household can use the box. It is linked to the family account. It is not used to track anyone across other companies' apps or websites.

| Data | Why |
| --- | --- |
| Precise location | Parents can see a phone that is enrolled to share location, including while the app is in the background. The system permission can be denied. |
| Name | The family name and member names. |
| User ID | The account on the family's box. |
| Photos and videos | Only what someone chooses to send in chat. |
| Audio | Microphone audio when someone records a video message. |
| Other content | Chat text, calendar events, and family events. |
| Device ID | A push token so the box can wake the phone. This is not an advertising identifier. |

The app does not collect the phone's address book, phone number, health data, payment data, or browsing history. The current app does not include an advertising SDK, an analytics SDK, or a crash-reporting SDK.

## Children

A parent creates a child's account on the family's box and enrolls that child's phone. Location from that phone, when sharing is on, goes to the box for the parents.

TinyWeb does not show ads to children and does not build advertising profiles. Children's chat, photos, and location stay on the family's box rather than in an advertising system.

This draft is not a finding that the product meets any particular children's-privacy statute. Counsel should review it before submission. The stores will also ask whether the app is directed at children. Answer from the product: parents set it up, and children use phones the parent enrolled.

## How long it is kept

Data on the box stays until a parent deletes it or deletes that person's account. A parent can remove a member from the household in the app.

Control-plane records (the family name, DNS, certificates, and tunnel credentials) are kept while that family name is in use. How a family releases the name has to be confirmed and written down here before this draft is published. There is no separate TinyWeb copy of chat, photos, calendars, or location to delete.

## Who we do not share it with

TinyWeb does not sell personal information. The app does not show ads.

The family's box is the family's, not a third-party analytics service. Apple and Google deliver push as described above. A public event page is public because the family published it.

## Security

The phone talks to the box over TLS. Chat message contents are encrypted on the device as well. No method of transmission or storage is perfect.

## Changes

The published policy, when it exists, should carry a date and replace this draft. Until `https://tinyweb.win/privacy` serves this document (after counsel's edits), the app is not ready to submit.

## Contact

Add a privacy contact address before publishing. Do not leave this sentence in the page you host.
