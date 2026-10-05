#!/usr/bin/env bash
# Stand-in for `gh`, used ONLY by tests/release/test_release.sh. Models one
# release: $FAKE_GH/state (none|draft|published), $FAKE_GH/assets/, and the
# bare origin repo at $FAKE_ORIGIN (publishing creates the tag there, as GitHub
# does for a draft created with --target). Every call is logged.
set -uo pipefail
S="${FAKE_GH:?}"; mkdir -p "$S/assets"; [[ -f "$S/state" ]] || echo none > "$S/state"
echo "gh $*" >> "$S/calls.log"
case " $* " in *" --clobber "*) echo "VIOLATION --clobber: $*" >> "$S/violations.log" ;; esac
state="$(cat "$S/state")"
publish_now() { git --git-dir="${FAKE_ORIGIN:?}" tag "$(cat "$S/version")" "$(cat "$S/target")"; echo published > "$S/state"; }
[[ "${1:-}" == "api" ]] && exit 1
[[ "${1:-}" == "release" ]] || { echo "fake gh: unsupported: $*" >&2; exit 2; }
cmd="$2"; shift 3 || true
case "$cmd" in
  view)
    [[ -f "$S/fail_view" ]] && { echo "HTTP 503: Service Unavailable (https://api.github.com/graphql)" >&2; exit 1; }
    if [[ -f "$S/publish_after_views" ]]; then      # someone else publishes the draft while we work
        n=$(( $(cat "$S/publish_after_views") - 1 ))
        if (( n <= 0 )); then rm "$S/publish_after_views"; publish_now; state=published; else echo "$n" > "$S/publish_after_views"; fi
    fi
    [[ "$state" == none ]] && { echo "release not found" >&2; exit 1; }
    [[ "$state" == draft ]] && d=true || d=false
    printf '%s|%s|%s|%s\n' "$(cat "$S/id")" "$d" "$(cat "$S/target")" "$(cd "$S/assets" && ls | tr '\n' ',' | sed 's/,$//')" ;;
  create)
    [[ "$state" == none ]] || { echo "release exists" >&2; exit 1; }
    while [[ $# -gt 0 ]]; do [[ "$1" == "--target" ]] && echo "$2" > "$S/target"; shift; done
    echo draft > "$S/state"; echo $(( $(cat "$S/id" 2>/dev/null || echo 100) + 1 )) > "$S/id" ;;
  download)
    [[ "$state" == none ]] && exit 1
    name=""; dir=""
    while [[ $# -gt 0 ]]; do case "$1" in --pattern) name="$2"; shift ;; --dir) dir="$2"; shift ;; esac; shift; done
    [[ -f "$S/assets/$name" ]] || exit 1
    cp "$S/assets/$name" "$dir/$name"
    if [[ -f "$S/publish_on_download" ]]; then rm "$S/publish_on_download"; publish_now; fi ;;
  upload)
    file="$1"; name="$(basename "$file")"
    [[ "$state" == published ]] && echo "VIOLATION upload to published: $name" >> "$S/violations.log"
    [[ -f "$S/assets/$name" ]] && { echo "asset already exists: $name" >&2; exit 1; }
    if [[ -f "$S/tear_next_upload" ]]; then      # a torn upload: partial bytes land, the command fails
        rm "$S/tear_next_upload"; head -c 10 "$file" > "$S/assets/$name"; exit 1
    fi
    [[ -f "$S/fail_uploads" ]] && exit 1
    cp "$file" "$S/assets/$name"; chmod u+w "$S/assets/$name" ;;
  delete-asset)
    [[ "$state" == published ]] && echo "VIOLATION delete on published: $1" >> "$S/violations.log"
    rm -f "$S/assets/$1" ;;
  edit)
    [[ "$state" == draft ]] || exit 1
    publish_now ;;
  *) echo "fake gh: unsupported release $cmd" >&2; exit 2 ;;
esac
