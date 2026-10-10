/* LAME 3.100 を configure なしでビルドするための設定（iOS / macOS 共通、arm64 と x86_64） */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STRING_H 1
#define HAVE_STDLIB_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1

#define HAVE_UINT8_T 1
#define HAVE_INT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_INT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_INT32_T 1
#define HAVE_UINT64_T 1
#define HAVE_INT64_T 1

typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
typedef long double ieee854_float80_t;

/* 速い近似の log を使う（configure の既定と同じ） */
#define USE_FAST_LOG 1

/* SwiftPMはデバッグビルドで DEBUG を定義する。LAMEではフレームごとのデバッグ出力が有効になってしまうので外す */
#undef DEBUG

#endif /* LAME_CONFIG_H */
