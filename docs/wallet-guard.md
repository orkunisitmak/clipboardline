# Wallet Guard

[English](#english) · [Türkçe](#türkçe)

## English

Wallet Guard is a small, local safety layer for people who copy crypto
recovery phrases, keys and addresses. It is on by default on macOS and
Windows and can be switched off in **Settings → Sources → Wallet Guard**.
All checks are pure local code. Wallet Guard makes no network request, loads
no web content, and stores nothing new.

### What it does

| Copied text | Result |
| --- | --- |
| A BIP39 recovery phrase (12, 15, 18, 21 or 24 English words with a valid checksum), also numbered or inside a short labelled note | Not saved to history, Library, search or previews. A short notice: "Recovery phrase not saved. Never paste it into websites or chats." |
| A private key: raw secp256k1 hex (optional `0x`, range-checked), WIF, extended private key (`xprv`/`tprv`/`yprv`/`zprv`/`uprv`/`vprv`/`Yprv`/`Zprv`), or a Solana keypair (base58 or JSON byte array) | Not saved. A short notice: "Private key not saved. Never paste it into websites or chats." |
| An address, then within 3 seconds a **different address of the same chain**, with no front application change | Persistent warning: "Your copied address was replaced by another address. This is how clipboard malware steals crypto." Both addresses stay visible. |
| An address whose first 4 and last 4 characters match a different address in recent text history or earlier in this session | Persistent lookalike warning with both addresses side by side. |

Address formats: Bitcoin base58 (P2PKH/P2SH, mainnet and testnet) and segwit
bech32/bech32m (`bc1`/`tb1`, BIP173/BIP350 rules), EVM `0x` addresses (EIP-55
checksum enforced when the letters are mixed case), Tron `T` addresses
(Base58Check) and Solana 32-byte public keys (format only).

Addresses are always saved normally when address capture is on; warnings never
block a copy or change the clipboard.

### Threat model

- **Clipboard hijackers ("clippers").** Malware watches the clipboard and swaps
  a copied address for the attacker's address of the same type. The paste looks
  plausible, and the funds go to the attacker. Wallet Guard compares
  consecutive copies: same chain, different address, inside a short window, and
  no front application change since the first copy.
- **Address poisoning.** Attackers send dust or zero-value transfers from a
  vanity address that shares the visible start and end of an address you use,
  hoping you copy it from your transaction history later. Wallet Guard compares
  a newly copied address with recent text history and with addresses copied
  earlier in this session.
- **Secret leakage through history.** A clipboard manager that saves everything
  turns a one-time seed or key copy into a long-lived file, search index entry,
  backup or synced copy. Wallet Guard keeps recognized secrets out of every
  ClipBoardLine destination.

### What is not protected

- Wallet Guard does not remove malware and cannot stop another program from
  reading the clipboard. It cannot clear the clipboard for you, and it does not
  change what the receiving application gets when you paste.
- It inspects text that ClipBoardLine already reads. If text and link capture
  are both off, ClipBoardLine does not read copied text and Wallet Guard is idle.
- Replacement detection needs to observe the original copy. On macOS the
  watcher polls every 0.5 seconds, so a clipper that swaps faster than that can
  hide the original copy. Windows uses the native clipboard change monitor.
- A front application change is the only available proxy for a new user copy
  action; neither platform reads keystrokes. Two different same-chain addresses
  copied within 3 seconds in the same application produce a warning, which is
  the intended conservative outcome.
- Recovery phrases in other languages, Electrum seed formats, images or
  screenshots of seeds, passwords and API keys are not recognized. A phrase
  inside a run of more than 48 wordlist words, or a copy longer than 16,384
  characters, is not inspected.
- Solana addresses have no checksum. The format check (base58, 32 bytes) can
  match other identifiers of the same shape.
- Strings in memory are released normally but are not zeroed; the platform
  string types do not offer secure erasure. Wallet Guard keeps no reference to
  a secret after classifying it.

### False-positive strategy

- Every recognized secret and address is validated, not pattern-matched:
  BIP39 checksum against the official English wordlist, Base58Check double
  SHA-256, bech32/bech32m checksums and BIP350 program rules, EIP-55 Keccak-256
  case checksum, and secp256k1 scalar range (non-zero, below the curve order).
- Solana keypairs are accepted only when the second half is the Ed25519 public
  key derived from the first half (CryptoKit on macOS, Node's Ed25519 on
  Windows). Transaction signatures of the same length are rejected.
- Raw hex keys and addresses must be the entire copy. A 64-digit hex string
  inside a sentence (for example `txid ...`) or a checksum line is not treated
  as a key. A bare 64-digit hex value is indistinguishable from a transaction
  hash, so it is withheld as a possible key; switch Wallet Guard off if you copy
  bare hashes often.
- Recovery phrases are searched as 12 to 24 word windows inside a run of
  wordlist words, so a phrase with a label such as "Seed phrase:" is still
  caught, while random word lists fail the checksum (1 in 16 to 1 in 256 per
  window).

### Privacy

- No network access, telemetry, external process or file write.
- Only public addresses are remembered: the last copied address and at most 32
  addresses copied in this session, in memory. Turning Wallet Guard off clears
  them. The lookalike check reads at most 200 recent text history entries that
  ClipBoardLine already stores.
- The bundled BIP39 English wordlist is unmodified (SHA-256
  `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`) and MIT
  licensed; see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

### Shared contract and tests

[`contracts/wallet-guard.json`](../contracts/wallet-guard.json) holds the
shared limits, 91 classification vectors and 15 stateful scenarios with an
injected clock. All values are public test vectors (BIP39, BIP32, BIP350,
EIP-55, the key `1`) or synthetic data that hold no funds.

- macOS: `WalletGuardTests` runs the contract against `WalletGuardClassifier`,
  the actual `TextClipboardWatcher` with a synthetic clipboard source and legacy
  text history, and `AppDelegate.admitCopiedText` with the persisted setting.
- Windows: `tests/wallet-guard.test.cjs` runs the contract against
  `lib/wallet-guard.cjs`, the Store settings and clipboard admission;
  `renderer-ui.test.cjs` covers the localized Settings toggle.

Presentation differs by platform convention: macOS shows a non-activating
floating panel at the top of the screen; Windows shows a system notification.
Both also show the message in the app's own notice area. Neither takes focus
from the application you copied from.

## Türkçe

Wallet Guard (Cüzdan Koruması), kripto kurtarma ifadesi, anahtar ve adres
kopyalayan kullanıcılar için küçük ve tamamen yerel bir güvenlik katmanıdır.
macOS ve Windows'ta varsayılan olarak açıktır; **Ayarlar → Kaynaklar → Cüzdan
Koruması** bölümünden kapatılabilir. Ağ isteği yapmaz, web içeriği yüklemez,
yeni bir veri saklamaz.

- **Kurtarma ifadeleri** (geçerli checksum'lı 12/15/18/21/24 İngilizce BIP39
  kelimesi; numaralı veya kısa bir not içinde olsa da) ve **özel anahtarlar**
  (secp256k1 hex, WIF, xprv/tprv/yprv/zprv, Solana anahtar çifti) geçmişe,
  kütüphaneye, aramaya veya önizlemelere kaydedilmez. Kısa bir bildirim
  gösterilir.
- **Pano korsanı uyarısı:** Bir adres kopyalandıktan sonra 3 saniye içinde,
  ön plandaki uygulama değişmeden aynı zincirden **farklı** bir adres panoya
  gelirse kalıcı bir uyarı iki adresi yan yana gösterir.
- **Adres zehirlenmesi uyarısı:** Yeni kopyalanan adres, son metin geçmişindeki
  veya bu oturumda kopyalanan başka bir adresle aynı ilk 4 ve son 4 karakteri
  paylaşıp ortada farklıysa benzer görünümlü adres uyarısı gösterilir.

Korunmayanlar: kötü amaçlı yazılımı silmez, panoyu temizlemez; metin ve link
yakalama kapalıysa çalışmaz; macOS 0,5 saniyede bir kontrol ettiği için daha
hızlı değişimleri kaçırabilir; diğer dillerdeki ifadeleri, ekran görüntülerini
ve parolaları tanımaz. Solana adreslerinde checksum yoktur.

Yanlış pozitifleri azaltmak için her şey doğrulanır: BIP39 checksum,
Base58Check, bech32/bech32m, EIP-55 Keccak-256, secp256k1 aralığı ve Solana
anahtar çiftinde Ed25519 açık anahtar türetimi. Tek başına kopyalanan 64
haneli hex değer işlem hash'inden ayırt edilemediği için olası anahtar olarak
kaydedilmez; bu sık kullandığınız bir akışsa özelliği kapatabilirsiniz.

Ortak davranış [`contracts/wallet-guard.json`](../contracts/wallet-guard.json)
dosyasındadır ve iki platformun testleri aynı dosyayı çalıştırır.
