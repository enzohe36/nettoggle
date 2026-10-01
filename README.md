# NetToggle

A small macOS app that lists the apps in `/Applications` and turns each one's internet access on or off.

## How it works

Switching an app's network off renames `X.app` to `X.app.bak`, next to it in the same folder, and puts a small launcher named `X.app` in its place. The launcher has the original's name, icon, bundle ID and document types, so the Dock, Finder, Spotlight, Launchpad and double-clicked files all open it. It starts the original from `X.app.bak` under `sandbox-exec`, with outgoing and listening IP connections denied. The app and every helper it starts run without internet; everything else works normally. Switching network on removes the launcher and renames `X.app.bak` back. The original app is never modified, and its code signature stays valid.

## Limitations

- Apps that use Apple's App Sandbox (most Mac App Store apps) are killed by `sandbox-exec`, so their switches are disabled. Use a system firewall such as [LuLu](https://objective-see.org/products/lulu.html) for those.
- Network traffic that an app hands to system services (e.g. Safari's web content processes) is not covered.
- An app must be quit while it is switched; NetToggle offers to quit and reopen it.
- Switch network on before updating an app. An updater that installs over the launcher leaves a stale `X.app.bak`, which NetToggle flags.
- Click **Restore All** before deleting NetToggle; otherwise blocked apps stay swapped.
- Folders owned by root (e.g. Adobe's) need an admin password. macOS may also ask you to allow NetToggle under System Settings → Privacy & Security → App Management.

## Build

Requires macOS 13+, the Xcode Command Line Tools and Python 3 with Pillow.

```sh
./build.sh
```

This draws the icon (`make_icon.py`), compiles `NetToggle.swift` and writes `~/Applications/NetToggle.app`, signed ad hoc.

`build.sh` works around a stray `usr/include/swift/module.modulemap` in some Command Line Tools installs, which duplicates `bridging.modulemap` and fails the build with "redefinition of module 'SwiftBridging'". Deleting that file also fixes it.
