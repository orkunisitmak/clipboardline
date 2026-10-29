# ClipBoardLine for Linux

[Main feature reference](../README.md) · [Linux guide](../docs/linux.md) · [Türkçe](#türkçe)

This folder contains the Linux edition of ClipBoardLine. It is an Electron
application derived from the [Windows edition](../windows/README.md) and keeps
its renderer, Library, OCR, offline image search, language catalogs and keyboard
map. The Linux desktop integration lives in `lib/linux-*.cjs`: clipboard
capture through `wl-clipboard` or X11 selections, global shortcuts, screenshots
through the desktop portal, FFmpeg recordings and XDG autostart.

It builds an AppImage, a `.deb` and an `.rpm`. There is no in-app update channel
yet; a newer package installed over an older one keeps the Library and settings.
See the [Linux guide](../docs/linux.md) for installation, what each desktop
provides and the optional packages.

## Development and validation

Node.js 24 and npm are required; building the `.rpm` also needs `rpm-build`.

```sh
cd linux
npm ci
python3 ../scripts/prepare-windows-search-models.py --config search-model-config.json --output assets/CLIP
npm test
npm start
npm run dist:linux        # dist/ClipBoardLine-<version>-x86_64.AppImage, .deb and .rpm
```

`npm run test:linux` launches the real application and checks clipboard
capture, copying out, file lists, Ctrl+Enter, recordings, shortcut commands,
the Linux settings pages and offline image search. It replaces the clipboard,
so run it only in a disposable session such as `xvfb-run`, headless Sway or a
nested compositor. Set `CLIPBOARDLINE_EXECUTABLE` to test the packaged app.
The [Linux workflow](../.github/workflows/linux.yml) runs both on X11 and
Wayland, builds the three packages and repeats acceptance with the packaged app.

See [component licenses and notices](THIRD_PARTY_NOTICES.md), the project
[privacy guide](../PRIVACY.md) and the [contribution guide](../CONTRIBUTING.md).

## Türkçe

Bu klasör ClipBoardLine’ın Linux sürümünü içerir. [Windows sürümünden](../windows/README.md)
türetilmiş bir Electron uygulamasıdır; arayüz, kütüphane, OCR, çevrimdışı görsel
arama, dil katalogları ve klavye haritası aynıdır. Linux masaüstü entegrasyonu
`lib/linux-*.cjs` dosyalarındadır. AppImage, `.deb` ve `.rpm` paketleri derlenir;
kurulum ve masaüstü farkları için [Linux rehberine](../docs/linux.md#türkçe) bakın.

```sh
cd linux
npm ci
python3 ../scripts/prepare-windows-search-models.py --config search-model-config.json --output assets/CLIP
npm test
npm run dist:linux
```

`npm run test:linux` gerçek uygulamayı açar ve panoyu değiştirir; yalnızca
`xvfb-run`, başsız Sway veya iç içe bir compositor gibi geçici bir oturumda
çalıştırın.
