# Contributing / Katkıda bulunma

## English

This public repository is a reviewed source snapshot of the independent ClipBoardLine project. Work in a branch and submit a pull request with the concrete problem, resulting behavior and relevant validation. Keep changes scoped; preserve keyboard navigation, editable previews, retention, recoverable deletion and privacy choices when changing adjacent features.

### macOS development

Use macOS 14 or newer with a selected Xcode/Swift toolchain capable of compiling the source. Python 3 is used for packaging and synthetic checks. The first dependency resolution downloads the pinned Sparkle release.

```sh
swift package resolve
swift test
bash scripts/test-clipboard.sh
bash scripts/test-history.sh
swift scripts/check-strings.swift
bash scripts/build-community.sh
```

The last command creates `build/ClipBoardLine Dev.app` for your Mac's architecture. It does not install or launch it. The development app is ad-hoc signed, uses bundle identifier `org.clipboardline.community`, and stores history separately at `~/Library/Application Support/ClipBoardLine Dev/Screenshots/`. Link enrichment defaults to off in this build. Official in-app updates are deliberately unavailable in this separate build. Download the signed official application from the [public releases](https://github.com/orkunisitmak/clipboardline-app/releases) if you want that update channel.

Optional semantic image search models can be bundled explicitly:

```sh
CLIPBOARDLINE_BUNDLE_MODELS=1 bash scripts/build-community.sh
```

This downloads pinned model assets at build time and retains their licenses. Without them, local Vision OCR remains available. The model files and generated applications belong in ignored output folders.

Running `swift run` directly is not the packaged development workflow: it lacks the application resources, branded icon, permission identity and isolated storage overlay produced by the builder. Use the built Dev bundle for UI tests. Stop one app or assign different global shortcuts before running Dev beside the official application. Development rebuilds may need their own macOS permission refresh; do not modify the official app's permission or signing setup to make a development test pass.

### Changes and evidence

- Use synthetic clipboard text, generated images and temporary directories in tests. Do not commit real clipboard contents, screenshots of accounts, library databases, API keys, private URLs, crash logs with personal paths, or signing material.
- Add a focused regression test for a meaningful behavior fix. Run the affected tests and the platform's broader relevant checks; distinguish source tests from a real native UI journey.
- Keep the English string keys and translations consistent. Document new shortcuts and test interaction with text editing and modifier keys.
- Preserve dependency versions, attribution and complete license notices. Do not replace the official release trust key, frozen helper, certificate, bundle identifier or update configuration in order to distribute a community build.
- Do not open a pull request with secrets in its history. Remove sensitive material before publishing and follow [SECURITY.md](SECURITY.md) if it was exposed.

Windows has its own implementation and build instructions. A macOS build/test cannot certify a Windows installer, clipboard interaction or global keyboard hook. State which platform and package you actually exercised.

### Linux development

The Electron project in `windows/` also builds for Linux; the Linux desktop integration lives in separate `windows/lib/linux-*.cjs` files. Use Node.js 24 on Linux x64; see the [Linux guide](docs/linux.md) for optional packages.

```sh
cd windows
npm ci
npm test
npm run dist:linux
```

`npm run test:linux` launches the real application and replaces the clipboard: run it only inside a disposable session (`xvfb-run`, headless Sway or a nested compositor), never on a desktop that holds personal clipboard data. A Linux run does not certify Windows or macOS behavior, and Windows acceptance on Linux is still rejected. Keep Linux-only behavior behind the Linux session or `state.platform === 'linux'` so the Windows build is unchanged; a fix to shared code reaches both editions.

## Türkçe

Bu public repo, bağımsız ClipBoardLine projesinin incelenmiş kaynak kod kopyasıdır. Bir dalda çalışıp sorunu, yeni davranışı ve doğrulamayı anlatan PR açın. Klavye akışını, düzenlenebilir önizlemeleri, geçmiş sürelerini, geri alınabilir silmeyi ve gizlilik tercihlerini koruyun.

macOS geliştirmesi için seçilmiş bir Xcode/Swift araç zinciri ve Python 3 gerekir. Yukarıdaki testlerden sonra `bash scripts/build-community.sh`, `build/ClipBoardLine Dev.app` oluşturur; uygulamayı kurmaz veya açmaz. Dev derlemesi kendi `org.clipboardline.community` kimliğini ve ayrı veri klasörünü kullanır. Link önizlemesi ve resmî güncelleme kanalı Dev derlemesinde varsayılan olarak kapalıdır; resmî güncelleme kanalı için imzalı resmî paketi indirin.

Anlamsal arama modelleri isteğe bağlıdır: `CLIPBOARDLINE_BUNDLE_MODELS=1 bash scripts/build-community.sh`. Model olmadan yerel Vision OCR kullanılabilir. Çıplak `swift run` yerine, kaynakları ve ayrı veri alanı hazırlanan Dev paketini UI testi için kullanın.

Testlerde yapay metin/görsel ve geçici dizin kullanın. Kişisel pano içeriği, hesap ekran görüntüsü, veritabanı, anahtar, özel URL veya imza dosyası commit etmeyin. Yeni kısayolları ve çevirileri güncel tutun. macOS'ta geçen testleri Windows'ta da geçmiş gibi sunmayın; gerçekten denediğiniz platformu ve paketi belirtin.

`windows/` içindeki Electron projesi Linux için de derlenir; Linux masaüstü entegrasyonu ayrı `windows/lib/linux-*.cjs` dosyalarındadır. Orada `npm ci`, `npm test` ve `npm run dist:linux` çalıştırın. `npm run test:linux` gerçek uygulamayı açar ve panoyu değiştirir; yalnızca geçici bir oturumda (`xvfb-run`, başsız Sway veya iç içe compositor) çalıştırın. Yalnızca Linux’a özgü davranışı Linux oturumu veya `state.platform === 'linux'` koşuluna bağlayın, böylece Windows derlemesi değişmez; ortak koddaki bir düzeltme iki sürüme de ulaşır. Ayrıntılar için [Linux rehberine](docs/linux.md#türkçe) bakın.
