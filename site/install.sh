#!/bin/sh
# Fluxion installer.
#
# Resolves the latest release, verifies its published SHA-256 before writing
# anything, and installs to ~/.local/bin. It does not touch shell startup
# files: if the install directory is not on PATH it says so and stops short of
# editing anything of yours.
#
#   curl --proto '=https' --tlsv1.2 -sSfL <url>/install.sh | sh
#   curl --proto '=https' --tlsv1.2 -sSfL <url>/install.sh | sh -s -- --version v0.2.0
set -eu

REPO="worxbend/fluxion.cr"
BIN_DIR="${HOME}/.local/bin"
VERSION=""

usage() {
    cat <<'USAGE'
Usage: install.sh [options]

  --version TAG     Install a specific release instead of the latest
  --bin-dir DIR     Install somewhere other than ~/.local/bin
  -h, --help        This message
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a tag}"; shift 2 ;;
        --bin-dir) BIN_DIR="${2:?--bin-dir needs a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "install.sh: $1 is required" >&2; exit 1; }
}
need curl
need tar

# Either sha256sum or shasum will do; refusing to continue without one is the
# point, since the checksum is what makes this safe to pipe into a shell.
if command -v sha256sum >/dev/null 2>&1; then
    checksum() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
    echo "install.sh: neither sha256sum nor shasum is available; refusing to install unverified bytes" >&2
    exit 1
fi

case "$(uname -s)" in
    Linux) ;;
    *) echo "install.sh: Fluxion targets Linux" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "install.sh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

if [ -z "$VERSION" ]; then
    VERSION=$(curl --proto '=https' --tlsv1.2 -sSfL \
        "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$VERSION" ] || { echo "install.sh: could not resolve the latest release" >&2; exit 1; }
fi

ASSET="fluxion-${VERSION}-linux-${ARCH}.tar.gz"
BASE="https://github.com/${REPO}/releases/download/${VERSION}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "Fetching ${ASSET} (${VERSION})"
curl --proto '=https' --tlsv1.2 --proto-redir '=https' -sSfL "${BASE}/${ASSET}" -o "${WORK}/${ASSET}"
curl --proto '=https' --tlsv1.2 --proto-redir '=https' -sSfL "${BASE}/fluxion-${VERSION}-checksums.sha256" -o "${WORK}/checksums"

EXPECTED=$(grep " \*\{0,1\}${ASSET}\$" "${WORK}/checksums" | cut -d' ' -f1 | head -n1)
[ -n "$EXPECTED" ] || { echo "install.sh: no checksum published for ${ASSET}" >&2; exit 1; }

ACTUAL=$(checksum "${WORK}/${ASSET}")
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "install.sh: checksum mismatch for ${ASSET}" >&2
    echo "  expected ${EXPECTED}" >&2
    echo "  actual   ${ACTUAL}" >&2
    exit 1
fi
echo "Checksum verified"

tar -xzf "${WORK}/${ASSET}" -C "$WORK"
[ -f "${WORK}/fluxion" ] || { echo "install.sh: archive did not contain a fluxion binary" >&2; exit 1; }

mkdir -p "$BIN_DIR"
# Written beside the destination and renamed, so a running fluxion is never
# replaced halfway through.
install -m 0755 "${WORK}/fluxion" "${BIN_DIR}/.fluxion.new"
mv -f "${BIN_DIR}/.fluxion.new" "${BIN_DIR}/fluxion"

echo "Installed ${VERSION} to ${BIN_DIR}/fluxion"

case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *)
        echo
        echo "${BIN_DIR} is not on your PATH. Add this to your shell startup file:"
        echo
        echo "    export PATH=\"${BIN_DIR}:\$PATH\""
        ;;
esac

echo
echo "Next:  fluxion generate --output ~/.config/fluxion/default.yaml"
echo "       fluxion validate"
echo "       fluxion dry-run"
