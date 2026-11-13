# ClipBoardLine on Linux

The Linux edition runs the same Electron application as Windows (`windows/`).
Shelves, Library, search, OCR, visual search, markup, recordings and settings
are shared code. Only the operating-system bridge differs; it lives in
`windows/lib/linux-*.cjs` and is selected when `process.platform === 'linux'`.

English · [Türkçe](#türkçe)

Tested on CachyOS (KDE Plasma 6, Wayland). The bridge also supports X11
desktops, Hyprland, Sway and GNOME, with the limits listed below.

**Status:** Linux is a source build. There is no signed Linux release or in-app
update channel yet; packages are unsigned, x64 only and about 500 MB, because they
bundle the offline image search model. **Settings → Sources → Linux integration**
shows the active display, capture and paste mode and any missing package.

## Install

### Arch Linux, CachyOS, EndeavourOS, Manjaro

```sh
sudo pacman -S --needed git nodejs npm wl-clipboard xclip
git clone https://github.com/orkunisitmak/clipboardline.git
cd clipboardline/packaging/arch
makepkg -si
```

The package installs `/opt/ClipBoardLine`, a `clipboardline` launcher, a
desktop entry and the icon. Optional helpers:

| Package | Used for |
| --- | --- |
| `ydotool` | Automatic paste on KDE Plasma and GNOME Wayland (`systemctl --user enable --now ydotool`) |
| `wtype` | Automatic paste on Hyprland, Sway and other wlroots compositors |
| `xclip`, `xdotool` | Clipboard access, window targeting and paste in X11 sessions |
| `ffmpeg` | Recording inspection, trim, poster frames and audio checks |

### Other distributions

`npm run dist:linux` in `windows/` builds an AppImage, a `.deb`, an `.rpm` and
a `.pacman` package into `windows/dist/`. Prepare the image search models first
with `python3 ../scripts/prepare-windows-search-models.py`, or the packages have no
visual search. The Linux CI workflow uploads the same artifacts for pull requests
and `main` pushes that change the application or its packaging.

```sh
# Fedora and other dnf-based distributions
sudo dnf install ./ClipBoardLine-*-linux-x86_64.rpm
sudo dnf install ffmpeg-free

# openSUSE (the package is not signed)
sudo zypper install --allow-unsigned-rpm ./ClipBoardLine-*-linux-x86_64.rpm
sudo zypper install wl-clipboard xclip ffmpeg-7

# Ubuntu, Debian and derivatives (apt installs the recommended extras)
sudo apt install ./ClipBoardLine-*-linux-amd64.deb
```

Both clipboard tools are recommended: GNOME and other Mutter desktops need `xclip`
even on Wayland. The `.deb` installs the AppArmor profile Ubuntu 24.04 and later
require for Electron's sandbox. AppImages get no such profile there, so use the
`.deb`; elsewhere an AppImage needs FUSE 2.

## How the bridge works

| Capability | Wayland | X11 |
| --- | --- | --- |
| Read and watch clipboard | `wl-paste`, change events from `wl-paste --watch` | `xclip`, polling the selection `TIMESTAMP`, then content |
| Write clipboard | Electron with every format while focused; `wl-copy` with the main format while hidden | Electron with every format |
| Remember the previous window | KWin script (KDE), `hyprctl`, `swaymsg`; otherwise the compositor returns focus after the shelves hide | `xdotool` |
| Send paste (Control+V) | `ydotool` or `wtype` | `xdotool`, else `ydotool` |
| Keep shelves above other windows | KWin script (KDE); elsewhere the line closes when it loses focus | Window manager |
| Place the line | The compositor, on the monitor in use | Display under the pointer |
| Global shortcuts | XDG desktop portal (`GlobalShortcutsPortal`) | Electron global shortcuts |
| Launch at login | `~/.config/autostart/clipboardline.desktop` | same |
| Recordings | FFmpeg | FFmpeg |
| Screenshots | `xdg-desktop-portal` through `gdbus` (the desktop may ask once) | Electron desktop capture |
| Link files (Alt-drag, Export Copies) | freedesktop `.desktop` Link entries | same |

A native Wayland client cannot read the selection while it is hidden, so every
clipboard read goes through the selection tools. If `wl-paste --watch` stops,
capture continues only while ClipBoardLine is focused, because without
data-control each read would take focus from the active window. KWin scripts are loaded through `org.kde.KWin` on the
session bus and report window ids with a one-time nonce through the user
journal. They only read the active window and activate the captured window or
ClipBoardLine itself.

### Shortcuts without the portal

When a desktop does not offer the GlobalShortcuts portal, bind a custom system
shortcut to one of these commands. They control the running instance, or
start ClipBoardLine in that view when it is not running:

```sh
clipboardline --toggle    # show or hide the shelves
clipboardline --search    # open shelf search
clipboardline --library   # open the Library
clipboardline --copy-latest  # copy the newest image
clipboardline --screenshot   # capture the screen
```

The desktop entry exposes the first three actions. `--hidden` starts without
showing the shelves; the autostart entry uses it.

## Linux exceptions

These differences come from the platform and are user-visible:

- **Editable field detection.** Linux has no portable UI Automation
  equivalent. ClipBoardLine verifies that the same window is focused before
  it pastes, but it cannot tell whether that window's focused control is
  editable or a password field. Password managers that mark their copies
  (`x-kde-passwordManagerHint` and similar) are still excluded from capture.
- **GNOME Wayland and other compositors without a window API.** The previous
  window is not identified; paste relies on GNOME returning focus after the
  shelves hide.
- **Mutter desktops run through Xwayland.** GNOME, Ubuntu, Budgie, Pantheon and
  Cinnamon have no data-control protocol, so ClipBoardLine relaunches itself
  with `--ozone-platform=x11` and polls the mirrored selection with `xclip`.
  Install `xclip` there. Set `CLIPBOARDLINE_DISPLAY_BACKEND=wayland` or pass
  `--ozone-platform=wayland` to choose the native backend; hidden capture then
  does not work.
- **The line on Wayland.** The compositor places the line and it fills the monitor
  in use. Only KWin can keep it above other windows; on other compositors it closes
  when another window takes focus, except while its own dialog or drag is open.
- **Images survive the app that copied them.** A Linux selection disappears when
  its owner quits, as Spectacle does right after copying. ClipBoardLine serves a
  captured image again while its item is on the shelf. Text, links, recordings
  and deleted items are never served again.
- **One clipboard format while hidden on Wayland.** `wl-copy` offers one format, so
  a copy made while the window is hidden is text, a PNG or a `text/uri-list`.
  Several images or a recording always travel as a file list.
- **Recordings.** FFmpeg is the distribution's own. It opens recordings only with its
  MP4/MOV demuxer and the local file protocol. Trims are H.264/AAC where the build
  has those encoders and VP9/Opus otherwise, as on Fedora's `ffmpeg-free`.
- **Updates.** The signed update feed is Windows-only, so Linux makes no update
  check. Settings opens the releases page; install a newer package over the old one.
- **Paste key.** Paste sends Control+V. Terminals that need Control+Shift+V
  receive the copy on the clipboard; paste it manually there.

## Development

```sh
cd windows
npm ci
LC_ALL=C.UTF-8 npm test           # shared suite + Linux bridge tests
npm start                         # development profile ("ClipBoardLine Dev")
xvfb-run -a npm run test:linux    # real Electron clipboard acceptance on X11
```

To run the acceptance test on Wayland without touching your desktop session:

```sh
dbus-run-session -- kwin_wayland --virtual --socket clipboardline-test \
  --exit-with-session "env WAYLAND_DISPLAY=clipboardline-test npm run test:linux"
```

The shared suite contains Turkish/diacritic search fixtures whose expected
results assume a locale-neutral lower-case mapping; run it with
`LC_ALL=C.UTF-8` on systems with a Turkish default locale.

## Türkçe

Linux sürümü, Windows ile aynı Electron uygulamasıdır (`windows/`). Raflar, Kütüphane,
arama, OCR, görsel arama, işaretleme, kayıtlar ve ayarlar ortaktır; yalnızca işletim
sistemi köprüsü `windows/lib/linux-*.cjs` içinde ayrıdır. Linux henüz kaynaktan
derlenir: imzalı sürüm ve uygulama içi güncelleme yoktur, paketler imzasızdır, yalnızca
x64 içindir ve görsel arama modeli yüzünden yaklaşık 500 MB tutar.

Arch tabanlı dağıtımlarda:

```sh
sudo pacman -S --needed git nodejs npm wl-clipboard xclip
git clone https://github.com/orkunisitmak/clipboardline.git
cd clipboardline/packaging/arch
makepkg -si
```

Diğer dağıtımlarda `windows/` içinde `npm ci`,
`python3 ../scripts/prepare-windows-search-models.py` ve `npm run dist:linux`
komutlarını çalıştırın; AppImage, `.deb`, `.rpm` ve `.pacman` paketleri `windows/dist/`
içine yazılır. GNOME ve diğer Mutter masaüstleri Wayland'de bile `xclip` ister.
Ubuntu 24.04 ve sonrasında AppImage yerine `.deb` kullanın.

**Ayarlar → Kaynaklar → Linux entegrasyonu** etkin görüntü, yakalama ve yapıştırma
modunu ve eksik paketleri gösterir.

- **Wayland'de yapıştırma:** `ydotool` (KDE, GNOME) veya `wtype` (Hyprland, Sway)
  gerekir. Yoksa Ctrl+Enter kopyalar ve odağı geri verir; siz Ctrl+V'ye basarsınız.
- **Çizgi:** Wayland'de compositor çizgiyi kullandığınız monitöre yerleştirir. Yalnızca
  KDE üstte tutabilir; diğerlerinde başka pencere odak alınca çizgi kapanır.
- **Genel kısayollar:** Portal yoksa bir sistem kısayolunu `clipboardline --toggle`,
  `--search`, `--library`, `--copy-latest` veya `--screenshot` komutuna bağlayın.
- **Kopyalayan uygulama kapanınca:** Yakalanan görsel raftayken yeniden sunulur. Metin,
  bağlantı, kayıt ve silinen öğeler sunulmaz, böylece parola yöneticisinin temizlediği
  pano geri gelmez.
- **Güncellemeler:** Linux güncelleme kontrolü yapmaz. Ayarlar sürümler sayfasını açar;
  yeni paketi eskisinin üzerine kurun, Kütüphane ve ayarlar korunur.
- **Kayıtlar:** Dağıtımın FFmpeg paketi gerekir. Kırpmalar mümkünse H.264/AAC, değilse
  VP9/Opus olarak kaydedilir.
