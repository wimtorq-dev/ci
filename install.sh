#!/bin/bash
# Nimbus Installer - Premium Edition
# Usage: curl -fsSL https://nimbus.yoodule.com/install.sh | bash
#   Pin a version:  NIMBUS_VERSION=vX.Y.Z bash  (i.e. before the `bash` at the end of the pipe)

set -e

REPO="Yoodule/nimbus"
INSTALL_DIR="${NIMBUS_HOME:-$HOME/.nimbus}"

# --- Test-only sourceable mode --------------------------------
# `NIMBUS_INSTALL_SOURCE_ONLY=1` is a no-op install path used by
# `tests/install/install-digest.bats`. When set, the script
# exits cleanly past the helper-function defs and BEFORE the
# install pipeline, so the bats test can `source install.sh`
# and call the digest-refresh helpers in-process. Real users
# never hit this — the env var is undocumented on purpose.
#
# We use an env var (not a positional arg like `--source-only`)
# because positional args don't propagate through `source`: the
# bats test does `source install.sh` (no args) and needs the
# early-exit to fire from the env, not the command line.
#
# We turn `set -e` OFF here: install.sh is `set -e` so a failed
# curl during a real install is fatal, but the test subshell
# inherits the option and would then refuse to run any
# subsequent command whose return code we want to inspect
# (e.g. `refresh_compose_pin … ; cat …`). Tests re-enable it
# per-assertion if they need it.
#
# The `return 0 2>/dev/null || exit 0` idiom works for both
# `source` and direct-execution contexts — `source` can't `exit`,
# only `return`, so the `|| exit 0` falls through when sourced.
if [ "${NIMBUS_INSTALL_SOURCE_ONLY:-0}" = "1" ]; then
    # Placeholder; the real early-exit is below, AFTER the
    # helper-function defs. We do the env-var check twice
    # (cheap: it's a string compare) so the early-exit can sit
    # at the end of the helper block and still fire when the
    # script is run directly with the env var set. This is
    # necessary because `source` doesn't propagate positional
    # args — bats does `source install.sh` (no args), so the
    # env-var check is the only way the test can short-circuit.
    :
fi

# --- OCI digest refresh helpers --------------------------------
# Used after `tar -xzf` to fix the stale `@sha256:…` pin in the
# extracted compose.yaml. The release tarball bakes the pin at
# release-build time, so any re-push of the same tag (e.g. a
# hotfix) makes the pin dangle. We HEAD the live index digest
# and sed-rewrite the @sha256 suffix in-place.
#
# Functions are defined BEFORE the install pipeline so the bats
# tests can `source install.sh --source-only` and call them in
# isolation, with no network. Real installs reach them after the
# tarball is on disk (see call site after `tar -xzf`).

# resolve_ghcr_digest <repo-name> <tag>
#   Prints `sha256:<64hex>` of the live ghcr.io OCI image index
#   for `ghcr.io/yoodule/nimbus/<repo>:<tag>`. Returns 0 on
#   success, non-zero on network/HTTP failure. Used by
#   refresh_compose_pin to look up the new digest.
#
# The Accept header `application/vnd.oci.image.index.v1+json`
# is REQUIRED: without it, ghcr returns 401 (it uses the Accept
# header to decide between a manifest, an index, and a manifest
# list — and treats the absence of the index Accept on the
# anonymous endpoint as unauthorized). This is a real bug we
# hit in v1.0.0 recut9 (project-release-v100-recut9.md).
#
# Test-override: when NIMBUS_TESTS_GHCR_DIGEST_CMD is set, the
# function skips the network call and runs the named command,
# printing its stdout. The bats tests use this to inject a
# canned digest without touching the network. Real installs
# never set this — only the bats source-only path does.
resolve_ghcr_digest() {
    local repo="$1"
    local tag="$2"

    if [ -n "${NIMBUS_TESTS_GHCR_DIGEST_CMD:-}" ]; then
        "$NIMBUS_TESTS_GHCR_DIGEST_CMD"
        return $?
    fi

    local url="https://ghcr.io/v2/yoodule/nimbus/${repo}/manifests/${tag}"
    # Use -I (HEAD) first; if the registry refuses to respond
    # to HEAD with the index Accept (some proxies strip it), fall
    # back to a GET and read the response header from the dump.
    # -L follows the Docker auth redirect to the S3-backed layer
    # store (anonymous bearer flow). --fail-with-body makes curl
    # exit non-zero on 4xx/5xx even when stdout is captured.
    local digest
    digest=$(curl -fsSL \
        -H "Accept: application/vnd.oci.image.index.v1+json" \
        -D - -o /dev/null \
        "$url" 2>/dev/null \
        | tr -d '\r' \
        | awk 'tolower($1) == "docker-content-digest:" { print $2; exit }')

    if [ -z "$digest" ]; then
        echo "Note: could not resolve live digest for ${repo}:${tag} (offline?)" >&2
        return 1
    fi
    echo "$digest"
}

# refresh_compose_pin <compose.yaml-path> <image-ref>
#   Rewrites a `image: <image-ref>@sha256:OLD` line in the given
#   compose.yaml to `image: <image-ref>@sha256:NEW`, where NEW is
#   the current ghcr.io index digest for <image-ref>. Leaves
#   bare `image: <image-ref>` lines (no pin) untouched — those
#   are intentional and will resolve to `latest` per OCI
#   semantics. Leaves other services' image lines alone.
#   Returns 0 always (offline-safe): a failed digest lookup is
#   logged and the file is left as-is.
refresh_compose_pin() {
    local compose_path="$1"
    local image_ref="$2"

    if [ ! -f "$compose_path" ]; then
        return 0
    fi

    # Pull the repo name and tag out of <image-ref> for the
    # ghcr.io lookup. We accept both `repo:tag` (the common
    # case) and the full `ghcr.io/org/repo:tag` form. Split on
    # the last `:` so registry-host:port cases (e.g.
    # `ghcr.io:443/...`, rare in practice) still work — we then
    # take the substring after the last `/` as the repo name.
    local ref_no_scheme="$image_ref"
    case "$ref_no_scheme" in
        https://*|http://*) ref_no_scheme="${ref_no_scheme#*://}" ;;
    esac
    local ref_tail="${ref_no_scheme##*/}"   # e.g. "gateway:v1.0.0"
    local repo="${ref_tail%%:*}"
    local tag="${ref_tail##*:}"

    local new_digest
    if ! new_digest=$(resolve_ghcr_digest "$repo" "$tag"); then
        # Offline or registry hiccup: leave the pin as-is.
        return 0
    fi

    # Normalize: tolerate callers (and the live registry) that
    # hand us a digest with or without the `sha256:` prefix. The
    # rewrite always emits `sha256:<64hex>` for OCI compliance.
    local new_hex="${new_digest#sha256:}"

    # Match `image: <image-ref>@sha256:<64hex>` and replace just
    # the @sha256:<64hex> suffix. The capture group preserves
    # the leading `image: <image-ref>` text. We use `#` as the
    # sed delimiter because image refs can contain `:` and `/`
    # but never `#` (ghcr.io URLs use only [a-z0-9._/-:@]).
    #
    # BSD sed (macOS) does not accept `@` at the END of a
    # capture group inside the match pattern — it errors with
    # "parentheses not balanced". The pattern below puts `@`
    # OUTSIDE the capture group, in the literal-to-match text,
    # so BSD sed is happy. GNU sed accepts either form.
    local sed_expr="s#^([[:space:]]*image:[[:space:]]+${image_ref}@sha256:)[0-9a-f]{64}#\\1${new_hex}#"
    sed -i.bak -E "$sed_expr" "$compose_path"
    rm -f "${compose_path}.bak"
}

# refresh_all_compose_pins <compose.yaml-path> <version>
#   Iterates the known pinned ghcr.io/yoodule/nimbus/* images
#   (currently: gateway, dashboard) and refreshes each in the
#   given compose.yaml against the live registry. Prints a
#   visible "Refreshed X pin to sha256:..." line on success
#   so the user can see the post-install digest refresh ran.
#   No-op when compose.yaml is missing or version is empty.
#
#   The version arg may have a leading `v` (e.g. `v1.0.0`); the
#   `v` is stripped before the registry query so the OCI tag
#   matches the manifest path ghcr.io expects. Mirrors the
#   PowerShell Invoke-NimbusInstallPostExtract on install.ps1.
refresh_all_compose_pins() {
    local compose_path="$1"
    local version="$2"
    if [ ! -f "$compose_path" ] || [ -z "$version" ]; then
        return 0
    fi
    local tag="$version"
    for REPO_NAME in gateway dashboard; do
        local image_ref="ghcr.io/yoodule/nimbus/${REPO_NAME}:${tag}"
        # Snapshot the hex in the file BEFORE the refresh, so we
        # can show "Refreshed X pin from OLD to NEW" (and stay
        # silent when the pin was already current). grep -oE
        # matches the first 64-hex occurrence on the image_ref's
        # line; an absent match yields empty (intentional — bare
        # lines are a no-op anyway).
        local old_hex
        old_hex=$(grep -oE "${image_ref}@sha256:[0-9a-f]{64}" "$compose_path" 2>/dev/null | head -1 | sed -E 's|.*@sha256:||' || true)
        if refresh_compose_pin "$compose_path" "$image_ref"; then
            local new_hex
            new_hex=$(grep -oE "${image_ref}@sha256:[0-9a-f]{64}" "$compose_path" 2>/dev/null | head -1 | sed -E 's|.*@sha256:||' || true)
            if [ -n "$old_hex" ] && [ "$old_hex" != "$new_hex" ]; then
                echo -e "  ${BLUE}Refreshed ${REPO_NAME} pin to sha256:${new_hex:0:12}…${NC} (was stale ${old_hex:0:12}…)"
            fi
        fi
    done
}

# Real early-exit for source-only mode. Must come AFTER the
# function defs above (so bats can call them) but BEFORE the
# install pipeline below (which would download real tarballs).
# See the env-var check at the top of the file for the rationale.
if [ "${NIMBUS_INSTALL_SOURCE_ONLY:-0}" = "1" ]; then
    set +e
    return 0 2>/dev/null || exit 0
fi

# --- Aesthetics (Yoodule Style: High Contrast, Minimalist) ---
# Defined here (after the source-only early-exit) so the install
# pipeline can use them. The function defs above (which run in
# both real installs AND source-only mode) define their own
# defaults if any of these are unset, so the bats test path is
# still safe.
BOLD='\033[1m'
BLUE='\033[34m'
CYAN='\033[36m'
YELLOW='\033[33m'
NC='\033[0m'

# `clear` exits non-zero on terminals whose terminfo entry isn't
# installed (e.g. a Lima VM with only xterm-256color in
# /etc/terminfo — `TERM=dumb` would trip it). The banner is
# decorative; if `clear` can't run, the banner is no less useful
# for just printing beneath whatever the user's terminal already
# showed. `|| true` keeps `set -e` from killing the install.
clear || true
echo ""
# Print the Nimbus brand mark as a **pre-baked stacked layout**:
# 26-line block-shading icon on top, 1 blank separator, 3-line
# text-block (wordmark / value prop / URL) centered within the
# 65-cell icon width, divider beneath — 31 rows total. Pre-baked
# by `nimbus-cli/build.rs` (writes `logo.banner`, copied to
# `release/banner.txt` by `scripts/release.sh`) and inlined into
# the heredoc below at release-build time (see the heredoc
# comment for the placeholder name). The runtime CLI's `print_banner`
# uses `banner::build_banner_lines` instead so it can pick layout by
# terminal width; the install banner is the brand's "best foot
# forward" — 65 cells, fixed, always renders the same shape.
#
# TTY gating: if the installer is being piped into another
# program (e.g. `curl -fsSL install.sh | bash > /tmp/log`), skip
# the banner entirely — block-shading characters in a log file
# are noise.
#
# The heredoc's closing `BANNER_EOF` is at column 0 by design —
# bash requires that for `<<'EOF'` (vs. `<<-EOF`, which only
# strips leading TABS, not spaces). The 2-space indent on each
# body line is baked into the file by build.rs (writes
# `logo.banner`) so the icon column-aligns with the
# 2-space-indented install text below (`  Preparing your
# environment...`).
if [ -t 1 ]; then
    cat <<'BANNER_EOF'
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████▒░▓█████████████████████████████████████████
  █████████████████████  ░███████████████████▓ ░███████████████████
  ████████████████▒░░░     ░░░▓███████████▓░░    ░▒████████████████
  ████████████████▓▓▒░     ░▒▓██████▓▓█████▓▒   ▒▓▓████████████████
  █████████████████████  ░█████████   ███████▓░▒███████████████████
  █████████████████████▒░▓████████▒   ▒████████████████████████████
  ███████████████████████████████░     ░███████████████████████████
  ███████████████████████████▓▒           ▒▓███████████████████████
  ██████████████████████░                       ░██████████████████
  █████████████████████████▓▒░             ░▒▓█████████████████████
  ██████████████████████████████▒       ▒██████████████████████████
  ████████████████████████████████░   ▒████████████████████████████
  █████████████████████████████████   █████████████████████████████
  █████████████████████████████████▓░▒█████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
                                                                   
                     NIMBUS — Your 24/7 Employee
   One command. No sign-up. The unified semantic gateway for MCP.
                     https://nimbus.yoodule.com
  ─────────────────────────────────────────────────────────────────
BANNER_EOF
fi
echo ""
echo -e "  Preparing your environment..."

# 1. System Check
printf "  Detecting system... "
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] && ARCH="amd64"
[[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]] && ARCH="arm64"
echo -e "${BLUE}Done ($OS-$ARCH)${NC}"

# 1.1 Export NIMBUS_HOST_ARCH so the compose file can pick the right
# platform variant from multi-arch images. Override with NIMBUS_HOST_ARCH
# in the env (e.g. `NIMBUS_HOST_ARCH=linux/amd64 bash …`) to force a
# different arch — useful on Apple Silicon under Rosetta or in CI.
export NIMBUS_HOST_ARCH="linux/$ARCH"

# 1.5 Ensure uv is installed (required for running MCP servers)
if ! command -v uv >/dev/null 2>&1; then
    printf "  uv not found. Installing uv... "
    if curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1; then
        export PATH="$HOME/.local/bin:$PATH"
        echo -e "${BLUE}Done${NC}"
    else
        echo -e "${RED}Failed. Please install manually: https://astral.sh/uv${NC}"
    fi
fi

# 2. Local-repo guard. The dev branch used to live here — building
# cargo + rsyncing source into $INSTALL_DIR — but that path is for
# maintainers and contributors only, never for `curl | bash`. If we
# detect a local clone, refuse to run and tell the user which script
# to use instead. A failure here is the correct outcome: a maintainer
# running install.sh by accident should be redirected to the right
# tool, not silently get a half-broken install.
if [[ -f "nimbus-cli/Cargo.toml" && -d "src" ]]; then
    echo ""
    echo -e "  ${BOLD}Local repository detected.${NC} This script downloads a prebuilt"
    echo "  release from GitHub. To install from a local clone, run:"
    echo ""
    echo -e "    ${BOLD}./scripts/dev-install.sh${NC}"
    echo ""
    exit 1
fi

# 3. Fetching Release
printf "  Fetching latest release... "
    # Resolve version when NIMBUS_VERSION is unset. /releases/latest returns
    # the newest non-draft, non-prerelease release. If you need a specific
    # build (including prereleases), set NIMBUS_VERSION explicitly.
    if [ -z "${NIMBUS_VERSION:-}" ]; then
        # Hit the GitHub API for the most recent non-prerelease tag. The
        # fallback below is a frozen-in-time version used only when the API
        # is unreachable (offline install, rate limit, etc.).
        RESOLVED=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
            2>/dev/null | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
        if [ -n "$RESOLVED" ]; then
            NIMBUS_VERSION="$RESOLVED"
        else
            # Frozen-in-time fallback used only when the API is unreachable
            # (offline install, rate limit, etc.). Update when cutting releases.
            NIMBUS_VERSION="v1.0.0"
        fi
    fi
    if [ -z "$NIMBUS_VERSION" ]; then
        echo -e "\n  ${BOLD}Error:${NC} Could not resolve a release version. Set NIMBUS_VERSION=vX.Y.Z and retry."
        exit 1
    fi

    RELEASE_BASE="https://github.com/$REPO/releases/download/$NIMBUS_VERSION"
    RELEASE_URL="${RELEASE_BASE}/nimbus-$OS-$ARCH.tar.gz"

    # Ensure the install dir exists before any download/extract, so a fresh
    # user (no ~/.nimbus yet) doesn't fail on the first tar.
    mkdir -p "$INSTALL_DIR"

    # Probe the asset. -L follows GitHub's redirect to the S3-backed CDN,
    # so we get the real 200/404 instead of the 302 that GitHub returns at
    # the origin. Without -L, the arm64 probe would always look "missing"
    # and the script would fall through to a nonexistent amd64 asset.
    ASSET_STATUS=$(curl -fsSLI -o /dev/null -w '%{http_code}' "$RELEASE_URL" || echo "000")
    if [ "$ASSET_STATUS" != "200" ] && [ "$OS" = "darwin" ] && [ "$ARCH" = "arm64" ]; then
        # Apple Silicon under Rosetta can run the Intel binary, but we don't
        # currently ship one. Fail fast with the actionable URL rather than
        # burning another 404 on an asset that doesn't exist.
        echo ""
        echo -e "  ${BOLD}Error:${NC} No darwin-arm64 asset found for $NIMBUS_VERSION."
        echo "  Check available assets at: $RELEASE_BASE"
        echo "  To install via Rosetta instead, set NIMBUS_HOST_ARCH=amd64."
        exit 1
    fi

    ASSET_NAME=$(basename "$RELEASE_URL")
    echo -e "${BLUE}$NIMBUS_VERSION${NC}"

    # 3. Downloading + verifying
    echo -e "  Downloading assets..."
    TMP_DIR=$(mktemp -d)
    TMP_FILE="$TMP_DIR/$ASSET_NAME"
    trap 'rm -rf "$TMP_DIR"' EXIT

    if ! curl -# -fSL "$RELEASE_URL" -o "$TMP_FILE"; then
        echo -e "\n  ${BOLD}Error:${NC} Download failed ($RELEASE_URL)."
        exit 1
    fi

    # Verify SHA256 against the release's SHA256SUMS. We download the sidecar
    # over the same pinned release tag so the checksum and the asset move
    # together. The grep is positional — SHA256SUMS lines look like
    # "<hex>  <asset-name>".
    SHA256SUMS_URL="${RELEASE_BASE}/SHA256SUMS"
    if curl -fsSL "$SHA256SUMS_URL" -o "$TMP_DIR/SHA256SUMS" \
        && grep -E "^[0-9a-f]{64}  ${ASSET_NAME}\$" "$TMP_DIR/SHA256SUMS" \
            | (cd "$TMP_DIR" && sha256sum -c --strict -); then
        printf "  Checksum verified... ${BLUE}OK${NC}\n"
    else
        echo -e "\n  ${BOLD}Error:${NC} SHA256 verification failed for $ASSET_NAME."
        echo "  Refusing to install. Verify the release at $RELEASE_BASE manually."
        exit 1
    fi

    # Integrity check: SHA256SUMS (above) is the only artifact-integrity
    # check at install time. The minisign step previously here was
    # removed — it required installing a non-standard CLI tool, blocked
    # installs in sandboxed/locked-down environments (Codespaces, CI
    # runners, minimal containers), and added no real defense (the
    # pubkey + fingerprint were both fetched from the same release the
    # attacker would control). The Rust CLI still verifies the same
    # minisign-signed manifest at `nimbus update` time using a pubkey
    # baked in at compile time — that's the right place for the
    # second line of defense.

    # 4. Extracting
    printf "  Installing Nimbus... "
    if ! tar -xzf "$TMP_FILE" -C "$INSTALL_DIR"; then
        echo -e "\n  ${BOLD}Error:${NC} Extraction failed."
        exit 1
    fi
    rm -rf "$TMP_DIR"
    echo -e "${BLUE}Success${NC}"

    BINARY_NAME="nimbus-$OS-$ARCH"
    [ ! -f "$INSTALL_DIR/$BINARY_NAME" ] && BINARY_NAME="nimbus"

    # 4.1 Refresh the OCI digest pin in the extracted compose.yaml.
    # The release tarball's compose.yaml carries
    # `image: ghcr.io/yoodule/nimbus/gateway:vX.Y.Z@sha256:OLD`
    # (and the dashboard line beside it). If vX.Y.Z has been
    # re-pushed (e.g. a v1.0.0 hotfix re-cut), the live index
    # digest is NEW but the tarball still bakes the OLD pin, and
    # `docker compose pull` 404s on the old digest. The fix is
    # one HTTP HEAD against ghcr.io per image and a sed rewrite
    # of the @sha256:… suffix. Offline-safe: if the network call
    # fails, we log a warning and leave the pin as-is (the user's
    # machine may be offline; a stale pin is better than a hard
    # install failure).
    #
    # The same $NIMBUS_VERSION resolved at the top is used here
    # (stripped of the leading `v`) so we never query a different
    # tag than the one we just downloaded.
    # Refresh every pinned ghcr.io/yoodule/nimbus/* image in the
    # extracted compose.yaml against the live registry. The same
    # $NIMBUS_VERSION resolved at the top is used here (stripped of
    # the leading `v`) so we never query a different tag than the
    # one we just downloaded.
    refresh_all_compose_pins "$INSTALL_DIR/compose.yaml" "$NIMBUS_VERSION"

    # 4.5 First-run .env stub. The runtime reads every env var from
    # $NIMBUS_HOME/.env (gateway via load_env_file in nimbus-cli/src/main.rs,
    # dashboard via compose env propagation in compose_up.rs:run_compose).
    # Without this file, `nimbus start` crashes on the first env lookup it
    # can't synthesize. Generate a stub with the same 27 keys as the
    # shipped working env so the install "just works" — user pastes real
    # values into the empty fields on first start. Skip silently if the
    # file already exists (dev re-installs, existing users).
    #
    # We do NOT generate real values for any secret. Only structural
    # defaults (GATEWAY_PORT, QDRANT_URL, EMBEDDING_MODEL, NIMBUS_DOMAIN,
    # NIMBUS_GATEWAY_URL) get non-empty values — the rest are empty
    # placeholders the user can populate. Four keys (BETTER_AUTH_SECRET,
    # QDRANT_API_KEY, NIMBUS_SERVICE_KEY, OPENROUTER_API_KEY) are
    # intentionally OMITTED from this stub: the first three are
    # auto-generated by `nimbus start` (or `nimbus env-init`) so the
    # Better Auth dashboard sees a real, crypto-strong secret from
    # first boot and the gateway↔dashboard service-key handshake has
    # a value, and OPENROUTER_API_KEY is prompted for interactively
    # on first start. Writing `KEY=` for any of them would
    # short-circuit those paths because the lookup would find the
    # key (with an empty value) and skip generation.
    # Per feedback-no-real-domains-in-dev.md, NIMBUS_DOMAIN defaults
    # to localhost (not the production hostname) so a fresh install
    # is self-evidently local; production deploys override directly.
    # The file is chmod'd 0600 because it WILL hold real secrets
    # once the user populates it — same pattern as
    # project-cli-config-file.md (config file is 0600).
    if [ ! -f "$INSTALL_DIR/.env" ]; then
        cat > "$INSTALL_DIR/.env" <<'NIMBUS_ENV_EOF'
# Nimbus runtime config — generated by install.sh on first install.
# Paste your real values into the empty fields, then run `nimbus start`.
# See https://nimbus.yoodule.com for the full list of integrations.

# --- Secrets (paste your real values) ---
# BETTER_AUTH_SECRET, QDRANT_API_KEY, and NIMBUS_SERVICE_KEY are
# auto-generated by `nimbus start` / `nimbus env-init` on first run.
# OPENROUTER_API_KEY is prompted for interactively on first start.
UPWORK_REDIRECT_URI=
UPWORK_CLIENT_ID=
NIMBUS_APPROVED=
EXA_API_KEY=
POLYGON_RPC_URL=
NIMBUS_USER_EMAIL=
NIMBUS_USER_NAME=
NIMBUS_API_KEY=
GITHUB_TOKEN=
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ZONE_ID=
NIMBUS_ADMIN_PASSWORD=
POLYMARKET_PRIVATE_KEY=
NIMBUS_RUN_MODE=
UPWORK_API_KEY_NAME=
UPWORK_ACCOUNT_TYPE=
UPWORK_CLIENT_SECRET=
NIMBUS_OPENROUTER_KEY=
UPWORK_PERMISSIONS=
MINISIGN_SECRET_KEY_FILE=
NOTION_TOKEN=

# --- Structural defaults (runtime needs these) ---
GATEWAY_PORT=8088
QDRANT_URL=http://qdrant:6333
EMBEDDING_MODEL=nvidia/llama-nemotron-embed-vl-1b-v2:free
NIMBUS_DOMAIN=localhost
NIMBUS_GATEWAY_URL=http://localhost:8088/mcp
NIMBUS_ENV_EOF
        chmod 0600 "$INSTALL_DIR/.env"
        echo -e "  Created ${BOLD}\$NIMBUS_HOME/.env${NC} — paste your API keys, then run \`nimbus start\` (OpenRouter key is prompted for on first start)"
    fi

# 5. Shell Setup
# (The tarball no longer ships a standalone gateway binary; the gateway
# is the OCI image pulled by `nimbus start` via docker compose. The
# PyInstaller nimbus-gateway binary used to be chmod'd here, but
# nothing on the install path executed it. The `docker-compose` block
# we used to extract is also gone — the compose.yaml in the tarball
# is renamed to .yaml by tar -xzf's default, and `nimbus start` reads
# $NIMBUS_HOME/compose.yaml directly. Nothing else needs to be
# chmod'd in the install step.)

chmod +x "$INSTALL_DIR/$BINARY_NAME" 2>/dev/null || true

# Determine shell config
SHELL_CONFIG="$HOME/.bashrc"
case "$SHELL" in
    */zsh)  SHELL_CONFIG="$HOME/.zshrc" ;;
    */bash) SHELL_CONFIG="$HOME/.bashrc" ;;
    *)      [ "$OS" = "darwin" ] && SHELL_CONFIG="$HOME/.zshrc" || SHELL_CONFIG="$HOME/.bashrc" ;;
esac

# The release tarball always extracts to nimbus-$OS-$ARCH (or nimbus
# if a multi-platform release was uploaded as a single binary). We
# use $BINARY_NAME for the launch below.
FINAL_BINARY="$BINARY_NAME"

# Shell-config integration.
#
# The Nimbus block is wrapped in paired `# BEGIN nimbus` / `# END nimbus`
# sentinels so `nimbus uninstall` can strip the whole block via the
# helper in nimbus-cli/src/lifecycle.rs::strip_nimbus_shell_block.
# The block is matched as a line-prefix (the helper trims leading and
# trailing whitespace before comparing), so trailing whitespace
# inserted by an editor doesn't break the strip. The guard below
# checks for the sentinel rather than `NIMBUS_HOME` so:
#   - a fresh install appends the block (with sentinels)
#   - a re-install does NOT double-append (the sentinel is already
#     present)
#   - a legacy install (pre-sentinel, no `# BEGIN nimbus`) will
#     append a SECOND block, which is harmless: the `nimbus` binary
#     added by the second install wins on PATH, and `nimbus uninstall`
#     strips the sentinel-wrapped block and leaves the legacy one
#     alone (a one-time migration artifact; the next uninstall on
#     the legacy block is a no-op because the sentinel-wrapped block
#     is already gone and the helper is idempotent on absent markers).
if ! grep -q "^# BEGIN nimbus" "$SHELL_CONFIG" 2>/dev/null; then
    {
        echo ""
        echo "# Nimbus Platform"
        echo "# BEGIN nimbus"
        echo "export NIMBUS_HOME=\"$INSTALL_DIR\""
        echo "export PATH=\"\$NIMBUS_HOME:\$PATH\""
        # Re-detect host arch in the shell so the compose file's
        # platform: \${NIMBUS_HOST_ARCH:-linux/arm64} picks the right
        # variant even if the user moves the install between machines.
        echo "export NIMBUS_HOST_ARCH=\"\$(uname -m | sed -E 's/x86_64/amd64/; s/aarch64/arm64/; s|^|linux/|')\""
        echo "# END nimbus"
    } >> "$SHELL_CONFIG"
    echo -e "  Added Nimbus to ${BOLD}$SHELL_CONFIG${NC}"
fi

echo ""
echo -e "  ${BOLD}Nimbus is ready to go.${NC}"
echo ""
echo -e "  ${CYAN}Two ways to use Nimbus:${NC}"
echo -e "  ${CYAN}  1.${NC} Just the gateway (headless, MCP-only): run ${BOLD}nimbus start${NC} and say ${BOLD}N${NC} to the dashboard prompt."
echo -e "  ${CYAN}  2.${NC} Full stack (gateway + agent dashboard): run ${BOLD}nimbus start${NC} and accept the dashboard prompt."
echo -e "  ${CYAN}Re-run later with: ${BOLD}nimbus dashboard install${NC} (or ${BOLD}nimbus dashboard uninstall${NC} to remove)."
echo ""

# 6. Auto-start option
#
# Skipped entirely when `--no-auto-start` is passed (used by
# scripts/test-e2e.sh to keep the install non-interactive — the
# prompt below would otherwise block on `read` from a piped stdin).
# The install still finishes the file writes, PATH wiring, and
# shell-config block, so a test that just wants to assert the
# install completed can do so without ever answering a prompt.
SHOULD_START="n"
if [ "${1:-}" != "--no-auto-start" ]; then
    if [ -t 0 ]; then
        read -p "  Would you like to start Nimbus now? (y/N) " -n 1 -r REPLY
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            SHOULD_START="y"
        fi
    elif [ -c /dev/tty ]; then
        if read -p "  Would you like to start Nimbus now? (y/N) " -n 1 -r REPLY < /dev/tty 2>/dev/null; then
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                SHOULD_START="y"
            fi
        fi
    fi
fi

if [ "$SHOULD_START" = "y" ]; then
    echo -e "  Starting Nimbus..."
    export NIMBUS_HOME="$INSTALL_DIR"
    export PATH="$INSTALL_DIR:$PATH"
    "$INSTALL_DIR/$FINAL_BINARY" start
else
    echo -e "  To start, please run:"
    echo -e "  ${BOLD}source $SHELL_CONFIG${NC}"
    echo -e "  ${BOLD}nimbus start${NC}\n"
fi

