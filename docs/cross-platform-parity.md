# One product on macOS and Windows

ClipBoardLine is one product on two operating systems. A user-visible feature,
shortcut or behavior change applies to both platforms by default. Implement and
validate both sides in the same change. An operating-system API difference is an
implementation detail, not permission to omit the corresponding feature.

If a native limitation requires a different behavior, document the exact affected
platform, user impact and reason in the shared contract's `nativeExceptions` and
review it explicitly. Command/Option on macOS and Control/Alt on Windows are the
current documented modifier-name difference; the actions keep the same meaning.
Never silently remove one platform from `defaultPlatforms`.

## Global access

Fresh installations use Control+Option+T on Mac and Control+Alt+T on Windows
for the shelf toggle, and Control+Option/Alt+S for shared search. Existing saved
Windows Control+Alt+Space or other custom choices remain unchanged. Global
Library and copy-latest-image shortcuts are configurable and off by default on
both platforms. Windows also keeps its configurable screenshot shortcut.
Settings can record or switch off each global action. A rejected replacement
keeps any previously working registration; copy-latest preserves the external
application's focus and copies the rendered image without opening the shelves.

## Executable shelf contract

[`contracts/shelf-behavior.json`](../contracts/shelf-behavior.json) is the shared,
versioned behavioral specification. Its synthetic items use portable aliases and
are listed newest first. Every step contains an expected active row, focused
item, complete selection, visible rows and native search-editing state.

The current eleven scenarios (62 observations per platform) cover one selected image on opening, reopening,
hidden/empty/filtered image fallback, column-preserving vertical navigation and
clamping, hidden/empty row skipping, horizontal navigation, adding and hiding
rows, search caret keys, empty shelves, remapping, disabling and restoring defaults.
A future user-visible change must add
or amend the relevant scenarios and both adapters in the same change. Extend the
contract's scope as the product grows; passing the current shelf scenarios is not
a claim that every feature has cross-platform coverage.

`policy.sharedBehaviors` records shared user-visible behavior outside shelf
navigation, with how macOS and Windows each implement it; the checker rejects an
entry missing either platform. `localized-notices` requires notices and the
shortcut-conflict message to follow the selected language, including refilled
templates such as `Exported %d · failed %d`. Its Windows evidence is the
renderer test that runs the shipped export through the Export shortcut.
`watched-folder-failures` records the shared failure notice for an image that
cannot be imported from a watched folder.

The adapters execute application behavior:

- macOS: `CrossPlatformBehaviorContractTests` creates the actual `LibraryStore`,
  `Line` and `LineKeyboard` with isolated synthetic files and preferences. It
  emits observations while running XCTest. It does not display windows, read
  application fields, post keys or touch the system clipboard.
- Windows: `renderer-ui.test.cjs` executes the shipped `renderer.js` handlers in
  its DOM/IPC fixture and records the rendered selection and active row. CI runs
  this adapter on Windows. Running it on a Mac is useful development feedback,
  but is explicitly rejected as Windows acceptance by the release checker.

These tests compare executed states to a common contract. They do not grep
source code or maintain a duplicate navigation implementation as the oracle.
The separate native Windows source, packaged and installed acceptance suites
still validate keyboard input, real text/image paste, focus, Library, rendering
and updates. Native Mac paste and focus acceptance remains a separate check.
Neither synthetic adapter proves that a particular third-party editor accepts
an OS paste command.

## CI evidence and publication

The existing read-only workflows emit exact-source reports:

| Workflow | Artifact | Report inside artifact |
| --- | --- | --- |
| `macos.yml` (`macOS source`) | `clipboardline-macos-parity-<source SHA>` | `macos.json` |
| `windows.yml` (`Windows application`) | `clipboardline-windows-<source SHA>` | `validation/parity/windows.json` |

Windows CI also runs when Mac sources, shared tests, the contract or parity guard
changes. Both native-host workflows must succeed for the same public commit.
Reports bind the complete source revision, exact contract SHA-256, platform,
host and adapter mode to every observed step. Missing, duplicate, unknown or
failing observations, a changed contract, execution errors, a stale revision or
a Windows report generated on another OS stop verification.

Release tooling authenticates the successful workflow runs, repository,
revision, artifact digests and report paths, then invokes:

```sh
python3 scripts/check-cross-platform-parity.py \
  --source-revision <full-public-source-SHA> \
  --macos-report <downloaded-macos-report.json> \
  --windows-report <downloaded-windows-report.json> \
  --report <local-validation-summary.json>
```

JSON alone is not an authenticated CI result. This checker never substitutes for
trusted artifact provenance, both platform version checks, native acceptance,
package signatures or the verified counterpart feed/package required for a
unified Latest release. Mac and Windows use the shared product version while
keeping independent monotonically increasing build counters. Unchanged Mac
application source does not require a new Mac binary merely because Windows
implementation, tests, documentation or CI changed.

Local development commands:

```sh
python3 scripts/test-cross-platform-parity.py
CLIPBOARDLINE_PARITY_REPORT=local/validation/parity/macos.json \
  swift test --filter CrossPlatformBehaviorContractTests
cd windows
CLIPBOARDLINE_PARITY_REPORT=validation/parity/windows.json npm test
```

On Windows PowerShell, set `$env:CLIPBOARDLINE_PARITY_REPORT` before `npm test`.
Commit no generated evidence, real clipboard content, local preferences,
credentials or signing material.


## 1.7.6: restored shelf slide

Mac build75 and Windows build69 retain the prepared shelf contents and fixed
native window bounds while restoring the downward reveal/upward dismissal.
The retained layer tree moves for 420ms opening and 220ms closing, using matching
curves on both platforms. Rapid reversal continues from the current presentation
position; generation guards reject stale hide completions. Pointer input waits
for the moving content to settle; keyboard navigation remains available. Reduce
Motion uses immediate endpoints.

Native validation must observe real compositor movement and fixed window bounds,
not infer animation from the target transform. Keep the existing performance,
focus, selection, retained-card and hidden-edit acceptance checks. The genuine
Windows upgrade baseline is 1.7.5/build68: 545769250 bytes, SHA256
`d37f86b5e355a58e3303899aa6917efb495a7f1d2a02732fd7e843cc1ef442e7`,
source `0d71154257aef8042a53ee6ff169079eddbb42bd`.
Stage `clipboardline-1.7.6-build75`, then publish `windows-1.7.6-build69`
with that exact counterpart; both feeds must say 1.7.6 before Latest promotion.

## 1.7.8: keyboard-complete Library

Mac build78 and Windows build71 implement the same Library keyboard workflow.
See [the bilingual guide](library-keyboard.md). The additive
`contracts/library-keyboard.json` specifies 10 scenarios / 87 observations through the
shipping Mac Model/Store and Windows renderer/Store. This contract proves state,
not physical focus; native Mac focus/workflow tests, Cua acceptance and Windows
source/packaged/installed keyboard journeys separately verify controls, panes,
search, dialogs, mixed previews, recoverable Trash and undo.

The existing Mac `macos.json` workflow artifact embeds an independently hashed
`libraryKeyboard` report; Windows adds `validation/parity/library-windows.json`
inside its existing validation artifact. Explicit separate-file Mac reporting is
also supported. The publisher reads both from the same authenticated archives as
the shelf reports and runs the strict Library checker. No broader workflow or
credential permission is required.
Windows publication requires all seven real Library acceptance checks in all
three runtime modes. Native text/IME undo stays owned by its editor; image
Command/Control-Z keeps markup priority. Control+Tab uses Control on both systems
because macOS Command+Tab switches applications. No global OS keyboard preference
is changed. Trash undo is a bounded, in-process journal; persistent Trash remains
restorable after restarting. Windows has one application-owned Store and does not
watch foreign direct JSON edits while running.

The genuine Windows upgrade baseline is 1.7.7/build70: 545777945 bytes, SHA256
`89b9d3d3ddc91d1ddddfb6b07ee73930686d9d2cbbc80a4785746befc9ad9768`,
source `1c93c163e7e45d102d13c1077dd8baa969eab8ba`. Stage
`clipboardline-1.7.8-build78`, then publish `windows-1.7.8-build71` with that
verified counterpart. Latest must contain both signed 1.7.8 feeds and packages.
