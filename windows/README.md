# ClipBoardLine for Windows

[Main feature reference](../README.md) · [Türkçe](#türkçe) ·
[Source](https://github.com/orkunisitmak/clipboardline) ·
[Windows CI](https://github.com/orkunisitmak/clipboardline/actions/runs/39296605977)

This folder contains the separate Electron/Windows implementation. Its source,
packaged executable and installed application have separate native acceptance
checks. A passing model or renderer test on another operating system does not
certify native Windows paste, capture, global keys or installation. Check the
actual Windows CI result and release assets for the build you use.

Windows [1.7.2 build 64](https://github.com/orkunisitmak/clipboardline/releases/tag/windows-1.7.2-build64) is released: [download the x64 installer](https://github.com/orkunisitmak/clipboardline/releases/download/windows-1.7.2-build64/ClipBoardLine-Setup-1.7.2-x64.exe).

**Historical 1.7.2 verification:** for source revision [`e734c7e`](https://github.com/orkunisitmak/clipboardline/commit/e734c7e97c0f8b22ff27a4ead3f82382407854cd), [Windows CI run 39296605977](https://github.com/orkunisitmak/clipboardline/actions/runs/39296605977) passed **65 Node tests, 146 native acceptance checks** (48 source, 49 packaged, 49 installed) and **7 isolated upgrade checks**.

**Published version:** the download links above are for macOS and Windows **1.7.2**; the **1.7.3 candidate** is not published yet. Future normal updates use the same product version on both platforms; platform build counters remain independent.

**Historical consolidation checks (1.7.1–1.7.2):** macOS 1.7.0 → 1.7.1 and Windows 1.7.1 → 1.7.2 installed from the application and reopened automatically, retaining history and settings. The [real Windows update run](https://github.com/orkunisitmak/clipboardline/actions/runs/39309767453) used unchanged production binaries, feed and key. Current updates need no GitHub token. Build64’s [exact-source native checks](https://github.com/orkunisitmak/clipboardline/actions/runs/39307655801) also passed (48 source, 49 packaged, 49 installed and seven candidate upgrade checks); application code is unchanged from build63.

**One-time build 62 → 63 upgrade note:** if the installer finishes without reopening ClipBoardLine, open it manually once. The original 1.7.0 build 62 client predates the relaunch fix. The real unchanged build62 client completed download and installation, with data preserved; current build63 → 64 also passed automatic reopening.

**One public repository.** `orkunisitmak/clipboardline-desktop` now contains the source and Mac/Windows releases. Each platform keeps its own signed feed; every release designated Latest carries both current `appcast.xml` and `windows-update.json`. Old Mac `clipboardline-app` update addresses continue through verified compatibility redirects, so existing Mac installations keep updating without reinstalling. Both signed feeds and all three previous Mac ZIPs were verified through the old addresses without authentication, with identical bytes and archive hashes.

## Choose what to collect

Clipboard image and text capture default to **off**. Standalone-link capture and
public link-title/thumbnail enrichment default to **on**, matching Mac. Open
**Settings → Sources** to change each source or enrichment preference. Existing
explicit choices, including opt-outs, remain unchanged. Text and link capture
never opens the shelves automatically. In **Settings → General**, **Captured
images** chooses what an arriving clipboard or watched-folder image opens: the
crop editor (default), the preview, a shelf selection, or nothing. Local
OCR/visual indexing can be disabled independently; search runs on this device.

History and managed images stay on this computer. Pins, folders and tags keep
records beyond ordinary expiry; other items have separate image/text/link time
limits and expire into recoverable Library Trash. Take-down hides saved records
from the shelf and trashes temporary ones. External original files remain in
place. There is no cloud sync, automatic macOS history import or encrypted vault.

**1.7.3 candidate:** this guide describes the current source. Publication is pending both native platform suites; see [scope and verification requirements](../docs/parity-1.7.3.md). Downloads above remain the published 1.7.2 packages.

## Keyboard workflow

The complete [English Windows keymap](../README.md#windows-default-keyboard-shortcuts) and [Turkish Windows keymap](../README.tr.md#windows-varsayılan-klavye-kısayolları) list all five global actions and configurable local shortcuts, fixed editor/dialog keys and their contexts. The static [English index](../docs/index.html#windows-shortcuts) and [Turkish index](../docs/tr/index.html#windows-shortcuts) carry the same reference.

Single-letter commands apply while browsing; text fields keep normal typing. Fixed native/editor control keys keep their own contexts even when an action binding is changed. Enter copies and closes shelves/shelf previews, returning focus to the previous application. In Library and Library-origin previews it copies and stays open. Plain shelf clicks copy without closing; use Select items mode or Ctrl/Shift modifiers for selection only.

Global actions include shelf toggle/search and screen capture. Library and
copy-latest-image shortcuts are off by default; record or disable them in Settings.
Native multi-image copying offers a FileDrop list and a first-image fallback;
the receiving app determines what it consumes. Images are not combined into a
single composite without your action.

## Windows interface and updates — 1.7.3 candidate

- **Hanging shelves over your desktop.** Images, text and links hang from three curved ropes on a transparent desktop surface. Aspect-fit image frames preserve wide or portrait screenshots; row controls stay compact. A plain shelf click copies and keeps browsing open. Turn on Select items or hold Ctrl/Shift to select only; clicking an empty shelf area hides the shelves.
- **A normal Library and Settings workspace.** Library opens in a resizable window with minimize, maximize and close controls. Its unified toolbar offers search, view and filter controls plus sidebar/inspector toggles. Neutral grid/list cards show media, type and tags. Settings uses a branded sidebar and grouped controls; full screen is not forced.
- **One centered search and Actions language.** Shelf search floats in the center with visible-type chips and a result count. Enter or Up/Down leaves text entry for result navigation; the applied query remains as a compact summary. Actions uses the same visual language and centered shortcut badges.
- **Preview without breaking your flow.** Space previews the focused item. Arrow keys change content in place; the top row combines navigation with markup/crop tools while keeping navigation accessible. Enter closes shelf-origin browsing after copying; Library and Library-origin previews stay open.
- **Pages sized to the visible shelf.** Alt+Left/Right advances by the number of cards that fit, up to nine, based on window width and card size. Number keys select the cards actually offered on that page. Library uses its actual grid columns for Up/Down and nine-result Alt jumps.
- **Check automatically, install deliberately.** When enabled, update checks are scheduled after launch when due and hourly while running; failed checks retry after five minutes. New versions appear in the tray, shelf badge and Updates page; notifications open that page. Checks never install. Click Update and reopen to download, verify the signed manifest and installer hash/size, replace the app and reopen it. Existing Library/settings are retained, and no GitHub token is required.

## Search, language and remaining platform gaps

- Both platforms use the original MobileCLIP-S2 for offline Library image search.
  Windows uses verified ONNX models and local CPU WASM in a worker; Mac uses Core
  ML. Text/visual/all modes respect folders, tags, type, date and pin filters.
  OCR uses packaged English/Turkish Tesseract on Windows and Apple Vision on Mac.
- Images keep immutable original files plus editable crop/annotation metadata and
  a rendered PNG. Undo/redo remains available after Done in the current app
  session; rendered images and editable annotations persist across restarts.
- Windows uses the same nine language catalogs as Mac, including system-language
  selection; CI checks that generated catalogs match. OCR languages remain
  English/Turkish and are separate from the interface language.
- **Screen recordings — 1.7.3 candidate, native acceptance pending.** Import
  `.mp4`/`.mov` files or collect them from explicitly watched folders. Recordings
  appear in Images with posters and duration, play inside preview, and use
  **M** or **Actions → Trim video** for a start/end range. Enter saves; Esc cancels.
  Copy, drag and export transfer the video file rather than its poster. Windows
  uses its native WinRT media stack; no additional FFmpeg binary is downloaded.
  Source files remain immutable; trims create a new managed MP4 and may re-encode.
  Playback/decoding depends on installed Windows codecs. H.264/AAC MP4 and MOV
  fixtures are the mandatory native acceptance target; HEVC/ProRes support is
  not guaranteed. Mac instead uses Quick Look/AVKit windows and its current Trim
  replaces the source file. These storage and native-control differences are
  explicit; the candidate is not declared verified or published yet.
- Windows uses Alt-drag for per-item text/link files while ordinary drag inserts
  text. Mac can advertise both text and files in a single drag. See the
  [native transfer contract](../docs/windows-native-transfer.md).
- The shared public repository carries separate signed Mac and Windows feeds.
  Every Latest release must include both current feed files. Public signed
  metadata and SHA-256 protect update integrity; the Windows installer currently
  has no Authenticode publisher certificate. Normal Windows first-run approval
  may be required. Do not disable system protections to install it.

## Development and validation

Use a supported Node.js version with npm on Windows x64. Dependencies are pinned
in `package-lock.json`. `npm start` uses a separate **ClipBoardLine Dev** data
folder; it cannot install official updates. It does not share the installed
application's user history.

```sh
npm ci
python ../scripts/prepare-windows-search-models.py
npm test
npm start
```

`npm test` runs test files serially so concurrent PowerShell ACL setup does not
compete on constrained Windows runners. All model/security checks still run with
the production permission checks and their existing time bounds.

The unit suite covers persistence, shared Unicode/newline text deduplication, per-kind retention,
batches, Trash/undo, preference validation, network/update boundaries and renderer
keyboard state. It uses synthetic fixtures. Native acceptance must run on an
actual Windows desktop session:

```sh
npm run dist
npm run test:electron
```

The Windows workflow also exercises packaged/installed artifacts, a separate
native editable target, real text/image copy/paste, file-drop batches, capture,
local OCR, real offline semantic inference and the renderer's actual keyboard events. Inspect its report rather
than interpreting the existence of this test as a passed result.

See [component licenses and notices](THIRD_PARTY_NOTICES.md), the project
[privacy guide](../PRIVACY.md), and [contribution guide](../CONTRIBUTING.md).

## Türkçe

**1.7.3 adayı:** bu rehber güncel kaynak kodunu anlatır. Yayımlama için iki yerel platform testinin tamamlanması bekleniyor; [kapsam ve doğrulama şartlarına](../docs/parity-1.7.3.md) bak. İndirmeler hâlâ yayımlanmış 1.7.2 paketleridir.

**Yayımlanmış sürüm:** yukarıdaki indirmeler macOS ve Windows **1.7.2** içindir; **1.7.3 adayı** henüz yayımlanmadı. Sonraki normal güncellemeler iki platformda aynı sürüm numarasını kullanır; platformların teknik build sayaçları bağımsızdır.

Geçmiş birleşme doğrulaması: gerçek Windows 1.7.1 → 1.7.2 güncellemesi, uygulama içinden kurulup otomatik açıldı; metin/görsel, klasör/etiket ve ayarlar korundu. [Yayımlanmış uygulamalarla canlı koşu](https://github.com/orkunisitmak/clipboardline/actions/runs/39309767453) ve [aynı kaynaktan yerel kontroller](https://github.com/orkunisitmak/clipboardline/actions/runs/39307655801) geçti.

Windows [1.7.2 build 64](https://github.com/orkunisitmak/clipboardline/releases/tag/windows-1.7.2-build64) yayımlandı: [x64 kurulumunu indir](https://github.com/orkunisitmak/clipboardline/releases/download/windows-1.7.2-build64/ClipBoardLine-Setup-1.7.2-x64.exe).

[`e734c7e`](https://github.com/orkunisitmak/clipboardline/commit/e734c7e97c0f8b22ff27a4ead3f82382407854cd) kaynak revizyonunun [39296605977 numaralı Windows CI çalışmasında](https://github.com/orkunisitmak/clipboardline/actions/runs/39296605977) **65 Node testi, 146 gerçek Windows kabul kontrolü** (48 kaynak, 49 paketlenmiş, 49 kurulmuş) ve **7 izole yükseltme kontrolü** geçti.

**Build 62 → 63 için tek seferlik yükseltme notu:** kurulum biter ama ClipBoardLine yeniden açılmazsa bir kez kendin aç. Özgün 1.7.0 build 62 istemcisinde yeniden açma düzeltmesi yoktur. Değiştirilmemiş gerçek build62 istemcisi indirme ve kurulumu verileri koruyarak tamamladı; güncel build63 → 64 geçişinde otomatik yeniden açılma da geçti.

Bu klasör, ayrı Electron/Windows uygulamasını içerir. Kaynak, paketlenmiş ve
kurulmuş uygulamanın yerel kabul testleri ayrıdır; başka sistemde geçen JavaScript
testi, Windows'ta gerçek yapıştırma veya kurulumun geçtiği anlamına gelmez.
Kullandığınız derlemenin Windows CI sonucuna ve sürüm dosyalarına bakın.

**Tek herkese açık depo.** Kaynak kodu ile Mac/Windows sürümleri artık `orkunisitmak/clipboardline-desktop` adresinde. Her platform kendi imzalı akışını korur; Latest seçilen her sürüm hem güncel `appcast.xml` hem de `windows-update.json` dosyasını taşır. Eski Mac `clipboardline-app` güncelleme adresleri doğrulanmış uyumluluk yönlendirmeleriyle çalışır; mevcut Mac kurulumları yeniden kurulmadan güncellenmeye devam eder. İki imzalı akış ve önceki üç Mac ZIP’i eski adreslerden oturum açılmadan doğrulandı; dosya içerikleri ve arşiv özetleri birebir aynı.

Pano görseli ve metni toplama varsayılan **kapalı**; tek URL toplama ve genel
link başlığı/küçük görsel zenginleştirmesi varsayılan **açıktır**. Ayarlar →
Kaynaklar’dan ayrı ayrı değiştirilebilir; eski kapalı tercihler korunur. Metin
ve link kopyaları askıyı otomatik açmaz. Ayarlar → Genel’deki **Yakalanan
görseller** seçeneği, panodan veya izlenen bir klasörden gelen görselin ne
açacağını belirler: crop düzenleyici (varsayılan), önizleme, askıda seçim veya
hiçbiri. Yerel OCR/görsel indeksleme kapatılabilir.
Geçmiş yerel kalır; platformlar arası otomatik aktarım veya bulut senkronizasyonu
sunulmaz.

Windows'ta Command yerine **Control**, Option yerine **Alt** kullanılır. Genel
kısayollar `Ctrl+Alt+T` (askı), `Ctrl+Alt+S` (arama) ve `Ctrl+Alt+A` (ekran
yakalama) olarak gelir; Ayarlar'dan değiştirilebilir. [Türkçe Windows kısayol tablosu](../README.tr.md#windows-varsayılan-klavye-kısayolları), beş genel ve değiştirilebilir yerel işlemlerin yanı sıra sabit düzenleyici/pencere tuşlarını ve bağlamlarını içerir. Enter askı/askı önizlemesinde kopyalayıp kapatır, odağı önceki uygulamaya döndürür. Kütüphane ve oradan açılan önizlemede kopyalayıp açık kalır. Normal askı tıklaması kapatmadan kopyalar; yalnızca seçim için Öğe seç modunu veya Ctrl/Shift tuşlarını kullan.

### Windows arayüzü ve güncellemeler — 1.7.3 adayı

- **Masaüstünün üstünde asılı içerikler.** Görsel, metin ve linkler saydam masaüstü yüzeyindeki üç eğri ipte asılır. Görseli sığdıran çerçeveler yatay veya dikey ekran görüntüsünün oranını korur; satır denetimleri kompakttır. Normal askı tıklaması kopyalar ve gezinmeyi açık tutar. Yalnızca seçmek için Öğe seç modunu aç veya Ctrl/Shift basılı tut; boş askı alanına tıklamak askıları gizler.
- **Normal kütüphane ve Ayarlar çalışma alanı.** Kütüphane; küçült, büyüt ve kapat denetimleri bulunan boyutlandırılabilir pencerede açılır. Birleşik araç çubuğunda arama, görünüm/filtre ve kenar/ayrıntı paneli denetimleri bulunur. Nötr ızgara/liste kartları medya, tür ve etiketleri gösterir. Ayarlar, uygulama kimliği bulunan kenar çubuğu ve gruplu denetimler kullanır; tam ekran zorlanmaz.
- **Ortada ortak arama ve Eylemler dili.** Askı araması görünür tür rozetleri ve sonuç sayısıyla ortada açılır. Enter veya Yukarı/Aşağı, yazı alanından sonuçlarda gezinmeye geçirir; uygulanan sorgu kompakt özet olarak kalır. Eylemler aynı görsel dili ve ortalanmış kısayol rozetlerini kullanır.
- **Akışı kesmeyen önizleme.** Space odaklı öğeyi önizler. Oklar içeriği pencere kapanmadan değiştirir; üst satır gezinmeyi erişilebilir tutarak işaretleme/kırpma araçlarını birleştirir. Enter askıdan açılan gezinmeyi kopyaladıktan sonra kapatır; kütüphane ve oradan açılan önizleme açık kalır.
- **Görünür askıya göre sayfalar.** Alt+Sol/Sağ, pencere genişliği ve kart boyutuna göre sığan kart sayısı kadar, en fazla dokuz kart ilerler. Numara tuşları o sayfada sunulan kartları seçer. Kütüphane Yukarı/Aşağı için gerçek ızgara sütunlarını, Alt geçişleri için dokuz sonuç kullanır.
- **Otomatik kontrol, seçerek kurulum.** Açıkken güncelleme kontrolü açılışta zamanı geldiyse ve uygulama çalışırken saatlik yapılır; başarısız kontroller beş dakika sonra yeniden denenir. Yeni sürüm sistem tepsisi, askı rozeti ve Güncellemeler’de görünür; bildirim bu sayfayı açar. Kontrol kurulum yapmaz. Güncelle ve yeniden aç’a tıklayınca indirilir; imzalı manifest ile kurulumun özeti/boyutu doğrulanır, uygulama değiştirilip yeniden açılır. Mevcut kütüphane/ayarlar korunur; GitHub token’ı gerekmez.

Özgün MobileCLIP-S2, doğrulanmış ONNX dosyaları ve yerel CPU WASM ile arka plan
çalışanında çevrimdışı görsel arama yapar. Metin/görsel/tümü modları mevcut
kütüphane kapsamını korur. Windows OCR’ı İngilizce/Türkçe Tesseract kullanır;
arayüz Mac ile aynı dokuz dil kataloğunu ve sistem dili seçimini kullanır.
İşaret/kırpma korunur; Bitti sonrasında aynı uygulama oturumunda geri alma sürer.
**Ekran kayıtları — 1.7.3 adayı, yerel kabul testi bekleniyor:** `.mp4`/`.mov`
dosyalarını içe aktar veya açıkça seçtiğin izlenen klasörlerden topla. Kayıtlar
küçük görsel ve süreyle Görseller’de görünür; önizlemede oynatılır. **M** veya
**Eylemler → Videoyu kırp** ile aralık seç; Enter kaydeder, Esc iptal eder.
Kopyalama/sürükleme/dışa aktarma küçük görsel yerine video dosyasını aktarır.
Windows yerel WinRT medya altyapısını kullanır; ek FFmpeg dosyası indirilmez.
Özgün dosya korunur; kırpılan sürüm gerektiğinde yeniden kodlanarak ayrı bir MP4
olarak tutulur. Codec desteği Windows’ta kurulu bileşenlere bağlıdır. H.264/AAC
MP4 ve MOV örnekleri zorunlu yerel kabul hedefidir; HEVC/ProRes garantisi yoktur.
Mac’te Quick Look/AVKit pencereleri kullanılır ve mevcut Trim kaynak dosyayı
değiştirir. Aday henüz doğrulanmış veya yayımlanmış sayılmaz.

`npm start`, resmî uygulamadan ayrı ClipBoardLine Dev veri alanını kullanır ve
resmî güncelleme kuramaz. `npm test` sentetik test dosyalarını sırayla çalıştırır;
böylece kısıtlı Windows koşucusunda PowerShell ACL hazırlıkları aynı anda yarışmaz.
Tüm model/güvenlik testleri, üretimdeki izin kontrolleri ve süre sınırlarıyla
çalışmaya devam eder. Gerçek Windows
masaüstü oturumunda `npm run dist` ve `npm run test:electron` ile yerel kabulü
inceleyin. Windows kurulumunun şu anda Authenticode sertifikası yoktur; normal
sistem onayını kullanın, güvenlik korumalarını kapatmayın.
