# Library keyboard guide / Library klavye rehberi

ClipBoardLine 1.7.8. macOS uses Command (⌘); Windows uses Control (Ctrl)
for application commands. Control+Tab is deliberately Control on both systems:
Command+Tab remains macOS application switching. Keys below are defaults and can
be changed or disabled in Settings → Keyboard shortcuts.

## Türkçe

Library açılınca geçerli seçim korunur; seçim yoksa ilk sonuç seçilir ve sonuçlar
klavye odağını alır. Oklar seçili kartı ekrana getirir. Üst/alt satır sınırında
seçim zıplamaz. Metin kutusunda yazarken harf kısayolları ve düzenleme tuşları
metne aittir; P veya S yazmak içeriği sabitlemez ya da silmez.

| İşlem | Tuşlar |
| --- | --- |
| Kartlar arasında gezin | ←/→; gridde ↑/↓ aynı sütundaki satıra, listede önceki/sonraki öğeye |
| Çoklu seçim | Shift+ok; ⌘/Ctrl+A tüm sonuçlar |
| İlk / son sonuç | ⌘/Ctrl+← / → |
| Dokuz öğe önce / sonra | Alt+← / → |
| Bölme değiştir | F6 / Shift+F6 veya Control+Tab / Control+Shift+Tab |
| Arama | ⌘/Ctrl+F; ↓, Enter veya Esc ile sorguyu koruyup sonuçlara dön |
| Önizleme | Space; kapatmak için Esc veya Space |
| Kopyala / önceki uygulamaya yapıştır | Enter veya ⌘/Ctrl+C / ⌘/Ctrl+Enter |
| Sabitle / sabitlenenleri göster | P / F |
| İsim verip sabitle | Alt+P; çoklu seçimde Enter ile sıradaki, Esc ile çık |
| Klasöre ekleyip sabitle | Shift+P; oklar ve Enter ile klasör seç |
| Etiketler | ⌘/Ctrl+Shift+T |
| Metni düzenle / görsel işaretle / kırp | E / M / C |
| Yeni not / yeni klasör | ⌘/Ctrl+N / ⌘/Ctrl+Shift+N |
| Çöp’e taşı | S, Delete veya ⌘/Ctrl+Backspace |
| Son Çöp’e taşıma işlemini geri al | Backspace veya ⌘/Ctrl+Z |
| Diğer işlemler | ⌘/Ctrl+K Actions; yazarak bul, ↑/↓ ve Enter ile çalıştır |

F6 sırası açık bölmelerde kenar çubuğu → sonuçlar → ayrıntılar → arama.
Gizli ayrıntılar atlanır. Kenar çubuğunda ↑/↓ kapsamı değiştirir; Enter veya →
sonuçlara geçer. Kapalı klasörde ilk → alt klasörleri açar. Tab/Shift+Tab ile
buton, seçim kutusu ve alanlar arasında normal şekilde dolaşılabilir.
Ayrıntılarda Esc taslağı kaydedip sonuçlara döner; kaydetme başarısızsa taslak
ve odak korunur. Actions içinden kapsam/tür, görünüm, sıralama, arama modu,
klasör/etiket oluşturma, yeniden adlandırma, kaldırma, Çöp’ten geri
yükleme, Kalıcı olarak sil ve Çöp Kutusu’nu boşalt işlemlerine ulaşılır.

Library önizlemesinde oklar, ilk/son ve sayfa kısayolları aynı sonuçlar içinde
ilerler; içerik türü değişse de pencere açık kalır. S sonrası sonraki öğe gelir;
son öğe de Çöp’e giderse açık pencerede Geri Al sunulur. Backspace geri getirir.
Görsel işaretlerken ⌘/Ctrl+Z çizimi geri almaya devam eder; metin düzenlerken
normal metin düzenleme ve geri alma tuşları korunur.

Enter ile Library’den kopyalamak Library’yi açık tutar. Askıda/askı
önizlemesinde Enter’ın kopyalayıp kapatma ve önceki uygulamaya odak döndürme
akışı korunur. Kısayolla Çöp’e taşıma kalıcı silme değildir; Çöp görünümünde de S, Delete ve
⌘/Ctrl+Backspace hiçbir şeyi kalıcı silmez. Kalıcı olarak sil ve Çöp Kutusu’nu
boşalt iki platformda da yalnızca menülerden ve Actions’tan çalışır, silinecek
öğe sayısını söyleyen bir onay ister.

## English

Opening Library preserves a valid selection or selects the first result and
focuses the content. Arrows navigate spatially in grid view and by item in list
view; Shift extends a range. Command/Control+arrows jump to either end and
Alt+arrows advance nine items. Command/Control+A selects all matching results.

F6/Shift+F6 or Control+Tab/Control+Shift+Tab cycles visible sidebar, content,
details and search. Sidebar arrows change scope; Right expands a collapsed
folder, otherwise Right or Enter enters content. Native Tab navigation remains
available for controls. Command/Control+F focuses search; Down, Return or Escape
commits the pending query and returns to the matching results without clearing
it. Text fields retain native caret, selection, copy and undo behavior.

Space previews; Enter or Command/Control+C copies; Command/Control+Enter invokes
the existing paste-to-previous-app flow. P pins, F filters pinned items, Alt+P
names and pins sequentially, Shift+P opens the keyboard folder picker and
Command/Control+Shift+T edits tags. E edits text, M opens image markup and C
opens image crop. Command/Control+N creates a note and Command/Control+Shift+N
creates a folder. Escape leaves details only after drafts save successfully.

S, Delete or Command/Control+Backspace moves selection to recoverable Trash and
selects the next surviving item. Backspace or Command/Control+Z undoes the last
Trash batch in this running app. Image markup undo and native text undo retain
priority while editing. Preview stays open across mixed-content navigation,
deletions, an empty result and undo. Library copy keeps Library open; shelf copy
retains its existing dismissal and returned-focus behavior.

Command/Control+K opens Actions: search, arrows and Enter reach scope/type,
view/sort/search modes, folder/tag management, membership removal, Trash recovery, Delete permanently and Empty Trash. Both
platforms confirm those two with the number of items they erase, and S, Delete or
Command/Control+Backspace never delete permanently, also in Trash. This is also the fallback when a function key
is intercepted by the OS or the keyboard requires Fn.

## Persistence and OS integration

Trash undo is an in-memory bounded journal; Trash itself persists across app
restarts and remains restorable from its Library scope. Undo refuses to overwrite
records changed after the captured batch. macOS revalidates against its durable
store on mutation. Windows has one application-owned in-memory Store; outside
processes must not edit its JSON database while the app is running. No extra
permissions, global keyboard preference changes or agent server are introduced.
