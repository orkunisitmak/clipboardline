# Synthetic recording fixtures

These three clips were generated specifically for automated ClipBoardLine tests.
They contain no captured screen, user data, speech or third-party media.
The project dedicates these fixture clips to the public domain under CC0 1.0.

The two `tone` clips contain six seconds of 160 × 120 H.264 video at 10 fps, with a mono 44.1 kHz
AAC 440 Hz tone. The first two seconds are red, the middle two green and the
last two blue. Codec/container timing may include a small audio padding interval.
Trimming the middle interval must produce approximately two seconds of green
video with its audio track intact, while preserving the original file.

`synthetic-rgb-silent.mp4` copies only the MP4 tone fixture's original video
track through an AVFoundation passthrough composition. It contains one video
track and **zero audio tracks**, rather than an audio track filled with silence.
Its probe and 2–4 second trim must both report exactly zero embedded audio
tracks, preserve the red/green poster checks and leave the original unchanged.

| File | SHA-256 |
| --- | --- |
| `synthetic-rgb-tone.mp4` | `1ebf023f2cab2db010b89c45a6cdbcd851f343cf99c34380315328863af153a3` |
| `synthetic-rgb-tone.mov` | `8b0413046a8dffcf792f69e6efe1b72d6b3be75369f653e25c3284a4a433a760` |
| `synthetic-rgb-silent.mp4` | `86de1527591597cc389f87769d11a0a5395db049ac3591c3db19ec3897b5250f` |

To regenerate functionally equivalent fixtures on macOS:

```sh
xcrun swift windows/tests/generate-recording-fixtures.swift /tmp/synthetic-recordings
```

To derive only the silent fixture from an existing generated
`synthetic-rgb-tone.mp4` without touching either tone fixture:

```sh
xcrun swift windows/tests/generate-recording-fixtures.swift windows/tests/fixtures/recordings --silent-only
```

Container metadata and encoder versions can change bytes across regenerations.
The committed hashes authenticate these exact test inputs, not every future
output from a different encoder/toolchain.
