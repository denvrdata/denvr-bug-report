#!/bin/sh
# ==============================================================================
# install.sh
#
# Downloads a denvr-bug-report release, verifies its checksum and runs it in a
# single step:
#
#   curl -sfL https://github.com/denvrdata/denvr-bug-report/releases/latest/download/install.sh | sudo sh -s -- [options]
#
# All arguments after `--` are passed to denvr-bug-report.sh. The report is
# written to the current directory unless -o is given. The downloaded copy is
# removed afterwards.
#
# Environment:
#   DBR_VERSION   release tag to fetch, e.g. v0.1.0 (default: latest release)
#   DBR_BASE_URL  URL of a directory holding the release assets; overrides
#                 DBR_VERSION (mirrors, testing; file:// works with curl)
# ==============================================================================

set -eu

REPO="denvrdata/denvr-bug-report"
ASSET="denvr-bug-report.tar.gz"
SUMS="sha256sums.txt"

info()  { printf '[denvr-bug-report] %s\n' "$*" >&2; }
fatal() { printf '[denvr-bug-report] ERROR: %s\n' "$*" >&2; exit 1; }

if [ -n "${DBR_BASE_URL:-}" ]; then
  base="${DBR_BASE_URL%/}"
elif [ -n "${DBR_VERSION:-}" ]; then
  base="https://github.com/$REPO/releases/download/$DBR_VERSION"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
else
  fatal "curl or wget is required"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fatal "sha256sum or shasum is required to verify the download"
fi

command -v tar  >/dev/null 2>&1 || fatal "tar is required"
command -v bash >/dev/null 2>&1 || fatal "bash is required"

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t denvr-bug-report)"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM

info "Downloading $base/$ASSET"
fetch "$base/$ASSET" "$tmp/$ASSET" || fatal "download failed: $base/$ASSET"
fetch "$base/$SUMS"  "$tmp/$SUMS"  || fatal "download failed: $base/$SUMS"

want="$(awk -v f="$ASSET" '$2 == f || $2 == "*" f { print $1 }' "$tmp/$SUMS")"
[ -n "$want" ] || fatal "$ASSET is not listed in $SUMS"
got="$(sha256 "$tmp/$ASSET")"
[ "$want" = "$got" ] || fatal "checksum mismatch for $ASSET (expected $want, got $got)"
info "Checksum OK"

tar -xzf "$tmp/$ASSET" -C "$tmp"
script="$tmp/denvr-bug-report/denvr-bug-report.sh"
[ -f "$script" ] || fatal "unexpected archive layout: denvr-bug-report/denvr-bug-report.sh missing"

# When piped (curl | sh), stdin is the download rather than the keyboard. Give
# the script the terminal so its prompts still work; with no terminal at all,
# give it /dev/null so it cannot read the rest of this script from the pipe.
rc=0
if [ -t 0 ]; then
  bash "$script" "$@" || rc=$?
elif (exec </dev/tty) 2>/dev/null; then
  bash "$script" "$@" </dev/tty || rc=$?
else
  bash "$script" "$@" </dev/null || rc=$?
fi
exit "$rc"
