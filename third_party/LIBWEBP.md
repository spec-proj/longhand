# libwebp

Google's WebP encoder, version 1.6.0 (https://github.com/webmproject/libwebp, tag `v1.6.0`),
copied unchanged into `third_party/libwebp` (the `src/dec`, `src/dsp`, `src/enc`, `src/utils`,
`src/webp` and `sharpyuv` folders, plus `COPYING` and `PATENTS`). BSD 3-clause licence, with
Google's patent grant; see `libwebp/COPYING` and `libwebp/PATENTS`.

Longhand uses it for one thing: saving a cover and the picture it was cut from as WebP
(`MarginStore.webp`), because macOS can read WebP but cannot write it. The MIPS, MSA and AVX2
files are left out of the build (`project.yml`); everything else is compiled into the app.

To update: copy the same folders from a newer tag, build, run the self-test.
