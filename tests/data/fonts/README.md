# Shaping, outline and color test fonts

Subsets of Noto fonts for `tests/ttf_shape_test.w`,
`tests/ttf_cff_test.w` and `graphics/ui/shape_test.w`, and color fonts
for `graphics/ui/font_color_test.w` and `graphics/ui/color_glyph_test.w`
(see the end of this file). Each subset keeps only
the glyphs the test text uses (plus the presentation forms some fallback
tests need) and the OpenType layout features the portable shaper
applies, so the files stay small.

| File | Source (notofonts.github.io, hinted TTF) |
| --- | --- |
| `NotoSans-subset.ttf` | `NotoSans-Regular.ttf` 2.015 |
| `NotoSansArabic-subset.ttf` | `NotoSansArabic-Regular.ttf` 2.013 |
| `NotoSansDevanagari-subset.ttf` | `NotoSansDevanagari-Regular.ttf` 2.007 |
| `NotoSansHebrew-subset.ttf` | `NotoSansHebrew-Regular.ttf` 3.001 |
| `NotoSansBengali-subset.ttf` | `NotoSansBengali-Regular.ttf` 3.011 |
| `NotoSansGurmukhi-subset.ttf` | `NotoSansGurmukhi-Regular.ttf` 2.004 |
| `NotoSansGujarati-subset.ttf` | `NotoSansGujarati-Regular.ttf` 2.106 |
| `NotoSansOriya-subset.ttf` | `NotoSansOriya-Regular.ttf` 2.007 |
| `NotoSansTamil-subset.ttf` | `NotoSansTamil-Regular.ttf` 2.004 |
| `NotoSansTelugu-subset.ttf` | `NotoSansTelugu-Regular.ttf` 2.005 |
| `NotoSansKannada-subset.ttf` | `NotoSansKannada-Regular.ttf` 2.006 |
| `NotoSansMalayalam-subset.ttf` | `NotoSansMalayalam-Regular.ttf` 2.104 |
| `NotoSansThai-subset.ttf` | `NotoSansThai-Regular.ttf` 2.002 |
| `NotoSansSinhala-subset.ttf` | `NotoSansSinhala-Regular.ttf` 2.001 (Debian fonts-noto-core) |
| `NotoSerifTibetan-subset.ttf` | `NotoSerifTibetan-Regular.ttf` 2.001 (Debian fonts-noto-core) |
| `NotoSansJavanese-subset.ttf` | `NotoSansJavanese-Regular.ttf` 2.000 (Debian fonts-noto-core) |
| `NotoSansBalinese-subset.ttf` | `NotoSansBalinese-Regular.ttf` 2.002 (Debian fonts-noto-core) |
| `NotoSansTaiTham-subset.ttf` | `NotoSansTaiTham-Regular.ttf` 2.001 (Debian fonts-noto-core) |
| `NotoSansDevanagari-dev3-subset.ttf` | `NotoSansDevanagari-Regular.ttf` 2.001 (Debian fonts-noto-core), its `dev2` script renamed `dev3` and `deva` dropped |
| `NotoSansKhmer-subset.ttf` | `NotoSansKhmer-Regular.ttf` 2.001 (Ubuntu `fonts-noto-core`) |
| `NotoSansMyanmar-subset.ttf` | `NotoSansMyanmar-Regular.ttf` 2.001 (Ubuntu `fonts-noto-core`) |
| `NotoSans-cff-subset.otf` | `NotoSans-Regular.otf` (unhinted OTF), CFF with subroutines |
| `NotoSansJP-subset.otf` | noto-cjk `Sans/SubsetOTF/JP/NotoSansJP-Regular.otf`, CID-keyed CFF |
| `NotoSansSyriac-subset.ttf` | `NotoSansSyriac-Regular.ttf` 2.000 (Ubuntu `fonts-noto-core`) |
| `NotoSansCJKkr-subset.otf` | Noto Sans CJK KR 2.004, font 1 of `NotoSansCJK-Regular.ttc` (Ubuntu `fonts-noto-cjk`), CID-keyed CFF |
| `NotoSans-symbol-subset.ttf` | `NotoSans-subset.ttf` above, its U+0020..U+00FF re-encoded as a symbol (3,0) cmap at U+F020..U+F0FF |
| `NotoSansGujarati-nogdef-subset.ttf` | `NotoSansGujarati-Regular.ttf` 2.001 (Ubuntu `fonts-noto-core`), without its GDEF table |

The fonts are Copyright 2015-2024 Google LLC / The Noto Project Authors and licensed
under the SIL Open Font License 1.1 (`OFL.txt`); these Noto fonts
declare no Reserved Font Names, so the subsets keep their names. Noto
Sans CJK is Copyright 2014-2021 Adobe under the same license with the
Reserved Font Name "Source" (`OFL-NotoSansCJK.txt`), which the subset's
"Noto Sans JP" name does not use.

They were made with fontTools' `pyftsubset`, for example:

```sh
pyftsubset NotoSansArabic-Regular.ttf --text-file=arabic-lines.txt \
  --unicodes=FC5E-FC63,FE70-FEFC --no-hinting --notdef-outline \
  --name-IDs='*' --layout-features=ccmp,locl,rvrn,nukt,akhn,rphf,rkrf,pref,blwf,abvf,half,pstf,vatu,cjct,pres,abvs,blws,psts,haln,isol,fina,medi,init,rlig,rclt,calt,liga,clig,kern,mark,mkmk,curs,dist,abvm,blwm \
  --output-file=NotoSansArabic-subset.ttf
```

(The Hebrew subset also keeps U+FB1D..U+FB4F; NotoSans keeps only
ccmp, locl, rvrn, liga, clig, calt, rclt, kern, mark, mkmk and dist.)
The eight Indic subsets other than Devanagari, and the Khmer and
Myanmar subsets, keep only the glyphs
HarfBuzz passes through while shaping their golden lines with the full
font (every intermediate GSUB buffer, collected with a buffer message
function), plus U+25CC, ZWNJ and ZWJ, with no layout closure, so they
stay 8-17 KB each and still shape those lines exactly as the full
font does:

```sh
pyftsubset NotoSansTelugu-Regular.ttf --text-file=telugu-lines.txt \
  --glyphs-file=telugu-glyphs.txt --unicodes=25CC,200C,200D \
  --no-layout-closure --glyph-names --no-hinting --notdef-outline \
  --name-IDs='*' --layout-features=ccmp,locl,rvrn,nukt,akhn,rphf,rkrf,pref,blwf,abvf,half,pstf,vatu,cjct,init,pres,abvs,blws,psts,haln,rlig,rclt,calt,liga,clig,kern,mark,mkmk,curs,dist,abvm,blwm \
  --output-file=NotoSansTelugu-subset.ttf
```

The six Universal Shaping Engine subsets (issue #825) were made the same
way, keeping every layout feature the USE shaper applies (including
`isol`, `init`, `medi`, `fina`); the `dev3` copy of Noto Sans Devanagari
renames the `dev2` script record with fontTools before subsetting, so
HarfBuzz and lib/ttf_use.w shape it with the USE shaper.

The Syriac, Korean and GDEF-less Gujarati subsets (issue #825) were
made the same way with `--layout-features='*'` (the Korean one from Noto
Sans CJK KR saved out of the collection with fontTools, with
`--desubroutinize`; the Gujarati one with `--drop-tables+=GDEF`). The
symbol subset was written with fontTools: a single format-4 (3,0) cmap
subtable mapping U+F000 + c to the glyph of each character c of
U+0020..U+00FF in `NotoSans-subset.ttf`.

The Khmer and Myanmar subsets were made the same way, also keeping
`cfar` and `rphf` in `--layout-features`.

The text is the matching lines of `tools/shape_golden_hb.py`; the two
OTF subsets keep hinting and subroutines (no `--no-hinting`) so the CFF
interpreter meets hintmask and callsubr/callgsubr. After replacing a
font, regenerate `tests/data/shape_golden.txt` with that script and
`tests/data/cff_paths.txt` with `tools/cff_paths_ref.py`.

## Color fonts (issue #827)

| File | Source |
| --- | --- |
| `NotoColorEmoji-subset.ttf` | `NotoColorEmoji.ttf` 2.047 (CBDT/CBLC, as packaged in `fonts-noto-color-emoji`) |
| `ColorTestCOLRv0.ttf` | `tools/make_color_test_fonts.py`: COLR version 0 + CPAL |
| `ColorTestCOLRv1.ttf` | `tools/make_color_test_fonts.py`: a COLR version 1 paint graph |
| `ColorTestSbix.ttf` | `tools/make_color_test_fonts.py`: sbix PNG strikes |

Noto Color Emoji is Copyright 2022 Google Inc. under the SIL Open Font
License 1.1 (`OFL.txt`), with no Reserved Font Name. The subset keeps
U+1F600, U+2764, U+1F44D, U+1F3FD, U+1F468, U+1F469, U+1F467, ZWJ and
VS16 plus the two GSUB ligatures for the skin-toned thumbs up and the
ZWJ family (the glyphs HarfBuzz produces for them), with no layout
closure, so it stays about 19 KB:

```sh
pyftsubset NotoColorEmoji.ttf \
  --unicodes=1F600,2764,FE0F,1F44D,1F3FD,1F468,200D,1F469,1F467 \
  --glyphs=glyph02059,glyph02112 --no-layout-closure \
  --layout-features='*' --name-IDs='*' --notdef-outline --glyph-names \
  --output-file=NotoColorEmoji-subset.ttf
```

The three `ColorTest` fonts were made for these tests and are released
under the same license. Rebuild them with
`python3 tools/make_color_test_fonts.py tests/data/fonts`, then rewrite
the goldens with `W_UPDATE_GOLDENS=1 bin/graphics_ui_color_glyph_test`
and check the expected colors in `graphics/ui/font_color_test.w`.
