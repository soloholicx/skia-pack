#!/usr/bin/env bash
# Materialize the pinned build inputs (pins.json) under third_party/ as plain
# git clones. Called at the top of scripts/build.sh; safe to run standalone.
#
# This repo deliberately contains NO submodules: SwiftPM recursively
# initializes submodules of git dependencies, which would make every consumer
# clone the full Skia + HarfBuzz history (~1.1 GB) for a ~23 MB binary
# product. Build inputs are pinned here instead and only exist on builder
# machines.
#
# Per pin:
#   third_party/<name> already at the pinned SHA  -> no-op
#   present at a different SHA                    -> fetch pin from origin,
#                                                    detached checkout
#   missing                                       -> clone the pinned URL,
#                                                    detached checkout
#
# SKIA_PACK_REFERENCE_SKIA / SKIA_PACK_REFERENCE_HARFBUZZ may point at a local
# repo to speed up a fresh clone (git clone --reference-if-able --dissociate:
# objects are copied locally, so the result stays self-contained).
#
# After the skia checkout, Skia's DEPS externals (vendored ICU, libjpeg-turbo,
# ...) are synced with tools/git-sync-deps (idempotent; network on first run).
# Skipped when already present, unless the checkout changed or
# SKIA_PACK_SYNC_DEPS=1.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="${PACK_ROOT}/pins.json"

pin_field() { # pin_field <name> <field>
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])" \
        "${PINS}" "$1" "$2"
}

skia_changed=0

for name in skia harfbuzz; do
    url="$(pin_field "${name}" url)"
    commit="$(pin_field "${name}" commit)"
    dir="${PACK_ROOT}/third_party/${name}"

    if [[ ! -d "${dir}/.git" ]]; then
        ref_var="SKIA_PACK_REFERENCE_$(printf '%s' "${name}" | tr '[:lower:]' '[:upper:]')"
        ref="${!ref_var:-}"
        if [[ -n "${ref}" ]]; then
            echo "[fetch] ${name}: cloning ${url} (reference: ${ref})"
            git clone --reference-if-able "${ref}" --dissociate "${url}" "${dir}"
        else
            echo "[fetch] ${name}: cloning ${url}"
            git clone "${url}" "${dir}"
        fi
    elif [[ "$(git -C "${dir}" rev-parse HEAD)" == "${commit}" ]]; then
        echo "[fetch] ${name}: at pin ${commit} — no-op"
        continue
    fi

    # Present but at the wrong SHA (or just cloned): make sure the pinned
    # commit exists locally, then check it out detached.
    if ! git -C "${dir}" rev-parse --quiet --verify "${commit}^{commit}" >/dev/null; then
        git -C "${dir}" fetch origin "${commit}"
    fi
    git -C "${dir}" checkout --detach "${commit}"
    if [[ "${name}" == "skia" ]]; then
        skia_changed=1
    fi
    echo "[fetch] ${name}: checked out ${commit}"
done

# Skia DEPS externals. Needs network; skipped when present so offline re-runs
# keep working — forced when the skia checkout moved (DEPS may differ).
SKIA_ROOT="${PACK_ROOT}/third_party/skia"
if [[ "${skia_changed}" == "1" || ! -d "${SKIA_ROOT}/third_party/externals/icu" || "${SKIA_PACK_SYNC_DEPS:-0}" == "1" ]]; then
    (cd "${SKIA_ROOT}" && python3 tools/git-sync-deps)
else
    echo "[fetch] skia externals present — skipping git-sync-deps (SKIA_PACK_SYNC_DEPS=1 to force)"
fi

echo "[fetch] sources ready: skia @ $(git -C "${SKIA_ROOT}" rev-parse HEAD), harfbuzz @ $(git -C "${PACK_ROOT}/third_party/harfbuzz" rev-parse HEAD)"
