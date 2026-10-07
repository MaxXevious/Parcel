# Parcel

A native SwiftUI iOS app for managing a home Usenet setup: **SABnzbd**, **NZBGet**, **Sonarr**, **Radarr**, and **Newznab-compatible NZB indexers**. It is an original app built from the services' public APIs and is not affiliated with any of them.

## Build it (needs a Mac with Xcode 15 or newer)

```sh
brew install xcodegen
cd Parcel            # the folder containing project.yml
xcodegen generate    # creates Parcel.xcodeproj
open Parcel.xcodeproj
```

Then in Xcode: select the **Parcel** target, **Signing & Capabilities**, choose your Team, and change the bundle identifier (`com.example.parcel`) to your own. Run on a device or simulator (iOS 17+).

No XcodeGen? Create a new iOS App project (SwiftUI, iOS 17), delete the template files, drag the `Parcel/` source folder in, and add to Info: `NSLocalNetworkUsageDescription` and App Transport Security > Allow Arbitrary Loads (home servers are usually plain http).

## What's in v0.1

- **Downloads** (SABnzbd or NZBGet): live queue (refreshes every 3 s), history, pause/resume all or per item, delete, speed limit presets, switch between downloaders.
- **TV (Sonarr)** and **Movies (Radarr)**: library with posters and filter, per-title detail (monitor toggle, search, remove; Sonarr shows episodes by season with per-episode search), calendar (next 30 days), wanted/missing with "search all missing", activity queue, and add-new-title (lookup, quality profile, root folder).
- **Search**: queries all your indexers at once, sorts by newest/largest/name, filters by category, and sends a result to the active downloader.
- **Settings**: multiple servers per type, "Test Connection", optional self-signed certificate support. API keys and passwords are stored in the Keychain.

## Not built yet

Push notifications, widgets and Live Activities, Lidarr/Readarr/Prowlarr/Tautulli/Overseerr, manual release search (picking a specific release inside Sonarr/Radarr), per-category downloader routing, iPad-specific layouts, and an app icon.

## Heads-up

This code was written without access to a Swift compiler or a running Sonarr/Radarr/SABnzbd/NZBGet, so expect a handful of compile errors or API quirks on the first build. The structure is small and consistent, so they should be quick to fix. Things most likely to need tweaking:

- Sonarr v3 vs v4 differences (the add flow already handles the language-profile difference).
- SABnzbd speed-limit units and NZBGet `append` behaviour across versions.
- Newznab indexers that return unusual XML.

If you hit an error, paste the Xcode message and the fix is usually a one-liner.
