#!/usr/bin/env bash

# typescript-remote-runner-macos: run the tests of npm, pnpm and Bun repositories on another Mac over
# SSH. Copy this file to a personal tools directory and adapt it per repository; see README.md.

set -euo pipefail

declare -a REMOTE_RUNNER_ALLOWED_ROOTS=() REMOTE_RUNNER_UNTRACKED_ALLOWLIST=()
declare -a REMOTE_RUNNER_UV_PROJECTS=() REMOTE_RUNNER_PACKAGE_PROJECTS=() REMOTE_RUNNER_COMMAND_ENV=()

# The runner was called npm-remote-runner-macos before it supported pnpm and Bun; its
# configuration variable and path are still honoured.
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
runner_config="${TYPESCRIPT_REMOTE_RUNNER_CONFIG:-${NPM_REMOTE_RUNNER_CONFIG:-$config_home/typescript-remote-runner-macos/config.sh}}"
if [[ -z "${TYPESCRIPT_REMOTE_RUNNER_CONFIG:-}${NPM_REMOTE_RUNNER_CONFIG:-}" && ! -f "$runner_config" &&
  -f "$config_home/npm-remote-runner-macos/config.sh" ]]; then
  runner_config="$config_home/npm-remote-runner-macos/config.sh"
fi
# A user-owned shell file; it must never come from a cloned repository.
# shellcheck source=/dev/null
[[ ! -f "$runner_config" ]] || source "$runner_config"

: "${REMOTE_RUNNER_HOST:=CHANGE_ME.local}" "${REMOTE_RUNNER_SSH_KEY:=}"
# An empty user leaves the choice to the SSH configuration of an alias.
: "${REMOTE_RUNNER_USER=CHANGE_ME}"
: "${REMOTE_RUNNER_BASE_DIR:=Library/Caches/typescript-remote-runner-macos}"
: "${REMOTE_RUNNER_NODE_VERSION:=}" "${REMOTE_RUNNER_BUN_VERSION:=}" "${REMOTE_RUNNER_PNPM_VERSION:=}"
: "${REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES:=0}" "${REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC:=0}"
: "${REMOTE_RUNNER_CONNECT_TIMEOUT:=10}" "${REMOTE_RUNNER_CONNECT_ATTEMPTS:=3}"
: "${REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT:=900}" "${REMOTE_RUNNER_REMOTE_LOCK_TIMEOUT:=900}"
: "${REMOTE_RUNNER_SETUP_TIMEOUT:=600}" "${REMOTE_RUNNER_JOB_TIMEOUT:=1200}"
# Jobs from different worktrees that may run at once (one worktree always runs one at a time), and
# an optional remote 1-minute load average a job waits for before it starts (0 disables it).
: "${REMOTE_RUNNER_REMOTE_CONCURRENCY:=1}" "${REMOTE_RUNNER_MAX_LOAD:=0}"

usage() {
  cat <<'USAGE'
Usage:
  remote-runner.sh doctor | bootstrap
  remote-runner.sh test [test arguments...]
  remote-runner.sh run -- <command> [arguments...]

The lockfile selects the package manager: package-lock.json npm, pnpm-lock.yaml pnpm (both with an
exact Node version), bun.lock or bun.lockb Bun. With several lockfiles, package.json's
packageManager field decides. "test" runs "npm test -- ...", "pnpm run test ..." or
"bun run test -- ...". Each command gets REMOTE_RUNNER_CPUS, the remote core count divided by
REMOTE_RUNNER_REMOTE_CONCURRENCY; pass it to the test runner through REMOTE_RUNNER_COMMAND_ENV,
for example VITEST_MAX_WORKERS={cpus}.

Configuration: ~/.config/typescript-remote-runner-macos/config.sh (README.md lists every setting).
Never put passwords, tokens or other secrets in it.
USAGE
}

# Used locally and prepended to every remote script. Remote paths and names are validated on both
# sides because the remote scripts receive them as arguments.
shared_functions='
fail() { printf "remote-runner: %s\n" "$*" >&2; exit 2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
safe_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
safe_relative() { [[ -n "$1" && "$1" != /* && "/$1/" != *"/../"* ]]; }
safe_base() {
  local pattern="^Library/Caches/(typescript|npm)-remote-runner-macos(/[A-Za-z0-9._-]+)*\$"
  [[ "$1" =~ $pattern && "/$1/" != *"/../"* && "/$1/" != *"/./"* ]]
}
git_isolated() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -c core.autocrlf=false -c core.safecrlf=false -c core.attributesFile=/dev/null "$@"
}
# The Git tree of the files listed (NUL-separated) in $1, built in an isolated index.
manifest_tree() {
  local manifest="$1"
  shift
  git_isolated "$@" read-tree --empty &&
    git_isolated "$@" --literal-pathspecs add --pathspec-from-file="$manifest" --pathspec-file-nul &&
    git_isolated "$@" write-tree
}
# Node comes from fnm; Bun and pnpm live beside, not inside, the runner cache. A pnpm toolchain is
# the pair NODE+PNPM, and its directory links both.
toolchain_bin() {
  local toolchains="$HOME/Library/Caches/typescript-remote-runner-macos-toolchains" node
  case "$1" in
    npm)
      node="$(fnm exec --using "$2" -- node -p process.execPath 2>/dev/null)" || return 1
      dirname "$node"
      ;;
    bun) printf "%s\n" "$toolchains/bun-$2/bin" ;;
    pnpm) printf "%s\n" "$toolchains/pnpm-${2#*+}-node-${2%%+*}/bin" ;;
    *) return 1 ;;
  esac
}
toolchain_reported_version() {
  case "$1" in
    npm) "$2/node" --version | sed "s/^v//" ;;
    bun) "$2/bun" --version ;;
    pnpm) printf "%s+%s\n" "$("$2/node" --version | sed "s/^v//")" \
      "$(PATH="$2:/usr/bin:/bin" "$2/pnpm" --version)" ;;
  esac
} 2>/dev/null
'
eval "$shared_functions"

canonical_directory() { (cd "$1" && pwd -P); }

git_common_directory() {
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
    canonical_directory "$common"
}

is_registered_worktree() {
  local line
  while IFS= read -r line; do
    [[ "$line" != "worktree "* ]] ||
      [[ "$(canonical_directory "${line#worktree }" 2>/dev/null)" != "$2" ]] || return 0
  done < <(git -C "$1" worktree list --porcelain)
  return 1
}

resolve_workspace() {
  workspace_root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    fail "run this command inside a Git worktree"
  workspace_root="$(canonical_directory "$workspace_root")"
  local allowed root common matched="" here
  common="$(git_common_directory "$workspace_root")" ||
    fail "cannot resolve this worktree's Git common directory"
  for allowed in ${REMOTE_RUNNER_ALLOWED_ROOTS[@]+"${REMOTE_RUNNER_ALLOWED_ROOTS[@]}"}; do
    root="$(canonical_directory "$allowed" 2>/dev/null)" || continue
    if [[ "$workspace_root" == "$root" ]] || {
      [[ "$REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES" == "1" &&
        "$(git_common_directory "$root" 2>/dev/null)" == "$common" ]] &&
        is_registered_worktree "$root" "$workspace_root"
    }; then
      matched=1
      break
    fi
  done
  [[ -n "$matched" ]] || fail "this worktree is outside the configured repository scope: $workspace_root"
  here="$(pwd -P)"
  [[ "$here/" == "$workspace_root/"* ]] || fail "current directory is outside the resolved worktree"
  workspace_relative_directory="${here#"$workspace_root"}"
  workspace_relative_directory="${workspace_relative_directory#/}"
}

read_pin() {
  local pin=""
  [[ ! -f "$workspace_root/$1" ]] || IFS= read -r pin <"$workspace_root/$1" || true
  printf "%s" "$pin"
}

resolve_package_manager() {
  local -a found=()
  [[ ! -f "$workspace_root/package-lock.json" ]] || found+=("npm")
  [[ ! -f "$workspace_root/pnpm-lock.yaml" ]] || found+=("pnpm")
  [[ ! -f "$workspace_root/bun.lock" && ! -f "$workspace_root/bun.lockb" ]] || found+=("bun")
  # "name version" from package.json's packageManager field, without a "+sha..." suffix.
  local field declared
  field="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([a-z]*\)@\([^"+]*\).*/\1 \2/p' \
    "$workspace_root/package.json" 2>/dev/null | head -n 1)"
  declared="${field%% *}"
  case "${#found[@]}" in
    0) fail "no package-lock.json, pnpm-lock.yaml, bun.lock or bun.lockb in $workspace_root; adapt the runner for this repository" ;;
    1) package_manager="${found[0]}" ;;
    *)
      [[ " ${found[*]} " == *" $declared "* ]] ||
        fail "several lockfiles (${found[*]}) and no matching packageManager field in package.json"
      package_manager="$declared"
      ;;
  esac
  declared_version=""
  [[ -z "$field" || "$declared" != "$package_manager" ]] || declared_version="${field#* }"
}

exact_version() {
  local version="${3#bun-v}"
  version="${version#v}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "set $2 to an exact $1 version"
  printf "%s" "$version"
}

# The package manager and the exact runtime version it needs remotely.
resolve_toolchain() {
  resolve_package_manager
  local pin
  if [[ "$package_manager" == "bun" ]]; then
    pin="${REMOTE_RUNNER_BUN_VERSION:-$(read_pin .bun-version)}"
    toolchain_version="$(exact_version Bun "REMOTE_RUNNER_BUN_VERSION, .bun-version or packageManager" \
      "${pin:-$declared_version}")"
    return
  fi
  pin="${REMOTE_RUNNER_NODE_VERSION:-$(read_pin .nvmrc)}"
  pin="${pin:-$(read_pin .node-version)}"
  if [[ -z "$pin" ]] && command -v node >/dev/null 2>&1; then
    pin="$(node --version)"
  fi
  toolchain_version="$(exact_version Node REMOTE_RUNNER_NODE_VERSION "$pin")"
  if [[ "$package_manager" == "pnpm" ]]; then
    pin="${REMOTE_RUNNER_PNPM_VERSION:-$declared_version}"
    toolchain_version+="+$(exact_version pnpm "REMOTE_RUNNER_PNPM_VERSION or packageManager" "$pin")"
  fi
}

validate_configuration() {
  [[ "$REMOTE_RUNNER_USER" != "CHANGE_ME" && "$REMOTE_RUNNER_HOST" != "CHANGE_ME.local" ]] ||
    fail "set REMOTE_RUNNER_USER and REMOTE_RUNNER_HOST in $runner_config"
  [[ -z "$REMOTE_RUNNER_USER" ]] || safe_name "$REMOTE_RUNNER_USER" ||
    fail "REMOTE_RUNNER_USER contains unsupported characters"
  safe_name "$REMOTE_RUNNER_HOST" || fail "REMOTE_RUNNER_HOST must be a hostname or SSH alias"
  local name
  for name in ALLOW_REGISTERED_WORKTREES ALLOW_TRACKED_PUBLIC_NPMRC; do
    name="REMOTE_RUNNER_$name"
    [[ "${!name}" == [01] ]] || fail "$name must be 0 or 1"
  done
  for name in CONNECT_TIMEOUT CONNECT_ATTEMPTS LOCAL_LOCK_TIMEOUT REMOTE_LOCK_TIMEOUT SETUP_TIMEOUT \
    JOB_TIMEOUT REMOTE_CONCURRENCY; do
    name="REMOTE_RUNNER_$name"
    [[ "${!name}" =~ ^[1-9][0-9]*$ ]] || fail "$name must be a positive integer"
  done
  ((REMOTE_RUNNER_REMOTE_CONCURRENCY <= 16)) || fail "REMOTE_RUNNER_REMOTE_CONCURRENCY must be at most 16"
  [[ "$REMOTE_RUNNER_MAX_LOAD" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
    fail "REMOTE_RUNNER_MAX_LOAD must be a non-negative number"
  safe_base "$REMOTE_RUNNER_BASE_DIR" ||
    fail "REMOTE_RUNNER_BASE_DIR must be a plain path under Library/Caches/typescript-remote-runner-macos"
}

# Everything before a remote step: local tools, scope, toolchain, configuration and SSH options.
prepare() {
  local name argument quoted
  for name in git rsync shasum shlock ssh; do
    command -v "$name" >/dev/null 2>&1 || fail "missing local command: $name"
  done
  resolve_workspace
  resolve_toolchain
  validate_configuration
  remote_target="${REMOTE_RUNNER_USER:+$REMOTE_RUNNER_USER@}$REMOTE_RUNNER_HOST"
  ssh_arguments=(-o BatchMode=yes -o "ConnectTimeout=$REMOTE_RUNNER_CONNECT_TIMEOUT"
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    -o ControlMaster=auto -o ControlPersist=600 -o "ControlPath=/tmp/ts-remote-runner-%C")
  [[ -z "$REMOTE_RUNNER_SSH_KEY" ]] || ssh_arguments+=(-i "$REMOTE_RUNNER_SSH_KEY" -o IdentitiesOnly=yes)
  rsync_transport="ssh"
  for argument in "${ssh_arguments[@]}"; do
    printf -v quoted " %q" "$argument"
    rsync_transport+="$quoted"
  done
}

# Runs standard input as a bash script on the remote Mac, after the shared functions.
remote_script() {
  {
    printf "%s\nset -euo pipefail\n" "$shared_functions"
    printf "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\n"
    cat
  } | ssh "${ssh_arguments[@]}" "$remote_target" "/bin/bash -s -- $*"
}

retry_transport() {
  local status=0 attempt
  for ((attempt = 1; attempt <= REMOTE_RUNNER_CONNECT_ATTEMPTS; attempt += 1)); do
    "$@" && return 0 || status=$?
    ((attempt == REMOTE_RUNNER_CONNECT_ATTEMPTS)) || {
      printf "Transport attempt %s/%s failed; retrying.\n" "$attempt" "$REMOTE_RUNNER_CONNECT_ATTEMPTS" >&2
      sleep "$attempt"
    }
  done
  return "$status"
}

is_protected_path() {
  case "/$1" in
    */.env.example | */.env.sample | */.env.template) return 1 ;;
    */.env | */.env.* | */.envrc | */.direnv | */.direnv/* | */.npmrc | */.netrc | */.authinfo | \
      */.git-credentials | */.pypirc | */.pgpass | */.kube/config | */.docker/config.json | \
      */.ssh | */.ssh/* | */.aws | */.aws/* | */.azure | */.azure/* | */.config/gcloud | \
      */.config/gcloud/* | */.gnupg | */.gnupg/* | */.password-store | */.password-store/* | \
      *.tfstate | *.tfstate.* | *.tfvars | */.terraform | */.terraform/* | *.ovpn | \
      *.mobileprovision | *.gpg | */service-account*.json | *.pem | *.key | *.p12 | *.pfx | *.jks | \
      *.keystore | *.agekey | *.kdbx | *.ppk | */id_rsa | */id_dsa | */id_ecdsa | */id_ed25519 | \
      */credentials.json | */credentials | */secrets.json | */secrets | */.git | */.git/* | \
      */node_modules | */node_modules/* | */.venv | */.venv/* | */.uv-cache | */.uv-cache/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Names alone cannot catch every secret, so approved untracked files, tracked .npmrc files and the
# command environment are also scanned for literal credentials. Only the file name is reported.
contains_literal_secret() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  LC_ALL=C grep -I -q -E \
    -e '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' \
    -e '(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Za-z0-9]|$)' \
    -e '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}' -e 'github_pat_[A-Za-z0-9_]{40,}' \
    -e 'glpat-[A-Za-z0-9_-]{20}' -e 'xox[abprs]-[A-Za-z0-9-]{10,}' -e 'npm_[A-Za-z0-9]{36}' \
    -e 'sk-(ant-|proj-|live_)?[A-Za-z0-9_-]{32,}' \
    -e '(_authToken|_auth|_password)[[:space:]]*=[[:space:]]*[^$[:space:]"]' \
    "$1"
}

# rsync would follow a symlinked parent directory and send what it points at, possibly outside the
# worktree. A branch switch or a local change can turn a tracked directory into such a link.
refuse_symlinked_parent() {
  local parent="$1"
  while [[ "$parent" == */* ]]; do
    parent="${parent%/*}"
    [[ ! -L "$workspace_root/$parent" ]] ||
      fail "$1 lies below the symlinked directory $parent; refusing to sync through it"
  done
}

# Adds a present path to the source manifest and, with a second argument, to the tracked manifest.
add_source_path() {
  [[ "$1" != *$'\n'* ]] || fail "the baseline runner does not support filenames containing newlines"
  safe_relative "$1" || fail "unsafe repository path: $1"
  [[ -e "$workspace_root/$1" || -L "$workspace_root/$1" ]] || return 0
  refuse_symlinked_parent "$1"
  printf "%s\n" "$1" >>"$work_dir/sources"
  [[ -z "${2:-}" ]] || printf "%s\0" "$1" >>"$tracked_manifest"
}

compute_tracked_tree() {
  manifest_tree "$tracked_manifest" -C "$workspace_root" --git-dir="$work_dir/git" --work-tree="$workspace_root"
}

# Everything the remote job needs besides source travels in $job_stage_dir.
build_job_metadata() {
  job_stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/ts-remote-job.XXXXXX")"
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ts-remote-work.XXXXXX")"
  source_manifest="$job_stage_dir/source-manifest"
  tracked_manifest="$job_stage_dir/tracked-manifest"
  : >"$work_dir/sources"
  : >"$tracked_manifest"
  local path entry name
  while IFS= read -r -d "" path; do
    if [[ "/$path" == */.npmrc ]]; then
      [[ "$REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC" == "1" ]] ||
        fail "tracked $path is excluded unless REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC=1 confirms it contains no credentials"
      ! contains_literal_secret "$workspace_root/$path" ||
        fail "tracked $path contains what looks like a literal credential; it was not synced"
    elif is_protected_path "$path"; then
      continue
    fi
    add_source_path "$path" tracked
  done < <(git -C "$workspace_root" ls-files -z --cached)
  for entry in ${REMOTE_RUNNER_UNTRACKED_ALLOWLIST[@]+"${REMOTE_RUNNER_UNTRACKED_ALLOWLIST[@]}"}; do
    safe_relative "$entry" || fail "unsafe untracked allowlist path: $entry"
    while IFS= read -r -d "" path; do
      ! is_protected_path "$path" || continue
      ! contains_literal_secret "$workspace_root/$path" ||
        fail "untracked $path contains what looks like a literal credential; remove it from the allowlist or the file"
      add_source_path "$path"
    done < <(git -C "$workspace_root" ls-files -z --others --exclude-standard -- "$entry")
  done
  LC_ALL=C sort -u "$work_dir/sources" -o "$source_manifest"
  [[ -s "$source_manifest" ]] || fail "source manifest is empty"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git init --bare -q "$work_dir/git"
  tracked_tree="$(compute_tracked_tree)"
  printf "%s\n" "$tracked_tree" >"$job_stage_dir/tracked-tree"

  printf "%s\0" "$package_manager" "$toolchain_version" "$workspace_relative_directory" "$@" \
    >"$job_stage_dir/run-arguments"
  : >"$job_stage_dir/uv-projects"
  for entry in ${REMOTE_RUNNER_UV_PROJECTS[@]+"${REMOTE_RUNNER_UV_PROJECTS[@]}"}; do
    safe_relative "$entry" || fail "unsafe REMOTE_RUNNER_UV_PROJECTS entry: $entry"
    printf "%s\n" "$entry" >>"$job_stage_dir/uv-projects"
  done
  : >"$job_stage_dir/package-projects"
  for entry in ${REMOTE_RUNNER_PACKAGE_PROJECTS[@]+"${REMOTE_RUNNER_PACKAGE_PROJECTS[@]}"}; do
    entry="${entry%/}"
    safe_relative "$entry" && [[ "$entry" != "." ]] ||
      fail "unsafe REMOTE_RUNNER_PACKAGE_PROJECTS entry: $entry"
    printf "%s\n" "$entry" >>"$job_stage_dir/package-projects"
  done
  # A tracked lockfile below the root that is not configured is usually a separately locked
  # package whose node_modules would otherwise be missing.
  while IFS= read -r -d "" path; do
    case "$package_manager:/$path" in
      */node_modules/*) ;;
      npm:*/package-lock.json | npm:*/npm-shrinkwrap.json | pnpm:*/pnpm-lock.yaml | bun:*/bun.lock | \
        bun:*/bun.lockb)
        [[ "$path" != */* ]] || grep -qxF "${path%/*}" "$job_stage_dir/package-projects" ||
          printf "remote-runner: warning: %s is not in REMOTE_RUNNER_PACKAGE_PROJECTS; its dependencies are not installed remotely\n" \
            "$path" >&2
        ;;
    esac
  done <"$tracked_manifest"

  # Names the runner sets itself, loader and toolchain settings, and names that suggest
  # credentials cannot be set. Values are scanned like untracked files.
  : >"$job_stage_dir/command-env"
  for entry in ${REMOTE_RUNNER_COMMAND_ENV[@]+"${REMOTE_RUNNER_COMMAND_ENV[@]}"}; do
    [[ "$entry" == *=* ]] || fail "REMOTE_RUNNER_COMMAND_ENV entries must be NAME=VALUE"
    name="${entry%%=*}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "REMOTE_RUNNER_COMMAND_ENV may not set $name"
    case "$(printf "%s" "$name" | tr "[:lower:]" "[:upper:]")" in
      HOME | PATH | USER | LOGNAME | SHELL | PWD | TMPDIR | LANG | LC_* | GIT_* | NPM_CONFIG_* | \
        BUN_INSTALL* | UV_* | DYLD_* | LD_* | SSH_* | REMOTE_RUNNER_* | NODE_OPTIONS | *TOKEN* | \
        *SECRET* | *PASSWORD* | *PASSWD* | *CREDENTIAL* | *API_KEY* | *APIKEY* | *PRIVATE* | *AUTH*)
        fail "REMOTE_RUNNER_COMMAND_ENV may not set $name"
        ;;
    esac
    [[ "$entry" != *$'\n'* ]] || fail "REMOTE_RUNNER_COMMAND_ENV value for $name contains a newline"
    printf "%s\n" "$entry" >>"$job_stage_dir/command-env"
  done
  ! contains_literal_secret "$job_stage_dir/command-env" ||
    fail "REMOTE_RUNNER_COMMAND_ENV contains what looks like a literal credential"
}

make_remote_slot() {
  local workspace_hash repository_key repository_name
  repository_key="$(git -C "$workspace_root" remote get-url origin 2>/dev/null ||
    git_common_directory "$workspace_root")"
  repository_name="$(basename "${repository_key%.git}" | tr -c "[:alnum:]._\n" "-")"
  repository_cache_name="${repository_name}-$(printf "%s" "$repository_key" | shasum -a 256 | cut -c1-12)"
  workspace_hash="$(printf "%s:%s:%s" "$(id -u)" "$(scutil --get LocalHostName 2>/dev/null || hostname)" \
    "$workspace_root" | shasum -a 256 | cut -c1-12)"
  remote_slot_name="$(basename "$workspace_root" | tr -c "[:alnum:]._\n" "-")-$workspace_hash"
  remote_slot="${REMOTE_RUNNER_BASE_DIR}/${remote_slot_name}"
  local_lock_file="${TMPDIR:-/tmp}/typescript-remote-runner-${workspace_hash}.lock"
  job_id="$(date -u +%Y%m%dT%H%M%SZ)-${workspace_hash}-$$"
}

wait_for_local_lock() {
  local waited=0
  until shlock -f "$local_lock_file" -p "$$"; do
    ((waited < REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT)) ||
      fail "timed out waiting ${REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT}s for the local runner lock"
    sleep 1
    waited=$((waited + 1))
    ((waited % 10)) || printf "Another request is using this worktree; still waiting...\n" >&2
  done
}

cleanup() {
  [[ -z "${local_lock_file:-}" ]] || rm -f "$local_lock_file"
  [[ -z "${work_dir:-}" ]] || rm -rf "$work_dir"
  [[ -z "${job_stage_dir:-}" ]] || rm -rf "$job_stage_dir"
}

doctor() {
  prepare
  remote_script "$package_manager" "$toolchain_version" <<'REMOTE'
package_manager="$1" version="$2"
printf "host=%s\nuser=%s\nos=%s\narch=%s\n" "$(scutil --get ComputerName 2>/dev/null || hostname)" \
  "$(id -un)" "$(sw_vers -productVersion)" "$(uname -m)"
printf "cpus=%s memory_gb=%s load=%s free_disk=%s\n" "$(sysctl -n hw.ncpu)" \
  "$(($(sysctl -n hw.memsize) / 1073741824))" "$(sysctl -n vm.loadavg | awk '{ print $2 }')" \
  "$(df -h "$HOME" | awk 'NR == 2 { print $4 }')"
printf "rsync=%s\ncaffeinate=%s\n" "$(command -v rsync || printf missing)" \
  "$(command -v caffeinate || printf missing)"
reported="$(toolchain_reported_version "$package_manager" "$(toolchain_bin "$package_manager" "$version")" || true)"
printf "package_manager=%s toolchain=%s\n" "$package_manager" "${reported:-missing}"
[[ "$reported" == "$version" ]] || { printf "status=toolchain-mismatch expected=%s; run bootstrap\n" "$version"; exit 2; }
printf "status=ready\n"
REMOTE
}

bootstrap() {
  prepare
  remote_script "$package_manager" "$toolchain_version" <<'REMOTE'
package_manager="$1" version="$2"
toolchains="$HOME/Library/Caches/typescript-remote-runner-macos-toolchains"
if [[ "$package_manager" == "bun" ]]; then
  bin="$toolchains/bun-$version/bin"
  if [[ "$(toolchain_reported_version bun "$bin" || true)" != "$version" ]]; then
    case "$(uname -m)" in
      arm64) asset="bun-darwin-aarch64" ;;
      x86_64) asset="bun-darwin-x64" ;;
      *) fail "unsupported architecture for Bun: $(uname -m)" ;;
    esac
    download_dir="$(mktemp -d "${TMPDIR:-/tmp}/ts-remote-bun.XXXXXX")"
    trap 'rm -rf "${download_dir:?}"' EXIT
    curl -fsSL --retry 3 -o "$download_dir/$asset.zip" \
      "https://github.com/oven-sh/bun/releases/download/bun-v$version/$asset.zip"
    unzip -q "$download_dir/$asset.zip" -d "$download_dir"
    mkdir -p "$bin"
    mv -f "$download_dir/$asset/bun" "$bin/bun"
    chmod 755 "$bin/bun"
  fi
else
  if ! command -v fnm >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || fail "Homebrew is required once to install fnm: https://brew.sh"
    brew install fnm
  fi
  fnm install "${version%%+*}"
  bin="$(toolchain_bin npm "${version%%+*}")"
  if [[ "$package_manager" == "pnpm" ]]; then
    # pnpm is installed once per version with the pinned Node's npm, then linked next to that node.
    pnpm_prefix="$toolchains/pnpm-${version#*+}"
    [[ "$(PATH="$bin:/usr/bin:/bin" "$pnpm_prefix/bin/pnpm" --version 2>/dev/null || true)" == "${version#*+}" ]] ||
      PATH="$bin:/usr/bin:/bin" "$bin/npm" install --global --no-audit --no-fund \
        --prefix "$pnpm_prefix" "pnpm@${version#*+}" >/dev/null
    node_bin="$bin"
    bin="$(toolchain_bin pnpm "$version")"
    mkdir -p "$bin"
    ln -sfn "$node_bin/node" "$bin/node"
    ln -sfn "$pnpm_prefix/bin/pnpm" "$bin/pnpm"
  fi
fi
installed="$(toolchain_reported_version "$package_manager" "$bin" || true)"
[[ "$installed" == "$version" ]] ||
  fail "$package_manager toolchain $version did not install correctly (found ${installed:-none})"
printf "installed=%s-%s\n" "$package_manager" "$installed"
REMOTE
  doctor
}

prepare_remote_snapshot() {
  remote_script "$REMOTE_RUNNER_BASE_DIR" "$remote_slot_name" "$job_id" <<'REMOTE'
base_dir="$1" slot_name="$2" job_id="$3"
safe_base "$base_dir" && safe_name "$slot_name" && safe_name "$job_id" || fail "unsafe remote path arguments"
make_dir() {
  [[ ! -L "$1" ]] || fail "$1 must not be a symlink"
  mkdir -p "$1"
  [[ "$(cd "$1" && pwd -P)" == "$1" ]] || fail "$1 contains a symlink"
}
runner_root="$HOME/$base_dir"
make_dir "$runner_root"
chmod 700 "$runner_root"
# Claim only an empty directory; mkdir decides between concurrent first runs.
marker="$runner_root/.npm-remote-runner-owned"
if [[ ! -e "$marker" ]]; then
  if mkdir "$runner_root/.initializing" 2>/dev/null; then
    if [[ -n "$(find "$runner_root" -mindepth 1 -maxdepth 1 ! -name .initializing \
      ! -name .npm-remote-runner-owned -print -quit)" ]]; then
      rmdir "$runner_root/.initializing"
      fail "remote cache is non-empty and has no ownership marker: $runner_root"
    fi
    : >"$marker"
    rmdir "$runner_root/.initializing"
  else
    for _ in {1..100}; do
      [[ ! -f "$marker" && -d "$runner_root/.initializing" ]] || break
      sleep 0.1
    done
  fi
fi
[[ -f "$marker" && ! -L "$marker" ]] || fail "invalid remote cache ownership marker"
# Each job stages into its own directory, so a sync never replaces files under another job from
# this slot, even one that outlived its SSH session.
slot="$runner_root/$slot_name"
make_dir "$slot"
make_dir "$slot/meta"
make_dir "$slot/jobs"
[[ ! -e "$slot/jobs/$job_id" ]] || fail "remote job staging directory already exists: $job_id"
mkdir -p "$slot/jobs/$job_id/source" "$slot/jobs/$job_id/meta"
REMOTE

  local remote_job="$remote_slot/jobs/$job_id" difference
  retry_transport rsync -rcz -e "$rsync_transport" "$job_stage_dir/" "$remote_target:$remote_job/meta/"
  # Staging starts empty, so ignored output from earlier runs never reappears. --copy-dest copies
  # files unchanged since the previous snapshot on the remote Mac instead of over the network.
  retry_transport rsync -az --copy-dest=../../../source --files-from="$source_manifest" \
    -e "$rsync_transport" "$workspace_root/" "$remote_target:$remote_job/source/"
  # The checksum dry run proves the result; files the size-and-time check missed are resent once.
  for attempt in 1 2; do
    difference="$(rsync -rlcni --files-from="$source_manifest" -e "$rsync_transport" \
      "$workspace_root/" "$remote_target:$remote_job/source/")"
    [[ -n "$difference" && "$attempt" == "1" ]] || break
    retry_transport rsync -acz --files-from="$source_manifest" -e "$rsync_transport" \
      "$workspace_root/" "$remote_target:$remote_job/source/"
  done
  [[ -z "$difference" ]] || fail "remote source differs after sync: ${difference:0:500}"
  printf "source_status=byte-identical\n"
}

run_remote() {
  [[ "$#" -gt 0 ]] || fail "run requires a command"
  prepare
  make_remote_slot
  retry_transport ssh "${ssh_arguments[@]}" "$remote_target" true >/dev/null 2>&1 ||
    fail "remote host is unreachable; no sync or test started"
  wait_for_local_lock
  run_started_seconds="$SECONDS"
  local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/typescript-remote-runner-macos"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  local_run_log="$state_dir/runs.log"
  terminal_recorded=0
  printf "%s job=%s state=started command=%s argumentCount=%s\n" "$(now)" "$job_id" "$1" "$#" \
    >>"$local_run_log"
  record_local_terminal() {
    local status=$?
    [[ "${terminal_recorded:-0}" == "1" ]] ||
      printf "%s job=%s state=interrupted status=%s\n" "$(now)" "$job_id" "$status" >>"$local_run_log"
    cleanup
  }
  trap record_local_terminal EXIT
  trap "exit 129" HUP
  trap "exit 130" INT
  trap "exit 143" TERM
  build_job_metadata "$@"
  prepare_remote_snapshot
  # The remote copy was verified against the files as they were after the upload. If the worktree
  # changed since its tree was recorded (a branch switch during sync), the copy may mix versions.
  [[ "$(compute_tracked_tree)" == "$tracked_tree" ]] ||
    fail "the worktree changed while it was being synced (branch switch or checkout?); nothing was run, retry when it is stable"

  set +e
  remote_script "$REMOTE_RUNNER_BASE_DIR" "$remote_slot_name" "$repository_cache_name" \
    "$REMOTE_RUNNER_REMOTE_LOCK_TIMEOUT" "$REMOTE_RUNNER_SETUP_TIMEOUT" "$REMOTE_RUNNER_JOB_TIMEOUT" \
    "$job_id" "$REMOTE_RUNNER_REMOTE_CONCURRENCY" "$REMOTE_RUNNER_MAX_LOAD" <<'REMOTE'
base_dir="$1" slot_name="$2" repository_cache_name="$3" remote_lock_timeout="$4" setup_timeout="$5"
job_timeout="$6" job_id="$7" concurrency="$8" max_load="$9"
safe_base "$base_dir" && safe_name "$slot_name" && safe_name "$repository_cache_name" &&
  safe_name "$job_id" || fail "unsafe remote path arguments"
for value in "$remote_lock_timeout" "$setup_timeout" "$job_timeout" "$concurrency"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "invalid runner limit: $value"
done
[[ "$max_load" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "invalid remote load limit: $max_load"
[[ "$(uname -s)" == "Darwin" ]] || fail "the remote host must run macOS"
real_dir() { [[ -d "$1" && ! -L "$1" && "$(cd "$1" && pwd -P)" == "$1" ]] || fail "unsafe remote path: $1"; }
make_dir() { [[ ! -L "$1" ]] || fail "$1 must not be a symlink"; mkdir -p "$1"; real_dir "$1"; }
runner_root="$HOME/$base_dir"
slot="$runner_root/$slot_name"
workspace="$slot/source"
job_stage="$slot/jobs/$job_id"
for directory in "$runner_root" "$slot" "$slot/meta" "$slot/jobs" "$job_stage" "$job_stage/meta" \
  "$job_stage/source"; do
  real_dir "$directory"
done
[[ -f "$runner_root/.npm-remote-runner-owned" && ! -L "$runner_root/.npm-remote-runner-owned" ]] ||
  fail "remote cache ownership marker is missing"
make_dir "$runner_root/logs"
chmod 700 "$runner_root/logs"
job_log="$runner_root/logs/$job_id.log"
log() { printf "phase=%s time=%s %s\n" "$1" "$(now)" "${*:2}" >>"$job_log"; }
log remote-started "pid=$$"
remote_terminal=0
record_remote_terminal() {
  local status=$?
  [[ "$remote_terminal" == "1" ]] || log remote-exited "status=$status"
}
trap record_remote_terminal EXIT HUP INT TERM

run_values=()
while IFS= read -r -d "" value; do
  run_values+=("$value")
done <"$job_stage/meta/run-arguments"
[[ "${#run_values[@]}" -ge 4 ]] || fail "remote command arguments are incomplete"
package_manager="${run_values[0]}"
toolchain_version="${run_values[1]}"
relative_directory="${run_values[2]}"
command_arguments=("${run_values[@]:3}")
version_pattern="^[0-9]+\.[0-9]+\.[0-9]+$"
case "$package_manager" in
  npm | bun) ;;
  pnpm) version_pattern="^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+\.[0-9]+\.[0-9]+$" ;;
  *) fail "unsupported package manager: $package_manager" ;;
esac
[[ "$toolchain_version" =~ $version_pattern ]] || fail "unsupported toolchain version: $toolchain_version"
toolchain_directory="$(toolchain_bin "$package_manager" "$toolchain_version" || true)"
[[ -n "$toolchain_directory" && "$(toolchain_reported_version "$package_manager" \
  "$toolchain_directory" || true)" == "$toolchain_version" ]] ||
  fail "remote $package_manager $toolchain_version is missing; run bootstrap first"
# The deadline wrapper runs on the repository's own runtime: Bun for Bun, Node otherwise.
wrapper_runtime="$toolchain_directory/node"
[[ "$package_manager" != "bun" ]] || wrapper_runtime="$toolchain_directory/bun"

# Download caches are shared between worktrees; virtualenvs and node_modules never are.
make_dir "$slot/runtime-home"
chmod 700 "$slot/runtime-home"
for cache in uv-cache "uv-cache/$repository_cache_name" npm-cache pnpm-store bun-cache; do
  make_dir "$runner_root/$cache"
done
clean_environment=(env -i "HOME=$slot/runtime-home" "USER=$(id -un)" "LOGNAME=$(id -un)"
  "PATH=$toolchain_directory:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
  "TMPDIR=${TMPDIR:-/tmp}" "LANG=en_US.UTF-8" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1"
  "UV_CACHE_DIR=$runner_root/uv-cache/$repository_cache_name")
# Only installs use the shared caches. Tests use the package manager's default cache under the
# private home, so a sandboxed test that starts bun or npm never has to reach the shared cache.
install_environment=("${clean_environment[@]}" "npm_config_cache=$runner_root/npm-cache"
  "BUN_INSTALL_CACHE_DIR=$runner_root/bun-cache" "npm_config_store_dir=$runner_root/pnpm-store")

open_lock() {
  [[ ! -L "$2" ]] || fail "remote lock is a symlink: $2"
  : >>"$2"
  chmod 600 "$2"
  [[ -f "$2" && ! -L "$2" ]] || fail "remote lock is not a regular file: $2"
  eval "exec $1<>\"\$2\""
}

# A job whose deadline wrapper died (for example from SIGKILL) can leave its process group running
# with the job's locks; reap it. A record whose wrapper is alive or whose group ID was reused stays.
group_members() { ps -axo pgid=,pid= | awk -v group="$1" '$1 == group { print $2 }'; }
reap_orphan() {
  local wrapper_pid="" group_id="" started="" leader_started
  [[ -f "$1" && ! -L "$1" ]] || return 0
  read -r wrapper_pid group_id started <"$1" || true
  [[ "$wrapper_pid" =~ ^[0-9]+$ && "$group_id" =~ ^[0-9]+$ ]] || { rm -f "$1"; return 0; }
  ! kill -0 "$wrapper_pid" 2>/dev/null || return 0
  leader_started="$(ps -o lstart= -p "$group_id" 2>/dev/null | sed 's/^ *//; s/ *$//' || true)"
  if [[ -z "$(group_members "$group_id")" || (-n "$leader_started" && "$leader_started" != "$started") ]]; then
    rm -f "$1"
    return 0
  fi
  printf "Reaping process group %s left by an interrupted job.\n" "$group_id" >&2
  log orphan-reaped "pgid=$group_id"
  for signal in TERM KILL; do
    kill "-$signal" -- "-$group_id" 2>/dev/null || true
    for _ in {1..50}; do
      [[ -n "$(group_members "$group_id")" ]] || { rm -f "$1"; return 0; }
      sleep 0.1
    done
  done
  printf "Process group %s survived SIGKILL.\n" "$group_id" >&2
  return 1
}
reap_all_orphans() {
  local record
  for record in "$runner_root"/*/meta/active-job; do
    [[ ! -e "$record" ]] || reap_orphan "$record" || true
  done
}

# Probes once a second: quiet for ten seconds, then a message every ten seconds.
waited=0
lock_wait_tick() {
  if ((waited >= remote_lock_timeout)); then
    printf "Timed out after %ss: %s.\n" "$remote_lock_timeout" "$1" >&2
    ps -axo pid=,ppid=,pgid=,stat=,%cpu=,%mem=,etime=,comm= >&2 || true
    exit 75
  fi
  sleep 1
  waited=$((waited + 1))
  ((waited % 10)) || printf "%s; still waiting...\n" "$1" >&2
}

# flock(2) locks on open descriptors: fd 8 for this worktree's slot, fd 9 for one of $concurrency
# execution slots. The kernel releases them when every holder exits, and the command's process
# group inherits both, so a test that outlives this shell keeps them and no sync replaces its source.
open_lock 8 "$slot/.slot.lock"
until lockf -s -t 0 8; do
  reap_all_orphans
  lock_wait_tick "Another job from this worktree is using the remote Mac"
done
active_job_record="$slot/meta/active-job"
reap_orphan "$active_job_record" || { printf "A previous job in this worktree could not be stopped.\n" >&2; exit 75; }
[[ ! -e "$active_job_record" ]] || { printf "A previous job in this worktree is still active.\n" >&2; exit 75; }
while :; do
  for ((index = 0; index < concurrency; index += 1)); do
    lock_name=".execution.lock"
    ((index == 0)) || lock_name=".execution.$index.lock"
    open_lock 9 "$runner_root/$lock_name"
    ! lockf -s -t 0 9 || break 2
    exec 9>&-
  done
  reap_all_orphans
  lock_wait_tick "The remote Mac is busy with other jobs"
done
log locks-acquired "waitedSeconds=$waited"
# Load admission holds the slot while waiting, so queue order is kept; it shares the lock timeout.
if awk -v m="$max_load" 'BEGIN { exit !(m > 0) }'; then
  while load="$(sysctl -n vm.loadavg | awk '{ print $2 }')" &&
    awk -v l="$load" -v m="$max_load" 'BEGIN { exit !(l > m) }'; do
    lock_wait_tick "The remote Mac load average is $load, above $max_load"
  done
  log load-admitted "load=$load waitedSeconds=$waited"
fi

# Every run starts from the verified snapshot; staging left by clients that died before this job
# was queued is removed.
rm -rf "${workspace:?}"
mv "$job_stage/source" "$workspace"
mv -f "$job_stage/meta/"* "$slot/meta/"
rm -rf "${job_stage:?}"
for stale_stage in "$slot/jobs"/*; do
  [[ ! -e "$stale_stage" || ! "${stale_stage##*/}" < "$job_id" ]] || rm -rf "${stale_stage:?}"
done

cd "$workspace"
# Tests may commit in the snapshot, so it carries a fake identity of its own.
git_isolated init -q
git_isolated config user.name "Remote Test Runner"
git_isolated config user.email "remote-test@fake.invalid"
actual_tree="$(manifest_tree "$slot/meta/tracked-manifest")"
[[ "$actual_tree" == "$(<"$slot/meta/tracked-tree")" ]] ||
  fail "remote tracked tree differs: expected $(<"$slot/meta/tracked-tree"), got $actual_tree"
log source-verified "tree=$actual_tree"
git_isolated -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q --allow-empty -m "remote test snapshot"

# A file, because "bun -" does not pass the following words to the script.
deadline_script="$slot/meta/deadline.cjs"
cat >"$deadline_script" <<'DEADLINE'
const fs = require("node:fs");
const { spawn, spawnSync } = require("node:child_process");
const [seconds, logPath, activePath, cwd, command, ...args] = process.argv.slice(2);
const startedAt = Date.now();
const log = fs.createWriteStream(logPath, { flags: "a" });
const ps = (...a) => spawnSync("ps", a, { encoding: "utf8" }).stdout || "";
// Descriptors 8 and 9 hold the runner locks; the command's process group inherits them.
const stdio = ["ignore", "pipe", "pipe", "ignore", "ignore", "ignore", "ignore", "ignore", 8, 9];
const child = spawn(command, args, { cwd, detached: true, stdio });
const clearActive = () => { try { fs.unlinkSync(activePath); } catch {} };
if (child.pid) {
  const leaderStart = ps("-o", "lstart=", "-p", String(child.pid)).trim();
  fs.writeFileSync(activePath, `${process.pid} ${child.pid} ${leaderStart}\n`);
}
// Why the runner stopped the command: null, "deadline" or "client-lost". Nobody reads the result
// of a lost client (dropped SSH session), so its command is stopped too.
let stopReason = null, clientOpen = true, settled = false, killTimer;
const emit = (stream, text) => { if (clientOpen) stream.write(text); log.write(text); };
const signalGroup = (signal) => { try { return process.kill(-child.pid, signal); } catch { return false; } };
const stop = (reason) => {
  if (stopReason) return;
  stopReason = reason;
  signalGroup("SIGTERM");
  killTimer = setTimeout(() => signalGroup("SIGKILL"), 5000);
};
const loseClient = () => { clientOpen = false; stop("client-lost"); };
process.stdout.on("error", loseClient);
process.stderr.on("error", loseClient);
for (const signal of ["SIGHUP", "SIGINT", "SIGTERM"]) process.once(signal, loseClient);
emit(process.stderr, `phase=command-started time=${new Date().toISOString()} pid=${child.pid} command=${JSON.stringify(command)} argumentCount=${args.length}\n`);
child.stdout.on("data", (chunk) => emit(process.stdout, chunk));
child.stderr.on("data", (chunk) => emit(process.stderr, chunk));
const timer = setTimeout(() => {
  if (stopReason) return;
  const rows = ps("-axo", "pid=,ppid=,pgid=,stat=,%cpu=,%mem=,etime=,comm=").split("\n")
    .filter((row) => row.trim().split(/\s+/)[2] === String(child.pid)).join("\n");
  emit(process.stderr, `Command exceeded ${seconds}s; process snapshot follows.\n${rows || "process group returned no rows"}\n`);
  stop("deadline");
}, Number(seconds) * 1000);
const finish = (status, keepActive, text) => {
  clearTimeout(timer);
  clearTimeout(killTimer);
  emit(process.stderr, text);
  if (!keepActive) clearActive();
  log.end(() => process.exit(status));
};
child.once("error", (error) => {
  if (settled) return;
  settled = true;
  finish(2, false, `Command failed to start: ${error.message}\n`);
});
child.once("exit", (code, signal) => {
  if (settled) return;
  settled = true;
  let status = { deadline: 124, "client-lost": 129 }[stopReason] ?? code ?? 2;
  let checks = 0;
  // Wait for the rest of the group. One that survives SIGKILL keeps its record for later jobs.
  const reap = () => {
    signalGroup("SIGKILL");
    const alive = signalGroup(0);
    if (alive && ++checks < 50) return setTimeout(reap, 100);
    if (alive) {
      status = 124;
      emit(process.stderr, `Process group ${child.pid} survived SIGKILL for 5s.\n`);
    }
    finish(status, alive, `phase=command-completed time=${new Date().toISOString()} status=${status} signal=${signal ?? "none"} stopReason=${stopReason ?? "none"} elapsedMs=${Date.now() - startedAt}\n`);
  };
  reap();
});
DEADLINE

# Started outside the repository so its bunfig.toml or .env cannot configure the wrapper itself.
run_bounded() {
  local seconds="$1" directory="$PWD"
  shift
  (cd "$slot/meta" && "$wrapper_runtime" "$deadline_script" "$seconds" "$job_log" \
    "$active_job_record" "$directory" "$@")
}
# The wrapper already writes setup output to the job log; the terminal sees it only on failure.
quiet_setup() {
  local step_log status=0
  step_log="$(mktemp /tmp/ts-remote-step.XXXXXX)"
  run_bounded "$setup_timeout" "$@" >"$step_log" 2>&1 || status=$?
  [[ "$status" == "0" ]] || cat "$step_log" >&2
  rm -f "$step_log"
  return "$status"
}

has_package_lock() {
  [[ -f "$1/package.json" ]] || return 1
  case "$package_manager" in
    npm) [[ -f "$1/package-lock.json" ]] ;;
    pnpm) [[ -f "$1/pnpm-lock.yaml" ]] ;;
    bun) [[ -f "$1/bun.lock" || -f "$1/bun.lockb" ]] ;;
  esac
}
has_package_lock . || fail "$package_manager mode requires package.json and its lockfile"
# The root first, then each configured separately locked package.
package_projects=(".")
while IFS= read -r package_project || [[ -n "$package_project" ]]; do
  [[ -n "$package_project" ]] || continue
  safe_relative "$package_project" || fail "unsafe package project path: $package_project"
  has_package_lock "$package_project" ||
    fail "configured package project lacks package.json or a $package_manager lockfile: $package_project"
  package_projects+=("$package_project")
done <"$slot/meta/package-projects"

package_manager_version="$toolchain_version"
[[ "$package_manager" != "npm" ]] || package_manager_version="$("${clean_environment[@]}" npm --version)"
# macOS bash 3.2 cannot parse a case statement inside a command substitution, hence a function.
tracked_file_digests() {
  local tracked_path
  while IFS= read -r -d "" tracked_path; do
    case "/$tracked_path" in
      */package.json | */package-lock.json | */npm-shrinkwrap.json | */.npmrc | */pnpm-lock.yaml | \
        */pnpm-workspace.yaml | */.pnpmfile.cjs | */bun.lock | */bun.lockb | */bunfig.toml)
        printf "%s=%s\n" "$tracked_path" "$(shasum -a 256 "$tracked_path" | cut -d " " -f 1)"
        ;;
    esac
  done <"$slot/meta/tracked-manifest"
}
dependency_identity="$({
  printf "identity-v4\npm=%s\npm_version=%s\nruntime=%s\nos=%s\nos_version=%s\nkernel=%s\narch=%s\n" \
    "$package_manager" "$package_manager_version" "$("$wrapper_runtime" --version)" \
    "$(uname -s)" "$(sw_vers -productVersion)" "$(uname -r)" "$(uname -m)"
  tracked_file_digests
  printf "package_projects=%s\n" "$(tr "\n" " " <"$slot/meta/package-projects")"
} | shasum -a 256 | cut -d " " -f 1)"
make_dir "$runner_root/dependencies"
dependency_parent="$runner_root/dependencies/$repository_cache_name"
make_dir "$dependency_parent"
dependency_root="$dependency_parent/$dependency_identity"
[[ ! -L "$dependency_root" ]] || fail "dependency cache path is unsafe"

# Every node_modules directory not inside another one, relative to $1; workspaces create several.
list_module_directories() {
  (cd "$1" && find . -name .git -prune -o -type d -name node_modules -prune -print) |
    sed 's|^\./||' | LC_ALL=C sort
}
# Worktrees on different branches with the same lockfiles share one entry, possibly at once.
# Restores and publishes take this lock (fd 7), so no job copies a tree another job replaces.
with_dependency_lock() {
  local status=0
  open_lock 7 "$dependency_parent/.cache.lock"
  lockf -s -t "$setup_timeout" 7 || { printf "Timed out waiting for the dependency cache lock.\n" >&2; exit 75; }
  "$@" || status=$?
  exec 7>&-
  return "$status"
}
restore_dependency_cache() {
  local relative
  [[ -d "$dependency_root/tree" && ! -L "$dependency_root/tree" ]] || return 1
  while IFS= read -r relative; do
    mkdir -p "$(dirname "$workspace/$relative")"
    cp -cR "$dependency_root/tree/$relative" "$workspace/$relative" || return 1
  done < <(list_module_directories "$dependency_root/tree")
}
remove_module_directories() {
  local relative
  while IFS= read -r relative; do
    rm -rf "${workspace:?}/${relative:?}"
  done < <(list_module_directories "$workspace")
}
publish_dependency_cache() {
  local dependency_old="$dependency_parent/${dependency_identity}.old.$job_id" stale
  if [[ -e "$dependency_root" ]]; then
    # Another job published this identity while this one was installing; keep that entry.
    [[ "$2" == "1" ]] || { rm -rf "${1:?}"; return 0; }
    mv "$dependency_root" "$dependency_old"
  fi
  mv "$1" "$dependency_root"
  rm -rf "${dependency_old:?}"
  while IFS= read -r -d "" stale; do
    rm -rf "${stale:?}"
  done < <(find "$dependency_parent" -mindepth 1 -maxdepth 1 \( -name "*.next.*" -o -name "*.old.*" \) \
    -mmin +1440 -print0)
}
# Staged under a job-unique name, then published by rename under the cache lock. A tree with an
# absolute symlink into the runner's directory would, restored into another slot, load that other
# worktree's code; it is used for this run but not cached.
save_dependency_cache() {
  local relative dependency_next="$dependency_parent/${dependency_identity}.next.$job_id"
  while IFS= read -r relative; do
    [[ -z "$(find "$workspace/$relative" -type l -lname "$runner_root/*" -print -quit)" ]] || { dependency_cache_state="$dependency_cache_state-uncacheable"; return 0; }
  done < <(list_module_directories "$workspace")
  [[ ! -L "$dependency_next" ]] || fail "dependency staging path is unsafe"
  rm -rf "${dependency_next:?}"
  mkdir -p "$dependency_next/tree"
  while IFS= read -r relative; do
    mkdir -p "$(dirname "$dependency_next/tree/$relative")"
    cp -cR "$workspace/$relative" "$dependency_next/tree/$relative"
  done < <(list_module_directories "$workspace")
  local replace=0
  [[ "$dependency_cache_state" != "invalid" ]] || replace=1
  with_dependency_lock publish_dependency_cache "$dependency_next" "$replace"
}
in_package_projects() {
  local package_project
  for package_project in "${package_projects[@]}"; do
    (cd "$package_project" && "$@") || return
  done
}
npm_tree_valid() { run_bounded "$setup_timeout" "${install_environment[@]}" npm ls --all --json >/dev/null 2>&1; }
npm_clean_install() { quiet_setup "${install_environment[@]}" npm ci --no-audit --no-fund; }
frozen_install() { quiet_setup "${install_environment[@]}" "$package_manager" install --frozen-lockfile; }

dependency_cache_state="miss"
! with_dependency_lock restore_dependency_cache || dependency_cache_state="hit"
if [[ "$package_manager" == "npm" ]]; then
  if [[ "$dependency_cache_state" == "miss" ]] || ! in_package_projects npm_tree_valid; then
    [[ "$dependency_cache_state" == "miss" ]] || dependency_cache_state="invalid"
    remove_module_directories
    in_package_projects npm_clean_install
    in_package_projects npm_tree_valid
    save_dependency_cache
  fi
else
  # For Bun and pnpm a frozen install over a restored tree is a fast consistency check that also
  # repairs anything missing; when it fails, install from scratch.
  if [[ "$dependency_cache_state" == "hit" ]] && ! in_package_projects frozen_install; then
    dependency_cache_state="invalid"
  fi
  if [[ "$dependency_cache_state" != "hit" ]]; then
    remove_module_directories
    in_package_projects frozen_install
    save_dependency_cache
  fi
fi
log dependencies-ready "identity=$dependency_identity cache=$dependency_cache_state"
printf "dependency_cache=%s identity=%s\n" "$dependency_cache_state" "${dependency_identity:0:12}" >&2

# uv projects share one download cache but never a virtualenv: editable installs keep their path.
while IFS= read -r uv_project || [[ -n "$uv_project" ]]; do
  [[ -n "$uv_project" ]] || continue
  safe_relative "$uv_project" || fail "unsafe uv project path: $uv_project"
  [[ -f "$uv_project/pyproject.toml" && -f "$uv_project/uv.lock" ]] ||
    fail "configured uv project is missing pyproject.toml or uv.lock: $uv_project"
  command -v uv >/dev/null 2>&1 || fail "uv is required on the remote Mac for project $uv_project"
  rm -rf "${uv_project:?}/.venv"
  quiet_setup "${install_environment[@]}" uv sync --project "$uv_project" --frozen
  [[ -x "$uv_project/.venv/bin/python" ]] || fail "uv sync did not produce a usable venv at $uv_project/.venv"
done <"$slot/meta/uv-projects"

[[ -z "$relative_directory" ]] || cd "$relative_directory"
# This job's share of the remote cores, and the configured command variables ("{cpus}" becomes
# the share). Only the names are logged.
cpu_share=$(($(sysctl -n hw.ncpu) / concurrency))
((cpu_share >= 1)) || cpu_share=1
command_environment=("${clean_environment[@]}" "REMOTE_RUNNER_CPUS=$cpu_share")
names=""
while IFS= read -r entry || [[ -n "$entry" ]]; do
  [[ -n "$entry" ]] || continue
  name="${entry%%=*}"
  [[ "$entry" == *=* && "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$name" != REMOTE_RUNNER_* &&
    "$name" != HOME && "$name" != PATH ]] || fail "unsafe command environment entry"
  value="${entry#*=}"
  command_environment+=("$name=${value//\{cpus\}/$cpu_share}")
  names="$names${names:+,}$name"
done <"$slot/meta/command-env"
log command-environment "cpus=$cpu_share names=${names:-none}"
printf "cpu_share=%s command_env=%s\n" "$cpu_share" "${names:-none}" >&2

set +e
run_bounded "$job_timeout" "${command_environment[@]}" caffeinate -i -- "${command_arguments[@]}"
result=$?
set -e
log remote-completed "status=$result"
remote_terminal=1
exit "$result"
REMOTE
  local result=$?
  set -e

  # Only a command that ran to completion leaves a remote-completed marker, so a runner failure is
  # never reported as a test failure.
  local outcome="runner-failure"
  if ssh "${ssh_arguments[@]}" "$remote_target" \
    "grep -qE '^phase=remote-completed ' $REMOTE_RUNNER_BASE_DIR/logs/$job_id.log" 2>/dev/null; then
    case "$result" in
      0) outcome="passed" ;;
      124) outcome="command-deadline" ;;
      *) outcome="command-failed" ;;
    esac
  fi
  printf "copyback_status=disabled-in-baseline\n"
  printf "outcome=%s status=%s elapsed_seconds=%s\n" "$outcome" "$result" "$((SECONDS - run_started_seconds))"
  printf "remote_log=~/%s/logs/%s.log\n" "$REMOTE_RUNNER_BASE_DIR" "$job_id"
  printf "%s job=%s state=completed status=%s outcome=%s\n" "$(now)" "$job_id" "$result" "$outcome" \
    >>"$local_run_log"
  terminal_recorded=1
  cleanup
  trap - EXIT HUP INT TERM
  return "$result"
}

task="${1:-}"
[[ -n "$task" ]] || { usage; exit 2; }
shift
case "$task" in
  doctor) doctor ;;
  bootstrap) bootstrap ;;
  test)
    resolve_workspace
    resolve_package_manager
    case "$package_manager" in
      bun) run_remote bun run test -- "$@" ;;
      # pnpm passes everything after the script name to the script as is.
      pnpm) run_remote pnpm run test "$@" ;;
      *) run_remote npm test -- "$@" ;;
    esac
    ;;
  run)
    [[ "${1:-}" != "--" ]] || shift
    run_remote "$@"
    ;;
  help | --help | -h) usage ;;
  *) usage; exit 2 ;;
esac
