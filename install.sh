#!/bin/sh
set -eu

REPO="${OMNICODE_REPO:-kyambuthia/omnicode}"
VERSION="${OMNICODE_VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

OS="$(uname -s)"
if [ "$OS" != "Linux" ]; then
    echo "error: prebuilt binaries are currently provided for Linux (detected $OS). Build from source with: zig build -Doptimize=ReleaseSafe" >&2
    exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) TARGET="x86_64" ;;
    aarch64|arm64) TARGET="aarch64" ;;
    *)
        echo "error: unsupported Linux architecture: $ARCH" >&2
        exit 1
        ;;
esac

ASSET="omnicode-linux-${TARGET}.tar.gz"
if [ "$VERSION" = "latest" ]; then
    BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
    BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

echo "Downloading ${ASSET} from ${REPO} (${VERSION})..."
curl -fsSL "${BASE_URL}/${ASSET}" -o "${TMP_DIR}/${ASSET}"

if curl -fsSL "${BASE_URL}/SHA256SUMS" -o "${TMP_DIR}/SHA256SUMS" 2>/dev/null; then
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$TMP_DIR" && grep " ${ASSET}\$" SHA256SUMS | sha256sum -c - >/dev/null)
    fi
fi

mkdir -p "$INSTALL_DIR"
tar -xzf "${TMP_DIR}/${ASSET}" -C "$TMP_DIR"
install -m 0755 "${TMP_DIR}/omnicode" "${INSTALL_DIR}/omnicode"

echo "Installed omnicode to ${INSTALL_DIR}/omnicode ($(${INSTALL_DIR}/omnicode --version))"
case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *) echo "Note: add ${INSTALL_DIR} to your PATH: export PATH=\"${INSTALL_DIR}:\$PATH\"" ;;
esac
