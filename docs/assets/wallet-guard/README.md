# Wallet Guard media

All values shown are public test vectors or synthetic data that hold no funds:
the BIP39 `abandon … about` vector, the WIF of private key `1`, and the
synthetic or EIP-55 example addresses from `contracts/wallet-guard.json`.

- `macos-*.png`: live captures of a self-built `ClipBoardLine Dev.app`
  (`scripts/build-community.sh`, separate storage) on macOS 26.5 at 1x, driven
  with `pbcopy`. The panels are window captures of the real Wallet Guard panel.
  `macos-history-proof.png` shows a neutral demo backdrop with a caption and the
  result of a read-only `sqlite3` query against the Dev library after the run.
- `windows-renderer-*.png`: the unmodified Windows renderer (`index.html`,
  `renderer.js`, `styles.css`) rendered in Chromium on macOS with a stub preload
  API. The notice text comes from `windows/lib/wallet-guard.cjs`. This is not a
  Windows run; the Windows system notification is not shown.
- `wallet-guard-overview.png`: summary card generated from HTML.
