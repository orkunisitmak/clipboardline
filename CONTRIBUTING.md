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

### How pull requests are reviewed

This project is maintained by one person, with automated help. To keep reviews fair and fast:

- **Features start with an issue.** Before building a new feature or changing how the app looks or behaves, open an issue that describes the idea. Once the maintainer accepts it (the `accepted` label or a maintainer comment), a pull request is welcome. Feature pull requests opened without an accepted issue are closed with a friendly note and can be reopened once the issue is accepted.
- **Bug fixes, translations, documentation and tests** can go straight to a pull request.
- **At most 5 open pull requests per contributor.** If you already have 5 open, please wait until some are merged or closed. Newer pull requests over the limit are closed with a note.
- **One change per pull request.** Small, focused pull requests are reviewed first; large mixed ones are asked to be split.
- **Keep your branch current.** Pull requests that conflict with `main` or fail CI wait for their author. If a useful fix stays stuck for a long time, the maintainer may finish it and credit you as co-author.
- Pull requests are reviewed about a day after their last commit, a few per day, oldest first. New dependencies, CI, release, signing and update changes always get a closer look.

## Türkçe

Bu public repo, bağımsız ClipBoardLine projesinin incelenmiş kaynak kod kopyasıdır. Bir dalda çalışıp sorunu, yeni davranışı ve doğrulamayı anlatan PR açın. Klavye akışını, düzenlenebilir önizlemeleri, geçmiş sürelerini, geri alınabilir silmeyi ve gizlilik tercihlerini koruyun.

macOS geliştirmesi için seçilmiş bir Xcode/Swift araç zinciri ve Python 3 gerekir. Yukarıdaki testlerden sonra `bash scripts/build-community.sh`, `build/ClipBoardLine Dev.app` oluşturur; uygulamayı kurmaz veya açmaz. Dev derlemesi kendi `org.clipboardline.community` kimliğini ve ayrı veri klasörünü kullanır. Link önizlemesi ve resmî güncelleme kanalı Dev derlemesinde varsayılan olarak kapalıdır; resmî güncelleme kanalı için imzalı resmî paketi indirin.

Anlamsal arama modelleri isteğe bağlıdır: `CLIPBOARDLINE_BUNDLE_MODELS=1 bash scripts/build-community.sh`. Model olmadan yerel Vision OCR kullanılabilir. Çıplak `swift run` yerine, kaynakları ve ayrı veri alanı hazırlanan Dev paketini UI testi için kullanın.

Testlerde yapay metin/görsel ve geçici dizin kullanın. Kişisel pano içeriği, hesap ekran görüntüsü, veritabanı, anahtar, özel URL veya imza dosyası commit etmeyin. Yeni kısayolları ve çevirileri güncel tutun. macOS'ta geçen testleri Windows'ta da geçmiş gibi sunmayın; gerçekten denediğiniz platformu ve paketi belirtin.
