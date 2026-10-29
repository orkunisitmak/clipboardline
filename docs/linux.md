# ClipBoardLine on Linux

English · [Türkçe](#türkçe)

The Electron edition in [`windows/`](../windows) also builds for Linux x64 as an
AppImage, a `.deb` and an `.rpm`. Linux runs the same renderer, Library, Tesseract
OCR (English/Turkish), offline MobileCLIP-S2 image search, nine language catalogs,
settings and Control/Alt keyboard map as Windows. The Linux desktop integration
lives in `windows/lib/linux-*.cjs`.

**Status:** Linux is a source build. There is no official signed Linux release or
in-app update channel yet; newer packages are installed over older ones and keep
the Library and settings.

## Install a package

Build the packages (see [Development](#development-and-validation)) or download
them from a release that lists Linux assets.

```sh
# Fedora, openSUSE and other RPM distributions
sudo dnf install ./ClipBoardLine-1.7.8-x86_64.rpm
sudo dnf install wl-clipboard ffmpeg-free     # recommended extras

# Ubuntu, Debian and derivatives (apt also installs the recommended extras)
sudo apt install ./ClipBoardLine-1.7.8-amd64.deb
```

The packages install `/opt/ClipBoardLine/clipboardline`, a desktop entry
(`com.clipboardline.ClipBoardLine.desktop`) and hicolor icons. The `.deb` also
installs the AppArmor profile that Ubuntu 24.04 and later require for Electron's
sandbox.

The AppImage runs without installation (`chmod +x ClipBoardLine-*.AppImage`). It
needs FUSE 2 (`sudo apt install libfuse2t64` on Ubuntu 24.04). On Ubuntu 24.04 and
later, prefer the `.deb`: AppImages have no AppArmor profile there, so Electron's
sandbox cannot start.

## What each desktop provides

ClipBoardLine picks its display backend at startup. Set
`CLIPBOARDLINE_DISPLAY_BACKEND=x11` or `wayland` (or pass
`--ozone-platform=x11|wayland`) to override it. **Settings → Sources → Linux
integration** shows the active mode and any missing optional package.

| | KDE Plasma, Sway, Hyprland (Wayland) | GNOME, Ubuntu (Wayland) | X11 desktops (Xfce, MATE, Cinnamon …) |
| --- | --- | --- | --- |
| Display backend | Native Wayland | Xwayland | X11 |
| Background clipboard capture | `wl-clipboard` through the data-control protocol | Mutter mirrors the selection to Xwayland | X11 selection polling |
| Global shortcuts | Desktop GlobalShortcuts portal; approve the request once | Bind a custom shortcut to a [command](#shortcut-commands); Xwayland key grabs only fire while an X11 window is focused | X11 key grabs |
| Screen capture | Screenshot portal (the desktop may ask once) | Screenshot portal | Direct capture |
| Ctrl+Enter | Copies, hides and returns focus; press Ctrl+V | Same as Wayland | Also pastes into the same, still active window when `xdotool` is installed |
| Tray icon | StatusNotifierItem | Needs the AppIndicator extension (preinstalled on Ubuntu) | Most panels |

Mutter (GNOME) offers no data-control protocol, which is why GNOME uses Xwayland.
Without `wl-clipboard` on KDE or wlroots compositors, copies are captured only while
ClipBoardLine is focused. Wayland never lets an application inject keystrokes or
inspect another application's text field, so ClipBoardLine does not paste there on
its own.

### Shortcut commands

A second launch forwards one of these actions to the running instance:

```sh
clipboardline --toggle        # show or hide the shelves
clipboardline --search        # open shelf search
clipboardline --library       # open the Library
clipboardline --copy-latest   # copy the newest image
clipboardline --screenshot    # capture the screen
```

Use the AppImage path in place of `clipboardline` for an AppImage. On GNOME add
them under **Settings → Keyboard → View and Customize Shortcuts → Custom
Shortcuts**.

## Optional packages

| Package | Enables |
| --- | --- |
| `wl-clipboard` | Background capture and copying while hidden on KDE and wlroots compositors |
| `ffmpeg` (`ffmpeg-free` on Fedora) | Importing, posters and trimming of `.mp4`/`.mov` recordings |
| `xdotool` | Automatic paste with Ctrl+Enter under X11 |
| `xdg-desktop-portal` with your desktop's backend | Wayland screenshots and global shortcuts (installed by default on desktop editions) |

Trimming writes a new managed MP4 with H.264/AAC. When the distribution's FFmpeg has
no working H.264 encoder (Fedora's `ffmpeg-free` needs Cisco's OpenH264), it writes
VP9/Opus in MP4 instead, which the preview still plays. FFmpeg is never downloaded
by ClipBoardLine.

## Data, privacy and integration

- The Library lives in `~/.config/ClipBoardLine` (`~/.config/ClipBoardLine Dev` for
  `npm start`), restricted to your user (0700).
- The shared privacy policy applies: concealed or password-manager markers, such as
  KDE's `x-kde-passwordManagerHint` set by KeePassXC, are never captured, and
  ClipBoardLine skips its own copies.
- The screenshot portal's temporary file is removed after it is imported.
- Several images or recordings are copied as a file list (`text/uri-list` and
  GNOME's copied-files format) with the first still image as PNG.
- Link exports and Alt-drag use freedesktop `.desktop` link files.
- **Launch at login** writes `~/.config/autostart/clipboardline.desktop`; an
  existing entry written by something else is never replaced.

## Development and validation

Node.js 24 and npm are required. Building `.rpm` also needs `rpm-build`
(`rpm` on Ubuntu); on Fedora, electron-builder's bundled packaging tool also needs
`libxcrypt-compat`.

```sh
cd windows
npm ci
python3 ../scripts/prepare-windows-search-models.py   # optional offline image search
npm test
npm start
npm run dist:linux        # dist/ClipBoardLine-<version>-x86_64.AppImage, .deb and .rpm
```

`npm run test:linux` launches the real app and checks capture, copying out, file
lists, Ctrl+Enter, recordings, shortcut commands and the Linux settings pages. It
replaces the clipboard, so run it only in a disposable session such as
`xvfb-run`, headless Sway or a nested compositor. Set `CLIPBOARDLINE_EXECUTABLE`
to test `dist/linux-unpacked/clipboardline` or the AppImage.

The [Linux workflow](../.github/workflows/linux.yml) runs the unit and renderer
suites, runtime acceptance on X11 (Xvfb) and Wayland (headless Sway), builds the
three packages and repeats acceptance with the packaged app. With
`CLIPBOARDLINE_PARITY_REPORT=validation/parity/linux.json`, `npm test` on Linux
writes `linux.json` and `library-linux.json`; both parity checkers verify them with
`--linux-report`. The Mac and Windows reports remain mandatory for every release.

## Türkçe

[`windows/`](../windows) klasöründeki Electron sürümü Linux x64 için AppImage,
`.deb` ve `.rpm` olarak da derlenir. Linux; Windows ile aynı arayüzü, kütüphaneyi,
İngilizce/Türkçe Tesseract OCR’ı, çevrimdışı MobileCLIP-S2 görsel aramasını, dokuz
dil kataloğunu, ayarları ve Control/Alt kısayollarını kullanır. Linux masaüstü
entegrasyonu `windows/lib/linux-*.cjs` dosyalarındadır.

**Durum:** Linux kaynak koddan derlenir. Henüz resmî imzalı bir Linux sürümü veya
uygulama içi güncelleme kanalı yoktur; yeni paket eskisinin üstüne kurulur,
kütüphane ve ayarlar korunur.

### Paket kurulumu

```sh
# Fedora, openSUSE ve diğer RPM dağıtımları
sudo dnf install ./ClipBoardLine-1.7.8-x86_64.rpm
sudo dnf install wl-clipboard ffmpeg-free     # önerilen ek paketler

# Ubuntu, Debian ve türevleri (apt önerilen ek paketleri de kurar)
sudo apt install ./ClipBoardLine-1.7.8-amd64.deb
```

Paketler `/opt/ClipBoardLine/clipboardline`, masaüstü girdisi
(`com.clipboardline.ClipBoardLine.desktop`) ve simgeleri kurar. `.deb`, Ubuntu
24.04 ve sonrasında Electron sandbox’ı için gereken AppArmor profilini de kurar.
AppImage kurulum gerektirmez (`chmod +x`), FUSE 2 ister (Ubuntu 24.04’te
`sudo apt install libfuse2t64`). Ubuntu 24.04 ve sonrasında `.deb` tercih edin;
AppImage için AppArmor profili olmadığından sandbox başlayamaz.

### Masaüstüne göre davranış

Görüntü altyapısı açılışta seçilir; `CLIPBOARDLINE_DISPLAY_BACKEND=x11` veya
`wayland` (ya da `--ozone-platform=x11|wayland`) ile değiştirilebilir. **Ayarlar →
Kaynaklar → Linux integration** etkin modu ve eksik isteğe bağlı paketleri gösterir.

| | KDE Plasma, Sway, Hyprland (Wayland) | GNOME, Ubuntu (Wayland) | X11 masaüstleri (Xfce, MATE, Cinnamon …) |
| --- | --- | --- | --- |
| Görüntü altyapısı | Yerel Wayland | Xwayland | X11 |
| Arka planda pano toplama | Data-control protokolüyle `wl-clipboard` | Mutter seçimi Xwayland’e yansıtır | X11 seçimini yoklama |
| Genel kısayollar | Masaüstünün GlobalShortcuts portalı; isteği bir kez onaylayın | Bir [komuta](#kısayol-komutları) özel kısayol atayın; Xwayland tuş yakalama yalnızca bir X11 penceresi odaktayken çalışır | X11 tuş yakalama |
| Ekran yakalama | Screenshot portalı (masaüstü bir kez izin isteyebilir) | Screenshot portalı | Doğrudan yakalama |
| Ctrl+Enter | Kopyalar, gizler ve odağı geri verir; Ctrl+V’ye basın | Wayland ile aynı | `xdotool` kuruluysa aynı, hâlâ etkin pencereye yapıştırır |
| Tepsi simgesi | StatusNotifierItem | AppIndicator eklentisi gerekir (Ubuntu’da hazır gelir) | Çoğu panel |

GNOME’un Mutter’ı data-control protokolü sunmadığı için GNOME’da Xwayland
kullanılır. KDE veya wlroots tabanlı ortamlarda `wl-clipboard` yoksa kopyalar
yalnızca ClipBoardLine odaktayken toplanır. Wayland, başka bir uygulamaya tuş
göndermeye veya onun metin alanını incelemeye izin vermez; bu yüzden orada
yapıştırma tuşuna siz basarsınız.

### Kısayol komutları

İkinci açılış, aşağıdaki işlemlerden birini çalışan uygulamaya iletir:

```sh
clipboardline --toggle        # askıları göster/gizle
clipboardline --search        # askı aramasını aç
clipboardline --library       # kütüphaneyi aç
clipboardline --copy-latest   # en yeni görseli kopyala
clipboardline --screenshot    # ekranı yakala
```

AppImage için `clipboardline` yerine AppImage dosyasının yolunu kullanın. GNOME’da
**Ayarlar → Klavye → Kısayolları Görüntüle ve Özelleştir → Özel Kısayollar**
altından ekleyin.

### İsteğe bağlı paketler

- `wl-clipboard`: KDE ve wlroots ortamlarında arka planda toplama ve gizliyken kopyalama.
- `ffmpeg` (Fedora’da `ffmpeg-free`): `.mp4`/`.mov` kayıtlarını içe aktarma, küçük görsel ve kırpma.
  Kırpma H.264/AAC MP4 yazar; çalışan H.264 kodlayıcı yoksa (Fedora’da Cisco
  OpenH264 gerekir) önizlemenin oynatabildiği VP9/Opus MP4 yazar. FFmpeg uygulama
  tarafından indirilmez.
- `xdotool`: X11’de Ctrl+Enter ile otomatik yapıştırma.
- Masaüstünüzün `xdg-desktop-portal` arka ucu: Wayland ekran görüntüsü ve genel kısayollar.

### Veri, gizlilik ve entegrasyon

- Kütüphane `~/.config/ClipBoardLine` içinde yalnızca kullanıcınıza açık (0700)
  tutulur; `npm start` için `~/.config/ClipBoardLine Dev` kullanılır.
- Ortak gizlilik kuralları geçerlidir: KeePassXC’nin koyduğu
  `x-kde-passwordManagerHint` gibi gizli/parola yöneticisi işaretli kopyalar
  toplanmaz; ClipBoardLine kendi kopyalarını atlar.
- Screenshot portalının geçici dosyası içe aktarıldıktan sonra silinir.
- Birden çok görsel veya kayıt, dosya listesi (`text/uri-list` ve GNOME biçimi) ve
  ilk görselin PNG’si olarak kopyalanır. Link dışa aktarma ve Alt ile sürükleme
  freedesktop `.desktop` link dosyaları kullanır.
- **Oturum açılışında başlat** `~/.config/autostart/clipboardline.desktop`
  dosyasını yazar; başka bir aracın yazdığı aynı adlı girdiyi değiştirmez.

### Geliştirme ve doğrulama

Node.js 24 ve npm gerekir. `.rpm` için `rpm-build` (Ubuntu’da `rpm`), Fedora’da
electron-builder’ın paketleme aracı için ayrıca `libxcrypt-compat` gerekir.

```sh
cd windows
npm ci
npm test
npm start
npm run dist:linux        # AppImage, .deb ve .rpm
```

`npm run test:linux` gerçek uygulamayı açıp pano toplama, dışarı kopyalama,
dosya listeleri, Ctrl+Enter, kayıtlar, kısayol komutları ve Linux ayar sayfalarını
denetler. Panoyu değiştirdiği için yalnızca `xvfb-run`, başsız Sway veya iç içe bir
compositor gibi geçici bir oturumda çalıştırın. [Linux iş akışı](../.github/workflows/linux.yml)
X11 ve Wayland’de kabul testlerini çalıştırır, üç paketi derler ve paketlenmiş
uygulamayla testi tekrarlar. Linux’ta `npm test`, eşlik raporlarını
`linux.json` ve `library-linux.json` olarak yazar; denetleyiciler bunları
`--linux-report` ile doğrular. Mac ve Windows raporları her yayım için zorunlu kalır.
