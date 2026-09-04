# Fonts

`font_src.bit` (16 px kanji/kana, JIS X 0208, gothic) and `latin1_src.bit`
(8x16 ISO 8859-1) are the bitmap sources of the **Shinonome font** (東雲フォント,
/efont/ — The Electronic Font Open Laboratory, 2001; original design by
Yasuyuki Furukawa, 2000), taken unchanged from
https://github.com/code4fukui/shinonome-font (`16/kanjic/font_src.bit`,
`16/latin1/font_src.bit`). The files are BDF with the bitmap rows written as
`.`/`@` characters; `tools/glyphs.py` reads them directly.

Licence (LICENSE in that repository): all font data is released as
**Public Domain** ("Free modification, conversion, embedding and
redistribution; no warranty"). `AUTHORS` lists the contributors.
