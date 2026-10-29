# Windows dependencies and notices / Windows bağımlılıkları ve bildirimleri

ClipBoardLine's source license does not replace the licenses of its runtime,
OCR engine, language data or dependencies. Preserve the dependency lockfile and
all accompanying notices when redistributing a Windows build.

| Component | License and notice |
| --- | --- |
| Electron 44.9.0 | MIT; [complete bundled text](assets/licenses/LICENSE-Electron.txt). Electron also ships Chromium, Node.js and other components under their own licenses. Preserve Electron's generated `LICENSES.chromium.html` and runtime notices with the packaged application. |
| Chromium | BSD-style main terms plus many component licenses. Electron's complete generated `LICENSES.chromium.html` is the component inventory; do not replace it with a generic BSD paragraph. |
| Tesseract.js 7.0.0 | Apache-2.0; [complete text](assets/licenses/LICENSE-Tesseract-js.txt). |
| Tesseract.js Core / Tesseract OCR | Apache-2.0; [complete text](assets/licenses/LICENSE-Tesseract-core-and-data.txt). Preserve any additional notices shipped by the engine. |
| English / Turkish traineddata | The `@tesseract.js-data/eng` and `/tur` 1.0.0 package metadata declares MIT for its packaging. The underlying Tesseract language-data distribution has [Apache-2.0 terms](https://github.com/naptha/tessdata/blob/gh-pages/LICENSE), also retained in the complete Apache text above. Do not infer that the model weights were relicensed under ClipBoardLine's MIT source license. |
| Electron Builder | MIT; a development/build dependency. Its bundled installer tools have their own notices. |

Official dependency sources: [Electron](https://github.com/electron/electron),
[Tesseract.js](https://github.com/naptha/tesseract.js),
[Tesseract.js Core](https://github.com/naptha/tesseract.js-core), and
[Tesseract language data](https://github.com/naptha/tessdata).

Windows does not bundle Apple Vision or the macOS MobileCLIP Core ML models.
Its OCR data is packaged for local English/Turkish recognition. See the project
[third-party inventory](../THIRD_PARTY_NOTICES.md) for the macOS-specific components
and the preserved Tendedero source ancestry.

## Türkçe

ClipBoardLine'ın MIT kaynak lisansı; Electron, Chromium, OCR motoru veya dil
verilerinin lisansının yerine geçmez. Yukarıdaki tam lisans metinlerini,
Electron'ın `LICENSES.chromium.html` dosyasını ve bağımlılıkların kendi
bildirimlerini dağıtımla birlikte koruyun. `@tesseract.js-data` paketinin MIT
metadata'sı ile özgün Tesseract dil verilerinin Apache-2.0 koşullarını ayırın.
Windows sürümü Apple Vision veya macOS Core ML modellerini paketlemez.
