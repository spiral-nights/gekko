#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
START_TIME=$(date +%s)

usage() {
  cat <<'EOF'
Usage: ./scripts/test_ecosystem.sh [OPTIONS]

Options:
  --fast       Run single-target (wasm) parity tests and skip native example CLI builds
  --no-cache   Disable persistent local ecosystem cache (uses a fresh temporary directory)
  -h, --help   Show this help message

Environment variables:
  TARGETS             Space-separated MoonBit targets for stdlib & json (default: "wasm wasm-gc js native")
  EXAMPLE_TARGETS     Space-separated MoonBit targets for examples (default: "wasm js")
  SKIP_NATIVE         Set to 1 to skip native binary builds in examples (default: 0)
  GEKKO_CACHE_DIR     Persistent cache directory (default locally: build/.ecosystem_cache; disabled in CI)
  GEKKO_STDLIB_DIR    Local checkout of gekko_stdlib (default: clone over HTTPS)
  GEKKO_JSON_DIR      Local checkout of gekko_json (default: clone over HTTPS)
  GEKKO_EXAMPLES_DIR  Local checkout of gekko_examples (default: clone over HTTPS)
  GEKKO_STDLIB_REF    Git ref for gekko_stdlib when cloning (default: main)
  GEKKO_JSON_REF      Git ref for gekko_json when cloning (default: main)
  GEKKO_EXAMPLES_REF  Git ref for gekko_examples when cloning (default: main)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      TARGETS="${TARGETS:-wasm}"
      EXAMPLE_TARGETS="${EXAMPLE_TARGETS:-wasm}"
      SKIP_NATIVE="${SKIP_NATIVE:-1}"
      ;;
    --no-cache)
      GEKKO_CACHE_DIR=""
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [ -z "${GEKKO_CACHE_DIR+x}" ]; then
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    GEKKO_CACHE_DIR=""
  else
    GEKKO_CACHE_DIR="$ROOT/build/.ecosystem_cache"
  fi
fi

if [ -n "$GEKKO_CACHE_DIR" ]; then
  mkdir -p "$GEKKO_CACHE_DIR"
  GEKKO_CACHE_DIR="$(cd "$GEKKO_CACHE_DIR" && pwd)"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Building gekko shipment ==="
(cd "$ROOT" && gleam export erlang-shipment)

mkdir -p "$TMP_DIR/bin"
GEKKO_BIN="$TMP_DIR/bin/gekko"
cat > "$GEKKO_BIN" <<EOF
#!/usr/bin/env bash
exec "$ROOT/build/erlang-shipment/entrypoint.sh" run "\$@"
EOF
chmod +x "$GEKKO_BIN"

resolve_repo() {
  local env_dir="$1"
  local https_url="$2"
  local ref="$3"
  local dest="$4"
  if [ -n "$env_dir" ]; then
    (cd "$env_dir" && pwd)
  else
    git clone --depth 1 --branch "$ref" "$https_url" "$dest" >/dev/null 2>&1
    echo "$dest"
  fi
}

STDLIB_DIR="$(resolve_repo "${GEKKO_STDLIB_DIR:-}" "https://github.com/spiral-nights/gekko_stdlib.git" "${GEKKO_STDLIB_REF:-main}" "$TMP_DIR/repos/gekko_stdlib")"
JSON_DIR="$(resolve_repo "${GEKKO_JSON_DIR:-}" "https://github.com/spiral-nights/gekko_json.git" "${GEKKO_JSON_REF:-main}" "$TMP_DIR/repos/gekko_json")"
EXAMPLES_DIR="$(resolve_repo "${GEKKO_EXAMPLES_DIR:-}" "https://github.com/spiral-nights/gekko_examples.git" "${GEKKO_EXAMPLES_REF:-main}" "$TMP_DIR/repos/gekko_examples")"

echo "=== Running gekko_stdlib upstream parity tests ==="
GEKKO="$GEKKO_BIN" \
TARGETS="${TARGETS:-}" \
GEKKO_CACHE_DIR="$GEKKO_CACHE_DIR" \
  "$STDLIB_DIR/scripts/test_upstream.sh"

echo "=== Running gekko_json upstream parity tests ==="
GEKKO="$GEKKO_BIN" \
TARGETS="${TARGETS:-}" \
GEKKO_CACHE_DIR="$GEKKO_CACHE_DIR" \
GEKKO_STDLIB_DIR="$STDLIB_DIR" \
  "$JSON_DIR/scripts/test_upstream.sh"

echo "=== Running gekko_examples tests ==="
GEKKO="$GEKKO_BIN" \
EXAMPLE_TARGETS="${EXAMPLE_TARGETS:-}" \
SKIP_NATIVE="${SKIP_NATIVE:-}" \
GEKKO_CACHE_DIR="$GEKKO_CACHE_DIR" \
GEKKO_STDLIB_DIR="$STDLIB_DIR" \
GEKKO_JSON_DIR="$JSON_DIR" \
  "$EXAMPLES_DIR/scripts/test_all.sh"

ELAPSED=$(( $(date +%s) - START_TIME ))
echo "All gekko ecosystem checks passed in ${ELAPSED}s."
