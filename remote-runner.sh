#!/usr/bin/env bash

# Generic npm-on-macOS baseline. Copy this file to a personal tools directory
# and adapt the configuration and routing for each selected repository.

set -euo pipefail

declare -a REMOTE_RUNNER_ALLOWED_ROOTS=()
declare -a REMOTE_RUNNER_UNTRACKED_ALLOWLIST=()
# Relative dirs with pyproject.toml + uv.lock. Virtualenvs are never synced;
# each entry is installed remotely from its lockfile when the identity changes.
declare -a REMOTE_RUNNER_UV_PROJECTS=()

runner_config="${NPM_REMOTE_RUNNER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/npm-remote-runner-macos/config.sh}"
if [[ -f "$runner_config" ]]; then
  # This is a user-owned shell configuration file. It must not come from a
  # cloned repository or another untrusted source.
  # shellcheck source=/dev/null
  source "$runner_config"
fi

REMOTE_RUNNER_USER="${REMOTE_RUNNER_USER:-CHANGE_ME}"
REMOTE_RUNNER_HOST="${REMOTE_RUNNER_HOST:-CHANGE_ME.local}"
REMOTE_RUNNER_BASE_DIR="${REMOTE_RUNNER_BASE_DIR:-Library/Caches/npm-remote-runner-macos}"
REMOTE_RUNNER_NODE_VERSION="${REMOTE_RUNNER_NODE_VERSION:-}"
REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES="${REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES:-0}"
REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC="${REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC:-0}"
REMOTE_RUNNER_CONNECT_TIMEOUT="${REMOTE_RUNNER_CONNECT_TIMEOUT:-10}"
REMOTE_RUNNER_CONNECT_ATTEMPTS="${REMOTE_RUNNER_CONNECT_ATTEMPTS:-3}"
REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT="${REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT:-900}"
REMOTE_RUNNER_REMOTE_LOCK_TIMEOUT="${REMOTE_RUNNER_REMOTE_LOCK_TIMEOUT:-900}"
REMOTE_RUNNER_SETUP_TIMEOUT="${REMOTE_RUNNER_SETUP_TIMEOUT:-600}"
REMOTE_RUNNER_JOB_TIMEOUT="${REMOTE_RUNNER_JOB_TIMEOUT:-1200}"
REMOTE_RUNNER_SSH_KEY="${REMOTE_RUNNER_SSH_KEY:-}"

usage() {
  cat <<'USAGE'
Usage:
  remote-runner.sh doctor
  remote-runner.sh bootstrap
  remote-runner.sh test [test arguments...]
  remote-runner.sh run -- <command> [arguments...]

Configuration defaults to:
  ~/.config/npm-remote-runner-macos/config.sh

Example configuration:
  REMOTE_RUNNER_USER="remote-user"
  REMOTE_RUNNER_HOST="test-mac.local"
  REMOTE_RUNNER_ALLOWED_ROOTS=(
    "/absolute/path/to/repository"
  )
  REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES=1
  REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC=0
  REMOTE_RUNNER_SETUP_TIMEOUT=600
  REMOTE_RUNNER_JOB_TIMEOUT=1200
  REMOTE_RUNNER_UNTRACKED_ALLOWLIST=(
    "generated-public-fixtures/"
  )
  REMOTE_RUNNER_UV_PROJECTS=(
    "tools/verifier"
  )

Do not put passwords, tokens or environment values in this configuration.
USAGE
}

fail() {
  printf "remote-runner: %s\n" "$*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing local command: $1"
}

require_positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail "$1 must be a positive integer"
}

canonical_directory() {
  (cd "$1" && pwd -P)
}

git_common_directory() {
  local root="$1" common
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
    return 1
  canonical_directory "$common"
}

is_registered_worktree() {
  local repository_root="$1" candidate_root="$2" line listed_root
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        listed_root="$(canonical_directory "${line#worktree }" 2>/dev/null || true)"
        [[ -z "$listed_root" || "$listed_root" != "$candidate_root" ]] || return 0
        ;;
    esac
  done < <(git -C "$repository_root" worktree list --porcelain)
  return 1
}

resolve_workspace() {
  workspace_root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    fail "run this command inside a Git worktree"
  workspace_root="$(canonical_directory "$workspace_root")"

  local allowed allowed_root allowed_common current_common matched=""
  current_common="$(git_common_directory "$workspace_root")" ||
    fail "cannot resolve this worktree's Git common directory"
  for allowed in "${REMOTE_RUNNER_ALLOWED_ROOTS[@]}"; do
    allowed_root="$(canonical_directory "$allowed" 2>/dev/null || true)"
    if [[ -n "$allowed_root" && "$workspace_root" == "$allowed_root" ]]; then
      matched="yes"
      break
    fi
    if [[ "$REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES" == "1" && -n "$allowed_root" ]]; then
      allowed_common="$(git_common_directory "$allowed_root" 2>/dev/null || true)"
      if [[ -n "$allowed_common" && "$current_common" == "$allowed_common" ]] &&
        is_registered_worktree "$allowed_root" "$workspace_root"; then
        matched="yes"
        break
      fi
    fi
  done
  [[ -n "$matched" ]] ||
    fail "this worktree is outside the configured repository scope: $workspace_root"

  local invocation_directory
  invocation_directory="$(pwd -P)"
  case "$invocation_directory/" in
    "$workspace_root/"*) workspace_relative_directory="${invocation_directory#"$workspace_root"}" ;;
    *) fail "current directory is outside the resolved worktree" ;;
  esac
  workspace_relative_directory="${workspace_relative_directory#/}"
}

resolve_node_version() {
  if [[ -n "$REMOTE_RUNNER_NODE_VERSION" ]]; then
    node_version="${REMOTE_RUNNER_NODE_VERSION#v}"
    return
  fi

  local pin=""
  if [[ -f "$workspace_root/.nvmrc" ]]; then
    IFS= read -r pin <"$workspace_root/.nvmrc"
  elif [[ -f "$workspace_root/.node-version" ]]; then
    IFS= read -r pin <"$workspace_root/.node-version"
  elif command -v node >/dev/null 2>&1; then
    pin="$(node --version)"
  fi
  pin="${pin#v}"
  [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "set REMOTE_RUNNER_NODE_VERSION to an exact version"
  node_version="$pin"
}

validate_configuration() {
  [[ "$REMOTE_RUNNER_USER" != "CHANGE_ME" ]] ||
    fail "set REMOTE_RUNNER_USER in $runner_config"
  [[ "$REMOTE_RUNNER_HOST" != "CHANGE_ME.local" ]] ||
    fail "set REMOTE_RUNNER_HOST in $runner_config"
  [[ "$REMOTE_RUNNER_USER" =~ ^[A-Za-z0-9._-]+$ ]] ||
    fail "REMOTE_RUNNER_USER contains unsupported characters"
  [[ "$REMOTE_RUNNER_HOST" =~ ^[A-Za-z0-9._-]+$ ]] ||
    fail "REMOTE_RUNNER_HOST must be a hostname or SSH alias"
  [[ "$REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES" == "0" ||
    "$REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES" == "1" ]] ||
    fail "REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES must be 0 or 1"
  [[ "$REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC" == "0" ||
    "$REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC" == "1" ]] ||
    fail "REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC must be 0 or 1"
  require_positive_integer REMOTE_RUNNER_CONNECT_TIMEOUT "$REMOTE_RUNNER_CONNECT_TIMEOUT"
  require_positive_integer REMOTE_RUNNER_CONNECT_ATTEMPTS "$REMOTE_RUNNER_CONNECT_ATTEMPTS"
  require_positive_integer REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT "$REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT"
  require_positive_integer REMOTE_RUNNER_REMOTE_LOCK_TIMEOUT "$REMOTE_RUNNER_REMOTE_LOCK_TIMEOUT"
  require_positive_integer REMOTE_RUNNER_SETUP_TIMEOUT "$REMOTE_RUNNER_SETUP_TIMEOUT"
  require_positive_integer REMOTE_RUNNER_JOB_TIMEOUT "$REMOTE_RUNNER_JOB_TIMEOUT"
  case "$REMOTE_RUNNER_BASE_DIR" in
    Library/Caches/npm-remote-runner-macos | Library/Caches/npm-remote-runner-macos/*) ;;
    *) fail "REMOTE_RUNNER_BASE_DIR must stay under Library/Caches/npm-remote-runner-macos" ;;
  esac
  [[ "$REMOTE_RUNNER_BASE_DIR" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    fail "REMOTE_RUNNER_BASE_DIR contains unsupported characters"
  case "/$REMOTE_RUNNER_BASE_DIR/" in
    *"/../"* | *"/./"* | *"//"*) fail "REMOTE_RUNNER_BASE_DIR contains unsafe path components" ;;
  esac
}

build_ssh_configuration() {
  remote_target="${REMOTE_RUNNER_USER}@${REMOTE_RUNNER_HOST}"
  ssh_arguments=(
    -o BatchMode=yes
    -o "ConnectTimeout=$REMOTE_RUNNER_CONNECT_TIMEOUT"
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o ControlMaster=auto
    -o ControlPersist=600
    -o "ControlPath=/tmp/npm-remote-runner-%C"
  )
  if [[ -n "$REMOTE_RUNNER_SSH_KEY" ]]; then
    ssh_arguments+=(-i "$REMOTE_RUNNER_SSH_KEY" -o IdentitiesOnly=yes)
  fi

  rsync_transport="ssh"
  local argument quoted
  for argument in "${ssh_arguments[@]}"; do
    printf -v quoted " %q" "$argument"
    rsync_transport+="$quoted"
  done
}

require_local_tools() {
  local name
  for name in git rsync shasum shlock ssh; do
    require_command "$name"
  done
}

retry_transport() {
  local status=0
  for ((attempt = 1; attempt <= REMOTE_RUNNER_CONNECT_ATTEMPTS; attempt += 1)); do
    if "$@"; then
      return 0
    else
      status=$?
    fi
    if ((attempt < REMOTE_RUNNER_CONNECT_ATTEMPTS)); then
      printf "Transport attempt %s/%s failed; retrying.\n" \
        "$attempt" "$REMOTE_RUNNER_CONNECT_ATTEMPTS" >&2
      sleep "$attempt"
    fi
  done
  return "$status"
}

is_protected_path() {
  local path="/$1"
  case "$path" in
    */.env.example | */.env.sample | */.env.template) return 1 ;;
    */.env | */.env.* | */.envrc | */.direnv | */.direnv/* | */.npmrc) return 0 ;;
    */.ssh | */.ssh/* | */.aws | */.aws/* | */.azure | */.azure/*) return 0 ;;
    */.config/gcloud | */.config/gcloud/* | */.kube/config | */.docker/config.json) return 0 ;;
    */.netrc | */.authinfo | */.git-credentials | */.pypirc) return 0 ;;
    *.pem | *.key | *.p12 | *.pfx | *.jks | *.keystore | *.agekey | *.kdbx) return 0 ;;
    */id_rsa | */id_dsa | */id_ecdsa | */id_ed25519) return 0 ;;
    */credentials.json | */credentials | */secrets.json | */secrets) return 0 ;;
    */.git | */.git/* | */node_modules | */node_modules/*) return 0 ;;
    */.venv | */.venv/* | */.uv-cache | */.uv-cache/*) return 0 ;;
    *) return 1 ;;
  esac
}

append_manifest_path() {
  local path="$1"
  [[ "$path" != /* && "$path" != ../* && "$path" != */../* ]] ||
    fail "unsafe repository path: $path"
  [[ "$path" != *$'\n'* ]] ||
    fail "the baseline runner does not support filenames containing newlines"
  [[ -e "$workspace_root/$path" || -L "$workspace_root/$path" ]] || return 0
  is_protected_path "$path" && return 0
  printf "%s\n" "$path" >>"$source_manifest_unsorted"
}

build_manifests() {
  source_manifest="$(mktemp "${TMPDIR:-/tmp}/npm-remote-source.XXXXXX")"
  source_manifest_unsorted="$(mktemp "${TMPDIR:-/tmp}/npm-remote-source-unsorted.XXXXXX")"
  tracked_manifest="$(mktemp "${TMPDIR:-/tmp}/npm-remote-tracked.XXXXXX")"
  : >"$source_manifest_unsorted"
  : >"$tracked_manifest"

  local path approved
  while IFS= read -r -d "" path; do
    if [[ "/$path" == */.npmrc ]]; then
      [[ "$REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC" == "1" ]] ||
        fail "tracked $path is excluded unless REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC=1 confirms it contains no credentials"
      [[ -e "$workspace_root/$path" || -L "$workspace_root/$path" ]] || continue
      printf "%s\n" "$path" >>"$source_manifest_unsorted"
      printf "%s\0" "$path" >>"$tracked_manifest"
    else
      append_manifest_path "$path"
      if ! is_protected_path "$path" &&
        [[ -e "$workspace_root/$path" || -L "$workspace_root/$path" ]]; then
        printf "%s\0" "$path" >>"$tracked_manifest"
      fi
    fi
  done < <(git -C "$workspace_root" ls-files -z --cached)

  for approved in "${REMOTE_RUNNER_UNTRACKED_ALLOWLIST[@]}"; do
    [[ "$approved" != /* && "$approved" != ../* && "$approved" != */../* ]] ||
      fail "unsafe untracked allowlist path: $approved"
    while IFS= read -r -d "" path; do
      append_manifest_path "$path"
    done < <(git -C "$workspace_root" ls-files -z --others --exclude-standard -- "$approved")
  done

  LC_ALL=C sort -u "$source_manifest_unsorted" -o "$source_manifest"
  [[ -s "$source_manifest" ]] || fail "source manifest is empty"

  tracked_git_dir="$(mktemp -d "${TMPDIR:-/tmp}/npm-remote-git.XXXXXX")"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git init --bare -q "$tracked_git_dir"
  tracked_index="$tracked_git_dir/index"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_INDEX_FILE="$tracked_index" \
    git --git-dir="$tracked_git_dir" --work-tree="$workspace_root" \
    -c core.autocrlf=false -c core.safecrlf=false \
    -c core.attributesFile=/dev/null read-tree --empty
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_INDEX_FILE="$tracked_index" \
    git --git-dir="$tracked_git_dir" --work-tree="$workspace_root" \
    -c core.autocrlf=false -c core.safecrlf=false \
    -c core.attributesFile=/dev/null --literal-pathspecs \
    add --pathspec-from-file="$tracked_manifest" --pathspec-file-nul
  tracked_tree="$(
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_INDEX_FILE="$tracked_index" \
      git --git-dir="$tracked_git_dir" --work-tree="$workspace_root" \
      -c core.autocrlf=false -c core.safecrlf=false \
      -c core.attributesFile=/dev/null write-tree
  )"
  tracked_identity="$(mktemp "${TMPDIR:-/tmp}/npm-remote-tree.XXXXXX")"
  printf "%s\n" "$tracked_tree" >"$tracked_identity"
}

make_remote_slot() {
  local workspace_name workspace_hash repository_hash repository_key repository_name local_machine_identity
  workspace_name="$(printf "%s" "$(basename "$workspace_root")" | tr -c "[:alnum:]._" "-")"
  repository_key="$(git -C "$workspace_root" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$repository_key" ]]; then
    repository_key="$(git_common_directory "$workspace_root")"
  fi
  repository_name="$(basename "${repository_key%.git}" | tr -c "[:alnum:]._" "-")"
  repository_hash="$(printf "%s" "$repository_key" | shasum -a 256 | cut -c1-12)"
  repository_cache_name="${repository_name}-${repository_hash}"
  local_machine_identity="$(
    printf "%s:%s" "$(id -u)" "$(scutil --get LocalHostName 2>/dev/null || hostname)"
  )"
  workspace_hash="$(
    printf "%s:%s" "$local_machine_identity" "$workspace_root" | shasum -a 256 | cut -c1-12
  )"
  remote_slot_name="${workspace_name}-${workspace_hash}"
  remote_slot="${REMOTE_RUNNER_BASE_DIR}/${remote_slot_name}"
  local_lock_file="/tmp/npm-remote-runner-${workspace_hash}.lock"
  job_id="$(date -u +%Y%m%dT%H%M%SZ)-${workspace_hash}-$$"
}

wait_for_local_lock() {
  local waited=0
  while ! shlock -f "$local_lock_file" -p "$$"; do
    if ((waited >= REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT)); then
      fail "timed out waiting ${REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT}s for the local runner lock"
    fi
    sleep 1
    waited=$((waited + 1))
    if ((waited % 10 == 0)); then
      printf "Another request is using this worktree; still waiting...\n" >&2
    fi
  done
}

cleanup() {
  [[ -z "${local_lock_file:-}" ]] || rm -f "$local_lock_file"
  [[ -z "${source_manifest:-}" ]] || rm -f "$source_manifest"
  [[ -z "${source_manifest_unsorted:-}" ]] || rm -f "$source_manifest_unsorted"
  [[ -z "${tracked_manifest:-}" ]] || rm -f "$tracked_manifest"
  [[ -z "${tracked_index:-}" ]] || rm -f "$tracked_index"
  [[ -z "${tracked_git_dir:-}" ]] || rm -rf "$tracked_git_dir"
  [[ -z "${tracked_identity:-}" ]] || rm -f "$tracked_identity"
  [[ -z "${run_arguments_file:-}" ]] || rm -f "$run_arguments_file"
  [[ -z "${uv_projects_file:-}" ]] || rm -f "$uv_projects_file"
}

doctor() {
  require_local_tools
  resolve_workspace
  resolve_node_version
  validate_configuration
  build_ssh_configuration

  ssh "${ssh_arguments[@]}" "$remote_target" "/bin/bash -s -- $node_version" <<'REMOTE'
set -euo pipefail
version="$1"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
command -v fnm >/dev/null 2>&1 || {
  printf "fnm=missing; run bootstrap\n"
  exit 2
}
node_path="$(fnm exec --using "$version" -- node -p 'process.execPath' 2>/dev/null || true)"
node_bin="$(dirname "$node_path")"
remote_node="$node_bin/node"
printf "host=%s\n" "$(scutil --get ComputerName 2>/dev/null || hostname)"
printf "user=%s\n" "$(id -un)"
printf "os=%s\n" "$(sw_vers -productVersion)"
printf "arch=%s\n" "$(uname -m)"
printf "logical_cores=%s\n" "$(sysctl -n hw.logicalcpu)"
printf "memory_bytes=%s\n" "$(sysctl -n hw.memsize)"
printf "node=%s\n" "$("$remote_node" --version 2>/dev/null || printf missing)"
if [[ "$("$remote_node" --version 2>/dev/null || true)" != "v$version" ]]; then
  printf "status=node-mismatch; run bootstrap\n"
  exit 2
fi
printf "status=ready\n"
REMOTE
}

bootstrap() {
  require_local_tools
  resolve_workspace
  resolve_node_version
  validate_configuration
  build_ssh_configuration

  ssh "${ssh_arguments[@]}" "$remote_target" "/bin/bash -s -- $node_version" <<'REMOTE'
set -euo pipefail
version="$1"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if ! command -v fnm >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || {
    printf "Homebrew is required once to install fnm: https://brew.sh\n" >&2
    exit 2
  }
  brew install fnm
fi

fnm install "$version"
node_path="$(fnm exec --using "$version" -- node -p 'process.execPath')"
node_bin="$(dirname "$node_path")"
printf "installed=%s node=%s\n" "$version" "$("$node_bin/node" --version)"
REMOTE

  doctor
}

prepare_remote_snapshot() {
  ssh "${ssh_arguments[@]}" "$remote_target" \
    "/bin/bash -s -- $REMOTE_RUNNER_BASE_DIR $remote_slot_name" <<'REMOTE'
set -euo pipefail
base_dir="$1"
slot_name="$2"
case "$base_dir" in
  Library/Caches/npm-remote-runner-macos | Library/Caches/npm-remote-runner-macos/*) ;;
  *) printf "Unsafe remote base: %s\n" "$base_dir" >&2; exit 2 ;;
esac
case "/$base_dir/" in
  *"/../"* | *"/./"* | *"//"*) printf "Unsafe remote base components.\n" >&2; exit 2 ;;
esac
[[ "$slot_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf "Unsafe remote slot: %s\n" "$slot_name" >&2
  exit 2
}
runner_root="$HOME/$base_dir"
mkdir -p "$runner_root"
chmod 700 "$runner_root"
canonical_root="$(cd "$runner_root" && pwd -P)"
[[ "$canonical_root" == "$runner_root" ]] || {
  printf "Remote cache path contains a symlink: %s\n" "$runner_root" >&2
  exit 2
}
marker="$runner_root/.npm-remote-runner-owned"
if [[ ! -e "$marker" ]]; then
  initialization_lock="$runner_root/.initializing"
  if mkdir "$initialization_lock" 2>/dev/null; then
    existing="$(
      find "$runner_root" -mindepth 1 -maxdepth 1 \
        ! -name ".initializing" ! -name ".npm-remote-runner-owned" -print -quit
    )"
    if [[ -n "$existing" ]]; then
      rmdir "$initialization_lock"
      printf "Remote cache is non-empty and has no ownership marker: %s\n" "$runner_root" >&2
      exit 2
    fi
    : >"$marker"
    rmdir "$initialization_lock"
  else
    waited=0
    while [[ ! -f "$marker" && -d "$initialization_lock" && "$waited" -lt 100 ]]; do
      sleep 0.1
      waited=$((waited + 1))
    done
  fi
fi
[[ -f "$marker" && ! -L "$marker" ]] || {
  printf "Invalid remote cache ownership marker.\n" >&2
  exit 2
}
base="$runner_root/$slot_name"
[[ ! -L "$base" ]] || {
  printf "Remote slot must not be a symlink: %s\n" "$base" >&2
  exit 2
}
mkdir -p "$base/meta"
canonical_base="$(cd "$base" && pwd -P)"
canonical_meta="$(cd "$base/meta" && pwd -P)"
[[ "$canonical_base" == "$base" && "$canonical_meta" == "$base/meta" ]] || {
  printf "Remote slot contains a symlink.\n" >&2
  exit 2
}
[[ ! -L "$base/source.next" ]] || {
  printf "Remote staging path must not be a symlink.\n" >&2
  exit 2
}
rm -rf "$base/source.next"
mkdir -p "$base/source.next"
REMOTE

  retry_transport rsync -acz -e "$rsync_transport" \
    "$source_manifest" "$remote_target:$remote_slot/meta/source-manifest.next"
  retry_transport rsync -acz -e "$rsync_transport" \
    "$tracked_manifest" "$remote_target:$remote_slot/meta/tracked-manifest.next"
  retry_transport rsync -acz -e "$rsync_transport" \
    "$tracked_identity" "$remote_target:$remote_slot/meta/tracked-tree.next"
  retry_transport rsync -acz --checksum --delete-delay --delay-updates \
    --files-from="$source_manifest" -e "$rsync_transport" \
    "$workspace_root/" "$remote_target:$remote_slot/source.next/"

  local checksum_difference
  checksum_difference="$(
    rsync -rlcni --files-from="$source_manifest" -e "$rsync_transport" \
      "$workspace_root/" "$remote_target:$remote_slot/source.next/"
  )"
  [[ -z "$checksum_difference" ]] ||
    fail "remote source differs after sync: ${checksum_difference:0:500}"
  printf "source_status=byte-identical\n"
}

run_remote() {
  [[ "$#" -gt 0 ]] || fail "run requires a command"
  require_local_tools
  resolve_workspace
  resolve_node_version
  validate_configuration
  build_ssh_configuration
  make_remote_slot
  if ! retry_transport ssh "${ssh_arguments[@]}" "$remote_target" true >/dev/null 2>&1; then
    fail "remote host is unreachable; no sync or test started"
  fi
  wait_for_local_lock
  local_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/npm-remote-runner-macos"
  mkdir -p "$local_state_dir"
  chmod 700 "$local_state_dir"
  local_run_log="$local_state_dir/runs.log"
  terminal_recorded=0
  printf "%s job=%s state=started command=%s argumentCount=%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$1" "$#" >>"$local_run_log"
  record_local_terminal() {
    local status=$?
    if [[ "${terminal_recorded:-0}" == "0" ]]; then
      printf "%s job=%s state=interrupted status=%s\n" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$status" >>"$local_run_log"
    fi
    cleanup
  }
  trap record_local_terminal EXIT
  trap "exit 129" HUP
  trap "exit 130" INT
  trap "exit 143" TERM
  build_manifests

  prepare_remote_snapshot
  run_arguments_file="$(mktemp "${TMPDIR:-/tmp}/npm-remote-arguments.XXXXXX")"
  printf "%s\0" "$node_version" "$workspace_relative_directory" "$@" >"$run_arguments_file"
  retry_transport rsync -acz -e "$rsync_transport" \
    "$run_arguments_file" "$remote_target:$remote_slot/meta/run-arguments.next"
  uv_projects_file="$(mktemp "${TMPDIR:-/tmp}/npm-remote-uv-projects.XXXXXX")"
  : >"$uv_projects_file"
  for uv_project in "${REMOTE_RUNNER_UV_PROJECTS[@]}"; do
    [[ "$uv_project" != /* && "$uv_project" != ../* && "$uv_project" != */../* ]] ||
      fail "unsafe REMOTE_RUNNER_UV_PROJECTS entry: $uv_project"
    printf "%s\n" "$uv_project" >>"$uv_projects_file"
  done
  retry_transport rsync -acz -e "$rsync_transport" \
    "$uv_projects_file" "$remote_target:$remote_slot/meta/uv-projects.next"
  rm -f "$uv_projects_file"
  uv_projects_file=""

  set +e
  ssh "${ssh_arguments[@]}" "$remote_target" \
    "/bin/bash -s -- $REMOTE_RUNNER_BASE_DIR $remote_slot_name $repository_cache_name $REMOTE_RUNNER_REMOTE_LOCK_TIMEOUT $REMOTE_RUNNER_SETUP_TIMEOUT $REMOTE_RUNNER_JOB_TIMEOUT $job_id" <<'REMOTE'
set -euo pipefail
base_dir="$1"
slot_name="$2"
repository_cache_name="$3"
remote_lock_timeout="$4"
setup_timeout="$5"
job_timeout="$6"
job_id="$7"
case "$base_dir" in
  Library/Caches/npm-remote-runner-macos | Library/Caches/npm-remote-runner-macos/*) ;;
  *) printf "Unsafe remote base: %s\n" "$base_dir" >&2; exit 2 ;;
esac
case "/$base_dir/" in
  *"/../"* | *"/./"* | *"//"*) printf "Unsafe remote base components.\n" >&2; exit 2 ;;
esac
[[ "$slot_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf "Unsafe remote slot: %s\n" "$slot_name" >&2
  exit 2
}
[[ "$repository_cache_name" =~ ^[A-Za-z0-9._-]+$ ]] ||
  { printf "Unsafe repository cache name.\n" >&2; exit 2; }
for value in "$remote_lock_timeout" "$setup_timeout" "$job_timeout"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { printf "Invalid runner deadline.\n" >&2; exit 2; }
done
[[ "$job_id" =~ ^[A-Za-z0-9._-]+$ ]] || { printf "Unsafe job identity.\n" >&2; exit 2; }

runner_root="$HOME/$base_dir"
canonical_root="$(cd "$runner_root" && pwd -P)"
[[ "$canonical_root" == "$runner_root" ]] ||
  { printf "Remote cache path contains a symlink.\n" >&2; exit 2; }
[[ -f "$runner_root/.npm-remote-runner-owned" &&
  ! -L "$runner_root/.npm-remote-runner-owned" ]] ||
  { printf "Remote cache ownership marker is missing.\n" >&2; exit 2; }
base="$runner_root/$slot_name"
[[ ! -L "$base" ]] || { printf "Remote slot is a symlink.\n" >&2; exit 2; }
canonical_base="$(cd "$base" && pwd -P)"
[[ "$canonical_base" == "$base" ]] ||
  { printf "Remote slot contains a symlink.\n" >&2; exit 2; }
workspace="$base/source"
next_workspace="$base/source.next"
log_dir="$runner_root/logs"
mkdir -p "$log_dir"
chmod 700 "$log_dir"
job_log="$log_dir/$job_id.log"
printf "phase=remote-started time=%s pid=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" >>"$job_log"
remote_terminal=0
record_remote_terminal() {
  local status=$?
  if [[ "$remote_terminal" == "0" ]]; then
    printf "phase=remote-exited time=%s status=%s\n" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" >>"$job_log"
  fi
}
trap record_remote_terminal EXIT HUP INT TERM
[[ -d "$base/meta" && ! -L "$base/meta" ]] ||
  { printf "Remote metadata directory is unsafe.\n" >&2; exit 2; }
[[ -d "$next_workspace" && ! -L "$next_workspace" ]] ||
  { printf "Synced source snapshot is missing or unsafe.\n" >&2; exit 2; }
canonical_next="$(cd "$next_workspace" && pwd -P)"
[[ "$canonical_next" == "$next_workspace" ]] ||
  { printf "Synced source snapshot contains a path redirection.\n" >&2; exit 2; }

declare -a run_values=()
while IFS= read -r -d "" value; do
  run_values+=("$value")
done <"$base/meta/run-arguments.next"
[[ "${#run_values[@]}" -ge 3 ]] ||
  { printf "Remote command arguments are incomplete.\n" >&2; exit 2; }
node_version="${run_values[0]}"
relative_directory="${run_values[1]}"
command_arguments=("${run_values[@]:2}")

[[ "$(uname -s)" == "Darwin" ]] || {
  printf "Remote host must run macOS.\n" >&2
  exit 2
}
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
command -v fnm >/dev/null 2>&1 ||
  { printf "fnm is missing; run bootstrap first.\n" >&2; exit 2; }
node_path="$(fnm exec --using "$node_version" -- node -p 'process.execPath' 2>/dev/null || true)"
node_bin="$(dirname "$node_path")"
[[ "$("$node_bin/node" --version 2>/dev/null || true)" == "v$node_version" ]] || {
  printf "Remote Node must be v%s; run bootstrap first.\n" "$node_version" >&2
  exit 2
}
clean_path="$node_bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
runner_home="$base/runtime-home"
mkdir -p "$runner_home"
chmod 700 "$runner_home"
uv_download_cache="$runner_root/uv-cache/$repository_cache_name"
[[ ! -L "$runner_root/uv-cache" && ! -L "$uv_download_cache" ]] ||
  { printf "uv download cache path is unsafe.\n" >&2; exit 2; }
mkdir -p "$uv_download_cache"
clean_environment=(
  env -i
  "HOME=$runner_home"
  "USER=$(id -un)"
  "LOGNAME=$(id -un)"
  "PATH=$clean_path"
  "TMPDIR=${TMPDIR:-/tmp}"
  "LANG=en_US.UTF-8"
  "GIT_CONFIG_GLOBAL=/dev/null"
  "GIT_CONFIG_NOSYSTEM=1"
  "UV_CACHE_DIR=$uv_download_cache"
)

# One test process at a time in this runner cache. The lock is released by the
# kernel when this process exits, including after a lost SSH connection.
lock_path="$runner_root/.execution.lock"
[[ ! -L "$lock_path" ]] || { printf "Remote lock is a symlink.\n" >&2; exit 2; }
: >>"$lock_path"
chmod 600 "$lock_path"
[[ -f "$lock_path" && ! -L "$lock_path" ]] ||
  { printf "Remote lock is not a regular file.\n" >&2; exit 2; }
exec 9<>"$lock_path"
waited=0
while ! lockf -s -t 0 9; do
  if ((waited >= remote_lock_timeout)); then
    printf "Timed out waiting %ss for the remote runner lock.\n" "$remote_lock_timeout" >&2
    ps -axo pid=,ppid=,pgid=,stat=,%cpu=,%mem=,etime=,comm= >&2 || true
    exit 75
  fi
  sleep 1
  waited=$((waited + 1))
  if ((waited % 10 == 0)); then
    printf "Another test is using the remote Mac; still waiting...\n" >&2
  fi
done

# Every run starts from the verified source snapshot. Dependencies are cloned
# from a separate pristine cache below.
[[ ! -L "$workspace" ]] || { printf "Remote workspace is a symlink.\n" >&2; exit 2; }
rm -rf "$workspace"
mv "$next_workspace" "$workspace"

mv "$base/meta/source-manifest.next" "$base/meta/source-manifest"
mv "$base/meta/tracked-manifest.next" "$base/meta/tracked-manifest"
mv "$base/meta/tracked-tree.next" "$base/meta/tracked-tree"

cd "$workspace"
if [[ ! -d .git ]]; then
  "${clean_environment[@]}" git init -q
  "${clean_environment[@]}" git config user.name "Remote Test Runner"
  "${clean_environment[@]}" git config user.email "remote-test@fake.invalid"
fi
"${clean_environment[@]}" git -c core.autocrlf=false -c core.safecrlf=false \
  -c core.attributesFile=/dev/null read-tree --empty
"${clean_environment[@]}" git -c core.autocrlf=false -c core.safecrlf=false \
  -c core.attributesFile=/dev/null --literal-pathspecs \
  add --pathspec-from-file="$base/meta/tracked-manifest" --pathspec-file-nul
expected_tree="$(<"$base/meta/tracked-tree")"
actual_tree="$(
  "${clean_environment[@]}" git -c core.autocrlf=false -c core.safecrlf=false \
    -c core.attributesFile=/dev/null write-tree
)"
[[ "$actual_tree" == "$expected_tree" ]] || {
  printf "Remote tracked tree differs: expected %s, got %s\n" "$expected_tree" "$actual_tree" >&2
  exit 2
}
printf "phase=source-verified time=%s tree=%s\n" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$actual_tree" >>"$job_log"
if ! "${clean_environment[@]}" git rev-parse --verify HEAD >/dev/null 2>&1 ||
  ! "${clean_environment[@]}" git diff --cached --quiet; then
  "${clean_environment[@]}" git -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    commit -q --allow-empty -m "remote test snapshot"
fi

run_bounded() {
  local seconds="$1"
  shift
  "$node_bin/node" - "$seconds" "$job_log" "$@" <<'NODE_DEADLINE'
const { createWriteStream } = require("node:fs");
const { spawn, spawnSync } = require("node:child_process");
const [secondsText, logPath, command, ...args] = process.argv.slice(2);
const startedAt = Date.now();
const log = createWriteStream(logPath, { flags: "a" });
const child = spawn(command, args, { detached: true, stdio: ["ignore", "pipe", "pipe"] });
let expired = false;
let settled = false;
let killTimer;
const emit = (stream, value) => {
  stream.write(value);
  log.write(value);
};
const signalGroup = (signal = "SIGTERM") => {
  if (child.pid === undefined) return;
  try {
    process.kill(-child.pid, signal);
  } catch {}
};
const terminate = () => {
  expired = true;
  signalGroup();
  killTimer = setTimeout(() => signalGroup("SIGKILL"), 5000);
};
process.stdout.once("error", terminate);
process.stderr.once("error", terminate);
for (const signal of ["SIGHUP", "SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    terminate();
    process.exitCode = 128;
  });
}
emit(
  process.stderr,
  `phase=command-started time=${new Date().toISOString()} pid=${child.pid} command=${JSON.stringify(command)} argumentCount=${args.length}\n`,
);
child.stdout.on("data", (chunk) => emit(process.stdout, chunk));
child.stderr.on("data", (chunk) => emit(process.stderr, chunk));
const timer = setTimeout(() => {
  expired = true;
  emit(process.stderr, `Command exceeded ${secondsText}s; process snapshot follows.\n`);
  const snapshot = spawnSync(
    "ps",
    ["-axo", "pid=,ppid=,pgid=,stat=,%cpu=,%mem=,etime=,comm="],
    { encoding: "utf8" },
  );
  const rows = (snapshot.stdout || "")
    .split("\n")
    .filter((row) => row.trim().split(/\s+/)[2] === String(child.pid))
    .join("\n");
  emit(process.stderr, `${rows || snapshot.stderr || "process group returned no rows"}\n`);
  signalGroup();
  killTimer = setTimeout(() => signalGroup("SIGKILL"), 5000);
}, Number(secondsText) * 1000);
child.once("error", (error) => {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  emit(process.stderr, `Command failed to start: ${error.message}\n`);
  log.end(() => process.exit(2));
});
child.once("exit", (code, signal) => {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  if (killTimer !== undefined) clearTimeout(killTimer);
  let status = expired ? 124 : (code ?? 2);
  let checks = 0;
  const finish = () => {
    emit(
      process.stderr,
      `phase=command-completed time=${new Date().toISOString()} status=${status} signal=${signal ?? "none"} elapsedMs=${Date.now() - startedAt}\n`,
    );
    log.end(() => process.exit(status));
  };
  const reapGroup = () => {
    signalGroup("SIGKILL");
    let alive = false;
    try {
      if (child.pid !== undefined) process.kill(-child.pid, 0);
      alive = child.pid !== undefined;
    } catch {}
    if (!alive) return finish();
    checks += 1;
    if (checks >= 50) {
      status = 124;
      emit(process.stderr, `Process group ${child.pid} survived SIGKILL for 5s.\n`);
      return finish();
    }
    setTimeout(reapGroup, 100);
  };
  reapGroup();
});
NODE_DEADLINE
}

quiet_setup() {
  local step_log status
  step_log="$(mktemp /tmp/npm-remote-step.XXXXXX)"
  if run_bounded "$setup_timeout" "$@" >"$step_log" 2>&1; then
    cat "$step_log" >>"$job_log"
    rm -f "$step_log"
    return 0
  fi
  status=$?
  cat "$step_log" >>"$job_log"
  cat "$step_log" >&2
  rm -f "$step_log"
  return "$status"
}

[[ -f package.json && -f package-lock.json ]] || {
  printf "The baseline runner requires package.json and package-lock.json; adapt it for this repository.\n" >&2
  exit 2
}

dependency_identity="$(
  {
    printf "identity-v3\nnode=%s\nnpm=%s\nos=%s\nos_version=%s\nkernel=%s\narch=%s\n" \
      "$("$node_bin/node" --version)" "$("${clean_environment[@]}" npm --version)" \
      "$(uname -s)" "$(sw_vers -productVersion)" "$(uname -r)" "$(uname -m)"
    shasum -a 256 package.json package-lock.json
    while IFS= read -r -d "" tracked_path; do
      if [[ "/$tracked_path" == */.npmrc ]]; then
        printf "%s=" "$tracked_path"
        shasum -a 256 "$tracked_path" | cut -d " " -f 1
      fi
    done <"$base/meta/tracked-manifest"
  } | shasum -a 256 | cut -d " " -f 1
)"
repository_dependency_root="$runner_root/dependencies/$repository_cache_name"
dependency_root="$repository_dependency_root/$dependency_identity"
[[ ! -L "$runner_root/dependencies" && ! -L "$repository_dependency_root" &&
  ! -L "$dependency_root" ]] ||
  { printf "Dependency cache path is unsafe.\n" >&2; exit 2; }
mkdir -p "$repository_dependency_root"
if [[ -d "$dependency_root/node_modules" && ! -L "$dependency_root/node_modules" ]]; then
  cp -cR "$dependency_root/node_modules" "$workspace/node_modules"
fi
if [[ ! -d node_modules ]] ||
  ! run_bounded "$setup_timeout" "${clean_environment[@]}" npm ls --all --json \
    >/dev/null 2>&1; then
  rm -rf node_modules
  quiet_setup "${clean_environment[@]}" npm ci --no-audit --no-fund
  run_bounded "$setup_timeout" "${clean_environment[@]}" npm ls --all --json \
    >/dev/null 2>&1
  dependency_next="$repository_dependency_root/${dependency_identity}.next"
  [[ ! -L "$dependency_next" ]] ||
    { printf "Dependency staging path is unsafe.\n" >&2; exit 2; }
  rm -rf "$dependency_next"
  mkdir -p "$dependency_next"
  cp -cR node_modules "$dependency_next/node_modules"
  rm -rf "$dependency_root"
  mv "$dependency_next" "$dependency_root"
fi
printf "phase=dependencies-ready time=%s identity=%s\n" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dependency_identity" >>"$job_log"

# Secondary toolchains use one shared download cache, but never share a virtualenv:
# uv project installs are editable by default and retain their source path.
if [[ -f "$base/meta/uv-projects.next" ]]; then
  mv "$base/meta/uv-projects.next" "$base/meta/uv-projects"
fi
if [[ -f "$base/meta/uv-projects" ]]; then
  while IFS= read -r uv_project || [[ -n "$uv_project" ]]; do
    [[ -n "$uv_project" ]] || continue
    [[ "$uv_project" != /* && "$uv_project" != ../* && "$uv_project" != */../* ]] ||
      { printf "Unsafe uv project path: %s\n" "$uv_project" >&2; exit 2; }
    if [[ ! -f "$uv_project/pyproject.toml" || ! -f "$uv_project/uv.lock" ]]; then
      printf "Configured uv project is missing pyproject.toml or uv.lock: %s\n" \
        "$uv_project" >&2
      exit 2
    fi
    if ! command -v uv >/dev/null 2>&1; then
      printf "uv is required on the remote Mac for project %s\n" "$uv_project" >&2
      exit 2
    fi
    rm -rf "$uv_project/.venv"
    quiet_setup "${clean_environment[@]}" uv sync --project "$uv_project" --frozen
    [[ -x "$uv_project/.venv/bin/python" ]] ||
      { printf "uv sync did not produce a usable venv at %s/.venv\n" "$uv_project" >&2; exit 2; }
  done <"$base/meta/uv-projects"
fi

if [[ -n "$relative_directory" ]]; then
  cd "$relative_directory"
fi

set +e
run_bounded "$job_timeout" "${clean_environment[@]}" caffeinate -i -- "${command_arguments[@]}"
result=$?
set -e
printf "phase=remote-completed time=%s status=%s\n" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" >>"$job_log"
remote_terminal=1
exit "$result"
REMOTE
  local result=$?
  set -e

  printf "copyback_status=disabled-in-baseline\n"
  printf "remote_log=~/%s/logs/%s.log\n" "$REMOTE_RUNNER_BASE_DIR" "$job_id"
  printf "%s job=%s state=completed status=%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$result" >>"$local_run_log"
  terminal_recorded=1
  cleanup
  trap - EXIT HUP INT TERM
  return "$result"
}

task="${1:-}"
[[ -n "$task" ]] || {
  usage
  exit 2
}
shift

case "$task" in
  doctor) doctor ;;
  bootstrap) bootstrap ;;
  test) run_remote npm test -- "$@" ;;
  run)
    [[ "${1:-}" != "--" ]] || shift
    run_remote "$@"
    ;;
  help | --help | -h) usage ;;
  *) usage; exit 2 ;;
esac
