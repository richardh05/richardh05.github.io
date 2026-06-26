#!/bin/sh
# Updates ALL direct dependencies to their latest versions and rewrites pnpm-lock.yaml
# (and optionally node_modules) via a throwaway Docker container.
# Also pins the three.js CDN version in scripts/download-assets.mjs.
#
# Security controls applied on every run:
#   1. Minimum release age  — pnpm refuses versions < 1 week old (pnpm-workspace.yaml)
#   2. Age report           — shows publish dates; warns if any resolved pkg is < 7 days old
#   3. Block exotic subdeps — pnpm rejects git/tarball transitive deps (pnpm-workspace.yaml)
#   4. Build approval       — pnpm blocks new install scripts; halts for human review
#   5. Audit                — fails if high/critical CVEs remain after update

set -e

INSTALL=0
DISCARD=0
LOCK_ONLY=0

# ── ANSI colours (only when stdout is a terminal) ─────────────────────────────
if [ -t 1 ]; then
  YELLOW='\033[1;33m'
  RED='\033[1;31m'
  GREEN='\033[0;32m'
  RESET='\033[0m'
else
  YELLOW='' RED='' GREEN='' RESET=''
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Updates ALL direct dependencies to their latest versions and rewrites pnpm-lock.yaml
via a throwaway Docker container. Also pins the three.js CDN version in
scripts/download-assets.mjs.

Direct dependencies updated:
  astro  tailwindcss  @tailwindcss/vite  @astrojs/check
  typescript  eslint  @typescript-eslint/parser
  eslint-plugin-astro  @types/node

Options:
  -i, --install     Install packages and leave node_modules on the host
  -d, --discard     Install and verify, then remove node_modules from the host
  -l, --lock-only   Update pnpm-lock.yaml only (no node_modules written to host)
  -h, --help        Show this help message and exit

Note:
  -d and -l are mutually exclusive — passing both will exit with an error.

Default behaviour (no flags):
  Show this help message.

Security controls run on every invocation:
  • pnpm minimumReleaseAge (1 week)  — enforced by pnpm itself during resolution
  • Age report                      — warns if resolved versions are < 7 days old
  • blockExoticSubdeps              — enforced by pnpm; git/tarball subdeps are rejected
  • strictDepBuilds                 — new install scripts halt the run for human review
  • pnpm audit --audit-level=high   — fails if high/critical CVEs are present
EOF
}

for arg in "$@"; do
  case "$arg" in
    -i|--install)   INSTALL=1 ;;
    -d|--discard)   DISCARD=1 ;;
    -l|--lock-only) LOCK_ONLY=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$INSTALL" -eq 0 ] && [ "$DISCARD" -eq 0 ] && [ "$LOCK_ONLY" -eq 0 ]; then
  usage
  exit 0
fi

if [ "$DISCARD" -eq 1 ] && [ "$LOCK_ONLY" -eq 1 ]; then
  echo "Error: --discard and --lock-only are mutually exclusive." >&2
  exit 1
fi

# ── All direct dependencies ───────────────────────────────────────────────────
PKGS="astro tailwindcss @tailwindcss/vite @astrojs/check typescript eslint @typescript-eslint/parser eslint-plugin-astro @types/node"

# ── Build the pnpm command string ─────────────────────────────────────────────
if [ "$LOCK_ONLY" -eq 1 ]; then
  UPDATE_CMD="pnpm update $PKGS --latest --lockfile-only --store-dir /tmp/pnpm-store"
elif [ "$DISCARD" -eq 1 ]; then
  # node_modules is a bind-mounted temp dir (NM_TMP); the trap cleans it on exit.
  UPDATE_CMD="pnpm update $PKGS --latest --store-dir /tmp/pnpm-store"
else
  UPDATE_CMD="pnpm update $PKGS --latest --store-dir /tmp/pnpm-store"
fi

# ── node_modules shadow ───────────────────────────────────────────────────────
# node_modules may be root-owned from a prior Docker build. Mounting a fresh
# user-owned temp directory over it prevents ERR_PNPM_UNEXPECTED_STORE (the old
# store reference in .modules.yaml is hidden) while keeping the host copy intact.
# For --install we swap the temp dir into place after the run.
NM_TMP=$(mktemp -d)
cleanup_nm_tmp() { rm -rf "$NM_TMP"; }
trap cleanup_nm_tmp EXIT

# ── Step 1: Update packages ───────────────────────────────────────────────────
# pnpm enforces minimumReleaseAge (1 week) and blockExoticSubdeps automatically.
# If strictDepBuilds detects new unapproved build scripts, pnpm will error here
# and you must run `pnpm approve-builds` before continuing.
#
# NPM_CONFIG_PREFIX redirects the global npm prefix to /tmp so that
# `npm install -g pnpm` succeeds for non-root --user container runs.
echo "==> Updating packages..."
docker run --rm \
  -v "$(pwd):/app:z" \
  -v "$NM_TMP:/app/node_modules:z" \
  -w /app \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  node:24-alpine \
  sh -c "NPM_CONFIG_PREFIX=/tmp/npm-global npm install -g pnpm@11 --silent 2>/dev/null; export PATH=/tmp/npm-global/bin:\$PATH; $UPDATE_CMD"

# ── Step 1b: Pin packageManager field to the resolved pnpm version ────────────
PNPM_VERSION=$(docker run --rm -e HOME=/tmp node:24-alpine \
  sh -c "NPM_CONFIG_PREFIX=/tmp/npm-global npm install -g pnpm@11 --silent 2>/dev/null; export PATH=/tmp/npm-global/bin:\$PATH; pnpm --version" 2>/dev/null)
if [ -n "$PNPM_VERSION" ]; then
  sed -i "s|\"packageManager\": \"pnpm@[^\"]*\"|\"packageManager\": \"pnpm@${PNPM_VERSION}\"|" package.json
  printf "${GREEN}packageManager pinned to pnpm@%s${RESET}\n" "$PNPM_VERSION"
fi

# ── Step 1c: Place node_modules for --install, discard temp dir otherwise ─────
if [ "$INSTALL" -eq 1 ]; then
  # Remove the old (potentially root-owned) node_modules via a root container,
  # then move the freshly installed temp dir into place.
  docker run --rm -v "$(pwd):/app:z" -w /app node:24-alpine sh -c "rm -rf node_modules"
  trap - EXIT
  mv "$NM_TMP" node_modules
  printf "${GREEN}node_modules installed.${RESET}\n"
fi
# For --discard and --lock-only the trap fires at exit and removes NM_TMP.

# ── Step 2: Prune expired minimumReleaseAgeExclude entries ───────────────────
# Each entry is a temporary bypass for the 7-day minimumReleaseAge hold (e.g.
# an emergency security patch that can't wait a week). Once the version is
# older than 7 days pnpm allows it anyway, so the exemption is dead config.
echo ""
echo "==> Pruning expired minimumReleaseAgeExclude entries..."

EXCLUDE_ENTRIES=$(grep -E '^  - "' pnpm-workspace.yaml 2>/dev/null \
  | sed 's/^  - "//;s/"$//')

if [ -z "$EXCLUDE_ENTRIES" ]; then
  echo "  No entries to check."
else
  EXCLUDE_CHANGED=0
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    VERSION=$(echo "$entry" | sed 's/.*@//')
    PKG=$(echo "$entry" | sed "s|@${VERSION}$||")

    # Fetch publish time from the full package document (time object contains
    # per-version timestamps keyed by semver string).
    PUBLISHED=$(wget -qO- "https://registry.npmjs.org/${PKG}" 2>/dev/null \
      | grep -o "\"${VERSION}\":\"[^\"]*\"" | head -1 \
      | sed 's/.*":"//;s/"$//')

    if [ -z "$PUBLISHED" ]; then
      printf "  %-40s (publish date unavailable — keeping)\n" "$entry"
      continue
    fi

    PUB_EPOCH=$(date -d "$PUBLISHED" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE_DAYS=$(( (NOW_EPOCH - PUB_EPOCH) / 86400 ))

    if [ "$AGE_DAYS" -ge 7 ]; then
      # Remove the entry line and any immediately-preceding indented comment block.
      awk -v target="  - \"${entry}\"" '
        /^  #/ { buf[nb++] = $0; next }
        $0 == target { nb = 0; next }
        { for (i = 0; i < nb; i++) print buf[i]; nb = 0; print }
        END { for (i = 0; i < nb; i++) print buf[i] }
      ' pnpm-workspace.yaml > pnpm-workspace.yaml.tmp \
        && [ -s pnpm-workspace.yaml.tmp ] \
        && mv pnpm-workspace.yaml.tmp pnpm-workspace.yaml \
        || { rm -f pnpm-workspace.yaml.tmp
             printf "${YELLOW}Warning: could not prune %s — skipping${RESET}\n" "$entry"; }
      printf "  ${GREEN}%-40s %d days old — removed${RESET}\n" "$entry" "$AGE_DAYS"
      EXCLUDE_CHANGED=1
    else
      printf "  ${YELLOW}%-40s %d days old — still active${RESET}\n" "$entry" "$AGE_DAYS"
    fi
  done <<ENTRIES
$EXCLUDE_ENTRIES
ENTRIES

  if [ "$EXCLUDE_CHANGED" -eq 0 ]; then
    echo "  Nothing to prune."
  fi
fi

# ── Step 3: Age report ────────────────────────────────────────────────────────
# Query the npm registry for publish timestamps of the resolved versions.
# pnpm already enforced the 1-week minimum; this report shows ages so the operator
# can confirm nothing slipped through before committing the lockfile.
echo ""
echo "==> Checking package publish ages..."

# Extract version from pnpm-lock.yaml v9 format.
# Regular packages:  "  pkg@ver:"
# Scoped packages:   "  '@scope/pkg@ver':"
get_version() {
  pkg="$1"
  case "$pkg" in
    @*)
      grep "^  '${pkg}@" pnpm-lock.yaml 2>/dev/null \
        | head -1 \
        | sed "s|^  '${pkg}@||;s|':.*||"
      ;;
    *)
      grep "^  ${pkg}@" pnpm-lock.yaml 2>/dev/null \
        | head -1 \
        | sed "s|^  ${pkg}@||;s|:.*||"
      ;;
  esac
}

AGE_WARNING=0
for pkg in $PKGS; do
  VERSION=$(get_version "$pkg")
  if [ -z "$VERSION" ]; then
    printf "  %-45s %s\n" "$pkg" "(version not found in lockfile)"
    continue
  fi

  # Fetch publish time from the npm registry
  PUBLISHED=$(wget -qO- "https://registry.npmjs.org/${pkg}/${VERSION}" 2>/dev/null \
    | grep -o '"time":"[^"]*"' | head -1 | sed 's/"time":"//;s/"//')

  if [ -z "$PUBLISHED" ]; then
    printf "  %-45s %s\n" "$pkg@$VERSION" "(publish date unavailable)"
    continue
  fi

  PUB_EPOCH=$(date -d "$PUBLISHED" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  AGE_DAYS=$(( (NOW_EPOCH - PUB_EPOCH) / 86400 ))

  if [ "$AGE_DAYS" -lt 7 ]; then
    printf "  ${YELLOW}%-45s published %s (%d days ago) ← REVIEW RECOMMENDED${RESET}\n" \
      "$pkg@$VERSION" "$PUBLISHED" "$AGE_DAYS"
    AGE_WARNING=1
  else
    printf "  ${GREEN}%-45s published %s (%d days ago)${RESET}\n" \
      "$pkg@$VERSION" "$PUBLISHED" "$AGE_DAYS"
  fi
done

if [ "$AGE_WARNING" -eq 1 ]; then
  echo ""
  printf "${YELLOW}Warning: one or more packages are < 7 days old.${RESET}\n"
  printf "pnpm has already enforced the 1-week minimum release age.\n"
  printf "You may want to wait before committing the updated lockfile.\n"
fi

# ── Step 4: Audit ─────────────────────────────────────────────────────────────
# Fail if any high or critical CVE is present in the resolved dependency tree.
# Workspace overrides in pnpm-workspace.yaml already patch known transitive CVEs
# (e.g. devalue GHSA-77vg-94rm-hx3p). Add new overrides there before running again.
echo ""
echo "==> Running security audit..."
docker run --rm \
  -v "$(pwd):/app:z" \
  -w /app \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  node:24-alpine \
  sh -c "NPM_CONFIG_PREFIX=/tmp/npm-global npm install -g pnpm@11 --silent 2>/dev/null; export PATH=/tmp/npm-global/bin:\$PATH; pnpm audit --audit-level=high" \
  || {
    echo ""
    printf "${RED}Audit failed: high or critical vulnerabilities found.${RESET}\n"
    printf "Add workspace overrides in pnpm-workspace.yaml to patch transitive deps,\n"
    printf "or add GHSA IDs to auditConfig.ignoreGhsas only after explicit review.\n"
    exit 1
  }

# ── Step 5: Pin three.js CDN version in download-assets.mjs ──────────────────
echo ""
printf 'Resolving latest three.js version... '
THREE_LATEST=$(docker run --rm -e HOME=/tmp node:24-alpine \
  sh -c "NPM_CONFIG_PREFIX=/tmp/npm-global npm install -g pnpm@11 --silent 2>/dev/null; export PATH=/tmp/npm-global/bin:\$PATH; pnpm view three version" 2>/dev/null)

if [ -z "$THREE_LATEST" ]; then
  echo 'FAILED (could not resolve — skipping)' >&2
else
  OLD_THREE=$(sed -n 's|.*cdn\.jsdelivr\.net/npm/three@\([^/]*\)/.*|\1|p' \
    scripts/download-assets.mjs | head -1)
  if [ "$OLD_THREE" = "$THREE_LATEST" ]; then
    echo "already at $THREE_LATEST"
  else
    # Replace versioned URL (three@x.y.z/) or unversioned URL (three/) with pinned version
    sed -i "s|/npm/three@[^/]*/|/npm/three@$THREE_LATEST/|g; s|/npm/three/|/npm/three@$THREE_LATEST/|g" scripts/download-assets.mjs
    rm -f public/scripts/three.min.js
    printf "${GREEN}%s → %s${RESET}  (public/scripts/three.min.js removed)\n" "$OLD_THREE" "$THREE_LATEST"
  fi
fi

# ── Step 6: Record successful update date in README.md ────────────────────────
TIMESTAMP=$(date -u +"%Y-%m-%d")
MARKER="<!-- packages-last-updated:"
NEW_LINE="<!-- packages-last-updated: ${TIMESTAMP} -->"

if grep -q "$MARKER" README.md 2>/dev/null; then
  sed -i "s|${MARKER}[^>]*>|${NEW_LINE}|" README.md
else
  printf "\n---\n\n%s\n" "$NEW_LINE" >> README.md
fi
printf "${GREEN}README.md updated: dependencies last updated on %s.${RESET}\n" "$TIMESTAMP"
