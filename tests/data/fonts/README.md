# Shaping and outline test fonts

Subsets of Noto fonts for `tests/ttf_shape_test.w`,
`tests/ttf_cff_test.w` and `graphics/ui/shape_test.w`. Each keeps only
the glyphs the test text uses (plus the presentation forms some fallback
tests need) and the OpenType layout features the portable shaper
applies, so the files stay small.

| File | Source (notofonts.github.io, hinted TTF) |
| --- | --- |
| `NotoSans-subset.ttf` | `NotoSans-Regular.ttf` 2.015 |
| `NotoSansArabic-subset.ttf` | `NotoSansArabic-Regular.ttf` 2.013 |
| `NotoSansDevanagari-subset.ttf` | `NotoSansDevanagari-Regular.ttf` 2.007 |
| `NotoSansHebrew-subset.ttf` | `NotoSansHebrew-Regular.ttf` 3.001 |
| `NotoSansThai-subset.ttf` | `NotoSansThai-Regular.ttf` 2.002 |
| `NotoSans-cff-subset.otf` | `NotoSans-Regular.otf` (unhinted OTF), CFF with subroutines |
| `NotoSansJP-subset.otf` | noto-cjk `Sans/SubsetOTF/JP/NotoSansJP-Regular.otf`, CID-keyed CFF |

The fonts are Copyright 2022-2024 The Noto Project Authors and licensed
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
The text is the matching lines of `tools/shape_golden_hb.py`; the two
OTF subsets keep hinting and subroutines (no `--no-hinting`) so the CFF
interpreter meets hintmask and callsubr/callgsubr. After replacing a
font, regenerate `tests/data/shape_golden.txt` with that script and
`tests/data/cff_paths.txt` with `tools/cff_paths_ref.py`.
