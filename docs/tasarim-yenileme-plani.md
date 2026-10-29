# Tasarım yenileme planı (Apple yaklaşımı)

Hedef: ClipBoardLine'ı Apple'ın içeriden geliştirdiği bir uygulama gibi hissettirmek.
Tek bir fiziksel metafor (çamaşır ipi) dürüstçe uygulanır, kontroller geri çekilir.
Her faz macOS ve Windows'ta birlikte yapılır (`docs/cross-platform-parity.md`).
Her fazın sonunda Mac XCTest + standalone, Windows `npm test`, parity testleri,
`check-release-version.py --require-windows`, gizli bilgi taraması ve yayın denetimi çalışır.

Karakter: **sakin ve zarif**. Yaylar hızlı durulur, en fazla bir görünür taşma olur.
Oyunbaz varyant, Faz 1 onaylanınca ayrı bir parametre seti olarak denenecek.

## Faz 1: Yaşayan ip ✅

- `contracts/hang-motion.json`: iki platformun ortak dalga formülü ve örnek değerleri.
- Kart gelince ip aşağı esner, kart kaldırılınca yukarı toparlanır, dalga komşulara gecikmeyle yayılır, 1.2 saniyede biter.
- Arama, filtre ve sayfa değişimi gibi 3'ten fazla kartı etkileyen değişimler ipi oynatmaz.
- Görsel geldiğinde mandal açılıp kapanır ve kart sakin bir yayla 10° salınır. Eski değerler 16° ve uzun süren bir salınımdı.
- Esinti artık rastgele değil, soldan sağa giden bir dalga.
- Seçili kart hafifçe öne gelir (ölçek 1.02).
- Reduce Motion açıkken ip, salınım ve esinti kapanır.
- Mac: `HangMotion.swift`, `RopeHung` modifier'ı, `Rope` dinamik çizim. Windows: `lib/hang-motion.cjs` + `styles.css`.

## Faz 2: Ada (çentikten doğan dock)

Prototip onaylandı (siyah ve cam yüzey, çentikli ve çentiksiz ekran).

### 2A: macOS ✅ (Ayarlar → Görünüm → Ada, varsayılan hâlâ Klasik)
- `Island.swift`: `IslandView` ve `IslandShape`. Omuzlar ekran kenarına kaynaşıyor. Açılış yayı 0.5 sn / 0.72 sönüm, kapanış 0.38 sn / kritik sönüm. İçerik açılırken geç geliyor, kapanırken önce gidiyor.
- Çentik `NSScreen.safeAreaInsets` ile algılanıyor. Çentiksiz ekranda ada yoktan doğup kayboluyor.
- Tek ip: görsel, metin ve link tarihe göre en yeniden eskiye sıralanıyor. Filtre seçenekleri: Tümü · Görseller · Metinler · Linkler (sayılarıyla).
- Klavye: ←/→ ipi türler arasında dolaşır, Tab filtreyi değiştirir. Seçim, kartın ait olduğu rafa geçer, böylece Enter, Space, P, S gibi tüm eylemler aynen çalışır.
- 30 mandal: `windows/lib/hangers.cjs` tek kaynak. `node scripts/generate-hangers.cjs` komutu `contracts/hangers.json` ve `HangerCatalog.swift` dosyalarını üretir. Mandal seçimi kart kimliğinden geldiği için her kart her açılışta aynı mandalda asılı kalır.
- Testler: `IslandTests` (katalog, mandal ataması, sıralama, ok ve filtre davranışı).

### 2B: Windows (sıradaki)
- Electron penceresi ekranın üstüne yapışık ve çerçevesiz olacak. Aynı yay `lib/hang-motion.cjs` yanında `lib/island.cjs` ile uygulanacak.
- `renderer.js` içinde `shelves()` yerine ada görünümü gelecek. `settings.layoutMode` ve `settings.islandSurface` ayarları eklenecek.
- Windows'ta çentik yok: ada her zaman yoktan doğar.

### 2C: Varsayılan yapma
- `contracts/shelf-behavior.json` ve `library-keyboard.json` dosyalarına ada senaryoları eklenecek (tek satır, filtre, ok ile türler arası gezinme). İki adaptör de bu senaryolarla test edilecek.
- İki platform da geçince varsayılan değer "Ada" olacak.

## Faz 3: Ayarlar penceresi (referans: Nashi ayarları)

- Sol kenar çubuğu: simge + başlık, seçili öğe yumuşak tint'li yuvarlak arka planla gösterilecek. Bölümler: Genel, Kaynaklar, Raflar ve görünüm, Klavye, Geçmiş, Güncellemeler, Hakkında. En altta "Yerel olarak çalışır" notu olacak.
- Sağ panel: küçük harfli tint'li üst etiket (ör. "GÖRÜNÜM"), büyük başlık, tek satırlık açıklama.
- Ayarlar yuvarlak köşeli gruplu kartlarda toplanacak. Her kartın kendi başlığı ve gerekiyorsa "Varsayılana dön" düğmesi olacak. Satırlar "etiket solda, kontrol sağda" düzeninde, aralarında ince ayraçlar olacak.
- Mac: `SettingsWindow.swift` `NavigationSplitView` + `Form(.grouped)` ile kurulacak. Windows: `renderer.js` içindeki `settings()` aynı bilgi mimarisiyle yeniden yazılacak.
- Ayar anahtarları ve davranışlar değişmeyecek, yalnızca yerleşim değişecek. Mevcut ayar testleri olduğu gibi geçmeli.

## Faz 4: Finder / Explorer'dan kopyalanan dosyalar

Öneri (seçilen): **görsel ve video dosyaları Görseller rafına gelir. Diğer dosya türleri şimdilik alınmaz.**
Gerekçe: Ürünün kimliği üç raf. Dördüncü bir raf bütün klavye kontratlarını (`library-keyboard.json`, `shelf-behavior.json`) ve iki platformun yerleşimini değiştirir. Görsel ve video kopyalama ise kullanıcının asıl beklentisi.

- Mac: `ClipboardWatcher.swift:92` şu an `.fileURL` içeren kopyaları tamamen atlıyor (Finder ikon TIFF'i gönderdiği için). Bunun yerine `fileURL`'ler okunacak. UTType `public.image` veya `public.movie` ise gerçek dosya `Line.hang(url)` ile asılacak, ikon verisi hiç okunmayacak. Kaynak dosya yerinde kalacak (harici orijinal kuralı).
- Windows: Explorer `CF_HDROP` (Electron `clipboard.readBuffer('FileNameW')` / native yardımcı) ile aynı filtre uygulanacak.
- `contracts/clipboard-admission.json` dosyasına "dosya kopyası: görsel/video kabul, diğerleri ret, ikon asla" senaryoları eklenecek ve iki adaptörde test edilecek.
- Ayarlar → Kaynaklar'da "Kopyalanan görsel dosyalarını as" seçeneği olacak (varsayılan: açık, görsel toplama açıksa).

## Faz 5: Koparma gerginliği ve son rötuşlar

- Kart sürüklenirken ip, tutulan noktada parmağı takip ederek aşağı gerilecek. Bırakınca dalga yayılacak (`HangMotion`'a sürekli bir "çekme" kuvveti eklenecek).
- Seçim değişince komşu kartlar 4–6pt aralanacak (Dock büyütmesinin sakin hâli).
- İp malzemesi temaya göre olacak: koyu temada gümüş kordon, açık temada keten tonu. Mandal raf tonunda hafif eloksal görünümünde olacak.
- Oyunbaz parametre seti (`contracts/hang-motion.json` → `playful`) ve Ayarlar'da "Hareket: Sakin / Oyunbaz" seçeneği.

## Doğrulama notu

Windows'ta renderer testlerinin macOS'ta çalışması yerel kabul sayılmaz. Yayın için iki platformun CI kanıtı gerekir.
