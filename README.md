# typescript-remote-runner-macos

Run the tests of npm, pnpm and Bun repositories on another Mac over SSH, without copying
`node_modules` or secrets. This README is the setup prompt for an implementation agent;
[`remote-runner.sh`](./remote-runner.sh) is the baseline it adapts. (Formerly
`npm-remote-runner-macos`; the old configuration path, `NPM_REMOTE_RUNNER_CONFIG` and the old
remote cache directory still work.)

## Configure a personal remote macOS test runner

You are an implementation agent. Set up transparent remote test execution for one or more local
npm, pnpm or Bun repositories, using another Mac as the runner.

Your first reply must contain exactly this question and nothing else:

> Which local repository or repositories should use the remote macOS test runner?

Wait for the answer before inspecting files or changing either computer.

Start from [`remote-runner.sh`](./remote-runner.sh). Copy it into the user's personal tools and
change the installed copy only where a selected repository needs different behaviour. It works with
macOS's own `/bin/bash` 3.2 as well as newer bash.

| Lockfile | Package manager | Pinned version from | `test` runs |
|---|---|---|---|
| `package-lock.json` | npm | Node: `REMOTE_RUNNER_NODE_VERSION`, `.nvmrc`, `.node-version` | `npm test -- …` |
| `pnpm-lock.yaml` | pnpm | Node as above; pnpm: `REMOTE_RUNNER_PNPM_VERSION`, `packageManager` | `pnpm run test …` |
| `bun.lock`, `bun.lockb` | Bun | `REMOTE_RUNNER_BUN_VERSION`, `.bun-version`, `packageManager` | `bun run test -- …` |

With several lockfiles, `packageManager` in `package.json` decides. The baseline never copies
test-written files back. Before enabling snapshot or fixture updates, add exact repository-specific
paths, pre-run conflict checks and staged replacement.

## Required result

For each selected repository:

- its normal test scripts and single-test commands run on the remote Mac;
- non-test commands stay local unless the user chooses otherwise;
- sync and execution form one queued operation;
- dependencies are installed and cached remotely, never copied;
- configuration is personal, survives restarts and is absent from tracked repository files;
- a remote failure produces a clear error and never falls back to running tests locally;
- unrelated repositories and unselected worktrees behave as before.

This gives CPU offload and filesystem isolation. It is not a security sandbox.

## Inspect the selected repositories

Resolve every selected path to its canonical Git worktree root. Include only paths the user named;
do not silently add sibling worktrees, nested repositories or submodules. Ask whether registered
Claude Code and Codex worktrees should inherit routing from each selected repository.

Read the repository's agent instructions and preserve its dirty working tree. Discover:

- package manager, workspaces and every tracked lockfile, including separately locked packages;
- exact runtime versions from the repository's own pins;
- test scripts, test framework, single-test syntax and the framework's worker setting;
- compound scripts that mix tests with builds, type checks or other work;
- test-written files: snapshots, coverage, generated fixtures and learned files such as recorded
  test timings (per-job staging discards them unless they are copied back);
- native dependencies, services, ports, Git history, submodules or LFS that tests need;
- commands that start applications, agents, development servers or other local systems;
- anything that already intercepts the package manager on this machine: shell functions, aliases,
  wrapper scripts earlier on `PATH` or agent hooks. A shell function shadows every `PATH` shim.

Do not install or replace the repository's test framework.

Show a small routing table before implementation:

| Command | Location | Reason |
|---|---|---|

Split a compound script only when its remote test stage does not depend on ignored local output and
later local stages do not depend on unapproved remote output; otherwise run it in one place or
report it as unsupported. `bun run` starts the `bun` of nested scripts without a `PATH` lookup, so a
shim cannot reach test stages inside a Bun compound script. Preserve command order and exit
behaviour.

## Select and prepare the remote Mac

Inspect configured SSH aliases, but do not scan the network. If the user has not named the remote,
propose a suitable existing alias or ask for an SSH alias or hostname and username. Before any
remote write, show the resolved hostname, username and installation directory and ask the user to
confirm them.

Use key-based SSH. Never request, store or embed a password. Probe the macOS version and
architecture, core count, memory, free disk space (each dependency identity can take about 1 GB),
sleep settings (`pmset`), `caffeinate`, rsync, and any Node-version manager, Node, npm, pnpm or Bun.

If key-based SSH does not already work, stop for a manual checkpoint:

1. ask the user to enable **Remote Login** on the runner Mac for the intended account;
2. ask whether to reuse an existing SSH key or create a dedicated Ed25519 key;
3. show the exact `ssh-keygen` command if a key is needed, and let the user handle its passphrase;
4. show the public-key path and ask the user to add it to the remote `~/.ssh/authorized_keys`;
5. offer a narrow `~/.ssh/config` entry with the alias, hostname, username, identity path and
   `IdentitiesOnly yes`;
6. wait until the user is done, then verify `ssh -o BatchMode=yes <alias> true`.

The agent may inspect or transfer a public key. It must never open, print, transfer or rewrite a
private key, type a password for the user, or weaken host-key checking.

After confirmation, install missing non-secret prerequisites; ask before using `sudo`. `bootstrap`
installs the pinned toolchain without `sudo` and leaves Homebrew's Node, pnpm and Bun alone:

- Node through fnm (Homebrew is needed once to install fnm);
- pnpm with the pinned Node's npm into
  `~/Library/Caches/typescript-remote-runner-macos-toolchains/pnpm-<version>`, linked next to that
  Node in `pnpm-<version>-node-<version>/bin`;
- Bun from its official release archive into `…-toolchains/bun-<version>/bin`.

`doctor` then reports the remote identity, cores, memory, load, free disk and toolchain.

Use SSH batch mode, connection reuse (the baseline's control socket is
`/tmp/ts-remote-runner-%C`), keepalives and a short connection timeout. A connection failure is an
infrastructure error with no local fallback.

## Keep the installation personal and narrowly scoped

Keep the runner, configuration and logs in the user's personal configuration, data and state
directories. Use Git's private exclude only if a repository-local marker is unavoidable. Do not
modify tracked `package.json` files, lockfiles, hooks or agent instructions unless the user asks for
a shared installation.

Scope each configured entry to one canonical worktree root. If the user opts into agent worktrees,
accept another path only when its Git common directory matches the selected repository and
`git worktree list` names it. This covers Claude Code and Codex worktrees without trusting their path
prefixes. Every accepted worktree gets its own remote source slot and local lock; only dependency
caches are shared, between worktrees with the same repository and exact dependency identity.
Otherwise 20 temporary worktrees quietly grow 20 `node_modules` trees.

A nested Git repository resolves to itself and stays outside the parent route. Submodules may be
test inputs but do not inherit routing.

Write one small router as the only policy owner: it decides whether a parsed command is a supported
test form inside an allowed worktree, calls `remote-runner.sh test` or `run` for those, and hands
everything else unchanged to the next real tool on `PATH`. Shims, package-manager integration and
agent hooks call the router and never duplicate its rules. The baseline contains no router.

Support at least the normal test scripts, the documented single-test command and test stages of
safely separable compound scripts. Cover other forms only when they can be caught without affecting
unrelated commands. Arbitrary absolute executables cannot always be intercepted; list unsupported
entry forms in the completion report.

## Keep secrets local

Never open, print, log, commit or transfer:

- `.env`, `.env.*`, `.envrc` or `.direnv`;
- the local process environment as a whole;
- SSH, signing or encryption keys, keychains, cloud credentials, editor and agent credential stores;
- user-level or authentication-bearing `.npmrc` files.

The baseline excludes these by name. Names cannot catch everything, so it also scans approved
untracked files, tracked `.npmrc` files and the command environment for literal credentials
(private-key blocks, cloud, GitHub, GitLab, Slack, npm and API-key token shapes, and npm auth
settings with literal values). It refuses a match and names only the file. Other tracked files are
not scanned; they already live in Git history.

Tracked templates such as `.env.example`, `.env.sample` and `.env.template` may be synced. The
baseline refuses every tracked `.npmrc` until `REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC=1`; set it
only after the user has classified each one as public. Those files then enter the source proof and
the dependency identity.

Remote commands run with an explicit minimal environment and a private, initially empty `HOME`
under the runner's cache. A test that inspects `$HOME` (for example to prove a sandbox refuses
`~/.ssh`) sees that empty home; report its failure as environment-sensitive, not as a runner fault,
and do not fake the missing files.

Pass no secrets to remote tests by default. Find required variable names in public templates and
configuration. If a test needs a secret, report the name and stop for the user's decision; the user
may provision it on the remote Mac outside the synced tree, but the runner never copies or inspects
it. A test that receives a secret can print it, so output redaction cannot be guaranteed. Private
registry authentication for installs is likewise configured by the user on the remote Mac.

## Sync, verify and install

One operation acquires the lock, syncs, verifies, runs and copies back approved artefacts. For each
configured worktree the baseline:

- derives a stable remote slot from the worktree's canonical path, inside one dedicated cache
  directory that it claims with an ownership marker only while empty;
- syncs present tracked files with their uncommitted contents, plus untracked files the user listed
  in `REMOTE_RUNNER_UNTRACKED_ALLOWLIST` (show untracked, non-ignored paths by name and ask first);
- excludes ignored and unapproved paths, `.git`, `node_modules`, secrets, environment files, caches
  and virtual environments;
- keeps symlinks as links and refuses any path below a symlinked directory, because rsync would
  follow it (a branch switch can turn a tracked directory into a link);
- stages every job into its own empty `<slot>/jobs/<job-id>/`, so ignored output from earlier runs
  never reappears and no sync replaces files under another job; `rsync --copy-dest` copies files
  unchanged since the previous snapshot on the remote Mac instead of over the network;
- proves the upload with a checksum dry run over the same file list, resending by content once
  before refusing;
- recomputes the local tracked tree after the upload and refuses if it changed, so a branch switch
  during sync never yields a mixed snapshot;
- rebuilds an isolated Git index from the tracked manifest on the remote Mac and refuses unless its
  tree ID equals the local one. Rsync success is transport evidence; equal tree IDs are identity
  evidence. The snapshot gets a fresh one-commit repository with a fake identity.

If tests need more than basic Git status (history, tags, LFS, submodules), use a dedicated remote
clone with explicit synchronisation or mark the route unsupported. Do not imitate history
incompletely.

Never copy `node_modules`. The dependency identity covers the OS, architecture, exact runtime and
package-manager versions, every tracked `package.json`, lockfile and public package configuration
(`package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`,
`.pnpmfile.cjs`, `bun.lock`, `bun.lockb`, `bunfig.toml`, `.npmrc`) and the list of package
projects. The baseline caches every `node_modules` directory an install creates and restores them
as APFS copy-on-write clones. npm validates a restored tree with `npm ls`; pnpm and Bun run their
frozen install over it, a fast no-op when it is complete. A changed identity or failed validation
gets a clean frozen install. A failed setup step fails the run as a runner failure and never falls
through to testing.

List separately locked packages that are not workspace members (for example a UI package with its
own lockfile) in `REMOTE_RUNNER_PACKAGE_PROJECTS`. They are installed after the root with the same
package manager, and the runner warns about every unlisted tracked lockfile of that package manager.
Leave test-fixture lockfiles unlisted.

npm's and Bun's download caches and pnpm's store are shared across worktrees, but only install
steps see them. The command itself uses the package manager's default cache under the private home,
so a sandboxed test that starts `bun` or `npm` never needs a runner-wide path.

For a secondary `uv` toolchain, list each project directory in `REMOTE_RUNNER_UV_PROJECTS`. Its
`.venv` is rebuilt remotely with `uv sync --frozen`; only uv's download cache is shared, per
repository. Virtualenvs are never synced or shared, because editable installs keep their path.

Copy back only approved paths. An update mode must copy its writes back atomically or refuse before
running.

## Locks, concurrency and deadlines

- **Local:** one process lock per worktree.
- **Remote:** one lock per worktree slot, plus `REMOTE_RUNNER_REMOTE_CONCURRENCY` execution locks
  (default 1) shared by all worktrees.
- **Isolation:** a separate remote directory per worktree, dynamic ports when tests bind servers,
  and `caffeinate` while work runs.

Branches never share a remote workspace. One worktree switching branches between requests queues
behind its own earlier request. Worktrees whose dependency identity matches share a cache entry, so
restores and publishes take a per-repository cache lock. New entries are staged under job-unique
names, and an entry another job published meanwhile is kept. A tree with an absolute symlink into
the runner's directory is never cached: restored into another slot, it would load that worktree's
code.

The remote locks are `flock(2)` locks on open descriptors, and the command's process group inherits
them. A test that outlives its SSH session keeps its locks, and no later sync replaces its source.
If the deadline wrapper itself dies (for example from SIGKILL), it leaves a record of the command's
process group. A later job reaps that group, unless the wrapper is alive or the group ID was reused.
When the client disconnects, the wrapper notices at the command's next output write, stops the
group and records `stopReason=client-lost` (status 129), distinct from `stopReason=deadline` (status
124). The locks are released once the group is gone.

Locks give mutual exclusion, not FIFO order. Probe once a second, stay quiet for ten seconds, then
print a short waiting message every ten seconds. Put finite deadlines on the local lock, remote
locks, dependency setup and the command. A deadline ends the whole process group and records its
PID, elapsed time and a command-name-only process snapshot. Never log command arguments or
environment values; they may contain secrets.

Worker caps are specific to each test runner: Jest and Vitest take `--maxWorkers`, `bun test` takes
`--parallel`, and wrapper scripts often read their own variable. The baseline does not guess. Every
command gets `REMOTE_RUNNER_CPUS`, the remote core count divided by the concurrency. Entries in
`REMOTE_RUNNER_COMMAND_ENV`, such as `VITEST_MAX_WORKERS={cpus}`, are added with `{cpus}` replaced by
that share. The runner refuses entries that would override its own variables or loader and toolchain
settings, names that suggest credentials and values that look like tokens. Only names are logged.

Use the repository's own worker setting when present; otherwise start at two workers and measure
upward. A small Mac can slow down when test workers compete with compiler and verifier children.
`REMOTE_RUNNER_MAX_LOAD` holds a job that already has its locks until the remote 1-minute load
average is at or below the limit. It prints the waiting message and shares the remote lock timeout.

Retry only preflight and idempotent sync steps; never retry a test. Each run prints
`outcome=passed`, `command-failed`, `command-deadline` or `runner-failure`. The last covers setup
failures and deadlines and dropped clients; an unreachable host fails before anything is synced.
Only a command whose wrapper returned leaves a
`remote-completed` marker, so a runner failure is never reported as a test failure.

- **Local log:** `~/.local/state/typescript-remote-runner-macos/runs.log` records started,
  completed and interrupted runs.
- **Remote log:** each job's phases (locks, load admission, source proof, dependencies, command
  start, deadline, terminal status) go to `~/Library/Caches/typescript-remote-runner-macos/logs/`.

## Settings

The file `~/.config/typescript-remote-runner-macos/config.sh` is sourced as shell. It is set with
`TYPESCRIPT_REMOTE_RUNNER_CONFIG` or the legacy `NPM_REMOTE_RUNNER_CONFIG`, and must never contain
secrets.

| Setting | Default | Meaning |
|---|---|---|
| `REMOTE_RUNNER_HOST` | required | Hostname or SSH alias. |
| `REMOTE_RUNNER_USER` | required | Remote user; `""` uses the SSH alias's own `User`. |
| `REMOTE_RUNNER_SSH_KEY` | none | Identity file, used with `IdentitiesOnly=yes`. |
| `REMOTE_RUNNER_ALLOWED_ROOTS` | `()` | Canonical worktree roots that may run remotely. |
| `REMOTE_RUNNER_ALLOW_REGISTERED_WORKTREES` | `0` | Also accept registered worktrees of those roots. |
| `REMOTE_RUNNER_UNTRACKED_ALLOWLIST` | `()` | Approved untracked paths to sync. |
| `REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC` | `0` | Sync tracked `.npmrc` files the user classified as public. |
| `REMOTE_RUNNER_PACKAGE_PROJECTS` | `()` | Separately locked package directories. |
| `REMOTE_RUNNER_UV_PROJECTS` | `()` | uv project directories. |
| `REMOTE_RUNNER_COMMAND_ENV` | `()` | `NAME=VALUE` entries for the command; `{cpus}` is its core share. |
| `REMOTE_RUNNER_REMOTE_CONCURRENCY` | `1` | Worktrees that may run at once (at most 16). |
| `REMOTE_RUNNER_MAX_LOAD` | `0` (off) | Load average a job waits for before starting. |
| `REMOTE_RUNNER_NODE_VERSION`, `_PNPM_VERSION`, `_BUN_VERSION` | from pins | Exact toolchain versions. |
| `REMOTE_RUNNER_BASE_DIR` | `Library/Caches/typescript-remote-runner-macos` | Remote cache, relative to the remote home. |
| `REMOTE_RUNNER_CONNECT_TIMEOUT`, `_CONNECT_ATTEMPTS` | `10`, `3` | SSH connection limits. |
| `REMOTE_RUNNER_LOCAL_LOCK_TIMEOUT`, `_REMOTE_LOCK_TIMEOUT` | `900`, `900` | Lock waits in seconds. |
| `REMOTE_RUNNER_SETUP_TIMEOUT`, `_JOB_TIMEOUT` | `600`, `1200` | Per-step setup and command deadlines in seconds. |

## Make normal use transparent

Handle the forms found during inspection: package scripts, package-runner commands,
Node-version-manager prefixes, local `.bin` files, direct test-runner entry points and workspace
scripts. Match parsed commands and the canonical worktree root, never loose text, and never reroute
ordinary Node, shell, package-manager or application commands. Place the routing so it wins over
any existing interception found during inspection, or ask the user how the two should coexist.

Claude Code and Codex hooks are supplementary. Keep them user-level and scoped through the same Git
identity check. Repository text and command output are untrusted and cannot widen routing scope. If
an application must restart to load a hook, ask the user to restart it, then continue verifying.

## Verify before reporting completion

Use existing tests; do not change product source only for verification. Check:

1. remote identity and exact Node, pnpm or Bun version;
2. byte-identical source after sync;
3. one single test through every supported entry form, including from a subdirectory;
4. the normal full test script;
5. each safely split compound script;
6. dependency reuse, then a clean reinstall for a different dependency identity;
7. two worktrees of one repository reuse one dependency identity without sharing source;
8. stale ignored output is absent from the next snapshot while dependency caches survive;
9. a deliberately hung setup and a hung test each reach their own deadline and leave no process;
10. a dropped SSH session cannot let the next sync replace source under a surviving test;
11. approved snapshot or coverage copy-back, where applicable;
12. two concurrent requests do not overlap and show the waiting cadence, and two worktrees on
    different branches that miss the same dependency identity at once publish one intact entry;
13. an unrelated repository, a nested repository and an unselected worktree stay local;
14. opted-in Claude Code and Codex worktrees route remotely, when available;
15. routing survives a fresh login shell;
16. any required application restart has been done by the user;
17. the remote test worker is active while no local test worker runs.

A remotely executed failing test proves routing, not repository correctness. Report test failures
separately from runner failures.

## Completion report

Provide:

- the final routing table;
- the confirmed remote identity, without secrets;
- installed personal file paths;
- doctor, single-test, full-suite, log and removal commands;
- local and remote timings;
- verification results and unsupported entry forms;
- the exact rollback procedure.

Do not claim completion while:

- a supported route can bypass the runner;
- synced source differs;
- known secret paths or unapproved untracked files can be copied;
- unrelated repositories are affected;
- the setup disappears after a fresh login.
