# CLame

LAME 3.100 のエンコーダー部分（`libmp3lame/` と `include/lame.h`）をそのまま置いたもの。

- 入手元：https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
- SHA-256：`ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`
- ライセンス：LGPL（`COPYING`）。アプリ内にライセンス表記を入れる
- 変更点：ソースは無変更。`configure` の代わりに `config.h` を置き、`HAVE_CONFIG_H` を定義してビルドする。
  デコーダー（mpglib）、frontend、x86向けの `i386/` は含めない。SSE向けの `vector/` は `fft.c` が読み込むヘッダーだけを置く
