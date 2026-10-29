# ClipBoardLine

**Kopyaladıkların için düzenli bir yer.**

Görseller, metinler ve linkler elinin altında. Son kopyalarını üç askıda tut, önemli olanları yerel kütüphaneye kaydet ve tümünde klavyeyle hızla gezin.

[English README](README.md) · [Mac için indir](https://github.com/orkunisitmak/clipboardline/releases/latest) · [Windows x64 için indir](https://github.com/orkunisitmak/clipboardline/releases/latest) · [Linux](docs/linux.md) · [Kaynak kodu incele](https://github.com/orkunisitmak/clipboardline) · [Ekran görüntüleri ve demolar](https://orkunisitmak.github.io/clipboardline/tr/#demo)

> macOS sürümü Swift, AppKit, SwiftUI, Vision ve Core ML kullanır; Apple silicon ve Intel’de macOS 14 veya üstünü destekler. Ayrı Electron sürümü Windows x64 için kullanılabilir; farklar ve gerçek Windows doğrulama kanıtı aşağıdaki platform tablosundadır.

**Özellik rehberi — 1.7.3:** bu sayfa kaynak ağacındaki uygulamayı anlatır. İndirilebilir paketler [son sürümde](https://github.com/orkunisitmak/clipboardline/releases/latest) listelenir; her yeni yayım iki yerel platform testini gerektirir. [Kapsam ve doğrulama şartları](docs/parity-1.7.3.md).

## İlk beş dakikan

1. **Kur ve aç.** Son Mac sürümünü indir, uygulamayı Applications klasörüne taşı ve aç. ClipBoardLine menü çubuğunda yaşar.
2. **Ne toplamak istediğini seç.** Ayarlar → Kaynaklar’dan istersen görsel veya metin yakalamayı aç. Tek URL yakalama varsayılan açık gelir ve kapatılabilir. Ekran görüntüsü yönetimini ayrıca seç.
3. **Akışını bozmadan gezin.** ⌃⌥T’ye bas, oklarla gezin, Space ile önizle. Enter kopyalar ve askıları kapatır; odak önceki uygulamaya döner.
4. **İşe yarayanları sakla.** P ile sabitle, ⇧P ile klasör seç veya ⌥P ile anlamlı bir ad ver. Etiketlenen ya da klasöre eklenen kayıtlar normal geçmiş süresi sonunda kalır.
5. **Kendine göre ayarla.** Her içerik türünün geçmiş süresini, kısayolları, renkleri ve otomatik güncelleme kontrolünü Ayarlar’dan düzenle.

## Tüm özellikler

| Özellik | Ne yapar? |
| --- | --- |
| **Üç bağımsız askı** | Görselleri, Metinleri ve Linkleri ayrı yatay satırlarda görüntüle. Her askıyı açıp kapat, etkin askıyı değiştir, sabitlenenleri filtrele ve eski kopyalara kaydır. Açılışta yalnız ilk görsel seçilir; Görseller kapalı veya boşsa sonraki görünür dolu askının ilk öğesi seçilir. |
| **Ekran görüntüsü ve pano yakalama** | Ekran görüntülerini anında yakala, en fazla üç ek görsel klasörünü izle ve istersen kopyalanan görsel ya da metinleri topla. Pano görseli ve metni ayrı ayrı etkinleştirilir. Metin ve link kopyaları askıyı açmadan sessizce eklenir. |
| **Yerel kütüphane** | Izgara ve sütunlu liste görünümleri, klasör/etiket kenar çubuğu ve değişiklikleri otomatik kaydeden ayrıntılar paneli içeren, boyutlandırılabilir normal pencere. Not oluştur; başlıkları ve içeriği düzenle; görsel, metin ve linkleri birlikte düzenle. Tam ekran isteğe bağlıdır. |
| **Sabitle, adlandır, klasörle ve etiketle** | Sabitleme ve favorileme aynı işlemdir. Sabitlenen, klasöre eklenen veya etiketlenen öğeler normal geçmiş süresinden sonra da korunur. Sanal alt klasörler ve birden çok etiket kullan; seçili öğeleri sırayla adlandırıp sabitle. |
| **Askılar için tek arama** | Ortadaki tek arama alanı görünür tüm askılarda arar: metin, link ayrıntıları, başlık, not, etiket ve görsellerden tanınan yazı. Kapalı askılar sonuçlara katılmaz. Kütüphaneyi açmadan sonuçlarda gez. |
| **OCR ve görsel anlam araması** | OCR Mac’te Apple Vision, Windows’ta paketlenmiş İngilizce/Türkçe Tesseract ile yerel çalışır. İki platform da kütüphanede çevrimdışı görsel arama için özgün MobileCLIP-S2 modelini kullanır. Metin/OCR, görsel ve birleşik arama; tür, tarih, alan adı, etiket, klasör ve sabitleme filtreleri bulunur. Görsel betimlemeler en iyi sonucu İngilizce verir. |
| **İçeriği gösteren link kartları** | Tek başına kopyalanan web adresi Linkler askısına gider; URL içeren paragraf metin olarak kalır. İsteğe bağlı zenginleştirme site veya YouTube başlığı, yazar ve küçük görsel ekler. Seçili linki tarayıcıda aç. |
| **Çerçevesiz önizlemeler** | Space; görsel, düzenlenebilir metin ve link önizlemesini açar. Askı önizlemesi pencereyi kapatmadan farklı içerik türlerine geçebilir. Görsel yakınlaştırma ilk sığdırma boyutundan %400’e kadardır; kıstırma, tekerlek ve sürükleyerek gezinme desteklenir. |
| **Düzenlenebilir işaretleme ve kırpma** | Kalem, saydam işaretleyici, dikdörtgen, elips, ok, çizgi ve metin araçları önizlemenin üst çubuğunu paylaşır. İşaretleri taşı, boyutlandır, biçimlerini değiştir ve geri al. Kırpma özgün dosyayı bozmaz; orijinal ve düzenlenebilir işaretler korunur. |
| **Kopyala, yapıştır, sürükle ve dışa aktar** | Seçili grubu sırasıyla kopyala, çoklu öğe sürükle, kopyaları dışa aktar veya açıkça komut vererek önceki uygulamanın seçili yazı alanına yapıştır. Görsel kopyaları tam çözünürlüklü kırpma/işaretleme içerir. Çoklu görsel yapıştırma hedef uygulamanın desteğine bağlıdır. |
| **Tekrarlanan metin kartları olmadan geçmiş** | Görsel, metin ve link geçmişini ayrı ayrı 1, 3, 7, 15 veya 30 gün tut; varsayılan süre 30 gündür. Aynı metni yeniden kopyalamak askıyı tekrarlarla doldurmak yerine mevcut tek kaydı yeniler; kayıtlı düzen korunur. |
| **Askıdan kaldır ve geri getir** | S seçili öğeleri kaldırır ve sıradaki uygun öğeyi seçer. Kaydedilmiş kayıtlar kütüphanede kalır; geçici kopyalar kurtarılabilir Çöp Kutusu’na gider. Backspace aynı oturumdaki son askı kaldırmasını, gruplar dahil, geri getirir. Harici özgün dosyalar korunur. |
| **Klavye odaklı Eylemler** | Bağlama uygun Eylemler çubuğunda düzenleme, gezinme, görsel araçları, kütüphane görünümleri, ayarlar ve güncellemeleri ara. Komutlar güncel kısayolları gösterir ve çubuk açılırken seçili olan öğe ya da sıralı grup üzerinde çalışır. |
| **Kişiselleştirilebilir arayüz** | Küçük, orta ve büyük kartlar; yumuşak askı renkleri veya nötr cam; açılma davranışı, tam ekran uygulama üstünde görünme, ses ve girişte başlatma ayarları. Uygulama dilini sistemden bağımsız seç. Gezinme, seçim ve genel kısayollar değiştirilebilir veya kapatılabilir. |
| **Ekran kayıtları** | MP4/MOV kayıtları Görseller’de tutulur. Windows 1.7.3; yerel Windows medya API’leriyle dosya içe aktarma/izleme, oynatma, M/Eylemler ile kırpma ve dosya kopyalama/sürükleme/dışa aktarma ekler. Yayımlamadan önce yerel kabul testi zorunludur; codec ve kırpma farkları aşağıdadır. |
| **Yerel ve imzalı güncellemeler** | Mac’te Sparkle, Windows’ta imzalı kurulum akışı kullanılır. Resmî herkese açık güncellemeler GitHub hesabı veya token istemez. Otomatik kontrol kapatılabilir; açıkken uygulama çalıştığı sürece saatte bir yapılır. İndirme ve kurulum senin işlemini gerektirir. |

## macOS varsayılan klavye kısayolları

Bu tablo macOS varsayılanlarını gösterir. Aşağıdaki [Windows kısayol tablosu](#windows-varsayılan-klavye-kısayolları) kendi bağlamlarını açıklar; ek ayrıntılar [Windows rehberindedir](windows/README.md#türkçe). Ayarlar → Klavye kısayolları bölümünden gezinme tuşları ve genel kısayollar değiştirilebilir veya kapatılabilir. Tek harfli tuşlar yalnızca gezinirken uygulama komutu olur; metin alanlarında normal yazım korunur. ⌘ Command · ⌥ Option/Alt · ⌃ Control · ⇧ Shift.

### Her uygulamadan erişim

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `⌃⌥T` | Askıları göster/gizle | Genel; Ayarlar’dan değiştirilebilir. |
| `⌃⌥S` | Askıları arama odakta aç | Genel; değiştirilebilir veya kapatılabilir. |
| `Varsayılan kapalı` | Kütüphaneyi genel kısayolla aç | Kendi kısayolunu ata; Ayarlar’da ⌃⌥L önerilir. |
| `Varsayılan kapalı` | Son görseli genel kısayolla kopyala | Kendi kısayolunu ata; ⌃⌥C ve ⌃⇧C hazır seçenekleri bulunur. |

### Gezinme ve seçim

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `L` | Kütüphaneyi aç | Askılar odaktayken. |
| `Tab / ⇧Tab` | Etkin askıyı değiştir | Askılarda; ikisi de etkin satırı döndürür. |
| `← / →` | Önceki / sonraki öğe | Askılar, kütüphane ve önizlemeler. |
| `↑ / ↓` | Satırlar veya sonuçlar arasında gezin | Askılarda arama veya önizleme açıkken de kapalıyken de önceki/sonraki görünür dolu satıra geçer; öğe sütununu korur ve kısa satırın son öğesinde sınırlar. Kütüphanede ızgara satırı (listede öğe), kütüphane önizlemesinde önceki/sonraki sonuç. |
| `⌘← / ⌘→` | Askıdaki ilk / son öğe | Askılar ve askıdan açılan önizlemeler. |
| `⌥← / ⌥→` | Önceki / sonraki askı sayfası | Numaralı görünür sayfalar arasında geçer; askı önizlemesinde de çalışır. |
| `1–9` | Numaralı görünür kartı seç | Etkin askı; numaralar görünür alanı ve filtreleri izler. |
| `⇧← / ⇧→ / ⇧↑ / ⇧↓` | Seçimi genişlet | Askılar ve kütüphane; metin yazarken düzenleyicinin kısayolları korunur. |
| `⌘A` | Görünür öğelerin tümünü seç | Etkin askı veya geçerli kütüphane sonuçları. |
| `⌘Click` | Tekil seçimi aç/kapat | Kartları çoklu seçime ekle veya seçimden çıkar. |

### Kopyalama ve düzenleme

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `Enter` | Kopyala; askılar kapanır, odak geri döner | Askıda seçili grup. Askı önizlemesinde görünen öğe; önizleme ve askılar kapanır. Kütüphane/kütüphane önizlemesinde bu askı kapatma davranışı olmadan kopyalar. |
| `⌘C` | Kopyala ve gezinmeye devam et | Seçim veya geçerli önizleme; pencereler açık kalır. |
| `⌘Enter` | Önceki uygulamaya yapıştır | Erişilebilirlik izni ve önceki düzenlenebilir hedef gerekir. Metin düzenlerken önce düzenlemeyi bitirir. |
| `P / ⌘P` | Sabitle / favori durumunu değiştir | Görsel, metin ve linkler için tek ortak işlem. |
| `F / ⇧⌘F` | Yalnız sabitlenenleri aç/kapat | Etkin askı veya kütüphane kapsamı; önizlemede de desteklenir. |
| `⇧P` | Klasöre ekleyerek sabitle | Çoklu seçim destekli: yazarak ara; ↑/↓ seç; Enter onayla; Esc iptal. Seçicide ⌘N klasör oluşturur. |
| `⌥P` | Adlandır ve sabitle | Çoklu seçimde Enter kaydeder ve sıradakine geçer; Esc kalan öğeleri değiştirmeden çıkar. |
| `⇧⌘T` | Etiket ekle | Mevcut etiketleri ara veya yenisini oluştur; çoklu seçimi destekler. |
| `S` | Askıdan kaldır | Askılar ve askı önizlemeleri; önizlemeyi kapatmadan sıradaki öğeyi seçer. |
| `Backspace ⌫` | Son askı kaldırmasını geri al | Askı/askı önizlemesi; bu oturumda en fazla 32 grup. Kütüphanede Backspace, Çöp Kutusu işlemini açar. |
| `Forward Delete ⌦` | Çöp Kutusu’na taşımayı onayla | Askılar ve kütüphane; kütüphanede Backspace de kullanılabilir. |
| `⇧⌘E` | Seçili kopyaları dışa aktar | Askılar veya kütüphane; orijinaller yerinde kalır. |

### Arama, eylemler ve askı görünürlüğü

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `⇧S` | Görünür askılarda ara | Açık görsel OCR, metin ve link askılarında tek sorgu. Enter veya ↑/↓ arama yazımından sonuçlara geçer; kopyalamak için yeniden Enter. |
| `⌘K` | Eylemler’i aç | Askılar, kütüphane, önizlemeler ve Ayarlar. ↑/↓ seçer; Enter çalıştırır; Esc kapatır. |
| `⇧I / ⇧T / ⇧L` | Görseller / Metinler / Linkler askısını aç/kapat | Askılar odaktayken. Son satırı kapatmak askıları kapatır. |
| `⇧⌘B` | Tüm askılar / etkin askı arasında geç | Askılar odaktayken. |
| `⌘F` | Kütüphane aramasını odakla | Kütüphanede; yerel metin düzenleme korunur. |
| `⌘0 / ⌘1 / ⌘2 / ⌘3` | Tümü / görsel / metin / link filtresi | Yalnızca kütüphanede. |

### Önizleme ve görsel düzenleme

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `Space` | Önizlemeyi aç/kapat | Odaklı içerik; yazı yazarken Space normal boşluk ekler. |
| `Esc` | Önizleme, arama veya askıyı kapat | Düzenleme modları önce kendi işlemini bitirir/iptal eder. |
| `E` | Metin önizlemesini düzenle | Düzenlerken Enter satır ekler; ⌘Enter veya Esc kaydeder ve bitirir. |
| `⌘O` | Linki tarayıcıda aç | Kütüphanedeki seçili link veya link önizlemesi; ⌘Enter yapıştırma içindir. |
| `⇧⌘C` | Görselde tanınan yazıyı kopyala | Görsel seçimi veya görsel önizlemesi; yerel OCR. |
| `M` | İşaretlemeyi aç / bitir | Görsel önizlemesinde. |
| `C` | Kırpmayı aç | Görsel önizlemesi veya işaretleme. Alanı çiz/taşı/boyutlandır; Enter uygular; Esc iptal eder. |
| `⌘Z / ⇧⌘Z` | Görsel düzenlemesini geri al / yinele | Kırpma ve işaretleme; metin düzenleyicilerin kendi geri alma işlemleri korunur. |
| `⌘S` | İşaretlemeyi kaydet | İşaretlemeden çıkmadan kaydeder. Esc veya ⌘Enter kaydedip bitirir. |
| `Pinch / wheel` | Görseli yakınlaştır | İlk sığdırma görünümünün %100–400’ü; çift tıklama sıfırlar. |
| `Drag / ⇧wheel` | Yakınlaştırılmış görselde gezin | %100 üstünde sürükle; Shift-tekerlek kaydırır. İşaretlemede Space basılı tutup sürükle. |

### İşaretleme araçları

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `V` | İşareti seç, taşı ve boyutlandır | Yalnızca işaretleme modunda. |
| `B / H` | Kalem / saydam işaretleyici | Yalnızca işaretleme modunda. |
| `R / O` | Dikdörtgen / elips | Kare / daire için Shift basılı tut. |
| `A / D` | Ok / çizgi | Açıları 45° adımlara sınırlamak için Shift basılı tut. |
| `T` | Metin işareti | Var olan metni seçip çift tıklayarak yeniden düzenle. |
| `Backspace / Forward Delete` | Seçili işareti sil | İşaretleme modunda; askıdaki öğeyi kaldırmaz. |

## Windows varsayılan klavye kısayolları

Bunlar macOS tablosundan ayrı Windows varsayılanlarıdır. Command yerine Control, Option yerine Alt kullanılır; geçerli bağlam aşağıdaki tablodur. Beş genel işlem ve yerel gezinme kısayolları Ayarlar → Klavye kısayolları bölümünden değiştirilebilir veya kapatılabilir. Bir gezinme işlemini değiştirmek veya kapatmak varsayılan eşdeğerlerini de değiştirir: Kopyala için Enter, Sabitle için Ctrl+P ve sabitleme filtresi için Ctrl+Shift+F dahil. Yerel düzenleyici ve pencere denetimleri kendi bağlamlarını korur. Metin alanlarında normal yazım, gezinme kısayollarından önce gelir.

[Windows yerel kullanım rehberi](windows/README.md#türkçe) · [Platform farkları](#platform-desteği-ve-mevcut-farklar)

### Windows · Her uygulamadan erişim

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `Ctrl+Alt+T` | Askıları aç / kapat | Başka uygulama etkinken çalışır. |
| `Ctrl+Alt+S` | Askı aramasını aç | Askıları, ortak arama alanı odaktayken açar. |
| `Varsayılan kapalı` | Kütüphaneyi genel kısayolla aç | Ayarlar’dan ata; normal Kütüphane penceresini açar. |
| `Varsayılan kapalı` | Son görseli genel kısayolla kopyala | Ayarlar’dan ata; düzenlenmiş görseli kopyalar, odak dış uygulamada kalır. |
| `Ctrl+Alt+A` | Ekran görüntüsü al | İmlecin bulunduğu ekranı yakalar; yeni görseli kırpma/önizlemede açar. |

### Windows · Gezinme, seçim ve arama

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `L` | Kütüphaneyi aç | Odaklı askılarda. |
| `← / →` | Önceki / sonraki öğe | Askılar, kütüphane ve önizlemeler; önizleme yerinde değişir. |
| `↑ / ↓` | Satırlar veya öğeler arasında gezin | Askılarda arama veya önizleme açıkken de kapalıyken de önceki/sonraki görünür dolu satıra geçer; öğe sütununu korur ve kısa satırın son öğesinde sınırlar. Kütüphane: ızgara satırı (listede öğe); kütüphane önizlemesi: önceki/sonraki sonuç. |
| `Ctrl+← / Ctrl+→` | İlk / son sonuç | Geçerli askı veya kütüphane sonuçları; önizlemeler dahil. |
| `Alt+← / Alt+→` | Önceki / sonraki sayfa | Etkin askıda pencere genişliği ve kart boyutuna göre görünür sayfa kadar, en fazla dokuz kart ilerler. Kütüphanede dokuz sonuç atlar. Önizlemede çalışır. |
| `Tab / Shift+Tab` | Etkin askıyı değiştir | İkisi de aynı yönde döner. Askılar ve askıdan açılan önizlemeler; pencerelerde normal odak geçişi kullanılır. |
| `1–9` | Numaralı kartı seç | Etkin askının görünür sayfasındaki numaralı kartlardan birini seçer; en fazla dokuz, önizleme dışındayken. |
| `Shift+← / Shift+→ / Shift+↑ / Shift+↓` | Seçimi genişlet | Askılarda veya kütüphanede gezinirken; metin alanlarında normal düzenleme korunur. |
| `Ctrl+A` | Geçerli sonuçların tümünü seç | Etkin askı veya geçerli kütüphane sonuçları. |
| `Ctrl+Click / Shift+Click` | Tekil / aralık seçimi | Kopyalamadan seçmek için değiştirici tuşları veya Öğe seç modunu kullan. Askıda normal tıklama kopyalar ve askıları açık tutar; kütüphanede tıklama seçer, çift tıklama önizler. |
| `Shift+S` | Görünür askılarda ara | Açık görsel OCR, metin ve link satırlarında tek sözcük araması. Kapalı askılar dahil edilmez. |
| `Ctrl+F` | Kütüphane aramasını odakla | Yalnız kütüphanede gezinirken. Yerel düzenleme alanları kendi kısayollarını korur. |
| `Ctrl+0 / Ctrl+1 / Ctrl+2 / Ctrl+3` | Tümü / görsel / metin / link | Yalnız kütüphane tür filtreleri. |
| `Ctrl+K` | Eylemler’i aç | Askılar, kütüphane, önizlemeler ve Ayarlar; değiştirici tuşlu kısayol metin önizlemesini düzenlerken de çalışır. Yazarak ara; ↑/↓ seç; Enter çalıştır; Esc kapat. |
| `Enter / ↑ / ↓ / Esc (arama)` | Aramadan sonuçlara geç / aramayı kapat | Enter veya oklar sonuçları odaklar; kopyalamak için yeniden Enter. Esc sorguyu temizler ve askı aramasını kapatır. |

### Windows · Kopyalama, düzenleme ve kurtarma

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `Enter` | Seçimi / geçerli önizlemeyi kopyala | Askı/askı önizlemesinde kopyalar, askı ve önizlemeyi kapatıp odağı geri verir. Kütüphane ve oradan açılan önizleme açık kalarak kopyalar. Düzenleyiciler ve pencereler Enter’ı önce kendileri işler. |
| `Ctrl+C` | Kopyala ve gezinmeye devam et | Seçili grup veya önizleme açıksa geçerli öğe. |
| `Ctrl+Enter` | Önceki uygulamaya yapıştır | Önceki düzenlenebilir hedef gerekir; güvenli veya değişmiş hedefler reddedilir. Metin/görsel düzenlerken önce kaydedip düzenlemeyi bitirir. |
| `P / Ctrl+P` | Sabitle / favori durumunu değiştir | Görsel, metin ve linkler için tek işlem; çoklu seçimi destekler. Sabitle kısayolu değiştirilince Ctrl+P eşdeğeri de değişir. |
| `F / Ctrl+Shift+F` | Yalnız sabitlenenleri aç/kapat | Etkin askı veya kütüphanenin kayıtlı/sabitlenen kapsamı; önizlemede çalışır. Filtre kısayolu değiştirilince Ctrl+Shift+F eşdeğeri de değişir. |
| `Shift+P` | Klasöre ekleyerek sabitle | Toplu seçici: yazarak ara; ↑/↓ seç; Enter onayla; Esc çık. Seçicide Ctrl+N klasör oluşturur. |
| `Alt+P` | Adlandır ve sabitle | Çoklu seçimde Enter geçerli adı kaydedip sıradakine geçer; Esc kalan öğeleri değiştirmeden çıkar. |
| `Ctrl+Shift+T` | Etiket ekle | Seçili gruba uygulanır; her öğenin mevcut etiketlerini korur. |
| `S` | Askıdan kaldır | Yalnız askılar/askı önizlemeleri. Sıradaki kalan komşu seçilir; açık önizleme kapanmaz. Saklanan kayıtlar kütüphanede kalır. |
| `Backspace` | Askı kaldırmasını geri al | Askılar/önizlemeler: son kaldırma; bu oturumda en fazla 32 grup. Kütüphanede Çöp Kutusu onayını açar. |
| `Delete` | Onayla Çöp Kutusu’na taşı | Askı veya kütüphanede gezinirken. Görsel düzenleyicide seçili işareti siler. |
| `Ctrl+Shift+E` | Seçili kopyaları dışa aktar | Hedef klasörü seç; harici orijinaller yerinde kalır. |

### Windows · Askı görünürlüğü

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `Shift+I / Shift+T / Shift+L` | Görseller / Metinler / Linkler askısını aç/kapat | Askılar odaktayken. Son satırı kapatmak askıları gizler. |
| `Ctrl+Shift+B` | Tüm askılar / etkin askı | Yalnız askılarda; kütüphane tür filtreleri ayrıdır. |

### Windows · Önizleme, metin ve görsel düzenleme

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `Space` | Önizlemeyi aç / kapat | Gezinirken. Metin alanında boşluk yazar; görsel düzenlerken gezinmek için basılı tutulur. |
| `Esc` | Geçerli katmanı kapat | Düzenleme dışında: önizlemeyi, sonra aramayı kapatır, sonra uygulamayı gizler. Pencereler ve düzenleyiciler aşağıdaki kuralları kullanır. |
| `Ctrl+O` | Seçili linki tarayıcıda aç | Kütüphanede seçili link veya link önizlemesi; Ctrl+Enter yapıştırma içindir. |
| `Ctrl+Shift+C` | Görselde tanınan yazıyı kopyala | Seçili görsel veya görsel önizlemesi; yerel İngilizce/Türkçe OCR. Gezinme açık kalır. |
| `E` | Metni düzenle | Metin önizlemesinde. Enter satır ekler; Ctrl+Enter veya Esc kaydedip bitirir. |
| `M` | Görsel işaretlemeyi aç / bitir | Fotoğraf önizlemesinde işaretlemeyi açar/bitirir. Kayıt önizlemesinde kırpmayı açar. Yerel kayıt kabul testi bekleniyor. |
| `C` | Görsel kırpmayı aç | Görsel önizlemesi veya işaretleme; özgün pikseller korunur. |
| `Enter / Esc (kırpma)` | Kırpmayı uygula / iptal et | Enter uygular, Esc iptal eder. Doğrudan kırpma önizleme gezinmesine, işaretlemeden açılan kırpma işaretlemeye döner. |
| `Ctrl+Enter / Esc (işaretleme)` | İşaretlemeyi kaydet ve bitir | Kırpma aracı dışındayken ikisi de kaydedip bitirir. Düzenlerken tek Enter kopyalamaz. Kaydetme başarısızsa taslak açık kalır. |
| `Ctrl+S` | İşaretlemeden çıkmadan kaydet | Yalnız görsel düzenleyicide; düzenleme açık kalır. |
| `Ctrl+Z / Ctrl+Shift+Z` | Görsel düzenlemesini geri al / yinele | Bu uygulama oturumunda kırpma/işaretleme ve Bitti sonrasındaki görsel önizlemesi. Yerel metin alanları kendi geri alma geçmişini kullanır. |
| `Backspace / Delete (işaretleme)` | Seçili işareti sil | Görsel öğesini kaldırmaz; kırpma seçimi ayrıdır. |
| `Tekerlek / çift tıklama` | Görseli yakınlaştır / sıfırla | Tekerlek ilk sığdırmanın %100–400’ü arasında yakınlaştırır; düzenleme dışında çift tıklama sıfırlar. |
| `Sürükle / Shift+tekerlek / Space+sürükle` | Görselde gezin | Yakınlaştırınca sürükle; Shift+tekerlek kaydırır. Görsel düzenlerken Space basılı tutup sürükle. |

### Windows · İşaretleme araçları

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `V` | İşareti seç / taşı / boyutlandır | Yalnız görsel düzenleyicide. Mevcut metin işaretine çift tıklayarak metnini düzenle. |
| `B / H` | Kalem / saydam işaretleyici | Yalnız görsel düzenleyicide; renk ve kalınlık üst çubuktadır. |
| `R / O` | Dikdörtgen / elips | Görsel düzenleyici; kare / daire için çizerken Shift basılı tut. |
| `A / D` | Ok / çizgi | Görsel düzenleyici; açıları 45° adımlara sınırlamak için çizerken Shift basılı tut. |
| `T` | Metin işareti | Yalnız görsel düzenleyicide; işaretin metni için pencere açar. |

### Windows · Pencereler ve kısayol kaydı

| Varsayılan | İşlem | Nerede / ayrıntı |
| --- | --- | --- |
| `↑ / ↓ / Enter / Esc` | Seç, onayla veya iptal et | Eylemler ve klasör seçicileri. Çok satırlı notta Enter satır ekler; Ctrl+Enter onaylar. |
| `Ctrl+N (klasör seçicisi)` | Klasör oluştur | Oluşturunca seçiciye geri döner. |
| `Tab / Shift+Tab (pencereler)` | Odağı taşı | Odak pencerenin denetimleri içinde kalır; burada askı değiştirmez. |
| `Esc / Backspace / Delete (kayıt)` | Kaydı iptal et / kısayolu kapat | Esc kaydı iptal eder. Backspace veya Delete Kapalı değerini kaydeder; uygulamak için Kaydet’i seç. Bu kayıt tuşları sabittir. |

Kütüphane ve son görseli kopyalama için genel kısayollar varsayılan kapalıdır; askı, arama ve ekran yakalamayla birlikte Ayarlar’dan atanabilir veya kapatılabilir. Toplama varsayılanları, platform farkları, derleme komutları ve gerçek Windows kabul testi kanıtı için Windows yerel kullanım rehberine bak.

## Windows arayüzü ve güncellemeler — 1.7.3

### Masaüstünün üstünde asılı içerikler

Görsel, metin ve linkler saydam masaüstü yüzeyindeki üç eğri ipte asılır. Görseli sığdıran çerçeveler yatay veya dikey ekran görüntüsünün oranını korur; satır denetimleri kompakttır. Normal askı tıklaması kopyalar ve gezinmeyi açık tutar. Yalnızca seçmek için Öğe seç modunu aç veya Ctrl/Shift basılı tut; boş askı alanına tıklamak askıları gizler.

### Normal kütüphane ve Ayarlar çalışma alanı

Kütüphane; küçült, büyüt ve kapat denetimleri bulunan boyutlandırılabilir pencerede açılır. Birleşik araç çubuğunda arama, görünüm/filtre ve kenar/ayrıntı paneli denetimleri bulunur. Nötr ızgara/liste kartları medya, tür ve etiketleri gösterir. Ayarlar, uygulama kimliği bulunan kenar çubuğu ve gruplu denetimler kullanır; tam ekran zorlanmaz.

### Ortada ortak arama ve Eylemler dili

Askı araması görünür tür rozetleri ve sonuç sayısıyla ortada açılır. Enter veya Yukarı/Aşağı, yazı alanından sonuçlarda gezinmeye geçirir; uygulanan sorgu kompakt özet olarak kalır. Eylemler aynı görsel dili ve ortalanmış kısayol rozetlerini kullanır.

### Akışı kesmeyen önizleme

Space odaklı öğeyi önizler. Oklar içeriği pencere kapanmadan değiştirir; üst satır gezinmeyi erişilebilir tutarak işaretleme/kırpma araçlarını birleştirir. Enter askıdan açılan gezinmeyi kopyaladıktan sonra kapatır; kütüphane ve oradan açılan önizleme açık kalır.

### Görünür askıya göre sayfalar

Alt+Sol/Sağ, pencere genişliği ve kart boyutuna göre sığan kart sayısı kadar, en fazla dokuz kart ilerler. Numara tuşları o sayfada sunulan kartları seçer. Kütüphane Yukarı/Aşağı için gerçek ızgara sütunlarını, Alt geçişleri için dokuz sonuç kullanır.

### Otomatik kontrol, seçerek kurulum

Açıkken güncelleme kontrolü açılışta zamanı geldiyse ve uygulama çalışırken saatlik yapılır; başarısız kontroller beş dakika sonra yeniden denenir. Yeni sürüm sistem tepsisi, askı rozeti ve Güncellemeler’de görünür; bildirim bu sayfayı açar. Kontrol kurulum yapmaz. Güncelle ve yeniden aç’a tıklayınca indirilir; imzalı manifest ile kurulumun özeti/boyutu doğrulanır, uygulama değiştirilip yeniden açılır. Mevcut kütüphane/ayarlar korunur; GitHub token’ı gerekmez.

[Windows uygulama ve doğrulama rehberi](windows/README.md#türkçe)

## Yerel arşiv. Açıkça seçilen bağlantılar.

- **Cihazında saklanır.** Geçmiş, klasör, etiket, not, küçük görsel ve arama indeksleri yerelde tutulur. ClipBoardLine bulut senkronizasyonu sunmaz. Yerel geçmiş bir parola kasası değildir; kopyaladığın ve sakladığın içerikleri sen seçersin.
- **Görsel ve metin yakalama isteğe bağlıdır.** İzlemeyi açmak panodaki eski içeriği içeri aktarmaz. Gizli, geçici ve otomatik üretilmiş pano işaretleri denetlenir; Finder dosya kopyaları atlanır ve uygulamanın kendi kopyaları yeniden eklenmez.
- **OCR ve görsel arama cihazda kalır.** Yazı tanıma, görsel vektörleri ve arama sorguları yerel çalışır. Çalışma anında OCR/görsel arama, görselleri veya sorgu metnini yüklemez.
- **Link zenginleştirme isteğe bağlı ağ erişimidir.** Açıkken başlık ve küçük görsel için linkin sitesine veya YouTube’a bağlanır. Yerel adresler ve bilinen gizli parametreleri taşıyan URL’ler dışlanır; istemiyorsan Kaynaklar’dan kapat.
- **Güncellemeler ağı kullanır, cihaz token’ı istemez.** Resmî Sparkle akışı ve arşivleri herkese açık ve imzalıdır. Kontrol ayarlanabilir; indirme ve kurulum senin işlemini gerektirir. Bu kanal GitHub hesabına giriş istemez.
- **Yapıştırmanın ayrı izni vardır.** ⌘Enter için uygulamanın macOS Erişilebilirlik izni gerekir. Önceki düzenlenebilir hedef doğrulanır; güvenli veya değişmiş hedefler reddedilir. Normal kopyalama bu izni istemez.
- **Geri getirilebilir kaldırma, korunan orijinaller.** Geçici kayıtlar kütüphanenin Çöp Kutusu’ndan kurtarılabilir. Harici özgün görseller, askıdan kaldırılınca silinmez. Süre sonu görsel, metin ve link için ayrıdır.

## Kaynak kodundan derleme ve test

Mac ve Windows sürümlerini bu herkese açık kaynaktan derleyebilirsin. Birleştirilmiş sürüm düzeninde kaynak kodu, indirmeler ve platform güncelleme akışları aynı depoda tutulur. Aşağıdaki komutlar için macOS SDK’sı bulunan Xcode ve Python 3 gerekir. İsteğe bağlı model hazırlama, sabitlenmiş MobileCLIP-S2 dosyalarını indirip yerelde derler; uygulamadaki arama çevrimdışı çalışır. Paketleme için deponun geliştirme rehberini izle. Resmî imzalama anahtarları, kimlik bilgileri ve kullanıcı geçmişi kaynak kopyasında bulunmaz.

```sh
git clone https://github.com/orkunisitmak/clipboardline.git
cd clipboardline
swift package resolve
swift test
bash scripts/build-community.sh
# İsteğe bağlı çevrimdışı anlamsal modeller (Vision OCR modelsiz de çalışır):
CLIPBOARDLINE_BUNDLE_MODELS=1 bash scripts/build-community.sh
# İsteğe bağlı izole arayüz test uygulaması:
bash scripts/build-ui-tests.sh
```

UI test uygulaması sentetik içerik ve ayrı tercihler kullanır. Asıl uygulamayı kurmaz veya pano toplamayı açmaz. Resmî imzalı sürümleri geliştirici hazırlar; kaynak kodunu klonlamak resmî imza kimliğini vermez.

## Katkıların hakkını vererek.

ClipBoardLine, Alejandro Buján’ın Tendedero uygulamasının upstream 1.5.0 tabanlı değiştirilmiş bir fork’udur. Gerçek MIT lisanslı kaynak atası Tendedero’dur; telif ve katkı bildirimleri korunur. ClipBoardLine ayrı isim ve görseller kullanır; özgün yazarın onayı veya desteği iddia edilmez.

Tendedero’dan ilham alan ClipBoardLine; yerel kütüphane, ortak OCR araması, sabitleme ve adlandırma, klasörler ve etiketler, düzenlenebilir görsel işaretleme ve kırpma, klavyeyle gezinme ve herkese açık imzalı güncellemelerle bu pano akışını geliştirir.

Güncellemeleri Sparkle sağlar. Cihazda arama Apple Vision ve özgün MobileCLIP-S2 modellerini kullanır; ilgili bildirimler ve model lisansları dağıtımda korunmalıdır. Uyarlanan Tendedero katkıları arasında Anubhav-Rai’ın pano yakalama katkısı, dil/kopyalama bildirimi, menü sayacı ve görsel arama köprüsü bulunur.

- [Tendedero — Alejandro Buján](https://github.com/alejandrobujan/tendedero)
- [MIT License](LICENSE)
- [Sparkle](https://sparkle-project.org/)
- [Apple MobileCLIP](https://github.com/apple-aiml-research/ml-mobileclip)


## Platform desteği ve mevcut farklar

**Tek herkese açık depo.** Kaynak kodu ile Mac/Windows sürümleri artık `orkunisitmak/clipboardline-desktop` adresinde. Her platform kendi imzalı akışını korur; Latest seçilen her sürüm hem güncel `appcast.xml` hem de `windows-update.json` dosyasını taşır. Eski Mac `clipboardline-app` güncelleme adresleri doğrulanmış uyumluluk yönlendirmeleriyle çalışır; mevcut Mac kurulumları yeniden kurulmadan güncellenmeye devam eder. İki imzalı akış ve önceki üç Mac ZIP’i eski adreslerden oturum açılmadan doğrulandı; dosya içerikleri ve arşiv özetleri birebir aynı.

Geçmiş sürüm: Windows [1.7.2 build 64](https://github.com/orkunisitmak/clipboardline/releases/tag/windows-1.7.2-build64) yayımlandı: [x64 kurulumunu indir](https://github.com/orkunisitmak/clipboardline/releases/download/windows-1.7.2-build64/ClipBoardLine-Setup-1.7.2-x64.exe).

**Geçmiş 1.7.2 doğrulaması:** [`e734c7e`](https://github.com/orkunisitmak/clipboardline/commit/e734c7e97c0f8b22ff27a4ead3f82382407854cd) kaynak revizyonunun [39296605977 numaralı Windows CI çalışmasında](https://github.com/orkunisitmak/clipboardline/actions/runs/39296605977) **65 Node testi, 146 gerçek Windows kabul kontrolü** (48 kaynak, 49 paketlenmiş, 49 kurulmuş) ve **7 izole yükseltme kontrolü** geçti.

**Güncel indirmeler:** yukarıdaki bağlantılar iki platformun birlikte yayımlanan son sürümüne gider. macOS ve Windows aynı ürün sürümünü kullanır; teknik build sayaçları bağımsızdır. Paketler ve doğrulama kanıtları sürüm notlarında belirtilir.

**Geçmiş birleşme kontrolleri (1.7.1–1.7.2):** macOS 1.7.0 → 1.7.1 ve Windows 1.7.1 → 1.7.2 uygulamadan kurulup otomatik açıldı; geçmiş ve ayarlar korundu. [Gerçek Windows güncelleme koşusu](https://github.com/orkunisitmak/clipboardline/actions/runs/39309767453), değiştirilmemiş yayımlanmış uygulamaları, akışı ve anahtarı kullandı. Güncel güncellemeler GitHub tokenı istemez. Build64 için [aynı kaynaktan yerel kontroller](https://github.com/orkunisitmak/clipboardline/actions/runs/39307655801) de geçti: 48 kaynak, 49 paket, 49 kurulu uygulama ve yedi aday yükseltme kontrolü; uygulama kodu build63 ile aynı.

**Build 62 → 63 için tek seferlik yükseltme notu:** kurulum biter ama ClipBoardLine yeniden açılmazsa bir kez kendin aç. Özgün 1.7.0 build 62 istemcisinde yeniden açma düzeltmesi yoktur. Değiştirilmemiş gerçek build62 istemcisi indirme ve kurulumu verileri koruyarak tamamladı; güncel build63 → 64 geçişinde otomatik yeniden açılma da geçti.

Geçmiş 1.7.2 sürümü; metin/görsel yapıştırma, odağı geri döndürme, ekran yakalama, OCR ve klavye akışları dahil gerçek Windows kaynak, paketlenmiş ve kurulmuş oturumlarında sınandı. Hangi pano biçimlerini kabul edeceğine hedef uygulama karar verir. macOS ve Windows veri depoları ayrıdır; cihazlar arası senkronizasyon veya otomatik platform geçişi sunulmaz.

| Özellik | macOS | Windows |
| --- | --- | --- |
| İçerik askıları ve kütüphane | Yerel AppKit/SwiftUI; görsel/metin/link askıları, ızgara/liste, klasör, etiket ve sabitleme. | Saydam eğri askılar; birleşik araç çubuğu, ızgara/liste, klasör, etiket, sabitleme, not ve açılıp kapanan kenar/ayrıntı panelli normal boyutlandırılabilir kütüphane. |
| Varsayılan genel kısayollar | ⌃⌥T askılar; ⌃⌥S arama. | Ctrl+Alt+T askılar; Ctrl+Alt+S arama; Ctrl+Alt+A ekran yakalama. Kütüphane ve son görseli kopyalama genel kısayolları atanabilir; varsayılan kapalıdır. |
| Yerel kısayol değiştiricileri | Uygulama komutlarında Command (⌘); adlandırma/sayfalarda Option (⌥). | Command yerine Control; Option yerine Alt. Yerel ve genel kısayollar değiştirilebilir. |
| Pano toplama | Görsel/metin isteğe bağlı; tek URL toplama varsayılan açık, ayarlanabilir. | Görsel/metin toplama varsayılan kapalı, tek URL toplama açıktır. Kaynaklar’dan değiştirilebilir; eski seçimler korunur. Metin ve linkler sessiz eklenir. |
| Arama ve OCR | Apple Vision OCR; isteğe bağlı özgün MobileCLIP-S2 görsel anlam araması. | Yerel İngilizce/Türkçe Tesseract OCR ve ONNX/WASM ile özgün MobileCLIP-S2 görsel anlam araması. Kütüphanenin metin/görsel/birleşik modları ve kapsam filtreleri çevrimdışı çalışır. |
| Önizleme düzenleme | Çerçevesiz görsel/metin/link; düzenlenebilir işaret/kırpma, otomatik kaydeden ayrıntılar ve düzenleme sonrası oturum içi geri alma. | Çerçevesiz görsel/metin/link; ortak üst çubuk, düzenlenebilir işaret/kırpma, otomatik kaydeden ayrıntılar ve düzenleme sonrası oturum içi geri alma. |
| Kopyalama ve yapıştırma | ⌘Enter, uygulamanın Erişilebilirlik izniyle önceki düzenlenebilir alanı hedefler. | Ctrl+Enter yerel köprüyle önceki düzenlenebilir Windows alanına döner. Güvenli/değişmiş hedefler reddedilir. |
| Görsel grupları | Birden çok görsel/dosya biçimi; hangisini alacağına hedef uygulama karar verir. | Yerel FileDrop dosya listesi ve ilk görsel yedeği. Hedef desteği değişir; görseller sessizce birleştirilmez. |
| Geçmiş ve kurtarma | Türe göre 1/3/7/15/30 gün; saklanan öğeler kalır; kütüphane Çöp Kutusu. | Süresiz tutma dahil türe göre ayrı süreler; saklanan öğeler kalır; kurtarılabilir Çöp Kutusu ve oturum içi kaldırma geri alma. |
| Link ayrıntıları | İsteğe bağlı genel site/YouTube başlık ve küçük görselleri. | İsteğe bağlı genel site/YouTube zenginleştirmesi varsayılan açıktır; kapatılabilir. Önceden kapatılmış tercihler korunur. |
| Ekran kaydı ve Quick Look | Quick Look ve AVKit .mov/.mp4 kayıtları yerel denetimlerle önizler. Kırpma özgünü korur; öğenin kimliğini ve düzenini koruyan yönetilen bir kopya kaydeder. | MP4/MOV içe aktarma ve izlenen klasörden toplama, oynatma, M/Eylemler ile kırpma, dosya kopyalama/sürükleme/dışa aktarma. Yayımlama öncesi yerel kabul testi zorunludur. Kurulu Windows codec’lerini kullanır; özgünü korur, kırpmayı gerekirse yeniden kodlayarak MP4’e yazar. |
| Diller | Sistem dili veya ortak dokuz dil kataloğundan biri. | Aynı ortak dokuz dil kataloğu ve sistem dili seçimi. OCR dilleri İngilizce/Türkçedir. |
| Güncellemeler ve işletim sistemi güveni | Sparkle imzalı herkese açık akış ve arşivler. Proje imzalı Mac derlemesi Apple noter onaylı değildir. | Ortak herkese açık depodaki Windows imzalı akışı; ayarlanabilir açılış/saatlik kontrol ve hatada beş dakika sonra yeniden deneme. Güncelle ve yeniden aç için tıklama gerekir. Kurulumun Authenticode yayıncı sertifikası yoktur. |

İlk açılışta işletim sisteminin normal onayı gerekebilir. Mac derlemesi Apple Developer ID/noter onayı yerine kalıcı proje sertifikası kullanır; Windows kurulumu Authenticode imzalı değildir. Güncelleme imzaları ve özetleri proje kanalını doğrular; Apple veya Microsoft yayıncı sertifikası anlamına gelmez. Belgelenmiş sürüm dosyalarını ve normal sistem onayını kullan; sistem korumalarını kapatma.

Windows çalışma zamanı bildirimleri: Electron MIT lisanslıdır; Chromium ve bileşenlerinin BSD türü ve diğer bireysel lisansları LICENSES.chromium.html içinde korunur. Tesseract.js/Core Apache-2.0 kullanır. İngilizce/Türkçe traineddata için, MIT paket metadata’sından ayrı upstream dil verisi Apache-2.0 koşulları korunur. Tam metinler ve bildirimler windows/THIRD_PARTY_NOTICES.md içinde listelenir.

### Windows kaynak geliştirme

```sh
cd windows
npm ci
python3 ../scripts/prepare-windows-search-models.py
npm test
npm start
# On the Windows x64 runner:
npm run dist
npm run test:electron
```

[Windows bileşen lisansları](windows/THIRD_PARTY_NOTICES.md)

### Linux

Windows Electron uygulaması Linux'ta da çalışır (KDE Plasma Wayland üzerinde
CachyOS ile test edildi; X11, Hyprland, Sway ve GNOME belgelenen sınırlarla
desteklenir). Pano, pencere hedefleme, yapıştırma ve kayıt köprüsü
`wl-clipboard`/`xclip`, KWin betikleri, `hyprctl`/`swaymsg`/`xdotool`,
`ydotool`/`wtype` ve FFmpeg kullanır.

```sh
(cd packaging/arch && makepkg -si)        # Arch, CachyOS, EndeavourOS, Manjaro
(cd windows && npm ci && npm run dist:linux)   # AppImage, deb, rpm, pacman
```

Yardımcı paketler, portal olmadan kısayollar (`clipboardline --toggle`) ve
Linux istisnaları için [ClipBoardLine on Linux](docs/linux.md) belgesine bakın.
