# Import fixtures

Genuine TempleOS programs that the app does **not** bundle, used by the import tests
(`ImportTests.swift`, `ImportTest.kt`; see `docs/file-import.md`). They are imported through the same
code path as the Start menu's Import... and run on the HolyC interpreter.

## Origin and license

All programs are from **TempleOS supplemental disc 1**, `TOS_Supplemental1.ISO.C` (a RedSea image,
8,445,952 bytes), published at templeos.org/Downloads with MD5 `e8bd06b9f3993003af20b6d16bc5b688`
(matches the published `md5sums.txt`; SHA-256
`fac6ce2eec2b928384ac9d1fec4d50904980f2af0e42775647afa01db1584923`). They were written by Terry A. Davis,
who declared TempleOS public domain (`docs/licensing-and-provenance.md`). Only files without third-party
data are used: `Kernel/FontCyrillic.HC` (credited in `Doc/Credits.DD` as taken from another source) and
the Pilgrims map were left out on purpose.

Files were read from the image with the repository's RedSea reader
(`tools/asset-extraction/extract_templeos_iso.py`), keeping the raw bytes. Expansions were checked with
TempleOS's own Linux utility `TOSZ.CPP` (TempleOS V5.03 ISO, `Downloads/Linux`), built locally, and with
the repository's Python expander: both give identical output for all 282 compressed files on the three
supplemental discs and all 645 on the V5.03 ISO.

## Files

| File | From the disc | Bytes | SHA-256 | Expanded | Use |
|---|---|---|---|---|---|
| `o.HC.Z` | `Sup1Hymns/o.HC.Z` (7-bit LZW, type 2) | 321 | `db9e8546bf4ce6cd6d49a708957cfe0d6056cc7398ea63815cc0c90e3811c533` | 437 B, `e2725f17ac75e7b06e611cf0577331145568872a3d142f6a4e2f574cd6dd39ea` | runs: plays a hymn until a key is pressed |
| `B17.HC.Z` | `Sup1Games/B17.HC.Z` (8-bit LZW, type 3; DolDoc sprites) | 1,657 | `9af29156bc7acba4c9fdad74afa78ce79e2355c2334e2b1757cd325fa2093e3a` | 2,775 B, `7b50f52794de6026f2ab9406bfaaf052d62402bbbc31aaeb206e7145879a65b6` | runs: graphics game |
| `NewOS.HC.Z` | `Sup1Videos/NewOS.HC.Z` (type 2) | 970 | `95f526cf755bf7354c20a6b336ec2d096b049f2005a58a2e51794a806d73651c` | 1,437 B, `49c4b33abba7851d929bdf99b25d5faed38bc4d7fd73509559a61f3c9103d9dc` | imports, then fails to compile: inline x86 assembly is not supported |
| `DiningStars.HC` | expansion of `Sup1Games/DiningStars.HC.Z` (13,698 B, type 3) | 30,942 | `559504014bb2fb4b6a0554f376bedb1640c254981eb4a1dfa07d180f8b70a8a7` | - | runs: prints instructions, graphics game |
| `Sup1Snd.zip` | folder `Sup1Snd/` (the five `.HC.Z` files below) | 9,003 | `d7074667cba9e3db5e1a9f1877fc6789970b8d322fb5f177cfddca8eb899e0af` | - | ZIP with `.HC.Z` inside; `MakeSnd.HC` includes its four siblings |
| `SndSource.zip` | the same five files, expanded | 6,415 | `9d9db98702f97c15371fcac329a2af05be0465ea909bea6c8409b4460a637f68` | - | ZIP of plain `.HC`, Deflate with data descriptors |

| `Span.zip` | see below | 10,132 | `e78a239235477392d207396d22b7e317c498a7e0e7b505795037ae2b95836298` | - | ZIP of a TempleOS app in a folder: `Run.HC` includes `Load.HC`, which includes `Span.HH` and four `.HC` files |

`Span.zip` is the one fixture that the app also bundles (as `C:/Apps/Span`): no program on the supplemental
discs that consists of several files compiles completely on the interpreter (they need HD Audio, block
devices or graphics internals it does not have), so the multi-file program that must run comes from the
official **TempleOS V5.03 ISO** (`TempleOS.ISO`, SHA-256
`5d0fc944e5d89c155c0fc17c148646715bc1db6fa5750c0b913772cfec19ba26`, public domain): the eight files of
`Apps/Span/` exactly as stored on the ISO (TempleOS-compressed `.HC.Z` and `.HH.Z`), in a folder `Span/`,
zipped with Python's `zipfile` (Deflate). The tests run the imported copy in `C:/Home/Imports/Span`, whose
includes resolve beside it, never the bundled one.

`DiningStars.HC` is byte-identical to the plain `DiningStars.HC` that is distributed independently in
ParkerrDev/TempleOS-Web (`games/upstream/TerrySupplement`, commit `937a2db`), as are the expansions of
`B17`, `Coach`, `Flappy`, `MissileDefense` and `Rocks`.

Expanded `Sup1Snd` files (in both ZIPs):

| File | Bytes | SHA-256 |
|---|---|---|
| `MakeSnd.HC` | 353 | `18950622af5eedf236666ddf4ad8d76f30ce49d8b5068dcacbdf1b26d40686de` |
| `SndMath.HC` | 5,243 | `f0d7ba7625624b960e2d179ceee6e240a8b6455ac65aabd273c84b59f1fd53a3` |
| `SndMusic.HC` | 4,477 | `b44d52a3e85e615a6b44a5d26adc4cd9325867e1ae8a164a4ad68942e6185166` |
| `SndEffects.HC` | 1,626 | `21d771ef71014645afa97df850fc7b3417d0e982a6ceb96055eb7d802f27f09f` |
| `SndFile.HC` | 3,173 | `d3efc36170b9e2a190eff94395e7e49d58fc8f6b436def2f14cb81b112d9940b` |

The ZIP containers were made for these tests: `Sup1Snd.zip` with Info-ZIP 3.0 (`zip -X -r`, which stored
the already-compressed entries, with a folder entry and Unix attributes), `SndSource.zip` with macOS
`ditto -c -k --keepParent` (the format of Finder's Compress). Adversarial archives are built by the tests
themselves.
