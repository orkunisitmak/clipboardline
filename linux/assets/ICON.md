ClipBoardLine uses the same original clipboard artwork on both platforms.

Regenerate on macOS, from the repository root:

```sh
xcrun swift scripts/make-review-icon.swift windows/assets/clipboardline.png
xcrun swift windows/scripts/make-icon.swift windows/assets/clipboardline.png windows/assets/clipboardline.ico
```

The PNG is byte-identical to the macOS build's artwork. The ICO contains
16, 24, 32, 48, 64, 128 and 256px PNG frames for Windows display scaling.

Linux packages install the freedesktop hicolor sizes from `assets/linux-icons`
(16–512px), rendered from the same PNG on any platform with Electron:

```sh
cd windows
npx electron scripts/make-linux-icons.cjs assets/clipboardline.png assets/linux-icons
```
