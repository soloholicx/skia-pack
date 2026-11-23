#!/usr/bin/env bash
# Take the linux-x86_64 slice candidate of a build-linux workflow run and
# check it is the slice of THIS checkout. Runs on the release machine.
#
#   fetch_linux_candidate.sh <run-id>   download the run's candidate into
#                                       artifacts/linux-candidate/ and check it
#   fetch_linux_candidate.sh --check    check the candidate already there
#
# The Mac cannot build or run the Linux slice. What it can check, and does:
#   * the run is a successful run of the build-linux workflow of this
#     repository, on the commit this checkout is at (HEAD) — so the scripts
#     that built and verified the slice are the ones in this checkout, and the
#     run's own gates (scripts/verify_linux.sh, scripts/verify_rust_consumer.sh)
#     passed on these bytes
#   * the tarball's sha256 is the one its manifest records; the manifest names
#     this VERSION, the pins.json commits and this gn/linux.gn
#   * the tarball's pack.json is that manifest; every archive's sha256 is the
#     recorded one; the header tree is byte-identical to the one the Apple
#     slices ship (staged here from the same pins)
#   * the headers-only tree the run's Rust gate used hashes the same as the one
#     staged here — the skia-headers asset is what the Linux gate proved
#
# SKIA_PACK_LINUX_CANDIDATE_SKIP_RUN_CHECK=1 skips the questions to GitHub
# about the run (tests, and candidates built outside CI for local trials). The
# candidate is then marked "unattested" and scripts/release.sh refuses it.
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PACK_ROOT}"
VERSION="$(tr -d '[:space:]' < VERSION)"
CAND="${PACK_ROOT}/artifacts/linux-candidate"
TARBALL_NAME="skia-pack-${VERSION}-linux-x86_64.tar.gz"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ $# -eq 1 ]] || { echo "usage: fetch_linux_candidate.sh <run-id> | --check" >&2; exit 2; }

if [[ "$1" != "--check" ]]; then
    [[ "$1" =~ ^[0-9]+$ ]] || fail "run id must be a number"
    rm -rf "${CAND}"
    mkdir -p "${CAND}"
    gh run download "$1" --name linux-x86_64-candidate --dir "${CAND}" \
        || fail "could not download artifact linux-x86_64-candidate of run $1"
    echo "$1" > "${CAND}/RUN_ID"
fi
for name in "${TARBALL_NAME}" linux-x86_64.json linux-x86_64.provenance RUN_ID; do
    [[ -f "${CAND}/${name}" ]] || fail "candidate file missing: ${CAND}/${name}"
done
run_id="$(tr -d '[:space:]' < "${CAND}/RUN_ID")"
head_commit="$(git rev-parse HEAD)"
prov_commit="$(sed -n 's/^commit=//p' "${CAND}/linux-x86_64.provenance")"
prov_run="$(sed -n 's/^run_id=//p' "${CAND}/linux-x86_64.provenance")"
[[ "${prov_commit}" == "${head_commit}" ]] \
    || fail "the candidate was built from ${prov_commit:0:12}, this checkout is at ${head_commit:0:12} — run build-linux on this commit"
[[ "${prov_run}" == "${run_id}" ]] || fail "the candidate says it is from run ${prov_run}, not ${run_id}"

rm -f "${CAND}/ATTESTED"
if [[ "${SKIA_PACK_LINUX_CANDIDATE_SKIP_RUN_CHECK:-0}" == "1" ]]; then
    echo "candidate: run check SKIPPED (SKIA_PACK_LINUX_CANDIDATE_SKIP_RUN_CHECK=1) — unattested, not releasable"
else
    answer="$(gh run view "${run_id}" --json conclusion,headSha,workflowName,status \
                 --jq '[.status, .conclusion, .headSha, .workflowName] | join("|")')" \
        || fail "could not read run ${run_id} — not assuming anything about it"
    [[ "${answer}" == "completed|success|${head_commit}|build-linux" ]] \
        || fail "run ${run_id} is '${answer}', want 'completed|success|${head_commit}|build-linux'"
    echo "${run_id} ${head_commit}" > "${CAND}/ATTESTED"
    echo "candidate: run ${run_id} is a successful build-linux run on ${head_commit:0:12}"
fi

# The trees this checkout's pins stage — what the slice must agree with.
[[ -d third_party/skia/.git && -d third_party/harfbuzz/.git ]] || fail "run scripts/fetch_sources.sh first"
SKIA_ROOT="${PACK_ROOT}/third_party/skia"; HB_ROOT="${PACK_ROOT}/third_party/harfbuzz"
# shellcheck source=scripts/headers.sh
source "${PACK_ROOT}/scripts/headers.sh"
work="${PACK_ROOT}/build/linux-candidate-check"
rm -rf "${work}"; mkdir -p "${work}"
stage_headers "${work}/headers"
stage_bind_headers "${work}/skia-headers"
tar -xzf "${CAND}/${TARBALL_NAME}" -C "${work}"

python3 - "${CAND}" "${TARBALL_NAME}" "${VERSION}" "${work}" \
    "$(headers_tree_sha256 "${work}/headers")" "$(headers_tree_sha256 "${work}/skia-headers")" \
    "$(headers_tree_sha256 "${work}/skia-pack-${VERSION}-linux-x86_64/headers")" <<'PY' || fail "the candidate is not the linux-x86_64 slice of this checkout"
import hashlib, json, pathlib, sys
cand, tarball, version, work, public_here, bind_here, public_there = sys.argv[1:8]
cand, work = pathlib.Path(cand), pathlib.Path(work)
sha = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
m = json.loads((cand / "linux-x86_64.json").read_text())
pins = json.loads(pathlib.Path("pins.json").read_text())
slice_dir = work / tarball[: -len(".tar.gz")]
inner = json.loads((slice_dir / "pack.json").read_text())
outer = dict(m); artifact = outer.pop("artifact")
errors = []
def check(ok, msg):
    if not ok: errors.append(msg)
check(artifact == {"file": tarball, "sha256": sha(cand / tarball)}, "tarball name or sha256 is not what the manifest records")
check(outer == inner, "the manifest differs from the pack.json inside the tarball")
check(m.get("version") == version and m.get("platform") == "linux-x86_64", "version or platform")
check(m["skia"]["commit"] == pins["skia"]["commit"], "Skia commit is not the pinned one")
check(m["harfbuzz"]["commit"] == pins["harfbuzz"]["commit"], "HarfBuzz commit is not the pinned one")
check(m["gn_args_sha256"] == sha("gn/linux.gn"), "gn/linux.gn differs from the one the slice was built with")
on_disk = sorted(p.name for p in (slice_dir / "lib").iterdir())
check(on_disk == m["libraries"] == sorted(m["library_sha256"]), "lib/ is not the recorded set of archives")
for name, want in m["library_sha256"].items():
    check((slice_dir / "lib" / name).is_file() and sha(slice_dir / "lib" / name) == want, f"lib/{name} is not the recorded archive")
check(public_there == public_here == m["headers_tree_sha256"], "headers/ differs from the tree this checkout stages for the Apple slices")
check(bind_here == m["skia_headers_tree_sha256"], "the headers-only tree the Linux Rust gate used differs from the one staged here")
for e in errors: print("candidate:", e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
rm -rf "${work}"
echo "candidate PASS: ${TARBALL_NAME} ($(shasum -a 256 "${CAND}/${TARBALL_NAME}" | cut -c1-12)…) is the linux-x86_64 slice of ${head_commit:0:12}"
