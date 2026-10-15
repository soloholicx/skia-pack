// Resource wiring only (see Package.swift): on iOS this target depends on
// SkiaPackPrivacy so that the privacy manifest's bundle reaches the app; on
// macOS it carries nothing. No headers, no API. SwiftPM needs one source file.
static const int skia_pack_support_wiring __attribute__((unused)) = 1;
