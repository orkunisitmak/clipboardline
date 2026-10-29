ClipBoardLine uses the same original clipboard artwork on both platforms.

Regenerate on macOS, from the repository root:

```sh
xcrun swift scripts/make-review-icon.swift windows/assets/clipboardline.png
xcrun swift windows/scripts/make-icon.swift windows/assets/clipboardline.png windows/assets/clipboardline.ico
```

The PNG is byte-identical to the macOS build's artwork. The ICO contains
16, 24, 32, 48, 64, 128 and 256px PNG frames for Windows display scaling.
