# Third-party notices

skia-pack redistributes prebuilt static libraries compiled from the following
projects. License texts live at the referenced paths inside the pinned source
checkouts under `third_party/` (fetched by `scripts/fetch_sources.sh` per
`pins.json`; Skia's bundled dependencies appear under
`third_party/skia/third_party/externals/` after `tools/git-sync-deps`). The two
headline licenses are reproduced verbatim below.

| Component | License | License text |
|---|---|---|
| Skia (incl. skcms, skshaper, skparagraph, skunicode) | BSD 3-Clause | `third_party/skia/LICENSE` |
| HarfBuzz | MIT ("Old MIT") | `third_party/harfbuzz/COPYING` |
| ICU | Unicode/ICU License | `third_party/skia/third_party/externals/icu/LICENSE` |
| libpng | PNG Reference Library License v2 | `third_party/skia/third_party/externals/libpng/LICENSE` |
| zlib | zlib License | `third_party/skia/third_party/externals/zlib/LICENSE` |
| libwebp | BSD 3-Clause | `third_party/skia/third_party/externals/libwebp/COPYING` |
| libjpeg-turbo | IJG + BSD 3-Clause + zlib | `third_party/skia/third_party/externals/libjpeg-turbo/LICENSE.md` |
| Expat | MIT | `third_party/skia/third_party/externals/expat/COPYING` |
| Wuffs | Apache-2.0 | `third_party/skia/third_party/externals/wuffs/LICENSE` |
| Adobe DNG SDK | Adobe DNG SDK License (BSD-style) | `third_party/skia/third_party/externals/dng_sdk/LICENSE` |
| PIEX (Preview Image Extractor) | Apache-2.0 | `third_party/skia/third_party/externals/piex/LICENSE` |

The exact upstream commits of every bundled dependency are recorded per release
in `pack.json` (`deps_externals`).

---

## Skia — BSD 3-Clause (`third_party/skia/LICENSE`)

```
Copyright (c) 2011 Google Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of the copyright holder nor the names of its
    contributors may be used to endorse or promote products derived
    from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## HarfBuzz — MIT ("Old MIT") (`third_party/harfbuzz/COPYING`)

```
HarfBuzz is licensed under the so-called "Old MIT" license.  Details follow.
For parts of HarfBuzz that are licensed under different licenses see individual
files names COPYING in subdirectories where applicable.

Copyright © 2010-2022  Google, Inc.
Copyright © 2015-2020  Ebrahim Byagowi
Copyright © 2019,2020  Facebook, Inc.
Copyright © 2012,2015  Mozilla Foundation
Copyright © 2011  Codethink Limited
Copyright © 2008,2010  Nokia Corporation and/or its subsidiary(-ies)
Copyright © 2009  Keith Stribley
Copyright © 2011  Martin Hosken and SIL International
Copyright © 2007  Chris Wilson
Copyright © 2005,2006,2020,2021,2022,2023  Behdad Esfahbod
Copyright © 2004,2007,2008,2009,2010,2013,2021,2022,2023  Red Hat, Inc.
Copyright © 1998-2005  David Turner and Werner Lemberg
Copyright © 2016  Igalia S.L.
Copyright © 2022  Matthias Clasen
Copyright © 2018,2021  Khaled Hosny
Copyright © 2018,2019,2020  Adobe, Inc
Copyright © 2013-2015  Alexei Podtelezhnikov

For full copyright notices consult the individual files in the package.


Permission is hereby granted, without written agreement and without
license or royalty fees, to use, copy, modify, and distribute this
software and its documentation for any purpose, provided that the
above copyright notice and the following two paragraphs appear in
all copies of this software.

IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE TO ANY PARTY FOR
DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES
ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN
IF THE COPYRIGHT HOLDER HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH
DAMAGE.

THE COPYRIGHT HOLDER SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING,
BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS
ON AN "AS IS" BASIS, AND THE COPYRIGHT HOLDER HAS NO OBLIGATION TO
PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
```
