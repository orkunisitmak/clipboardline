# ClipBoardLine on Linux

[Türkçe özet](#türkçe-özet)

The Electron edition in [`windows/`](../windows) also runs on Linux. Shared
behavior (shelves, Library, search, OCR, offline image search, markup, Trash,
keyboard model) is unchanged; only the operating-system bridge differs. This
page lists what was incompatible, how each piece is provided on Linux, and the
remaining native exceptions.

## Compatibility audit (source 1.7.8 / build 71)

| Area | Problem on Linux before this change | Linux implementation |
| --- | --- | --- |
| Clipboard capture | `native.clipboardSequence()` returned `null` outside Windows, so the shared admission policy rejected **every** copy: nothing was ever captured. | `lib/linux-clipboard.cjs`: a change counter fed by `wl-paste --watch` (Wayland data-control) or X11 `TIMESTAMP` polling, with the same race, size, private-marker and ownership rules. |
| Reading in the background | Electron cannot read a Wayland selection while unfocused; through XWayland the compositor does not synchronize it either. | Reads go through `wl-paste` / `xclip`. `UTF8_STRING`, charset and X11 aliases become `text/plain`; JPEG/WebP/BMP offers are converted to PNG. |
| Copying an image | Electron's Linux `clipboard.write()` silently drops `image/png` and fails while the window is hidden (paste, copy-latest). | Writes go through `wl-copy` / `xclip` with an explicit MIME type (no content sniffing). Self-copies are recognized and never recaptured. |
| Multi-image copy, recordings | PowerShell/WinForms FileDrop only; failed on Linux. | `text/uri-list` of the managed files. |
| Paste into the previous app | UI Automation + `SendInput` (PowerShell) only. | X11: `xdotool` captures the window and process, re-activates and validates it, then sends Ctrl+V. Wayland: the compositor returns focus when the shelves hide; Ctrl+V is injected through `ydotool` (uinput). |
| Global shortcuts | Default `Control+Alt+T` is the terminal shortcut on KDE, GNOME and Ubuntu. KWin forwards only non-character combinations to XWayland key grabs, so letter shortcuts never fired on Plasma Wayland. | New Linux profiles default to `Control+Alt+V` (saved choices are kept). On Plasma Wayland shortcuts are registered with **kglobalaccel** over D-Bus and appear in System Settings → Shortcuts; registrations left by a killed instance are removed at the next start, and Ctrl+C/SIGTERM/SIGHUP quit cleanly. X11 sessions use Electron key grabs. Any desktop can bind `clipboardline --toggle`, `--search`, `--library`, `--screenshot` or `--copy-latest`. |
| Overlay window | Through XWayland, Electron 44's GPU process crashes on Mesa/Intel and the software fallback presents nothing: the transparent shelves were invisible although every state check passed. | On a Wayland session the window is a native Wayland client with GPU compositing. `CLIPBOARDLINE_OZONE_PLATFORM=x11` forces XWayland. Non-Plasma Wayland desktops get global shortcuts through the XDG portal. |
| Screenshots | `desktopCapturer` under XWayland sees only X11 windows. | `spectacle`, `grim`, `gnome-screenshot`, `xfce4-screenshooter` or `scrot`, then `desktopCapturer`. |
| Screen recordings | WinRT `Windows.Media.Editing` helper only. | `lib/linux-media.cjs` uses `ffprobe`/`ffmpeg` (H.264/AAC re-encode for trims; same poster, duration and source-identity checks). |
| Launch at login | `app.setLoginItemSettings` is not implemented on Linux. | XDG autostart entry in `~/.config/autostart/clipboardline.desktop`. |
| Updates | The signed feed contains a Windows installer; a Linux client would have offered it. | Disabled on Linux; packages are updated outside the app. |
| Private data folder | ACLs were applied only on Windows. | The profile is forced to mode `0700`. |
| Link export | `.url` (Windows Internet Shortcut). | freedesktop `Type=Link` `.desktop` file. |
| Packaging | NSIS target only. | `npm run dist:linux`: AppImage, `.deb` and `.pacman`. |

## Runtime tools

| Purpose | Wayland | X11 |
| --- | --- | --- |
| Clipboard (required) | `wl-clipboard` (compositor with data-control: KDE, wlroots, …) | `xclip` (Electron fallback without it) |
| Automatic paste (optional) | `ydotool` with the `ydotoold` service running | `xdotool` |
| Recordings (optional) | `ffmpeg` | `ffmpeg` |
| Screenshots (optional) | `spectacle` / `grim` / `gnome-screenshot` | any of those or built-in capture |
| Plasma global shortcuts | `gdbus` (glib2) | — |

Without a paste tool, Enter still copies; Ctrl+Enter reports what to install.

## Native exceptions (Linux)

- **Single MIME type per copy.** `wl-copy`/`xclip` publish one type. A single
  image is offered as PNG (accompanying text is not), several images or a
  recording as a file list. Windows offers text, bitmap and FileDrop together.
- **Wayland paste validation.** Wayland never reveals another client's window,
  so the destination is "the window that regains focus" rather than a verified
  field. Secure-field detection is not available. X11 keeps window/process
  validation. Terminals usually need Ctrl+Shift+V: set
  `CLIPBOARDLINE_PASTE_KEYS=ctrl+shift+v` (or `shift+insert`). `ydotool` sends
  physical key positions, so non-QWERTY layouts such as Turkish F or Dvorak
  should use `shift+insert`.
- **GNOME Wayland.** Mutter has no data-control protocol: the clipboard falls
  back to XWayland polling and global shortcuts should be bound to the
  `clipboardline --…` commands in Settings → Keyboard.
- **Default toggle shortcut** is `Control+Alt+V` on new Linux profiles because
  `Control+Alt+T` opens the terminal.

## Build and validate

```sh
cd windows
npm ci
npm test                 # includes the Linux unit tests (OS-independent)
npm run test:linux       # native acceptance on a live Wayland session
npm run dist:linux       # AppImage, .deb and .pacman in dist/
```

`npm run test:linux` launches the real application with an isolated profile
and checks that the shelves are actually drawn (screen pixels with the shelves
hidden versus shown), that the shortcut opens them with keyboard focus, and
background text/link/PNG/JPEG capture, ownership of self-copies,
image and file-list publication, FFmpeg import/trim, screenshots, the global
shortcut and a real paste into a disposable Wayland editor. It saves and
restores the current text or image clipboard, and finally quits the app and
verifies that no clipboard watcher or Plasma shortcut registration remains. To
check a packaged build instead of the source tree:

```sh
npx electron-builder --linux dir --x64 --publish never
CLIPBOARDLINE_EXECUTABLE=dist/linux-unpacked/clipboardline npm run test:linux
```

Verified on CachyOS, KDE Plasma 6.8.1 (Wayland), Intel Iris Xe/Mesa 26.2,
Electron 44.9: 19/19 checks for the source tree, the packaged build and the
installed pacman package.

## Türkçe özet

Electron sürümü artık Linux'ta da çalışır. Önceki durumda Linux'ta pano
yakalama hiç çalışmıyordu (Windows'a özel sıra numarası `null` dönüyordu),
görsel kopyalama sessizce boş kalıyordu, video/yapıştırma/çoklu görsel
PowerShell'e bağlıydı ve `Ctrl+Alt+T` terminal kısayoluyla çakışıyordu.

Linux köprüsü: pano için `wl-clipboard`/`xclip`, yapıştırma için
`xdotool` (X11) veya `ydotool` (Wayland), video için `ffmpeg`, ekran görüntüsü
için `spectacle`/`grim`/`gnome-screenshot`, Plasma'da genel kısayollar için
kglobalaccel (D-Bus). Wayland oturumunda pencere yerel Wayland istemcisi
olarak çalışır; XWayland'de Electron 44'ün GPU süreci Mesa/Intel üzerinde
çöktüğü için raflar görünmüyordu. Yeni Linux profillerinde varsayılan kısayol
`Ctrl+Alt+V`'dir. Paketler: `npm run dist:linux` (AppImage, .deb, .pacman).
Doğrulama: `npm test` ve canlı oturumda `npm run test:linux`.
