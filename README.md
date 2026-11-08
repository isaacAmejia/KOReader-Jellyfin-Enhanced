# KOReader Jellyfin Enhanced

A KOReader plugin for browsing and downloading **ebooks and audiobooks from your own Jellyfin server**.

This project is an enhanced fork of [KOReader-Jellyfin-Plugin](https://github.com/DeclanChidlow/KOReader-Jellyfin-Plugin) by Declan Chidlow (Vale). It keeps the original Jellyfin login and reading-status features while adding a more complete on-device library experience.

> This project is not affiliated with or endorsed by Jellyfin or KOReader.

## What it does

From KOReader you can:

- connect to your own Jellyfin server
- optionally prefer a local Jellyfin address at home and fall back to an external address away from home
- log in with username/password or Jellyfin Quick Connect
- browse Jellyfin book libraries
- see cover art, title, author, and description
- search a library
- page through results in an e-reader-friendly layout
- mark items read or unread in Jellyfin
- download ebooks to `books/eBooks/`
- download audiobooks to `books/AudioBooks/`
- save audiobook artwork as `<book>.sdr/cover.jpg`
- launch **Jellyfin: Browse Books** from KOReader's Dispatcher/gesture system

## Ebooks vs. audiobooks

### Ebooks

Ebooks work with this plugin by itself. After an ebook downloads, KOReader can open it normally if the file format is supported by KOReader.

### Audiobooks

This plugin downloads audiobook files and cover art, but it does **not** contain an audio player.

For a library-style audiobook experience, install the companion [KOReader Audiobook Bridge](https://github.com/isaacAmejia/KOReader-Audiobook-Bridge) and **Audiobook Read-Along**.

The resulting flow is:

```text
Jellyfin
   ↓
KOReader Jellyfin Enhanced
   ↓
books/AudioBooks/My Book.m4b
books/AudioBooks/My Book.sdr/cover.jpg
   ↓
KOReader Audiobook Bridge
   ↓
Audiobook Read-Along
```

## Requirements

- KOReader
- network access from the device to your Jellyfin server
- a Jellyfin account that can access one or more book libraries

The current development branch has been source-audited against **KOReader v2026.07.1**, the latest KOReader release at the time of this compatibility pass. It has also been checked against **Jellyfin Server v12.1** API routes. The plugin keeps fallbacks for older Jellyfin user-view, item-listing, and played-state endpoints.

The plugin uses KOReader data-directory APIs rather than Kindle-specific filesystem locations, so it is intended to be portable across KOReader platforms. A clean-device runtime test is still recommended before treating a development build as a release.

### Low-resource design

The browser is designed for slower e-readers: Jellyfin results are fetched in 40-item batches, full item metadata is loaded only for the selected book, covers are fetched only for the visible page, and the local thumbnail cache is bounded. The browser still minimizes runtime work through batched results, lazy per-item metadata, visible-page cover loading, and bounded caches. The core API/auth/UI modules intentionally load at plugin startup to preserve the official Jellyfin plugin's proven KOReader networking initialization behavior.

## Installation

1. Download **[jellyfin.koplugin.zip](https://github.com/isaacAmejia/KOReader-Jellyfin-Enhanced/releases/latest/download/jellyfin.koplugin.zip)**. This link always points to the latest release.
2. Unzip it and copy the `jellyfin.koplugin` folder into your KOReader `plugins` folder:

| Platform | KOReader plugin directory |
| --- | --- |
| Kindle | `koreader/plugins/` |
| Kobo | `.adds/koreader/plugins/` |
| Linux | `~/.config/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |

3. Restart KOReader.

If you are replacing a copy installed before updates were available, delete the old `jellyfin.koplugin` folder first. Your server addresses and login are stored in KOReader's settings, not in the plugin folder, so they are kept.

## Updating

After the first install, update from the device:

```text
Tools → Jellyfin Books → Check for updates
```

The plugin checks this repository's latest release, shows what changed, installs it, and asks you to restart KOReader. Your settings and login are kept. If a download fails or a file arrives damaged, the installed version is left untouched.

## Configuration

Open:

```text
Tools → Jellyfin Books
```

### 1. Configure Server Addresses

Choose **Server Addresses**.

The **external URL** is required and should be the address that works away from home, for example:

```text
https://jellyfin.example.com
```

The **local URL** is optional. If supplied, the plugin briefly checks whether that address is reachable and prefers it when available:

```text
http://192.168.1.20:8096
```

When the local address is not reachable, the plugin automatically uses the external address instead. This is useful on networks where the public Jellyfin hostname does not work from inside the LAN because the router lacks working NAT loopback/hairpin NAT.

The route decision is cached briefly to avoid repeatedly probing the local address on low-power devices. A trailing slash is optional; the plugin removes it automatically.

### 2. Log in

Choose **Login** and use either:

- **Login with Password** — enter your Jellyfin username and password on the device.
- **Login with Quick Connect** — KOReader displays a code that you approve from another Jellyfin client.

The password itself is not stored by this plugin. After a successful login, Jellyfin returns an access token and user ID that KOReader stores in its normal settings file.

### 3. Browse

Choose **Browse Books**.

The plugin shows Jellyfin libraries whose collection type is `books`. Choose a library to browse its items.

From the library screen you can:

- tap a book to view details
- use the search icon to search the current library
- use the arrows at the bottom to move between result pages
- load cover artwork only for the page being viewed, avoiding a long all-library cover download on large libraries

### 4. Download

On an item's detail screen choose **Download**.

A dedicated download dialog appears before the transfer starts. When Jellyfin supplies the media size, the dialog shows live byte progress; otherwise it remains visible as an indeterminate download screen until the transfer finishes.

Downloads are stored under KOReader's data directory:

```text
books/eBooks/
books/AudioBooks/
```

The plugin determines the actual KOReader data directory at runtime; no device-specific base path is hard-coded.

## Gestures, Dispatcher, and SimpleUI

The plugin registers this KOReader Dispatcher action:

```text
Jellyfin: Browse Books
```

You can assign that action to a KOReader gesture or another interface that supports Dispatcher actions.

SimpleUI is **optional**. If you use SimpleUI, create a Quick Action using the same Dispatcher action. No SimpleUI source files need to be replaced.

## Audiobook sidecar artwork

When Jellyfin identifies an item as an audiobook, the plugin creates a sidecar directory next to the downloaded file and attempts to save the item's primary Jellyfin image as `cover.jpg`.

Example:

```text
The Hobbit.m4b
The Hobbit.sdr/
└── cover.jpg
```

Cover download failure does not remove or invalidate the audiobook download.

The companion Audiobook Bridge can expose this sidecar image to compatible KOReader library UIs.

## Privacy and credentials

The repository contains **no server address, username, user ID, access token, or device-specific configuration**.

Your own Jellyfin server URL, user ID, and access token are stored locally by KOReader in its settings. Treat your KOReader settings file as sensitive and do not post it publicly without removing credentials first.

The plugin deliberately avoids logging full Jellyfin request URLs so routine logs do not unnecessarily expose your server hostname or Jellyfin user ID.

## Troubleshooting

### Browse Books is disabled

You are not currently authenticated. Configure the server and log in first.

### No libraries appear

This plugin currently browses Jellyfin libraries reported with the `books` collection type. Confirm the library is configured as a Books library in Jellyfin and that your user can access it.

### Check for updates fails

The device needs internet access to reach GitHub. GitHub also limits unauthenticated checks to 60 per hour per network; if you hit that limit, try again later.

### Login fails

Check that:

- both configured server URLs include `http://` or `https://`
- the KOReader device can reach the server
- the account credentials are correct
- Quick Connect is enabled on the Jellyfin server if you are using it

### Audiobooks download but do not open

Audio playback is outside this plugin's scope. Install Audiobook Read-Along and the companion KOReader Audiobook Bridge.

## Publishing a release

1. Set the new version in `jellyfin.koplugin/_meta.lua` and `BUILD_VERSION` in `jellyfin.koplugin/main.lua`.
2. Commit, then push a matching tag, for example `git tag v1.2.3 && git push origin v1.2.3`.

GitHub Actions checks that the tag matches the plugin version, builds `jellyfin.koplugin.zip`, and publishes the release. The download link above and **Check for updates** on devices both pick it up automatically.

## Attribution and license

This is a modified version of **KOReader-Jellyfin-Plugin** by Declan Chidlow (Vale).

The original project is licensed under the **GNU Affero General Public License v3.0**, and this enhanced fork remains under the same license. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).