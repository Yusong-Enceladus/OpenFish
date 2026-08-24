#!/usr/bin/env bash

# Shared storage routing for local OpenFish builds.
#
# A developer can keep the default repository-local paths, or define a local
# (git-ignored) .openfish-build.env with OPENFISH_STORAGE_ROOT. When
# OPENFISH_REQUIRE_EXTERNAL_STORAGE=1, the configured volume must already be
# mounted: this helper never creates a look-alike directory on the system disk.

if [[ -z "${OPENFISH_REPO_ROOT:-}" ]]; then
  OPENFISH_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

OPENFISH_LOCAL_BUILD_CONFIG="$OPENFISH_REPO_ROOT/.openfish-build.env"
if [[ -f "$OPENFISH_LOCAL_BUILD_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$OPENFISH_LOCAL_BUILD_CONFIG"
fi

if [[ -n "${OPENFISH_STORAGE_ROOT:-}" ]]; then
  if [[ "$OPENFISH_STORAGE_ROOT" != /* ]]; then
    echo "OpenFish storage root must be an absolute path." >&2
    return 2 2>/dev/null || exit 2
  fi

  if [[ "${OPENFISH_REQUIRE_EXTERNAL_STORAGE:-0}" == "1" ]]; then
    OPENFISH_STORAGE_VOLUME="${OPENFISH_STORAGE_VOLUME:-}"
    if [[ -z "$OPENFISH_STORAGE_VOLUME" || "$OPENFISH_STORAGE_VOLUME" != /Volumes/* ]]; then
      echo "OpenFish external storage requires an explicit /Volumes mount." >&2
      return 2 2>/dev/null || exit 2
    fi
    if ! /sbin/mount | grep -F " on $OPENFISH_STORAGE_VOLUME (" >/dev/null; then
      echo "OpenFish external build volume is not mounted; refusing local fallback." >&2
      return 1 2>/dev/null || exit 1
    fi
    case "$OPENFISH_STORAGE_ROOT/" in
      "$OPENFISH_STORAGE_VOLUME"/*) ;;
      *)
        echo "OpenFish storage root must be inside the configured external volume." >&2
        return 2 2>/dev/null || exit 2
        ;;
    esac
  fi

  OPENFISH_BUILD_ROOT="$OPENFISH_STORAGE_ROOT/build"
  OPENFISH_DERIVED_DATA_ROOT="$OPENFISH_STORAGE_ROOT/derived-data"
  OPENFISH_ARTIFACT_ROOT="$OPENFISH_STORAGE_ROOT/artifacts/current"
  OPENFISH_CACHE_ROOT="$OPENFISH_STORAGE_ROOT/cache"
  OPENFISH_TEMP_ROOT="$OPENFISH_STORAGE_ROOT/tmp"
else
  if [[ "${OPENFISH_REQUIRE_EXTERNAL_STORAGE:-0}" == "1" ]]; then
    echo "OpenFish external storage is required but no storage root is configured." >&2
    return 1 2>/dev/null || exit 1
  fi
  OPENFISH_BUILD_ROOT="$OPENFISH_REPO_ROOT/.build"
  OPENFISH_DERIVED_DATA_ROOT="$OPENFISH_BUILD_ROOT/derived-data"
  OPENFISH_ARTIFACT_ROOT="$OPENFISH_REPO_ROOT/dist"
  OPENFISH_CACHE_ROOT="$OPENFISH_BUILD_ROOT/cache"
  OPENFISH_TEMP_ROOT="$OPENFISH_BUILD_ROOT/tmp"
fi

mkdir -p \
  "$OPENFISH_BUILD_ROOT" \
  "$OPENFISH_DERIVED_DATA_ROOT" \
  "$OPENFISH_ARTIFACT_ROOT" \
  "$OPENFISH_CACHE_ROOT" \
  "$OPENFISH_TEMP_ROOT"

# pnpm 11 reads non-auth settings from pnpm-workspace.yaml, global YAML, CLI,
# or PNPM_CONFIG_* environment variables (not a project .npmrc). Export the
# machine-local cache routing for every OpenFish build script that sources this
# helper, while leaving the public workspace configuration portable.
pnpm_config_store_dir="$OPENFISH_CACHE_ROOT/pnpm-store"
pnpm_config_virtual_store_dir="$OPENFISH_CACHE_ROOT/virtual-store-main-v2"

export \
  OPENFISH_REPO_ROOT \
  OPENFISH_BUILD_ROOT \
  OPENFISH_DERIVED_DATA_ROOT \
  OPENFISH_ARTIFACT_ROOT \
  OPENFISH_CACHE_ROOT \
  OPENFISH_TEMP_ROOT \
  pnpm_config_store_dir \
  pnpm_config_virtual_store_dir
