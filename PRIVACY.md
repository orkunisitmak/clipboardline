# Privacy / Gizlilik

## English

ClipBoardLine keeps the clipboard items it captures and the library you organize on your computer. There is no ClipBoardLine cloud account or cross-device history synchronization. Text, image OCR and semantic image queries are processed locally. The source does not include analytics or a service that uploads your history.

### What is stored

History and library records can include copied text, image files, URLs, custom names, pins, folders, tags, link titles/thumbnails, OCR text and derived search vectors. Images may refer to original files you selected or to private copies made by the app. Search indexes are derived data but can still reveal the content of your history. Trash and recovery copies may remain after an item leaves a shelf; deleting a history row is not a secure erase of every original, export or backup.

The macOS library uses a local SQLite database and files restricted to the current user. These files are not encrypted by ClipBoardLine. Your operating system's account permissions, disk encryption and backup settings remain relevant. Avoid treating the app as a secret manager. A saved API key is still a key, even when you give its card a friendly name.

Official macOS builds keep their existing storage location for compatibility. A source-built **ClipBoardLine Dev** uses `~/Library/Application Support/ClipBoardLine Dev/Screenshots/` and preferences under `org.clipboardline.community`. It does not import or update the official app's history. Keep the apps' global shortcuts distinct if both are running.

### Capture and network choices

- Image and text clipboard capture are separate controls and are opt-in in the macOS implementation. Recognized private clipboard markers are skipped; not every application marks confidential data. The watcher cannot infer that an arbitrary value is a password or token.
- Standalone URL capture and link enrichment are separate settings. The community Dev build defaults link enrichment to off. If you enable it, enrichment can request the saved URL from its website. YouTube previews use YouTube's public oEmbed/thumbnail services. Those services can see the request and your network address. Disable link previews to avoid these requests.
- macOS automatic metadata requests require HTTPS and reject credentials, known secret query parameters and private/reserved network destinations. Each DNS result and redirect is checked; connections use the checked IP with the original hostname for TLS validation. Preview HTML is not executed. A blocked or unsupported preview leaves the saved link available to open yourself.
- Model-free macOS source builds retain local Vision OCR. Adding semantic image search models is optional: `CLIPBOARDLINE_BUNDLE_MODELS=1 bash scripts/build-community.sh`. This downloads pinned assets from Apple/GitHub/Hugging Face at **build time**. A normal source build does not download these models. Once bundled, model inference is local.
- Official public update checks contact the public GitHub release/feed infrastructure; downloads use its asset hosts. No private GitHub token is needed. You control automatic checks, and choose when to install. A self-built Dev app has no update feed and makes no update checks.
- Installing the application or building its source does not itself send clipboard contents to the project maintainers. Opening a URL or pasting/exporting content explicitly gives that content to the chosen application or service.

Platform builds can differ. Consult the Windows documentation for its current capture defaults, storage and supported features rather than assuming every macOS behavior is identical. The Linux build shares the Windows defaults and stores its Library in `~/.config/ClipBoardLine` (owner-only). It makes no update checks; Wayland screenshots go through the desktop's screenshot portal, whose temporary file is removed after import. See the [Linux guide](docs/linux.md).

## Türkçe

ClipBoardLine yakaladığı pano öğelerini ve düzenlediğiniz kütüphaneyi bilgisayarınızda saklar. ClipBoardLine bulut hesabı veya cihazlar arasında geçmiş senkronizasyonu yoktur. Metin, görsellerde OCR ve anlamsal görsel arama sorguları yerelde işlenir. Kaynakta geçmişinizi yükleyen bir analiz veya telemetri servisi bulunmaz.

Geçmiş; metin, görsel, URL, verdiğiniz isim, sabitleme, klasör, etiket, link başlığı/thumbnail'i, OCR metni ve arama vektörlerini içerebilir. Arama indeksleri de içerik hakkında bilgi taşır. Askıdan kaldırılan bir öğenin orijinali, dışa aktarılmış kopyası, çöpü veya yedeği kalabilir; geçmişten silmek güvenli veri imhası değildir.

macOS'taki veritabanı ve dosyalar kullanıcıya özel izinlerle saklanır, ancak uygulama tarafından şifrelenmez. İşletim sistemi hesap izinleri, disk şifrelemesi ve yedekleme tercihleri önemini korur. Uygulamayı parola kasası olarak kullanmayın; bir API anahtarına isim vermek onu hassas olmaktan çıkarmaz.

Resmî macOS sürümleri mevcut veri konumunu uyumluluk için korur. Kaynaktan derlenen **ClipBoardLine Dev** ayrı `~/Library/Application Support/ClipBoardLine Dev/Screenshots/` klasörünü ve `org.clipboardline.community` ayar alanını kullanır. Resmî uygulamanın geçmişini içe aktarmaz veya güncellemez.

- macOS'ta görsel ve metin yakalama ayrı, isteğe bağlı ayarlardır. Bilinen özel pano işaretleri atlanır; her uygulama hassas içeriği işaretlemez.
- Link yakalama ve link önizlemesi ayrı ayarlardır. Community Dev derlemesinde önizleme varsayılan olarak kapalıdır. Açarsanız ilgili siteye veya YouTube'a ağ isteği gönderebilir; istemiyorsanız kapalı bırakın.
- macOS'taki otomatik metadata HTTPS gerektirir; kimlik bilgilerini, bilinen hassas sorgu alanlarını ve özel/rezerve ağ adreslerini reddeder. DNS cevapları ve yönlendirmeler denetlenir; bağlantı denetlenmiş IP'ye, TLS doğrulaması özgün alan adına göre yapılır. Önizleme HTML'i çalıştırılmaz. Önizleme engellenirse kaydettiğiniz link kendiniz açabilmeniz için korunur.
- Standart kaynak derlemesinde model indirilmez; yerel Vision OCR çalışır. `CLIPBOARDLINE_BUNDLE_MODELS=1` ile anlamsal arama modellerini seçerseniz derleme sırasında sabitlenmiş Apple/GitHub/Hugging Face dosyaları indirilir. Paketlenmiş modeller çalışma sırasında yerelde kullanılır.
- Resmî public güncellemeler GitHub'a bağlanır; GitHub tokenı istemez. Otomatik kontrolü kapatabilir, kurulumu kendiniz başlatabilirsiniz. Dev derlemesinin güncelleyicisi kapalıdır.

Windows sürümünün mevcut özellikleri, kayıt konumu ve varsayılanları için kendi platform belgesini okuyun; bütün macOS davranışlarının aynı olduğunu varsaymayın. Linux derlemesi Windows varsayılanlarını kullanır, kütüphanesini yalnızca kullanıcıya açık `~/.config/ClipBoardLine` içinde tutar ve güncelleme kontrolü yapmaz. Wayland’de ekran görüntüsü masaüstünün portalıyla alınır; geçici dosya içe aktarıldıktan sonra silinir. Ayrıntılar [Linux rehberinde](docs/linux.md#türkçe).
