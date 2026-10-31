# ClipBoardLine on Linux

The Linux edition runs the same Electron application as Windows (`windows/`).
Shelves, Library, search, OCR, visual search, markup, recordings and settings
are shared code. Only the operating-system bridge differs; it lives in
`windows/lib/linux-*.cjs` and is selected when `process.platform === 'linux'`.

Tested on CachyOS (KDE Plasma 6, Wayland). The bridge also supports X11
desktops, Hyprland, Sway and GNOME, with the limits listed below.

## Install

### Arch Linux, CachyOS, EndeavourOS, Manjaro

```sh
sudo pacman -S --needed nodejs npm wl-clipboard
cd packaging/arch
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
a `.pacman` package into `windows/dist/`. The Linux CI workflow uploads the same
artifacts for pull requests and `main` pushes that change the application or
its packaging. Install `wl-clipboard` (Wayland) or `xclip` (X11).

## How the bridge works

| Capability | Wayland | X11 |
| --- | --- | --- |
| Read, write and watch clipboard | `wl-paste`/`wl-copy`, change events from `wl-paste --watch` | `xclip`, digest polling |
| Remember the previous window | KWin script (KDE), `hyprctl`, `swaymsg`; otherwise the compositor returns focus after the shelves hide | `xdotool` |
| Send paste (Control+V) | `ydotool` or `wtype` | `xdotool`, else `ydotool` |
| Keep shelves above other windows | KWin script (KDE) | Window manager |
| Global shortcuts | XDG desktop portal (`GlobalShortcutsPortal`) | Electron global shortcuts |
| Launch at login | `~/.config/autostart/clipboardline.desktop` | same |
| Recordings | FFmpeg | FFmpeg |

A native Wayland client cannot read the selection while it is hidden, so every
clipboard read and write goes through the selection tools rather than
Electron's clipboard. KWin scripts are loaded through `org.kde.KWin` on the
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
```

The desktop entry exposes the same three actions. `--hidden` starts without
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
  shelves hide. GNOME has no data-control protocol, so the clipboard is polled.
- **One clipboard format per copy.** `wl-copy` and `xclip` offer one MIME type.
  A text copy is text, a single image copy is PNG, and several images or a
  recording are copied as a `text/uri-list` of the managed files. A selection
  that mixes images and text copies only the images; Windows also offers the
  text.
- **Updates.** The signed update feed is Windows-only. Update Linux builds with
  your package manager or a newer AppImage.
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
