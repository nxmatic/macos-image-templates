#!/usr/bin/env bash
set -euo pipefail

# Recreate nikopol role disks as Case-sensitive APFS (APFSX), copy data,
# and optionally activate by swapping filenames in-place.
#
# Defaults are conservative:
# - dry-run by default (no writes)
# - no in-place swap unless --activate is passed
#
# Usage examples:
#   ./fix-nikopol-case-sensitive-disks.sh
#   ./fix-nikopol-case-sensitive-disks.sh --apply
#   ./fix-nikopol-case-sensitive-disks.sh --apply --activate
#   ./fix-nikopol-case-sensitive-disks.sh --apply --activate --vm nikopol --tart-home .tart

VM_NAME="nikopol"
TART_HOME="${TART_HOME:-.tart}"
APPLY=0
ACTIVATE=0
KEEP_STAGING=1
STAGING_SUBDIR=".new.d"

usage() {
  cat <<'EOF'
fix-nikopol-case-sensitive-disks.sh

Options:
  --vm <name>             VM name (default: nikopol)
  --tart-home <path>      Tart home root (default: $TART_HOME or .tart)
  --apply                 Execute writes (default is dry-run)
  --activate              Swap resulting staged images into canonical filenames
  --no-keep-staging       Remove staging directory after successful --activate
  -h, --help              Show this help

Behavior:
  1) Creates new ASIF images with canonical max sizes and APFS case-sensitive format.
  2) Copies data from existing images to staged images under disks/<vm>/.new.d/.
  3) If --activate is passed, renames originals to *.bak-<timestamp>.asif and
     moves staged images into canonical names.

Safety checks:
  - Requires root privileges for apply mode (metadata/ownership fidelity).
  - Refuses to run apply mode if VM is currently running.
  - Requires source role disks to exist.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)
      VM_NAME="$2"; shift 2 ;;
    --tart-home)
      TART_HOME="$2"; shift 2 ;;
    --apply)
      APPLY=1; shift ;;
    --activate)
      ACTIVATE=1; shift ;;
    --no-keep-staging)
      KEEP_STAGING=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2 ;;
  esac
done

if [[ "$ACTIVATE" -eq 1 && "$APPLY" -ne 1 ]]; then
  echo "--activate requires --apply" >&2
  exit 2
fi

if [[ "$APPLY" -eq 1 && "$EUID" -ne 0 ]]; then
  echo "Refusing --apply without root privileges." >&2
  echo "Run with sudo to preserve ownership/ACL/xattrs metadata correctly." >&2
  exit 2
fi

DISKS_DIR="$TART_HOME/disks/$VM_NAME"
STAGING_DIR="$DISKS_DIR/$STAGING_SUBDIR"
if [[ ! -d "$DISKS_DIR" ]]; then
  echo "Missing disks directory: $DISKS_DIR" >&2
  exit 2
fi

if command -v tart >/dev/null 2>&1; then
  set +e
  tart_state="$(TART_HOME="$TART_HOME" tart list 2>/dev/null | awk -v vm="$VM_NAME" '$1=="local" && $2==vm { print $NF; found=1; exit } END { if (!found) print "" }')"
  set -e
  if [[ "$APPLY" -eq 1 && "$tart_state" == "running" ]]; then
    echo "Refusing --apply while VM is running: $VM_NAME" >&2
    echo "Stop VM first, then rerun." >&2
    exit 2
  fi
fi

# basename|size_gb|volume_label
SPECS=(
  "user-home.asif|160|user-home"
  "user-libraries-cache.asif|40|user-libraries-cache"
  "git-bare-store.asif|8|git-bare-store"
  "git-worktree-store.asif|9|git-worktree-store"
  "nix-store.asif|180|Nix Store"
  "build-chains-cache.asif|64|user-build-chains-cache"
  "vm-image-store.asif|512|vm-images-store"
)

log() { printf '%s\n' "$*"; }

COPY_BACKEND="ditto"

rsync_help_text() {
  rsync --help 2>&1 || true
}

rsync_probe_opt() {
  local opt="$1"
  local out
  set +e
  out="$(rsync "$opt" --version 2>&1)"
  local ec=$?
  set -e

  if [[ "$ec" -eq 0 ]]; then
    return 0
  fi

  # Common unknown-option signatures across Apple/GNU rsync builds.
  if printf '%s\n' "$out" | grep -Eiq 'unknown option|unrecognized option|invalid option'; then
    return 1
  fi

  # Conservative fallback: if we cannot prove support, treat as unsupported.
  return 1
}

rsync_supports_long_opt() {
  local opt="$1"
  rsync_probe_opt "$opt"
}

rsync_supports_short_opt() {
  local opt="$1"
  rsync_probe_opt "$opt"
}

init_rsync_args() {
  local has_e=0
  local has_x=0
  local has_a=0

  RSYNC_ARGS=( -aH )

  # Keep argument safety when available (modern rsync).
  if rsync_supports_long_opt '--protect-args'; then
    RSYNC_ARGS+=( --protect-args )
  fi

  # macOS metadata / xattrs compatibility:
  # - Apple rsync commonly supports -E and --extended-attributes
  # - GNU/modern rsync commonly supports -X/--xattrs and -A/--acls
  if rsync_supports_short_opt '-E'; then
    has_e=1
    RSYNC_ARGS+=( -E )
  fi
  if rsync_supports_short_opt '-X'; then
    has_x=1
    RSYNC_ARGS+=( -X )
  elif rsync_supports_long_opt '--xattrs'; then
    has_x=1
    RSYNC_ARGS+=( --xattrs )
  elif rsync_supports_long_opt '--extended-attributes'; then
    has_x=1
    RSYNC_ARGS+=( --extended-attributes )
  fi
  if rsync_supports_short_opt '-A'; then
    has_a=1
    RSYNC_ARGS+=( -A )
  elif rsync_supports_long_opt '--acls'; then
    has_a=1
    RSYNC_ARGS+=( --acls )
  fi

  # Strict metadata policy for home-folder replication:
  # require either Apple metadata mode (-E) OR explicit xattrs+ACLs (-X -A).
  if [[ "$has_e" -ne 1 && ! ( "$has_x" -eq 1 && "$has_a" -eq 1 ) ]]; then
    echo "ERROR: rsync metadata support is insufficient for strict macOS home replication." >&2
    echo "Need either: -E (Apple metadata mode) OR both -X (xattrs) and -A (ACLs)." >&2
    echo "Detected support: -E=$has_e -X=$has_x -A=$has_a" >&2
    echo "Refusing to continue to avoid metadata loss." >&2
    exit 2
  fi

  # Creation times and file flags only when explicitly supported.
  if rsync_supports_long_opt '--crtimes'; then
    RSYNC_ARGS+=( --crtimes )
  fi
  if rsync_supports_long_opt '--fileflags'; then
    RSYNC_ARGS+=( --fileflags )
  fi
}

run() {
  if [[ "$APPLY" -eq 1 ]]; then
    "$@"
  else
    printf 'DRY-RUN: '
    printf '%q ' "$@"
    printf '\n'
  fi
}

attached_base_device_for_image() {
  local image="$1"
  hdiutil info 2>/dev/null | awk -v img="$image" '
    $1 == "image-path" {
      in_image = (index($0, img) > 0)
      next
    }
    in_image && /^\/dev\/disk[0-9]+/ {
      print $1
      exit
    }
  '
}

detach_image_if_attached() {
  local image="$1"
  local base_dev

  base_dev="$(attached_base_device_for_image "$image")"
  if [[ -n "$base_dev" ]]; then
    log "Detaching stale attachment for image: $image ($base_dev)"
    diskutil unmountDisk force "$base_dev" >/dev/null 2>&1 || true
    hdiutil detach -force "$base_dev" >/dev/null 2>&1 || true
    diskutil detach force "$base_dev" >/dev/null 2>&1 || true
  fi
}

attach_and_get_mount() {
  local image="$1"
  local readonly_flag="$2"
  local out base_dev mount

  if [[ "$readonly_flag" == "1" ]]; then
    out="$(diskutil image attach -readonly -nobrowse "$image")"
  else
    out="$(diskutil image attach -nobrowse "$image")"
  fi

  base_dev="$(printf '%s\n' "$out" | awk '/^\/dev\/disk[0-9]+/{print $1; exit}')"
  mount="$(printf '%s\n' "$out" | awk 'match($0,/\/Volumes\/.*/){print substr($0,RSTART); exit}')"

  if [[ -z "$base_dev" ]]; then
    echo "Failed to resolve base device for image: $image" >&2
    return 1
  fi

  if [[ -z "$mount" ]]; then
    local vol_dev
    vol_dev="$(diskutil list "$base_dev" | awk '/disk[0-9]+s[0-9]+/ && /Apple_APFS/{print $NF; exit}')"
    if [[ -z "$vol_dev" ]]; then
      vol_dev="$(diskutil list "$base_dev" | awk '/disk[0-9]+s[0-9]+/{print $NF; exit}')"
    fi
    if [[ -z "$vol_dev" ]]; then
      echo "Failed to resolve APFS volume device for $image ($base_dev)" >&2
      return 1
    fi
    diskutil mount "$vol_dev" >/dev/null
    mount="$(diskutil info "$vol_dev" | awk -F': *' '/Mount Point/{print $2; exit}')"
  fi

  if [[ -z "$mount" || "$mount" == "Not mounted" ]]; then
    echo "Failed to resolve mount point for image: $image" >&2
    return 1
  fi

  printf '%s|%s\n' "$base_dev" "$mount"
}

assert_case_sensitive() {
  local image="$1"
  local attached base_dev mount
  local probe_dir lower upper inode_lower inode_upper

  attached="$(attach_and_get_mount "$image" 0)"
  base_dev="${attached%%|*}"
  mount="${attached#*|}"

  probe_dir="$mount/.case-sensitivity-probe-$$-$(date +%s)"
  lower="$probe_dir/probe"
  upper="$probe_dir/PROBE"

  mkdir -p "$probe_dir"
  : >"$lower"
  : >"$upper"

  inode_lower="$(stat -f '%i' "$lower")"
  inode_upper="$(stat -f '%i' "$upper")"

  rm -rf "$probe_dir"

  diskutil unmount force "$mount" >/dev/null 2>&1 || true
  diskutil detach "$base_dev" >/dev/null 2>&1 || true

  [[ "$inode_lower" != "$inode_upper" ]]
}

ensure_case_sensitive_image() {
  local image="$1"
  local volume_label="$2"
  local attached base_dev mount vol_dev

  if assert_case_sensitive "$image"; then
    return 0
  fi

  log "WARN: image was created case-insensitive; enforcing Case-sensitive APFS via reformat: $image"

  attached="$(attach_and_get_mount "$image" 0)"
  base_dev="${attached%%|*}"
  mount="${attached#*|}"

  vol_dev="$(diskutil info "$mount" | awk -F': *' '/Device Node/{print $2; exit}')"
  if [[ -z "$vol_dev" ]]; then
    diskutil unmount force "$mount" >/dev/null 2>&1 || true
    diskutil detach "$base_dev" >/dev/null 2>&1 || true
    echo "ERROR: could not resolve APFS volume device for reformat: $image" >&2
    return 1
  fi

  diskutil eraseVolume "Case-sensitive APFS" "$volume_label" "$vol_dev" >/dev/null

  diskutil unmount force "$mount" >/dev/null 2>&1 || true
  diskutil detach "$base_dev" >/dev/null 2>&1 || true

  if ! assert_case_sensitive "$image"; then
    echo "ERROR: failed to enforce case-sensitive filesystem on: $image" >&2
    return 1
  fi
}

copy_data() {
  local src_img="$1"
  local dst_img="$2"
  local src_attached dst_attached src_dev src_mount dst_dev dst_mount
  local rsync_ec=0

  src_attached="$(attach_and_get_mount "$src_img" 1)"
  src_dev="${src_attached%%|*}"
  src_mount="${src_attached#*|}"

  dst_attached="$(attach_and_get_mount "$dst_img" 0)"
  dst_dev="${dst_attached%%|*}"
  dst_mount="${dst_attached#*|}"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: this replication path requires Darwin (ditto)." >&2
    return 2
  fi
  if ! command -v ditto >/dev/null 2>&1; then
    echo "ERROR: ditto is required but not available in PATH." >&2
    return 2
  fi

  # Darwin-native metadata-aware copy path.
  # Source is mounted read-only, destination is writable staging volume.
  ditto --acl --extattr --rsrc "$src_mount" "$dst_mount"
  rsync_ec=0

  diskutil unmount force "$src_mount" >/dev/null 2>&1 || true
  diskutil unmount force "$dst_mount" >/dev/null 2>&1 || true
  diskutil detach "$src_dev" >/dev/null 2>&1 || true
  diskutil detach "$dst_dev" >/dev/null 2>&1 || true

  if [[ "$rsync_ec" -ne 0 && "$rsync_ec" -ne 24 ]]; then
    return "$rsync_ec"
  fi
}

ts="$(date +%Y%m%d-%H%M%S)"

log "VM_NAME=$VM_NAME"
log "TART_HOME=$TART_HOME"
log "DISKS_DIR=$DISKS_DIR"
log "STAGING_DIR=$STAGING_DIR"
log "MODE=$([[ "$APPLY" -eq 1 ]] && echo apply || echo dry-run)"
log "ACTIVATE=$ACTIVATE"
log "COPY_BACKEND=$COPY_BACKEND"

run mkdir -p "$STAGING_DIR"

# Phase 1: Create + copy into staging files under .new.d/
for spec in "${SPECS[@]}"; do
  IFS='|' read -r base size_gb volume_label <<<"$spec"
  src="$DISKS_DIR/$base"
  staging="$STAGING_DIR/$base"

  if [[ ! -f "$src" ]]; then
    echo "Missing source disk image: $src" >&2
    exit 2
  fi

  log "=== $base ==="
  if [[ "$APPLY" -eq 1 && -f "$staging" ]]; then
    detach_image_if_attached "$staging"
    log "Removing existing staging image: $staging"
    rm -f "$staging"
  fi

  if [[ "$APPLY" -eq 1 ]]; then
    if ! diskutil image create blank --format ASIF --size "${size_gb}G" --fs APFSX --volumeName "$volume_label" "$staging"; then
      diskutil image create blank --format ASIF --size "${size_gb}G" --fs "Case-sensitive APFS" --volumeName "$volume_label" "$staging"
    fi
  else
    printf 'DRY-RUN: '
    printf '%q ' diskutil image create blank --format ASIF --size "${size_gb}G" --fs APFSX --volumeName "$volume_label" "$staging"
    printf '
'
  fi

  if [[ "$APPLY" -eq 1 ]]; then
    ensure_case_sensitive_image "$staging" "$volume_label"

    log "Copying data: $src -> $staging"
    copy_data "$src" "$staging"

    if assert_case_sensitive "$staging"; then
      log "Verified case-sensitive filesystem on: $staging"
    else
      echo "ERROR: staging image is not case-sensitive: $staging" >&2
      exit 1
    fi
  fi
done

# Phase 2: Activate (optional)
if [[ "$ACTIVATE" -eq 1 ]]; then
  for spec in "${SPECS[@]}"; do
    IFS='|' read -r base _size _label <<<"$spec"
    src="$DISKS_DIR/$base"
    staging="$STAGING_DIR/$base"
    backup="$DISKS_DIR/${base%.asif}.bak-$ts.asif"

    if [[ ! -f "$staging" ]]; then
      echo "Missing staging image for activation: $staging" >&2
      exit 2
    fi

    log "Activating $base (backup => $(basename "$backup"))"
    mv "$src" "$backup"
    mv "$staging" "$src"
  done

  if [[ "$KEEP_STAGING" -eq 0 && -d "$STAGING_DIR" ]]; then
    rmdir "$STAGING_DIR" >/dev/null 2>&1 || true
  fi

  log "Activation complete. Originals are preserved as *.bak-$ts.asif"
else
  log "Staging complete. Re-run with --apply --activate to swap into live filenames."
fi

log "Done."
