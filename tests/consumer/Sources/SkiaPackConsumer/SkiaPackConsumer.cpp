#include "SkiaPackConsumer.h"

#include <cstdio>
#include <cstring>

#include <hb.h>

#include "include/core/SkCanvas.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/encode/SkPngEncoder.h"
#include "include/ports/SkFontMgr_mac_ct.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skunicode/include/SkUnicode_icu.h"

namespace tl = skia::textlayout;

int skia_pack_consumer_check(void) {
    if (std::strncmp(hb_version_string(), "14.2", 4) != 0) return 1;
    sk_sp<SkFontMgr> fontMgr = SkFontMgr_New_CoreText(nullptr);
    sk_sp<SkUnicode> unicode = SkUnicodes::ICU::Make();
    if (!fontMgr || !unicode) return 2;
    auto fonts = sk_make_sp<tl::FontCollection>();
    fonts->setDefaultFontManager(fontMgr);
    tl::TextStyle style;
    style.setColor(SK_ColorBLACK);
    style.setFontSize(24.0f);
    style.setFontFamilies({SkString("Helvetica")});
    tl::ParagraphStyle para;
    para.setTextStyle(style);
    auto builder = tl::ParagraphBuilder::make(para, fonts, unicode);
    if (!builder) return 3;
    builder->pushStyle(style);
    static const char kText[] = "Shaped: fi \xE2\x86\x92 \xD9\x85\xD8\xB1\xD8\xAD\xD8\xA8\xD8\xA7";
    builder->addText(kText, sizeof(kText) - 1);
    auto paragraph = builder->Build();
    paragraph->layout(560.0f);
    auto surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(600, 80));
    if (!surface) return 4;
    surface->getCanvas()->clear(SK_ColorWHITE);
    paragraph->paint(surface->getCanvas(), 10.0f, 10.0f);
    SkPixmap pixmap;
    if (!surface->peekPixels(&pixmap)) return 5;
    int ink = 0;
    for (int y = 0; y < 80; y++)
        for (int x = 0; x < 600; x++)
            if (pixmap.getColor(x, y) != SK_ColorWHITE) ink++;
    if (ink < 100) return 6;
    SkDynamicMemoryWStream png;
    if (!SkPngEncoder::Encode(&png, pixmap, {}) || png.bytesWritten() == 0) return 7;
    std::printf("consumer OK: hb %s, %d ink pixels, %zu png bytes\n", hb_version_string(), ink, png.bytesWritten());
    return 0;
}
