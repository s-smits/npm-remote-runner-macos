#!/usr/bin/env bash

# Generic npm- and Bun-on-macOS baseline. Copy this file to a personal tools
# directory and adapt the configuration and routing for each selected repository.

set -euo pipefail

declare -a REMOTE_RUNNER_ALLOWED_ROOTS=()
declare -a REMOTE_RUNNER_UNTRACKED_ALLOWLIST=()
# Relative dirs with pyproject.toml + uv.lock. Virtualenvs are never synced;
# each entry is installed remotely from its lockfile when the identity changes.
declare -a REMOTE_RUNNER_UV_PROJECTS=()
# Relative dirs with their own package.json and lockfile that are not workspace
# members of the root (for example a separately locked UI package). Each entry
# is installed remotely with the same package manager after the root.
declare -a REMOTE_RUNNER_PACKAGE_PROJECTS=()

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
REMOTE_RUNNER_BUN_VERSION="${REMOTE_RUNNER_BUN_VERSION:-}"
REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES="${REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES:-0}"
REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC="${REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC:-0}"
REMOTE_RUNNER_CONNECT_TIMEOUT="${REMOTE_RUNNER_CONNECT_TIMEOUT:-10}"
REMOTE_RUNNER_CONNECT_ATTEMPTS="${REMOTE_RUNNER_CONNECT_ATTEMPTS:-3}"
REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT="${REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT:-900}"
REMOTE_RUNNER_REMOTE_LOCK_TIMEOUT="${REMOTE_RUNNER_REMOTE_LOCK_TIMEOUT:-900}"
REMOTE_RUNNER_SETUP_TIMEOUT="${REMOTE_RUNNER_SETUP_TIMEOUT:-600}"
REMOTE_RUNNER_JOB_TIMEOUT="${REMOTE_RUNNER_JOB_TIMEOUT:-1200}"
# Jobs from different worktrees that may run on the remote Mac at once. Jobs from
# one worktree always run one at a time.
REMOTE_RUNNER_REMOTE_CONCURRENCY="${REMOTE_RUNNER_REMOTE_CONCURRENCY:-1}"
REMOTE_RUNNER_SSH_KEY="${REMOTE_RUNNER_SSH_KEY:-}"

usage() {
  cat <<'USAGE'
Usage:
  remote-runner.sh doctor
  remote-runner.sh bootstrap
  remote-runner.sh test [test arguments...]
  remote-runner.sh run -- <command> [arguments...]

The package manager follows the lockfile: package-lock.json selects npm with an
exact Node version, bun.lock or bun.lockb selects Bun with an exact Bun version.
"test" runs "npm test -- ..." or "bun run test -- ..." accordingly.

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
  REMOTE_RUNNER_REMOTE_CONCURRENCY=1
  REMOTE_RUNNER_UNTRACKED_ALLOWLIST=(
    "generated-public-fixtures/"
  )
  REMOTE_RUNNER_UV_PROJECTS=(
    "tools/verifier"
  )
  REMOTE_RUNNER_PACKAGE_PROJECTS=(
    "packages/ui"
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

resolve_package_manager() {
  if [[ -f "$workspace_root/package-lock.json" ]]; then
    package_manager="npm"
  elif [[ -f "$workspace_root/bun.lock" || -f "$workspace_root/bun.lockb" ]]; then
    package_manager="bun"
  else
    fail "no package-lock.json, bun.lock or bun.lockb in $workspace_root; adapt the runner for this repository"
  fi
}

resolve_bun_version() {
  local pin="$REMOTE_RUNNER_BUN_VERSION"
  if [[ -z "$pin" && -f "$workspace_root/.bun-version" ]]; then
    IFS= read -r pin <"$workspace_root/.bun-version" || true
  fi
  if [[ -z "$pin" ]]; then
    pin="$(
      sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"bun@\([^"]*\)".*/\1/p' \
        "$workspace_root/package.json" 2>/dev/null | head -n 1
    )"
  fi
  pin="${pin#bun-v}"
  pin="${pin#v}"
  [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "set REMOTE_RUNNER_BUN_VERSION, .bun-version or packageManager to an exact Bun version"
  toolchain_version="$pin"
}

# Resolves the package manager and the exact runtime version it needs remotely.
resolve_toolchain() {
  resolve_package_manager
  if [[ "$package_manager" == "bun" ]]; then
    resolve_bun_version
  else
    resolve_node_version
    toolchain_version="$node_version"
  fi
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
  require_positive_integer REMOTE_RUNNER_REMOTE_CONCURRENCY "$REMOTE_RUNNER_REMOTE_CONCURRENCY"
  ((REMOTE_RUNNER_REMOTE_CONCURRENCY <= 16)) ||
    fail "REMOTE_RUNNER_REMOTE_CONCURRENCY must be at most 16"
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
    */.netrc | */.authinfo | */.git-credentials | */.pypirc | */.pgpass) return 0 ;;
    */.gnupg | */.gnupg/* | */.password-store | */.password-store/*) return 0 ;;
    *.tfstate | *.tfstate.* | *.tfvars | */.terraform | */.terraform/*) return 0 ;;
    *.ovpn | *.mobileprovision | *.gpg | */service-account*.json) return 0 ;;
    *.pem | *.key | *.p12 | *.pfx | *.jks | *.keystore | *.agekey | *.kdbx | *.ppk) return 0 ;;
    */id_rsa | */id_dsa | */id_ecdsa | */id_ed25519) return 0 ;;
    */credentials.json | */credentials | */secrets.json | */secrets) return 0 ;;
    */.git | */.git/* | */node_modules | */node_modules/*) return 0 ;;
    */.venv | */.venv/* | */.uv-cache | */.uv-cache/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Names alone cannot catch every secret, so files that are not already in Git
# history (approved untracked paths) and tracked .npmrc files are also scanned
# for literal credentials. Only the file name is reported, never the match.
contains_literal_secret() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  LC_ALL=C grep -I -q -E \
    -e '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' \
    -e '(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Za-z0-9]|$)' \
    -e '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}' \
    -e 'github_pat_[A-Za-z0-9_]{40,}' \
    -e 'glpat-[A-Za-z0-9_-]{20}' \
    -e 'xox[abprs]-[A-Za-z0-9-]{10,}' \
    -e 'npm_[A-Za-z0-9]{36}' \
    -e 'sk-(ant-|proj-|live_)?[A-Za-z0-9_-]{32,}' \
    -e '(_authToken|_auth|_password)[[:space:]]*=[[:space:]]*[^$[:space:]"]' \
    "$file"
}

append_manifest_path() {
  local path="$1"
  [[ "$path" != /* && "$path" != ../* && "$path" != */../* ]] ||
    fail "unsafe repository path: $path"
  [[ "$path" != *$'\n'* ]] ||
    fail "the baseline runner does not support filenames containing newlines"
  [[ -e "$workspace_root/$path" || -L "$workspace_root/$path" ]] || return 0
  is_protected_path "$path" && return 0
  refuse_symlinked_parent "$path"
  printf "%s\n" "$path" >>"$source_manifest_unsorted"
}

# rsync would follow a symlinked parent directory and send whatever it points
# at, possibly outside the worktree. This happens when a branch switch or a
# local change turns a tracked directory into a symlink.
refuse_symlinked_parent() {
  local parent="${1%/*}"
  while [[ "$parent" != "$1" && -n "$parent" ]]; do
    [[ ! -L "$workspace_root/$parent" ]] ||
      fail "$1 lies below the symlinked directory $parent; refusing to sync through it"
    [[ "$parent" == */* ]] || break
    parent="${parent%/*}"
  done
}

warn_unlisted_package_projects() {
  # A tracked lockfile below the root that is not configured is usually a
  # separately locked package whose node_modules would otherwise be missing.
  local path directory listed package_project
  while IFS= read -r -d "" path; do
    case "/$path" in
      */node_modules/*) continue ;;
    esac
    case "$package_manager:/$path" in
      npm:*/package-lock.json | npm:*/npm-shrinkwrap.json | bun:*/bun.lock | bun:*/bun.lockb) ;;
      *) continue ;;
    esac
    directory="$(dirname "$path")"
    [[ "$directory" != "." ]] || continue
    listed=0
    while IFS= read -r package_project; do
      [[ "$package_project" != "$directory" ]] || listed=1
    done <"$job_stage_dir/package-projects"
    [[ "$listed" == "1" ]] ||
      printf "remote-runner: warning: %s is not in REMOTE_RUNNER_PACKAGE_PROJECTS; its dependencies are not installed remotely\n" \
        "$path" >&2
  done <"$tracked_manifest"
}

# The Git tree of the tracked manifest as it is on disk right now, built in an
# isolated index so the user's own index is never touched.
compute_tracked_tree() {
  local tracked_index="$tracked_git_dir/index"
  rm -f "$tracked_index"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_INDEX_FILE="$tracked_index" \
    git --git-dir="$tracked_git_dir" --work-tree="$workspace_root" \
    -c core.autocrlf=false -c core.safecrlf=false \
    -c core.attributesFile=/dev/null read-tree --empty
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_INDEX_FILE="$tracked_index" \
    git --git-dir="$tracked_git_dir" --work-tree="$workspace_root" \
    -c core.autocrlf=false -c core.safecrlf=false \
    -c core.attributesFile=/dev/null --literal-pathspecs \
    add --pathspec-from-file="$tracked_manifest" --pathspec-file-nul
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_INDEX_FILE="$tracked_index" \
    git --git-dir="$tracked_git_dir" --work-tree="$workspace_root" \
    -c core.autocrlf=false -c core.safecrlf=false \
    -c core.attributesFile=/dev/null write-tree
}

build_manifests() {
  # Everything the remote job needs besides source travels in one directory.
  job_stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/npm-remote-job.XXXXXX")"
  source_manifest="$job_stage_dir/source-manifest"
  source_manifest_unsorted="$(mktemp "${TMPDIR:-/tmp}/npm-remote-source-unsorted.XXXXXX")"
  tracked_manifest="$job_stage_dir/tracked-manifest"
  : >"$source_manifest_unsorted"
  : >"$tracked_manifest"

  local path approved
  while IFS= read -r -d "" path; do
    if [[ "/$path" == */.npmrc ]]; then
      [[ "$REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC" == "1" ]] ||
        fail "tracked $path is excluded unless REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC=1 confirms it contains no credentials"
      [[ -e "$workspace_root/$path" || -L "$workspace_root/$path" ]] || continue
      ! contains_literal_secret "$workspace_root/$path" ||
        fail "tracked $path contains what looks like a literal credential; it was not synced"
      refuse_symlinked_parent "$path"
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
      is_protected_path "$path" && continue
      ! contains_literal_secret "$workspace_root/$path" ||
        fail "untracked $path contains what looks like a literal credential; remove it from the allowlist or the file"
      append_manifest_path "$path"
    done < <(git -C "$workspace_root" ls-files -z --others --exclude-standard -- "$approved")
  done

  LC_ALL=C sort -u "$source_manifest_unsorted" -o "$source_manifest"
  [[ -s "$source_manifest" ]] || fail "source manifest is empty"

  tracked_git_dir="$(mktemp -d "${TMPDIR:-/tmp}/npm-remote-git.XXXXXX")"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git init --bare -q "$tracked_git_dir"
  tracked_tree="$(compute_tracked_tree)"
  printf "%s\n" "$tracked_tree" >"$job_stage_dir/tracked-tree"
}

make_remote_slot() {
  local workspace_name workspace_hash repository_hash repository_key repository_name local_machine_identity
  workspace_name="$(printf "%s" "$(basename "$workspace_root")" | tr -c "[:alnum:]._" "-")"
  repository_key="$(git -C "$workspace_root" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$repository_key" ]]; then
    repository_key="$(git_common_directory "$workspace_root")"
  fi
  repository_name="$(printf "%s" "$(basename "${repository_key%.git}")" | tr -c "[:alnum:]._" "-")"
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
  local_lock_file="${TMPDIR:-/tmp}/npm-remote-runner-${workspace_hash}.lock"
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
  [[ -z "${source_manifest_unsorted:-}" ]] || rm -f "$source_manifest_unsorted"
  [[ -z "${tracked_git_dir:-}" ]] || rm -rf "$tracked_git_dir"
  [[ -z "${job_stage_dir:-}" ]] || rm -rf "$job_stage_dir"
}

# Shared by the remote scripts. Bun toolchains live beside, not inside, the
# runner cache so bootstrap never has to claim the cache directory.
remote_toolchain_functions='
toolchain_bin() {
  case "$1" in
    npm)
      command -v fnm >/dev/null 2>&1 || return 1
      local node_path
      node_path="$(fnm exec --using "$2" -- node -p "process.execPath" 2>/dev/null)" || return 1
      dirname "$node_path"
      ;;
    bun) printf "%s\n" "$HOME/Library/Caches/npm-remote-runner-macos-toolchains/bun-$2/bin" ;;
    *) return 1 ;;
  esac
}
toolchain_reported_version() {
  case "$1" in
    npm) "$2/node" --version 2>/dev/null | sed "s/^v//" ;;
    bun) "$2/bun" --version 2>/dev/null ;;
  esac
}
'

doctor() {
  require_local_tools
  resolve_workspace
  resolve_toolchain
  validate_configuration
  build_ssh_configuration

  {
    printf "%s\n" "$remote_toolchain_functions"
    cat <<'REMOTE'
set -euo pipefail
package_manager="$1"
version="$2"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
printf "host=%s\n" "$(scutil --get ComputerName 2>/dev/null || hostname)"
printf "user=%s\n" "$(id -un)"
printf "os=%s\n" "$(sw_vers -productVersion)"
printf "arch=%s\n" "$(uname -m)"
printf "logical_cores=%s\n" "$(sysctl -n hw.logicalcpu)"
printf "memory_bytes=%s\n" "$(sysctl -n hw.memsize)"
printf "free_disk=%s\n" "$(df -h "$HOME" | awk 'NR == 2 { print $4 }')"
printf "rsync=%s\n" "$(command -v rsync || printf missing)"
printf "caffeinate=%s\n" "$(command -v caffeinate || printf missing)"
bin="$(toolchain_bin "$package_manager" "$version" || true)"
reported="$(toolchain_reported_version "$package_manager" "$bin" || true)"
printf "package_manager=%s\n" "$package_manager"
if [[ "$package_manager" == "bun" ]]; then
  printf "bun=%s\n" "${reported:-missing}"
else
  printf "node=%s\n" "${reported:-missing}"
fi
if [[ "$reported" != "$version" ]]; then
  printf "status=toolchain-mismatch expected=%s; run bootstrap\n" "$version"
  exit 2
fi
printf "status=ready\n"
REMOTE
  } | ssh "${ssh_arguments[@]}" "$remote_target" \
    "/bin/bash -s -- $package_manager $toolchain_version"
}

bootstrap() {
  require_local_tools
  resolve_workspace
  resolve_toolchain
  validate_configuration
  build_ssh_configuration

  {
    printf "%s\n" "$remote_toolchain_functions"
    cat <<'REMOTE'
set -euo pipefail
package_manager="$1"
version="$2"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ "$package_manager" == "bun" ]]; then
  bin="$(toolchain_bin bun "$version")"
  if [[ "$(toolchain_reported_version bun "$bin" || true)" != "$version" ]]; then
    case "$(uname -m)" in
      arm64) asset="bun-darwin-aarch64" ;;
      x86_64) asset="bun-darwin-x64" ;;
      *) printf "Unsupported architecture for Bun: %s\n" "$(uname -m)" >&2; exit 2 ;;
    esac
    download_dir="$(mktemp -d "${TMPDIR:-/tmp}/npm-remote-bun.XXXXXX")"
    trap 'rm -rf "${download_dir:?}"' EXIT
    curl -fsSL --retry 3 -o "$download_dir/$asset.zip" \
      "https://github.com/oven-sh/bun/releases/download/bun-v$version/$asset.zip"
    unzip -q "$download_dir/$asset.zip" -d "$download_dir"
    mkdir -p "$bin"
    mv -f "$download_dir/$asset/bun" "$bin/bun"
    chmod 755 "$bin/bun"
  fi
  installed="$(toolchain_reported_version bun "$bin" || true)"
  [[ "$installed" == "$version" ]] ||
    { printf "Bun %s did not install correctly (found %s).\n" "$version" "${installed:-none}" >&2; exit 2; }
  printf "installed=bun-%s\n" "$installed"
  exit 0
fi

if ! command -v fnm >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || {
    printf "Homebrew is required once to install fnm: https://brew.sh\n" >&2
    exit 2
  }
  brew install fnm
fi
fnm install "$version"
bin="$(toolchain_bin npm "$version")"
printf "installed=node-%s\n" "$(toolchain_reported_version npm "$bin")"
REMOTE
  } | ssh "${ssh_arguments[@]}" "$remote_target" \
    "/bin/bash -s -- $package_manager $toolchain_version"

  doctor
}

prepare_remote_snapshot() {
  ssh "${ssh_arguments[@]}" "$remote_target" \
    "/bin/bash -s -- $REMOTE_RUNNER_BASE_DIR $remote_slot_name $job_id" <<'REMOTE'
set -euo pipefail
base_dir="$1"
slot_name="$2"
job_id="$3"
[[ "$job_id" =~ ^[A-Za-z0-9._-]+$ ]] || { printf "Unsafe job identity.\n" >&2; exit 2; }
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
# Each job stages into its own directory, so a sync can never replace files
# under another job from this slot, even one that outlived its SSH session.
[[ ! -L "$base/jobs" ]] || {
  printf "Remote job staging path must not be a symlink.\n" >&2
  exit 2
}
mkdir -p "$base/jobs"
[[ ! -e "$base/jobs/$job_id" ]] || {
  printf "Remote job staging directory already exists: %s\n" "$job_id" >&2
  exit 2
}
mkdir -p "$base/jobs/$job_id/source" "$base/jobs/$job_id/meta"
REMOTE

  local remote_job="$remote_slot/jobs/$job_id"
  retry_transport rsync -rcz -e "$rsync_transport" \
    "$job_stage_dir/" "$remote_target:$remote_job/meta/"
  # Staging starts empty, so ignored output from earlier runs never reappears.
  # --copy-dest lets files that are unchanged since the previous snapshot be
  # copied on the remote Mac instead of over the network.
  retry_transport rsync -az --copy-dest=../../../source \
    --files-from="$source_manifest" -e "$rsync_transport" \
    "$workspace_root/" "$remote_target:$remote_job/source/"

  local checksum_difference
  checksum_difference="$(
    rsync -rlcni --files-from="$source_manifest" -e "$rsync_transport" \
      "$workspace_root/" "$remote_target:$remote_job/source/"
  )"
  if [[ -n "$checksum_difference" ]]; then
    # The size-and-time check missed a change; resend those files by content.
    retry_transport rsync -acz --files-from="$source_manifest" -e "$rsync_transport" \
      "$workspace_root/" "$remote_target:$remote_job/source/"
    checksum_difference="$(
      rsync -rlcni --files-from="$source_manifest" -e "$rsync_transport" \
        "$workspace_root/" "$remote_target:$remote_job/source/"
    )"
  fi
  [[ -z "$checksum_difference" ]] ||
    fail "remote source differs after sync: ${checksum_difference:0:500}"
  printf "source_status=byte-identical\n"
}

run_remote() {
  [[ "$#" -gt 0 ]] || fail "run requires a command"
  require_local_tools
  resolve_workspace
  resolve_toolchain
  validate_configuration
  build_ssh_configuration
  make_remote_slot
  if ! retry_transport ssh "${ssh_arguments[@]}" "$remote_target" true >/dev/null 2>&1; then
    fail "remote host is unreachable; no sync or test started"
  fi
  wait_for_local_lock
  run_started_seconds="$SECONDS"
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

  printf "%s\0" "$package_manager" "$toolchain_version" "$workspace_relative_directory" "$@" \
    >"$job_stage_dir/run-arguments"
  : >"$job_stage_dir/uv-projects"
  for uv_project in "${REMOTE_RUNNER_UV_PROJECTS[@]}"; do
    [[ "$uv_project" != /* && "$uv_project" != ../* && "$uv_project" != */../* ]] ||
      fail "unsafe REMOTE_RUNNER_UV_PROJECTS entry: $uv_project"
    printf "%s\n" "$uv_project" >>"$job_stage_dir/uv-projects"
  done
  : >"$job_stage_dir/package-projects"
  for package_project in "${REMOTE_RUNNER_PACKAGE_PROJECTS[@]}"; do
    package_project="${package_project%/}"
    [[ -n "$package_project" && "$package_project" != "." && "$package_project" != /* &&
      "$package_project" != ../* && "$package_project" != */../* &&
      "$package_project" != .. && "$package_project" != */.. ]] ||
      fail "unsafe REMOTE_RUNNER_PACKAGE_PROJECTS entry: $package_project"
    printf "%s\n" "$package_project" >>"$job_stage_dir/package-projects"
  done
  warn_unlisted_package_projects
  prepare_remote_snapshot
  # The remote copy was verified against the files as they were after the
  # upload. If the worktree changed since the tree was recorded (a branch switch
  # or checkout during sync), the remote copy may be a mix of both versions.
  [[ "$(compute_tracked_tree)" == "$tracked_tree" ]] ||
    fail "the worktree changed while it was being synced (branch switch or checkout?); nothing was run, retry when it is stable"

  set +e
  {
    printf "%s\n" "$remote_toolchain_functions"
    cat <<'REMOTE'
set -euo pipefail
base_dir="$1"
slot_name="$2"
repository_cache_name="$3"
remote_lock_timeout="$4"
setup_timeout="$5"
job_timeout="$6"
job_id="$7"
concurrency="$8"
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
for value in "$remote_lock_timeout" "$setup_timeout" "$job_timeout" "$concurrency"; do
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
job_stage="$base/jobs/$job_id"
next_workspace="$job_stage/source"
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
[[ -d "$base/jobs" && ! -L "$base/jobs" && -d "$job_stage/meta" && ! -L "$job_stage" &&
  ! -L "$job_stage/meta" ]] ||
  { printf "Remote job staging directory is missing or unsafe.\n" >&2; exit 2; }
[[ -d "$next_workspace" && ! -L "$next_workspace" ]] ||
  { printf "Synced source snapshot is missing or unsafe.\n" >&2; exit 2; }
canonical_next="$(cd "$next_workspace" && pwd -P)"
[[ "$canonical_next" == "$next_workspace" ]] ||
  { printf "Synced source snapshot contains a path redirection.\n" >&2; exit 2; }

declare -a run_values=()
while IFS= read -r -d "" value; do
  run_values+=("$value")
done <"$job_stage/meta/run-arguments"
[[ "${#run_values[@]}" -ge 4 ]] ||
  { printf "Remote command arguments are incomplete.\n" >&2; exit 2; }
package_manager="${run_values[0]}"
toolchain_version="${run_values[1]}"
relative_directory="${run_values[2]}"
command_arguments=("${run_values[@]:3}")
[[ "$package_manager" == "npm" || "$package_manager" == "bun" ]] ||
  { printf "Unsupported package manager: %s\n" "$package_manager" >&2; exit 2; }
[[ "$toolchain_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  { printf "Unsupported toolchain version: %s\n" "$toolchain_version" >&2; exit 2; }

[[ "$(uname -s)" == "Darwin" ]] || {
  printf "Remote host must run macOS.\n" >&2
  exit 2
}
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
toolchain_directory="$(toolchain_bin "$package_manager" "$toolchain_version" || true)"
if [[ -z "$toolchain_directory" || "$(toolchain_reported_version "$package_manager" \
  "$toolchain_directory" || true)" != "$toolchain_version" ]]; then
  printf "Remote %s %s is missing; run bootstrap first.\n" \
    "$package_manager" "$toolchain_version" >&2
  exit 2
fi
# The deadline wrapper runs on the repository's own runtime: Node for npm, Bun for Bun.
if [[ "$package_manager" == "bun" ]]; then
  wrapper_runtime="$toolchain_directory/bun"
else
  wrapper_runtime="$toolchain_directory/node"
fi
clean_path="$toolchain_directory:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
runner_home="$base/runtime-home"
mkdir -p "$runner_home"
chmod 700 "$runner_home"
uv_download_cache="$runner_root/uv-cache/$repository_cache_name"
[[ ! -L "$runner_root/uv-cache" && ! -L "$uv_download_cache" ]] ||
  { printf "uv download cache path is unsafe.\n" >&2; exit 2; }
mkdir -p "$uv_download_cache"
# npm's content-addressed download cache is safe to share between worktrees and
# concurrent installs; node_modules trees are cached separately below.
npm_download_cache="$runner_root/npm-cache"
[[ ! -L "$npm_download_cache" ]] ||
  { printf "npm download cache path is unsafe.\n" >&2; exit 2; }
mkdir -p "$npm_download_cache"
bun_download_cache="$runner_root/bun-cache"
[[ ! -L "$bun_download_cache" ]] ||
  { printf "Bun download cache path is unsafe.\n" >&2; exit 2; }
mkdir -p "$bun_download_cache"
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
# Download caches are only for installs. Tests run with the package manager's
# default cache under the private runtime home, so a sandboxed test that starts
# bun or npm never has to reach the shared cache.
install_environment=(
  "${clean_environment[@]}"
  "npm_config_cache=$npm_download_cache"
  "BUN_INSTALL_CACHE_DIR=$bun_download_cache"
)

prepare_lock_file() {
  [[ ! -L "$1" ]] || { printf "Remote lock is a symlink: %s\n" "$1" >&2; exit 2; }
  : >>"$1"
  chmod 600 "$1"
  [[ -f "$1" && ! -L "$1" ]] ||
    { printf "Remote lock is not a regular file: %s\n" "$1" >&2; exit 2; }
}

# A job whose deadline wrapper died (for example from SIGKILL) can leave its
# process group running. That group inherits the job's locks, so it would block
# every later job; reap it instead. A record whose wrapper is still alive, or
# whose process-group ID has been reused, is left alone.
reap_orphan() {
  local record="$1" wrapper_pid="" group_id="" started="" leader_started members attempt
  [[ -f "$record" && ! -L "$record" ]] || return 0
  read -r wrapper_pid group_id started <"$record" || true
  [[ "$wrapper_pid" =~ ^[0-9]+$ && "$group_id" =~ ^[0-9]+$ ]] || { rm -f "$record"; return 0; }
  ! kill -0 "$wrapper_pid" 2>/dev/null || return 0
  group_members() { ps -axo pgid=,pid= | awk -v group="$group_id" '$1 == group { print $2 }'; }
  members="$(group_members)"
  leader_started="$(ps -o lstart= -p "$group_id" 2>/dev/null | sed 's/^ *//; s/ *$//' || true)"
  if [[ -z "$members" || ( -n "$leader_started" && "$leader_started" != "$started" ) ]]; then
    rm -f "$record"
    return 0
  fi
  printf "Reaping process group %s left by an interrupted job.\n" "$group_id" >&2
  printf "phase=orphan-reaped time=%s pgid=%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$group_id" >>"$job_log"
  kill -TERM -- "-$group_id" 2>/dev/null || true
  for attempt in {1..50}; do
    [[ -n "$(group_members)" ]] || break
    sleep 0.1
  done
  kill -KILL -- "-$group_id" 2>/dev/null || true
  for attempt in {1..50}; do
    [[ -n "$(group_members)" ]] || { rm -f "$record"; return 0; }
    sleep 0.1
  done
  printf "Process group %s survived SIGKILL.\n" "$group_id" >&2
  return 1
}

reap_all_orphans() {
  local record
  for record in "$runner_root"/*/meta/active-job; do
    [[ -e "$record" ]] || continue
    reap_orphan "$record" || true
  done
}

lock_wait_tick() {
  if ((waited >= remote_lock_timeout)); then
    printf "Timed out waiting %ss for the remote runner lock.\n" "$remote_lock_timeout" >&2
    ps -axo pid=,ppid=,pgid=,stat=,%cpu=,%mem=,etime=,comm= >&2 || true
    exit 75
  fi
  sleep 1
  waited=$((waited + 1))
  if ((waited % 10 == 0)); then
    printf "%s; still waiting...\n" "$1" >&2
  fi
}

# Locks are flock(2) locks on open descriptors. They are released by the kernel
# when every holder exits, including after a lost SSH connection. The command's
# process group receives both descriptors, so a test that survives this shell
# keeps holding them and no later sync can replace source underneath it.
waited=0
slot_lock="$base/.slot.lock"
prepare_lock_file "$slot_lock"
exec 8<>"$slot_lock"
while ! lockf -s -t 0 8; do
  reap_all_orphans
  lock_wait_tick "Another job from this worktree is using the remote Mac"
done
active_job_record="$base/meta/active-job"
reap_orphan "$active_job_record" ||
  { printf "A previous job in this worktree could not be stopped.\n" >&2; exit 75; }
[[ ! -e "$active_job_record" ]] ||
  { printf "A previous job in this worktree is still active.\n" >&2; exit 75; }

# At most $concurrency jobs run at once across the whole runner cache.
while :; do
  for ((lock_index = 0; lock_index < concurrency; lock_index += 1)); do
    execution_lock="$runner_root/.execution.lock"
    ((lock_index == 0)) || execution_lock="$runner_root/.execution.$lock_index.lock"
    prepare_lock_file "$execution_lock"
    exec 9<>"$execution_lock"
    if lockf -s -t 0 9; then
      break 2
    fi
    exec 9>&-
  done
  reap_all_orphans
  lock_wait_tick "The remote Mac is busy with other jobs"
done
printf "phase=locks-acquired time=%s waitedSeconds=%s\n" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$waited" >>"$job_log"

# Every run starts from the verified source snapshot. Dependencies are cloned
# from a separate pristine cache below.
[[ ! -L "$workspace" ]] || { printf "Remote workspace is a symlink.\n" >&2; exit 2; }
rm -rf "${workspace:?}"
mv "$next_workspace" "$workspace"
for meta_name in source-manifest tracked-manifest tracked-tree run-arguments uv-projects \
  package-projects; do
  mv "$job_stage/meta/$meta_name" "$base/meta/$meta_name"
done
rm -rf "${job_stage:?}"
# Staging left by clients that died before this job was queued, and the staging
# directory used by earlier versions of this runner.
for stale_stage in "$base/jobs"/*; do
  [[ -e "$stale_stage" ]] || continue
  [[ "$(basename "$stale_stage")" < "$job_id" ]] || continue
  rm -rf "${stale_stage:?}"
done
rm -rf "${base:?}/source.next"
rm -f "${base:?}/meta/"*.next

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

# Written to a file because "bun -" does not treat the following words as script
# arguments.
deadline_script="$base/meta/deadline.cjs"
cat >"$deadline_script" <<'NODE_DEADLINE'
const { createWriteStream, unlinkSync, writeFileSync } = require("node:fs");
const { spawn, spawnSync } = require("node:child_process");
const [secondsText, logPath, activePath, cwd, command, ...args] = process.argv.slice(2);
const startedAt = Date.now();
const log = createWriteStream(logPath, { flags: "a" });
// Descriptors 8 and 9 hold the runner locks; pass them to the command's group.
const stdio = ["ignore", "pipe", "pipe"];
while (stdio.length < 8) stdio.push("ignore");
stdio.push(8, 9);
const child = spawn(command, args, { cwd, detached: true, stdio });
const clearActive = () => {
  try {
    unlinkSync(activePath);
  } catch {}
};
if (child.pid !== undefined) {
  const leaderStart = spawnSync("ps", ["-o", "lstart=", "-p", String(child.pid)], {
    encoding: "utf8",
  });
  writeFileSync(activePath, `${process.pid} ${child.pid} ${(leaderStart.stdout || "").trim()}\n`);
}
// Why the runner stopped the command: null, "deadline" or "client-lost". A lost
// client (dropped SSH session) stops the command, since nobody reads its result;
// the job's locks stay held by the group until it is gone.
let stopReason = null;
let settled = false;
let killTimer;
let clientOpen = true;
const emit = (stream, value) => {
  if (clientOpen) stream.write(value);
  log.write(value);
};
const signalGroup = (signal = "SIGTERM") => {
  if (child.pid === undefined) return;
  try {
    process.kill(-child.pid, signal);
  } catch {}
};
const stop = (reason) => {
  if (stopReason !== null) return;
  stopReason = reason;
  signalGroup();
  killTimer = setTimeout(() => signalGroup("SIGKILL"), 5000);
};
const loseClient = () => {
  clientOpen = false;
  stop("client-lost");
};
process.stdout.on("error", loseClient);
process.stderr.on("error", loseClient);
for (const signal of ["SIGHUP", "SIGINT", "SIGTERM"]) {
  process.once(signal, loseClient);
}
emit(
  process.stderr,
  `phase=command-started time=${new Date().toISOString()} pid=${child.pid} command=${JSON.stringify(command)} argumentCount=${args.length}\n`,
);
child.stdout.on("data", (chunk) => emit(process.stdout, chunk));
child.stderr.on("data", (chunk) => emit(process.stderr, chunk));
const timer = setTimeout(() => {
  if (stopReason !== null) return;
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
  stop("deadline");
}, Number(secondsText) * 1000);
child.once("error", (error) => {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  emit(process.stderr, `Command failed to start: ${error.message}\n`);
  clearActive();
  log.end(() => process.exit(2));
});
child.once("exit", (code, signal) => {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  if (killTimer !== undefined) clearTimeout(killTimer);
  let status = stopReason === "deadline" ? 124 : stopReason === "client-lost" ? 129 : (code ?? 2);
  let checks = 0;
  let survived = false;
  const finish = () => {
    emit(
      process.stderr,
      `phase=command-completed time=${new Date().toISOString()} status=${status} signal=${signal ?? "none"} stopReason=${stopReason ?? "none"} elapsedMs=${Date.now() - startedAt}\n`,
    );
    // A group that survived SIGKILL keeps its record, so later jobs reap it.
    if (!survived) clearActive();
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
      survived = true;
      status = 124;
      emit(process.stderr, `Process group ${child.pid} survived SIGKILL for 5s.\n`);
      return finish();
    }
    setTimeout(reapGroup, 100);
  };
  reapGroup();
});
NODE_DEADLINE

run_bounded() {
  local seconds="$1"
  shift
  local directory="$PWD"
  # Started outside the repository so its bunfig.toml or .env cannot configure
  # the wrapper itself; the command still runs in the original directory.
  (cd "$base/meta" &&
    "$wrapper_runtime" "$deadline_script" "$seconds" "$job_log" "$active_job_record" \
      "$directory" "$@")
}

quiet_setup() {
  local step_log status
  step_log="$(mktemp /tmp/npm-remote-step.XXXXXX)"
  status=0
  run_bounded "$setup_timeout" "$@" >"$step_log" 2>&1 || status=$?
  if [[ "$status" == "0" ]]; then
    cat "$step_log" >>"$job_log"
    rm -f "$step_log"
    return 0
  fi
  cat "$step_log" >>"$job_log"
  cat "$step_log" >&2
  rm -f "$step_log"
  return "$status"
}

tracked_file_digests() {
  local tracked_path
  while IFS= read -r -d "" tracked_path; do
    case "/$tracked_path" in
      */package.json | */package-lock.json | */npm-shrinkwrap.json | */.npmrc | \
        */bun.lock | */bun.lockb | */bunfig.toml)
        printf "%s=" "$tracked_path"
        shasum -a 256 "$tracked_path" | cut -d " " -f 1
        ;;
    esac
  done <"$base/meta/tracked-manifest"
}

if [[ "$package_manager" == "npm" ]]; then
  [[ -f package.json && -f package-lock.json ]] || {
    printf "npm mode requires package.json and package-lock.json.\n" >&2
    exit 2
  }
  package_manager_version="$("${clean_environment[@]}" npm --version)"
else
  [[ -f package.json && ( -f bun.lock || -f bun.lockb ) ]] || {
    printf "Bun mode requires package.json and bun.lock or bun.lockb.\n" >&2
    exit 2
  }
  package_manager_version="$toolchain_version"
fi
# The root first, then each configured separately locked package.
package_projects=(".")
while IFS= read -r package_project || [[ -n "$package_project" ]]; do
  [[ -n "$package_project" ]] || continue
  [[ "$package_project" != /* && "$package_project" != ../* && "$package_project" != */../* &&
    "$package_project" != .. && "$package_project" != */.. ]] ||
    { printf "Unsafe package project path: %s\n" "$package_project" >&2; exit 2; }
  if [[ "$package_manager" == "npm" ]]; then
    [[ -f "$package_project/package.json" && -f "$package_project/package-lock.json" ]] || {
      printf "Configured package project lacks package.json or package-lock.json: %s\n" \
        "$package_project" >&2
      exit 2
    }
  else
    [[ -f "$package_project/package.json" &&
      ( -f "$package_project/bun.lock" || -f "$package_project/bun.lockb" ) ]] || {
      printf "Configured package project lacks package.json or a Bun lockfile: %s\n" \
        "$package_project" >&2
      exit 2
    }
  fi
  package_projects+=("$package_project")
done <"$base/meta/package-projects"

dependency_identity="$(
  {
    printf "identity-v4\npm=%s\npm_version=%s\nruntime=%s\nos=%s\nos_version=%s\nkernel=%s\narch=%s\n" \
      "$package_manager" "$package_manager_version" "$("$wrapper_runtime" --version)" \
      "$(uname -s)" "$(sw_vers -productVersion)" "$(uname -r)" "$(uname -m)"
    tracked_file_digests
    printf "package_projects=%s\n" "$(tr "\n" " " <"$base/meta/package-projects")"
  } | shasum -a 256 | cut -d " " -f 1
)"
repository_dependency_root="$runner_root/dependencies/$repository_cache_name"
dependency_root="$repository_dependency_root/$dependency_identity"
[[ ! -L "$runner_root/dependencies" && ! -L "$repository_dependency_root" &&
  ! -L "$dependency_root" ]] ||
  { printf "Dependency cache path is unsafe.\n" >&2; exit 2; }
mkdir -p "$repository_dependency_root"

# Every node_modules directory that is not inside another one, relative to $1.
# Bun and npm workspaces may create one per workspace package.
list_module_directories() {
  (cd "$1" && find . -name .git -prune -o -type d -name node_modules -prune -print) |
    sed 's|^\./||' | LC_ALL=C sort
}

# Worktrees on different branches with the same lockfiles share one cache entry,
# possibly at the same time. Restores and publishes of that entry take this lock
# (fd 7) so a job never copies a tree that another job is replacing.
dependency_lock="$repository_dependency_root/.cache.lock"
with_dependency_lock() {
  local status=0
  prepare_lock_file "$dependency_lock"
  exec 7<>"$dependency_lock"
  lockf -s -t "$setup_timeout" 7 ||
    { printf "Timed out waiting for the dependency cache lock.\n" >&2; exit 75; }
  "$@" || status=$?
  exec 7>&-
  return "$status"
}

restore_dependency_cache() {
  local relative
  [[ -d "$dependency_root/tree" && ! -L "$dependency_root/tree" ]] || return 1
  while IFS= read -r relative; do
    [[ -n "$relative" ]] || continue
    mkdir -p "$(dirname "$workspace/$relative")"
    cp -cR "$dependency_root/tree/$relative" "$workspace/$relative" || return 1
  done < <(list_module_directories "$dependency_root/tree")
}

remove_module_directories() {
  local relative
  while IFS= read -r relative; do
    [[ -n "$relative" ]] || continue
    rm -rf "${workspace:?}/${relative:?}"
  done < <(list_module_directories "$workspace")
}

# A tree with an absolute symlink into the runner's directory (for example into
# this slot's workspace) would, once restored into another worktree's slot, load
# that other worktree's code. Such a tree is used for this run but not cached.
dependency_tree_portable() {
  local relative
  while IFS= read -r relative; do
    [[ -n "$relative" ]] || continue
    [[ -z "$(find "$workspace/$relative" -type l \
      \( -lname "$runner_root/*" -o -lname "$canonical_root/*" \) -print -quit)" ]] ||
      return 1
  done < <(list_module_directories "$workspace")
}

publish_dependency_cache() {
  local dependency_next="$1" replace="$2" stale
  local dependency_old="$repository_dependency_root/${dependency_identity}.old.$job_id"
  [[ ! -L "$dependency_old" ]] || { printf "Dependency staging path is unsafe.\n" >&2; exit 2; }
  if [[ -e "$dependency_root" ]]; then
    if [[ "$replace" != "1" ]]; then
      # Another job published this identity while we were installing.
      rm -rf "${dependency_next:?}"
      return 0
    fi
    mv "$dependency_root" "$dependency_old"
  fi
  mv "$dependency_next" "$dependency_root"
  rm -rf "${dependency_old:?}"
  # Staging left by jobs that died more than a day ago.
  while IFS= read -r -d "" stale; do
    rm -rf "${stale:?}"
  done < <(find "$repository_dependency_root" -mindepth 1 -maxdepth 1 \
    \( -name "*.next.*" -o -name "*.old.*" \) -mmin +1440 -print0)
}

save_dependency_cache() {
  # Stage under a job-unique name so concurrent jobs never share a staging tree,
  # then publish the entry with renames under the cache lock.
  local relative replace=0
  local dependency_next="$repository_dependency_root/${dependency_identity}.next.$job_id"
  [[ "$dependency_cache_state" != "invalid" ]] || replace=1
  if ! dependency_tree_portable; then
    dependency_cache_state="$dependency_cache_state-uncacheable"
    return 0
  fi
  [[ ! -L "$dependency_next" ]] ||
    { printf "Dependency staging path is unsafe.\n" >&2; exit 2; }
  rm -rf "${dependency_next:?}"
  mkdir -p "$dependency_next/tree"
  while IFS= read -r relative; do
    [[ -n "$relative" ]] || continue
    mkdir -p "$(dirname "$dependency_next/tree/$relative")"
    cp -cR "$workspace/$relative" "$dependency_next/tree/$relative"
  done < <(list_module_directories "$workspace")
  with_dependency_lock publish_dependency_cache "$dependency_next" "$replace"
}

dependency_cache_state="miss"
if with_dependency_lock restore_dependency_cache; then
  dependency_cache_state="hit"
fi
# Each step runs in every package project; the subshell keeps the job's cwd.
in_package_projects() {
  local package_project
  for package_project in "${package_projects[@]}"; do
    (cd "$package_project" && "$@") || return
  done
}
npm_tree_valid() {
  run_bounded "$setup_timeout" "${install_environment[@]}" npm ls --all --json >/dev/null 2>&1
}
npm_clean_install() {
  quiet_setup "${install_environment[@]}" npm ci --no-audit --no-fund
}
bun_frozen_install() {
  quiet_setup "${install_environment[@]}" bun install --frozen-lockfile
}

if [[ "$package_manager" == "npm" ]]; then
  if [[ "$dependency_cache_state" == "miss" ]] || ! in_package_projects npm_tree_valid; then
    [[ "$dependency_cache_state" == "miss" ]] || dependency_cache_state="invalid"
    remove_module_directories
    in_package_projects npm_clean_install
    in_package_projects npm_tree_valid
    save_dependency_cache
  fi
else
  # A frozen install over a restored tree is a fast consistency check that also
  # repairs anything missing; if it fails, fall back to a clean install.
  if [[ "$dependency_cache_state" == "hit" ]] && ! in_package_projects bun_frozen_install; then
    dependency_cache_state="invalid"
  fi
  if [[ "$dependency_cache_state" != "hit" ]]; then
    remove_module_directories
    in_package_projects bun_frozen_install
    save_dependency_cache
  fi
fi
printf "phase=dependencies-ready time=%s identity=%s cache=%s\n" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dependency_identity" "$dependency_cache_state" >>"$job_log"
printf "dependency_cache=%s identity=%s\n" \
  "$dependency_cache_state" "${dependency_identity:0:12}" >&2

# Secondary toolchains use one shared download cache, but never share a virtualenv:
# uv project installs are editable by default and retain their source path.
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
    rm -rf "${uv_project:?}/.venv"
    quiet_setup "${install_environment[@]}" uv sync --project "$uv_project" --frozen
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
  } | ssh "${ssh_arguments[@]}" "$remote_target" \
    "/bin/bash -s -- $REMOTE_RUNNER_BASE_DIR $remote_slot_name $repository_cache_name $REMOTE_RUNNER_REMOTE_LOCK_TIMEOUT $REMOTE_RUNNER_SETUP_TIMEOUT $REMOTE_RUNNER_JOB_TIMEOUT $job_id $REMOTE_RUNNER_REMOTE_CONCURRENCY"
  local result=$?
  set -e

  # Tell a command's own failure apart from a runner failure: only a command
  # that ran to completion leaves a remote-completed marker in the job log.
  local outcome="runner-failure" completed_marker
  completed_marker="$(
    ssh "${ssh_arguments[@]}" "$remote_target" \
      "grep -E '^phase=remote-completed ' $REMOTE_RUNNER_BASE_DIR/logs/$job_id.log" \
      2>/dev/null || true
  )"
  if [[ -n "$completed_marker" ]]; then
    case "$result" in
      0) outcome="passed" ;;
      124) outcome="command-deadline" ;;
      *) outcome="command-failed" ;;
    esac
  fi

  printf "copyback_status=disabled-in-baseline\n"
  printf "outcome=%s status=%s elapsed_seconds=%s\n" \
    "$outcome" "$result" "$((SECONDS - run_started_seconds))"
  printf "remote_log=~/%s/logs/%s.log\n" "$REMOTE_RUNNER_BASE_DIR" "$job_id"
  printf "%s job=%s state=completed status=%s outcome=%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$result" "$outcome" >>"$local_run_log"
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
  test)
    resolve_workspace
    resolve_package_manager
    if [[ "$package_manager" == "bun" ]]; then
      run_remote bun run test -- "$@"
    else
      run_remote npm test -- "$@"
    fi
    ;;
  run)
    [[ "${1:-}" != "--" ]] || shift
    run_remote "$@"
    ;;
  help | --help | -h) usage ;;
  *) usage; exit 2 ;;
esac
