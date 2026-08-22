#!/bin/sh
# https://github.com/Lommix/blitzdenk
set -eu

REPO="Lommix/blitzdenk"
BIN="blitz"

have() {
  command -v "$1" >/dev/null 2>&1
}

info() {
  printf '%s\n' "$1" >&2
}

err() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

fetch() {
  url=$1
  out=$2
  if have curl; then
    curl -fSL --retry 3 -o "$out" "$url"
  elif have wget; then
    wget -q -O "$out" "$url"
  else
    err "curl or wget is required"
  fi
}

main() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) ;;
    aarch64 | arm64) ARCH=aarch64 ;;
    *) err "unsupported architecture: $ARCH" ;;
  esac

  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  SUFFIX="-gnu"
  case "$OS" in
    darwin) SUFFIX="" ;;
    linux)
      if have ldd && ldd --version 2>&1 | grep -qi musl; then
        SUFFIX="-musl"
      fi
      ;;
    *) err "unsupported os: $OS" ;;
  esac

  ASSET="${BIN}-${ARCH}-${OS}${SUFFIX}.gz"
  URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  info "downloading $URL"
  fetch "$URL" "$TMP/$ASSET"
  gunzip -c "$TMP/$ASSET" >"$TMP/$BIN"
  chmod +x "$TMP/$BIN"

  DEST=${BLITZDENK_INSTALL_DIR:-}
  [ -n "$DEST" ] || DEST="$HOME/.local/bin"

  mkdir -p "$DEST"
  mv "$TMP/$BIN" "$DEST/$BIN"

  info "installed $DEST/$BIN"

  case ":$PATH:" in
    *":$DEST:"*) ;;
    *)
      info "warning: $DEST is not in your PATH, add it with:"
      case "$(basename "${SHELL:-sh}")" in
        fish) info "  fish_add_path $DEST" ;;
        nushell) info '  $env.PATH = ($env.PATH | prepend "'"$DEST"'")' ;;
        *) info "  export PATH=\"$DEST:\$PATH\"" ;;
      esac
      ;;
  esac
}

main "$@"
