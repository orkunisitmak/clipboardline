# Third-party notices / Üçüncü taraf bildirimleri

The application source and bundled components have separate licenses. The project's MIT license does not replace a model, framework or artwork license.

## Source ancestry

ClipBoardLine is an independent modified version of [Tendedero by Alejandro Buján](https://github.com/alejandrobujan/tendedero). Retain the complete [LICENSE](LICENSE), including its original copyright and the reserved Tendedero name/icon terms. ClipBoardLine uses its own name and original artwork from `scripts/make-review-icon.swift`; it is not endorsed by Tendedero's author. The upstream icon and documentation images are not ClipBoardLine assets and are excluded from this public source snapshot.

Selected adaptations retain source attribution:

- Clipboard image capture: Anubhav-Rai's Tendedero [PR #1](https://github.com/alejandrobujan/tendedero/pull/1), revision `0f4b3df1d05ed88303b0c3bb3311aa4c08d57745`, under the repository's MIT terms.
- MobileCLIP bridge/tokenizer: JOHN-AMAO's Tendedero [PR #3](https://github.com/alejandrobujan/tendedero/pull/3), revision prefix `e3558ea`, under MIT. Relevant source attribution remains in `Sources/Tendedero/Clip.swift`.

## Sparkle 2.10.0

macOS links the pinned [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/tree/2.10.0) framework. Its [complete license](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE) includes the main MIT terms and the notices for bundled BSD/zlib-style components. Preserve the entire notice, not only its first paragraph. The community builder copies this file as `Contents/Resources/LICENSE-Sparkle.txt`; Sparkle's versioned framework and nested components keep their existing notices.

## Optional original MobileCLIP-S2 models

The optional offline model assets are pinned to Apple Core ML model revision `3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947`. They are fetched by `scripts/prepare-search-models.py` into an ignored local directory rather than committed to this source repository. This implementation uses the **original S2** assets; it does not substitute MobileCLIP2.

- Model weights/data: Apple's [pinned `LICENSE_weights_data`](https://github.com/apple-aiml-research/ml-mobileclip/blob/341ef058802f0e4e5ab13c02f0cb32a3a94e367b/LICENSE_weights_data), Apple Sample Code terms. These weights are not relicensed as MIT by this project.
- Apple code: the corresponding [MIT license](https://github.com/apple-aiml-research/ml-mobileclip/blob/341ef058802f0e4e5ab13c02f0cb32a3a94e367b/LICENSE).
- Subcomponents: retain the complete pinned [ACKNOWLEDGEMENTS](https://github.com/apple-aiml-research/ml-mobileclip/blob/341ef058802f0e4e5ab13c02f0cb32a3a94e367b/ACKNOWLEDGEMENTS), which includes the applicable third-party copyright and license texts.
- Tokenizer resources: Apple source revision `48faa0fea4b08d74188b3841771aca6ff2c92852`, under its [source license](https://github.com/apple-aiml-research/ml-mobileclip/blob/48faa0fea4b08d74188b3841771aca6ff2c92852/LICENSE).

When models are included, the builder preserves `LICENSE-MobileCLIP-S2`, `LICENSE-Apple-code`, `ACKNOWLEDGEMENTS-MobileCLIP` and `model-source.json` in `Contents/Resources/CLIP/`. Keep these files with any redistributed model bundle. Source builds without these models continue to offer the local OCR path.

## Windows offline semantic models and ONNX Runtime

Windows bundles the same original MobileCLIP-S2 model family as separately
pinned FP32 ONNX graphs, exported from Apple's original checkpoint and clean
source. The exact export, checkpoint/tokenizer hashes, numerical verification
and provenance are described in [Windows model preparation](docs/windows-search-models.md).
The archive includes the complete Apple model license, code license,
acknowledgements and `model-source.json`; installed resources preserve them in
`resources/CLIP/`. They retain Apple's separate terms and are not relicensed
under this project's MIT source license.

ONNX Runtime Web/Common 1.30.0 supplies the local WASM CPU engine. Preserve the
[complete Microsoft MIT license](windows/assets/licenses/LICENSE-ONNXRuntime.txt)
and [complete upstream third-party notices](windows/assets/licenses/THIRD_PARTY_NOTICES-ONNXRuntime.txt)
with the installed application, alongside the Windows dependency notices.

## BIP39 English wordlist

Wallet Guard bundles the unmodified [BIP39 English wordlist](https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt) as `Sources/Tendedero/BIP39English.swift` and `windows/lib/bip39-english.cjs` (SHA-256 of the newline-terminated list: `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`). BIP-0039 by Marek Palatinus, Pavol Rusnak, Aaron Voisine and Sean Bowe is published under the MIT License (the BIP header states `License: MIT` and its Copyright section reads "This BIP falls under the MIT License."; upstream has no separate copyright line, so the holders and year below are taken from the BIP's Authors and Assigned 2013-09-10 header fields):

> Copyright (c) 2013 Marek Palatinus, Pavol Rusnak, Aaron Voisine, Sean Bowe.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Platform components

macOS uses operating-system frameworks including AppKit, SwiftUI, Vision, Core ML and SQLite's system interface. They are not copied into this source repository. Windows dependencies and their bundled notices are described in the Windows package documentation and dependency lockfile; audit them independently when adding or changing a package.

## Türkçe

Uygulama kodu, modeller, framework'ler ve görseller ayrı lisanslara tabidir. Projenin MIT lisansı diğer bileşenlerin lisansının yerine geçmez. Alejandro Buján'ın telif bildirimi ve Tendedero'nun isim/ikon koşulları [LICENSE](LICENSE) içinde korunur; ClipBoardLine kendi adını ve özgün ikonunu kullanır.

Sparkle dağıtımında tam lisans metnini; model kullanıldığında Apple'ın model lisansını, kod lisansını, `ACKNOWLEDGEMENTS` dosyasını ve model kaynak kaydını koruyun. Özgün MobileCLIP-S2 ağırlıkları bu proje tarafından MIT olarak yeniden lisanslanmaz. Kaynak kod paketine özel imza anahtarı, Keychain dosyası veya kullanıcı geçmişi dahil edilmez.

Cüzdan Koruması, değiştirilmemiş BIP39 İngilizce kelime listesini MIT lisansı ve yukarıdaki yazar bildirimiyle birlikte paketler.
