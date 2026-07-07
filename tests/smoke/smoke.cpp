// skia-pack smoke test — links the packaged artifact exactly as consumers do.
//
// Exercises the full text stack end-to-end:
//   1. hb_version_string()  — proves the pack's standalone HarfBuzz 14.2 is
//      the HB that actually linked (and that <hb.h> resolves from headers/).
//   2. skparagraph layout of a mixed-script line (Latin ligature + arrow +
//      Arabic) — drives SkShaper's HarfBuzz path, SkUnicode/ICU, CoreText
//      font manager.
//   3. Raster draw — asserts non-background pixels were produced.
//   4. PNG encode — exercises libpng/zlib. Pass an output path as argv[1] to
//      keep the PNG for inspection.
//
// Exit code 0 = pass. Any failure prints FAIL: ... and exits non-zero.

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hb.h>

#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkStream.h"
#include "include/core/SkString.h"
#include "include/core/SkSurface.h"
#include "include/encode/SkPngEncoder.h"
#include "include/ports/SkFontMgr_mac_ct.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/ParagraphStyle.h"
#include "modules/skparagraph/include/TextStyle.h"
#include "modules/skunicode/include/SkUnicode_icu.h"

namespace tl = skia::textlayout;

static int fail(const char* msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

int main(int argc, char** argv) {
    // 1. HarfBuzz version — must be the pack's standalone 14.2.x.
    const char* hb = hb_version_string();
    std::printf("hb_version_string() = %s\n", hb);
    if (std::strncmp(hb, "14.2", 4) != 0) {
        return fail("expected HarfBuzz 14.2.x — wrong HB linked");
    }

    // 2. Shape + lay out a mixed-script paragraph.
    sk_sp<SkFontMgr> fontMgr = SkFontMgr_New_CoreText(nullptr);
    if (!fontMgr) return fail("SkFontMgr_New_CoreText returned null");

    sk_sp<SkUnicode> unicode = SkUnicodes::ICU::Make();
    if (!unicode) return fail("SkUnicodes::ICU::Make returned null");

    auto fontCollection = sk_make_sp<tl::FontCollection>();
    fontCollection->setDefaultFontManager(fontMgr);

    tl::TextStyle textStyle;
    textStyle.setColor(SK_ColorBLACK);
    textStyle.setFontSize(24.0f);
    textStyle.setFontFamilies({SkString("Helvetica")});

    tl::ParagraphStyle paraStyle;
    paraStyle.setTextStyle(textStyle);

    auto builder = tl::ParagraphBuilder::make(paraStyle, fontCollection, unicode);
    if (!builder) return fail("ParagraphBuilder::make returned null");
    builder->pushStyle(textStyle);
    // "Shaped: fi <arrow> <Arabic marhaban>" — the ligature and the RTL run
    // both require real shaping; whitespace-only shaping would not produce
    // the joined Arabic forms.
    static const char kText[] =
        "Shaped: fi \xE2\x86\x92 \xD9\x85\xD8\xB1\xD8\xAD\xD8\xA8\xD8\xA7";
    builder->addText(kText, sizeof(kText) - 1);
    auto paragraph = builder->Build();
    if (!paragraph) return fail("ParagraphBuilder::Build returned null");
    paragraph->layout(560.0f);
    std::printf("paragraph: height=%.1f longestLine=%.1f\n",
                paragraph->getHeight(), paragraph->getLongestLine());
    if (paragraph->getHeight() <= 0 || paragraph->getLongestLine() <= 0) {
        return fail("paragraph layout produced empty metrics");
    }

    // 3. Raster draw + non-background pixel assertion.
    constexpr int kW = 600;
    constexpr int kH = 80;
    sk_sp<SkSurface> surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(kW, kH));
    if (!surface) return fail("SkSurfaces::Raster returned null");
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorWHITE);
    paragraph->paint(canvas, 10.0f, 10.0f);

    SkPixmap pixmap;
    if (!surface->peekPixels(&pixmap)) return fail("peekPixels failed");
    int nonBackground = 0;
    for (int y = 0; y < kH; y++) {
        for (int x = 0; x < kW; x++) {
            if (pixmap.getColor(x, y) != SK_ColorWHITE) nonBackground++;
        }
    }
    std::printf("non-background pixels: %d\n", nonBackground);
    if (nonBackground < 100) return fail("shaped text did not draw (blank surface)");

    // 4. PNG encode.
    SkDynamicMemoryWStream png;
    if (!SkPngEncoder::Encode(&png, pixmap, {})) return fail("PNG encode failed");
    std::printf("png bytes: %zu\n", png.bytesWritten());
    if (png.bytesWritten() == 0) return fail("PNG encode produced no bytes");
    if (argc > 1) {
        sk_sp<SkData> data = png.detachAsData();
        FILE* f = std::fopen(argv[1], "wb");
        if (!f) return fail("could not open PNG output path");
        std::fwrite(data->data(), 1, data->size(), f);
        std::fclose(f);
        std::printf("wrote %s\n", argv[1]);
    }

    std::printf("SMOKE OK\n");
    return 0;
}
