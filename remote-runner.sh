#!/usr/bin/env bash

# Generic npm-on-macOS baseline. Copy this file to a personal tools directory
# and adapt the configuration and routing for each selected repository.

set -euo pipefail

declare -a REMOTE_RUNNER_ALLOWED_ROOTS=()
declare -a REMOTE_RUNNER_UNTRACKED_ALLOWLIST=()

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
REMOTE_RUNNER_CONNECT_TIMEOUT="${REMOTE_RUNNER_CONNECT_TIMEOUT:-10}"
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
  REMOTE_RUNNER_UNTRACKED_ALLOWLIST=(
    "generated-public-fixtures/"
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
    append_manifest_path "$path"
    if ! is_protected_path "$path" &&
      [[ -e "$workspace_root/$path" || -L "$workspace_root/$path" ]]; then
      printf "%s\0" "$path" >>"$tracked_manifest"
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
}

make_remote_slot() {
  local workspace_name workspace_hash local_machine_identity
  workspace_name="$(printf "%s" "$(basename "$workspace_root")" | tr -c "[:alnum:]._" "-")"
  local_machine_identity="$(
    printf "%s:%s" "$(id -u)" "$(scutil --get LocalHostName 2>/dev/null || hostname)"
  )"
  workspace_hash="$(
    printf "%s:%s" "$local_machine_identity" "$workspace_root" | shasum -a 256 | cut -c1-12
  )"
  remote_slot_name="${workspace_name}-${workspace_hash}"
  remote_slot="${REMOTE_RUNNER_BASE_DIR}/${remote_slot_name}"
  local_lock_file="/tmp/npm-remote-runner-${workspace_hash}.lock"
}

wait_for_local_lock() {
  local waited=0
  while ! shlock -f "$local_lock_file" -p "$$"; do
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
  [[ -z "${run_arguments_file:-}" ]] || rm -f "$run_arguments_file"
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

  rsync -acz -e "$rsync_transport" \
    "$source_manifest" "$remote_target:$remote_slot/meta/source-manifest.next"
  rsync -acz -e "$rsync_transport" \
    "$tracked_manifest" "$remote_target:$remote_slot/meta/tracked-manifest.next"
  rsync -acz --files-from="$source_manifest" -e "$rsync_transport" \
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
  wait_for_local_lock
  trap cleanup EXIT
  trap "exit 129" HUP
  trap "exit 130" INT
  trap "exit 143" TERM
  build_manifests

  prepare_remote_snapshot
  run_arguments_file="$(mktemp "${TMPDIR:-/tmp}/npm-remote-arguments.XXXXXX")"
  printf "%s\0" "$node_version" "$workspace_relative_directory" "$@" >"$run_arguments_file"
  rsync -acz -e "$rsync_transport" \
    "$run_arguments_file" "$remote_target:$remote_slot/meta/run-arguments.next"

  set +e
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
clean_environment=(
  env -i
  "HOME=$runner_home"
  "USER=$(id -un)"
  "LOGNAME=$(id -un)"
  "PATH=$clean_path"
  "TMPDIR=${TMPDIR:-/tmp}"
  "LANG=en_US.UTF-8"
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

cd "$workspace"
if [[ ! -d .git ]]; then
  "${clean_environment[@]}" git init -q
  "${clean_environment[@]}" git config user.name "Remote Test Runner"
  "${clean_environment[@]}" git config user.email "remote-test@fake.invalid"
fi
"${clean_environment[@]}" git read-tree --empty
"${clean_environment[@]}" git --literal-pathspecs \
  add --pathspec-from-file="$base/meta/tracked-manifest" --pathspec-file-nul
if ! "${clean_environment[@]}" git rev-parse --verify HEAD >/dev/null 2>&1 ||
  ! "${clean_environment[@]}" git diff --cached --quiet; then
  "${clean_environment[@]}" git -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    commit -q --allow-empty -m "remote test snapshot"
fi

[[ -f package.json && -f package-lock.json ]] || {
  printf "The baseline runner requires package.json and package-lock.json; adapt it for this repository.\n" >&2
  exit 2
}

dependency_identity="$(
  {
    printf "identity-v2\nnode=%s\nnpm=%s\nos=%s\nos_version=%s\nkernel=%s\narch=%s\n" \
      "$("$node_bin/node" --version)" "$("${clean_environment[@]}" npm --version)" \
      "$(uname -s)" "$(sw_vers -productVersion)" "$(uname -r)" "$(uname -m)"
    shasum -a 256 package.json package-lock.json
  } | shasum -a 256 | cut -d " " -f 1
)"
dependency_root="$base/dependencies/$dependency_identity"
[[ ! -L "$base/dependencies" && ! -L "$dependency_root" ]] ||
  { printf "Dependency cache path is unsafe.\n" >&2; exit 2; }
mkdir -p "$base/dependencies"
if [[ -d "$dependency_root/node_modules" && ! -L "$dependency_root/node_modules" ]]; then
  cp -cR "$dependency_root/node_modules" "$workspace/node_modules"
fi
if [[ ! -d node_modules ]] ||
  ! "${clean_environment[@]}" npm ls --all --json >/dev/null 2>&1; then
  rm -rf node_modules
  "${clean_environment[@]}" npm ci --no-audit --no-fund
  "${clean_environment[@]}" npm ls --all --json >/dev/null
  dependency_next="$base/dependencies/${dependency_identity}.next"
  [[ ! -L "$dependency_next" ]] ||
    { printf "Dependency staging path is unsafe.\n" >&2; exit 2; }
  rm -rf "$dependency_next"
  mkdir -p "$dependency_next"
  cp -cR node_modules "$dependency_next/node_modules"
  rm -rf "$dependency_root"
  mv "$dependency_next" "$dependency_root"
fi

if [[ -n "$relative_directory" ]]; then
  cd "$relative_directory"
fi

set +e
"${clean_environment[@]}" caffeinate -i -- "${command_arguments[@]}"
result=$?
set -e
exit "$result"
REMOTE
  local result=$?
  set -e

  printf "copyback_status=disabled-in-baseline\n"
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
