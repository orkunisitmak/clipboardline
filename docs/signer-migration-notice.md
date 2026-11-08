# One-time manual reinstall for 1.7.8 and earlier (macOS and Windows)

Status: applies once ClipBoardLine 1.7.9 is released for your platform.

## English

Starting with **1.7.9**, ClipBoardLine for macOS is signed with an Apple **Developer ID** and
**notarized by Apple**. Both platforms also use a new update-signing key.

Copies of **1.7.8 and earlier**, on Mac and on Windows, only trust the previous key. For your
security they **cannot** accept 1.7.9 or any later update automatically, and **Check for updates** may
report a signature problem. This is expected; your copy has not been tampered with.

Do this **once**:

- **macOS:** quit ClipBoardLine (menu bar icon → Quit), download the 1.7.9 Mac ZIP from
  [Releases](https://github.com/orkunisitmak/clipboardline/releases), open it and drag
  **ClipboardLine Review.app** into `~/Applications`, choosing **Replace**. Keep the same name and place.
  macOS may ask once more for Accessibility, Screen Recording or folder access.
- **Windows:** quit ClipBoardLine, download `ClipBoardLine-Setup-1.7.9-x64.exe` from the same page and
  run it. SmartScreen may warn because the installer has no Authenticode certificate.

History, Library, pins and settings are stored outside the app and are kept. From 1.7.9 on, updates
install from inside the app again.

## Türkçe

**1.7.9** sürümünden itibaren ClipBoardLine'ın macOS sürümü Apple **Developer ID** ile imzalanıyor ve
**Apple tarafından noter onaylı (notarized)**. İki platform da artık yeni bir güncelleme imza anahtarı
kullanıyor.

Mac ve Windows'taki **1.7.8 ve önceki** kurulumlar yalnızca eski anahtara güveniyor. Güvenlik gereği
1.7.9'u ve sonraki güncellemeleri **otomatik olarak kabul edemezler**; **Güncellemeleri denetle** bir
imza sorunu bildirebilir. Bu beklenen bir durumdur, kurulumunuz kurcalanmamıştır.

Bunu **bir kez** yapın:

- **macOS:** ClipBoardLine'dan çıkın (menü çubuğu simgesi → Çık),
  [Releases](https://github.com/orkunisitmak/clipboardline/releases) sayfasından 1.7.9 Mac ZIP
  dosyasını indirip açın ve **ClipboardLine Review.app** uygulamasını `~/Applications` klasörüne
  sürükleyip **Değiştir**'i seçin. Adı ve konumu aynı kalsın. macOS, Erişilebilirlik, Ekran Kaydı veya
  klasör erişimi iznini bir kez daha isteyebilir.
- **Windows:** ClipBoardLine'dan çıkın, aynı sayfadan `ClipBoardLine-Setup-1.7.9-x64.exe` dosyasını
  indirip çalıştırın. Yükleyicide Authenticode sertifikası olmadığı için SmartScreen uyarı verebilir.

Geçmiş, Kitaplık, sabitlemeler ve ayarlar uygulamanın dışında saklandığı için korunur. 1.7.9'dan
itibaren güncellemeler yeniden uygulama içinden kurulur.
