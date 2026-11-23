// The C++ side of the Rust consumer test: a translation unit that uses Skia, SkShaper,
// SkUnicode (ICU) and HarfBuzz directly, linked into the same executable as
// Slint. It draws shaped text into a CPU surface and writes a PNG.
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkMilestone.h"
#include "include/core/SkPaint.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTextBlob.h"
#include "include/core/SkTypeface.h"
#include "include/encode/SkPngEncoder.h"
#ifdef __APPLE__
#include "include/ports/SkFontMgr_mac_ct.h"
#else
#include "include/ports/SkFontMgr_fontconfig.h"
#include "include/ports/SkFontScanner_FreeType.h"
#endif
#include "modules/skshaper/include/SkShaper.h"
#include "modules/skshaper/include/SkShaper_harfbuzz.h"
#include "modules/skshaper/include/SkShaper_skunicode.h"
#include "modules/skunicode/include/SkUnicode_icu.h"

#include <hb.h>

#include <cstdio>
#include <cstring>

extern "C" int corestub_render(const char* png_path, char* info, size_t info_size) {
#ifdef __APPLE__
    sk_sp<SkFontMgr> font_mgr = SkFontMgr_New_CoreText(nullptr);
    const char* family_name = "Menlo";
#else
    sk_sp<SkFontMgr> font_mgr = SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
    const char* family_name = "monospace";
#endif
    if (!font_mgr) return 1;
    sk_sp<SkTypeface> typeface = font_mgr->matchFamilyStyle(family_name, SkFontStyle());
    if (!typeface) return 2;
    SkFont font(typeface, 28);

    sk_sp<SkUnicode> unicode = SkUnicodes::ICU::Make();
    if (!unicode) return 3;
    std::unique_ptr<SkShaper> shaper = SkShapers::HB::ShaperDrivenWrapper(unicode, font_mgr);
    if (!shaper) return 4;

    const char text[] = "Core stub: fi -> != \xe4\xbd\xa0\xe5\xa5\xbd";
    const size_t bytes = sizeof(text) - 1;
    auto font_runs = SkShaper::MakeFontMgrRunIterator(text, bytes, font, font_mgr);
    auto bidi_runs = SkShapers::unicode::BidiRunIterator(unicode, text, bytes, 0);
    auto script_runs = SkShapers::HB::ScriptRunIterator(text, bytes);
    auto language_runs = SkShaper::MakeStdLanguageRunIterator(text, bytes);
    if (!font_runs || !bidi_runs || !script_runs || !language_runs) return 5;
    SkTextBlobBuilderRunHandler handler(text, {16, 48});
    shaper->shape(text, bytes, *font_runs, *bidi_runs, *script_runs, *language_runs, nullptr, 0,
                  1000, &handler);
    sk_sp<SkTextBlob> blob = handler.makeBlob();
    if (!blob) return 6;

    sk_sp<SkSurface> surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(640, 96));
    if (!surface) return 7;
    surface->getCanvas()->clear(SK_ColorBLACK);
    SkPaint paint;
    paint.setColor(SK_ColorGREEN);
    paint.setAntiAlias(true);
    surface->getCanvas()->drawTextBlob(blob, 0, 0, paint);

    SkPixmap pixmap;
    if (!surface->peekPixels(&pixmap)) return 8;
    SkFILEWStream out(png_path);
    if (!out.isValid() || !SkPngEncoder::Encode(&out, pixmap, {})) return 9;

    size_t lit = 0;
    for (int y = 0; y < pixmap.height(); ++y)
        for (int x = 0; x < pixmap.width(); ++x)
            if (SkColorGetG(pixmap.getColor(x, y)) > 128) ++lit;
    SkString family;
    typeface->getFamilyName(&family);
    std::snprintf(info, info_size, "skia m%d, harfbuzz %s, font \"%s\", lit pixels %zu",
                  SK_MILESTONE, hb_version_string(), family.c_str(), lit);
    return lit > 200 ? 0 : 10;
}
