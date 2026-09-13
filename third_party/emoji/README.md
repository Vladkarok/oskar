# Vendored emoji data

The panel's emoji catalogue is generated from the files in this directory.
Nothing here is read at runtime. Regenerate the catalogue with
`tools/emoji/generate.py`; it fails loudly if any checksum changes.

| file | what it provides | source | sha256 |
|---|---|---|---|
| `emoji-test.txt` | the set, order, groups, variant structure, and the primary names | https://www.unicode.org/Public/emoji/16.0/emoji-test.txt (Emoji 16.0, 2024-08-14) | `24f0c534e86cf142e2496953e8f0e46a3e702392911eddcd29c6cced85139697` |
| `cldr46-annotations-en.xml` | search keywords, base emoji | CLDR 46.0 `common/annotations/en.xml`, from https://www.unicode.org/Public/cldr/46/cldr-common-46.0.zip | `b33e2e88ed2fb8c438c1efa9747b9d845e8d7d74ef0c32342a805c0f46fdd7ec` |
| `cldr46-annotations-derived-en.xml` | fallback names for sequences the comments do not name | CLDR 46.0 `common/annotationsDerived/en.xml`, same zip | `461d1578079c5ebc947e506df6b5a55c93f006160e8dff3f05dcf917ce081604` |
| `cldr46-annotations-ru.xml` | Russian search keywords (ticket 36) | CLDR 46.0 `common/annotations/ru.xml`, same zip | `72a09fb4292687f3538420ebe723da1590f0ef0910e5ced5e0375339ae6c6dcd` |
| `cldr46-annotations-uk.xml` | Ukrainian search keywords (ticket 36) | CLDR 46.0 `common/annotations/uk.xml`, same zip | `77fbefc84fc99ba28f40103eb7bf755491881b039301c6967ef633c1f1b6990a` |
| `cldr46-annotations-derived-ru.xml` | Russian derived annotations, vendored for family completeness; not read by the generator | CLDR 46.0 `common/annotationsDerived/ru.xml`, same zip | `7532ab16dca25f11d92ed9aed4467d3d1a5f07fb043c09eb6c5a1ea824244226` |
| `cldr46-annotations-derived-uk.xml` | Ukrainian derived annotations, vendored for family completeness; not read by the generator | CLDR 46.0 `common/annotationsDerived/uk.xml`, same zip | `25aa443e3ed2f55da4ef49414ef19623203480a154f1fb2c3685d8b19c19afc5` |
| `LICENSE` | Unicode License V3, covers all data files | https://www.unicode.org/license.txt | `e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96` |

The data files are © Unicode, Inc., distributed under the Unicode
License V3 (see `LICENSE`). The versions are pinned together: Emoji 16.0 is
the release CLDR 46 carries names for. The ru and uk keyword files keyword
exactly the same 1948 sequences as the en one (CLDR keeps locale parity
there), which is what lets the generator mirror its English keyword policy —
annotations only, derived keywords unused — for every language. Upgrading is
deliberate — replace the files, update this table, regenerate, re-run
`tests/emoji-catalog.qml`.

## Known defects in the upstream data, recorded 2026-09-09

- CLDR 46's derived annotations name the "facing right" toned families
  (E14/E15.1, e.g. 🚶🏻‍➡) without their skin-tone suffix — six visually
  distinct sequences all read "person walking facing right". The
  `emoji-test.txt` comment names are correct, which is why the generator
  takes names from the comments first and falls back to the XMLs.
- The variant links reach 655 of the 1875 toned sequences. 1220 toned
  sequences hang off no base: 925 carry their tone inside the sequence
  (🧔🏻‍♂️, 👨🏾‍🦰, the toned gendered activities — the generator's rule
  strips only *trailing* tones), and 295 are two-tone couples, kisses,
  holding hands and handshakes whose tone-less shape Unicode does not
  define. Stripping all tones anywhere in a sequence would link 1060 of the
  1220; the remaining 205 stay standalone under any tone-stripping rule. A
  skin-tone UI keyed on base/variant links silently skips whatever is left
  unlinked — decide the grouping with the page, not inside the generator.
