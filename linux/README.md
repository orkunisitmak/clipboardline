# ClipBoardLine for Linux (preview)

This port shares the existing Electron application in `windows/`: the same shelves,
Library, keyboard handlers, editable previews, organization, Trash/retention,
translations, local Tesseract OCR and offline MobileCLIP search. Linux platform
adapters live alongside the Windows adapters; no second renderer or data model is
maintained. macOS sources, Windows installer identity and signed feeds are retained.

## Desktop support

- **X11**, or **XWayland inside a Wayland session**, is required. The source command
  and packaged launcher pass `--ozone-platform=x11` **before Electron starts**.
  Changing this switch inside `main.cjs` is too late to select the clipboard
  backend. Startup rejects a launch without the flag instead of mixing a Wayland
  clipboard with an unrelated X11 generation counter.
- The XFixes helper tracks only CLIPBOARD ownership generations and window IDs/PIDs.
  It never reads clipboard payloads or PRIMARY/middle-click selection. Electron
  inspects formats before payloads and validates the generation around each read.
  Concealed/password/history-excluded content, file-manager copies and the app's
  own copies are excluded. Capture fails closed if the helper is unavailable.
- Image and text capture start **off**; standalone-link capture starts on. Enabling
  collection skips existing clipboard contents. Link enrichment is configurable
  network access; OCR and visual search run locally.
- Global shortcuts are configurable: Ctrl+Alt+T shelves, Ctrl+Alt+S search,
  Ctrl+Alt+A capture. A desktop may reserve these; change them in Settings. Tray
  visibility requires the desktop's StatusNotifier/AppIndicator support.
- **Direct Ctrl+Enter paste is unavailable.** X11 window identity cannot verify a
  secure editable field. The action is disabled and its command rejects before
  changing the clipboard. Enter/Ctrl+C copies; switch to the destination and use
  Ctrl+V. On X11, ordinary copy requests return to the previous window; the window
  manager owns activation policy. Native Wayland destinations may require a manual
  switch. No global keyboard/security setting is changed.
- Screen capture uses Electron's X11 desktop capture. Under XWayland the compositor
  decides which screens/windows are exposed; native Wayland-only capture and
  portal integration are not claimed.
- Multi-image/video file copy provides `text/uri-list` and GNOME copied-files
  formats, with a first-image raster fallback for still-image batches. Receiving
  applications decide which formats to use. Text/link Alt-drag uses the shared
  portable file export behavior.
- Recordings use installed **FFmpeg and ffprobe**. MP4/MOV inspection, posters,
  playback and trimming preserve originals; trims create managed H.264/AAC MP4
  derivatives through the existing bounded queue. FFmpeg must include libx264/AAC
  encoders. No codec executable is fetched at runtime.
- Linux updates are **manual** package replacements. There is no signed Linux
  update feed, and Linux never checks or installs the Windows channel. This PR
  does not publish an official release or change coordinated Latest-release rules.

The native exceptions are also recorded in
[`contracts/shelf-behavior.json`](../contracts/shelf-behavior.json). Linux is a
preview platform; the existing mandatory macOS/Windows release gates remain.

## Build and run

Use Node.js 24+ and npm. On Debian/Ubuntu, install native build/runtime tools:

```sh
sudo apt-get install build-essential libx11-dev libxfixes-dev ffmpeg
cd windows
npm ci
# Pinned original models and their licenses, downloaded only at build time:
python3 ../scripts/prepare-windows-search-models.py
npm run start:linux
```

On Arch-based systems, the corresponding build packages are `base-devel libx11
libxfixes ffmpeg`. Electron also needs the usual GTK/NSS/GBM/audio runtime libraries.
The build fails if dependencies/models are missing; it does not substitute a
runtime network download. `npm run build:linux-native` compiles the small X11
helper without a Node native-addon ABI dependency.

Source runs use **ClipBoardLine Dev** under Electron's Linux app-data directory
(normally `$XDG_CONFIG_HOME/ClipBoardLine Dev` or `~/.config/ClipBoardLine Dev`).
Packaged runs use **ClipBoardLine**, separately from Dev. The private library and
media directories are secured to the current user with mode 0700; managed JSON
and images are created with 0600. Data is local and is not an encrypted vault.
Launch at login manages only its own XDG `autostart/clipboardline.desktop` entry;
turning it off removes that entry. Foreign entries are preserved.

```sh
cd windows
npm test
npm run test:linux
npm run dist:linux
```

Packaging currently targets **Linux x64**, producing:

- `windows/dist/ClipBoardLine-<version>-x86_64.AppImage`
- `windows/dist/ClipBoardLine-<version>-amd64.deb`

The Debian package declares system FFmpeg and Electron runtime dependencies.
AppImage users install these system dependencies themselves. If FUSE is unavailable,
use `APPIMAGE_EXTRACT_AND_RUN=1 ./ClipBoardLine-<version>-x86_64.AppImage`.
Keep Chromium sandboxing enabled. The packaged shell launcher selects X11; do not
launch the internal `clipboardline-bin` executable directly.

## Verification

Install `xvfb`, `openbox`, `xdotool` and `xauth` for a separate synthetic desktop:

```sh
cd windows
CLIPBOARDLINE_ISOLATED_DISPLAY=1 XDG_SESSION_TYPE=x11 \
  xvfb-run -a -s '-screen 0 1440x900x24 -nolisten tcp' \
  sh -c 'unset WAYLAND_DISPLAY; openbox --sm-disable >/dev/null 2>&1 & npm run test:linux:electron'
# Repeat with the packaged executable (same Xvfb command/environment):
# CLIPBOARDLINE_EXECUTABLE="$PWD/dist/linux-unpacked/clipboardline"
```

The runtime suite requires explicit isolation and uses temporary libraries plus a
separate Electron clipboard sender/receiver. It checks real clipboard generations,
UTF-8, privacy markers, PRIMARY exclusion, text/link/image capture, external copy,
file URI batches, global shortcuts, manual paste/focus, OCR, canvas pixel parity,
recording playback/trim, desktop capture, semantic inference and restart persistence.
Screenshots contain only synthetic test content. Reports/screenshots go to ignored
`validation/linux/`; do not commit them or real user data.

The Node suite also executes the shared shelf and Library behavior contracts through
the shipped renderer. On Linux, report metadata says `linux`; it cannot certify
Windows acceptance. Native FFmpeg tests verify red/green frames, decoded audio,
silent tracks, immutable originals and temporary-job cleanup. Autostart tests use
temporary XDG directories. File creation tests do not claim a subsequent login was
observed. See `.github/workflows/linux.yml` for source and packaged CI acceptance.

## Türkçe

Linux önizleme sürümü X11 veya Wayland içindeki XWayland ile çalışır. `windows`
klasöründe bağımlılıkları ve sabitlenmiş arama modellerini hazırladıktan sonra
`npm run start:linux` ile açılır; `npm run dist:linux` AppImage ve Debian paketi üretir.
Metin/görsel toplama varsayılan kapalıdır. Otomatik doğrudan yapıştırma yerine
kopyala, hedef uygulamaya geç ve Ctrl+V kullan. Video için sistemde FFmpeg gerekir.
Güncellemeler elle paket değiştirilerek yapılır; Linux, Windows güncelleme kanalını
kullanmaz. Yerel Wayland desteği ve gerçek oturum açılışı henüz doğrulanmış değildir.
