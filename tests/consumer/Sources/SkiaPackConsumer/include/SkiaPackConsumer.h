#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Returns 0 on success. Shapes and rasterizes one paragraph (HarfBuzz 14.2 +
// SkParagraph + ICU + CoreText) and PNG-encodes it — the same surface
// tests/smoke/smoke.cpp exercises, reached through the SwiftPM product.
int skia_pack_consumer_check(void);
#ifdef __cplusplus
}
#endif
