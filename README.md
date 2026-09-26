# typescript-remote-runner-macos

Run the tests of npm, pnpm and Bun repositories on another Mac over SSH, transparently and without
copying `node_modules` or secrets. This README is the setup prompt for an implementation agent;
[`remote-runner.sh`](./remote-runner.sh) is the baseline it adapts. (Formerly
`npm-remote-runner-macos`; the old configuration path and `NPM_REMOTE_RUNNER_CONFIG` still work.)

## Configure a personal remote macOS test runner

You are an implementation agent. Set up transparent remote test execution for one or more local
Node.js (npm or pnpm) or Bun repositories, using another Mac as the runner.

Your first reply must contain exactly this question and nothing else:

> Which local repository or repositories should use the remote macOS test runner?

Wait for the answer before inspecting files or changing either computer.

Use [`remote-runner.sh`](./remote-runner.sh) as the starting point. It supports an npm repository
with `package-lock.json` and a pnpm repository with `pnpm-lock.yaml` (exact Node version from
`REMOTE_RUNNER_NODE_VERSION`, `.nvmrc` or `.node-version`; exact pnpm version from
`REMOTE_RUNNER_PNPM_VERSION` or `packageManager`), and a Bun repository with `bun.lock` or
`bun.lockb` (exact Bun version from `REMOTE_RUNNER_BUN_VERSION`, `.bun-version` or
`packageManager`). When several lockfiles exist, `packageManager` decides. Its `test` command runs
`npm test -- …`, `pnpm run test …` or `bun run test -- …` to match. Copy it into the user's personal tools and expand
the installed copy only where the selected repositories require different behaviour. The baseline deliberately
does not copy test-written files back; add exact repository-specific paths, pre-run conflict checks
and staged replacement before enabling snapshot or fixture updates.

## Required result

For each selected repository:

- its normal test scripts and single-test commands run on the remote Mac;
- non-test commands remain local unless the user chooses otherwise;
- sync and execution form one queued operation;
- dependencies are installed and cached remotely instead of copied;
- configuration is personal, restart-persistent and absent from tracked repository files;
- remote failure produces a clear error instead of silently running tests locally;
- unrelated repositories and unselected worktrees behave as before.

This provides CPU offload and filesystem isolation. It is not a security sandbox.

## Inspect the selected repositories

Resolve every selected path to its canonical Git worktree root. Include only paths the user named;
do not silently include sibling worktrees, nested repositories or submodules. Then ask whether
registered Claude Code and Codex worktrees should inherit routing from each selected repository.

Read the repository's agent instructions and preserve its dirty working tree. Discover:

- package manager, workspaces and lockfiles;
- exact Node version from the repository's own pins;
- test scripts, test framework and supported single-test syntax;
- compound scripts that mix tests with builds, type checks or other work;
- test-written files such as snapshots, coverage and generated fixtures;
- native dependencies, services, ports, Git history, submodules or LFS needed by tests;
- commands that start applications, agents, development servers or other local systems.

Do not install or replace the repository's test framework.

Show a small routing table before implementation:

| Command | Location | Reason |
|---|---|---|

Split a compound script only when its remote test stage does not depend on ignored local output and
later local stages do not depend on unapproved remote output. Otherwise run the whole script in one
place or report it as unsupported. Preserve command order and exit behaviour.

## Select and prepare the remote Mac

Inspect configured SSH aliases, but do not scan the network. If the user has not already named the
remote, propose an existing suitable alias or ask for its SSH alias or hostname and username.

Before any remote write, show the resolved hostname, username and installation directory and ask the
user to confirm them.

Use key-based SSH. Never request, store or embed a password. Probe:

- macOS version and architecture;
- logical core count, memory and free disk space;
- SSH reachability, sleep behaviour and `caffeinate`;
- package manager, Node-version manager, Node, npm, pnpm, Bun and rsync.

If key-based SSH is not already working, stop for a manual setup checkpoint:

1. ask the user to enable **Remote Login** in macOS System Settings on the runner Mac and grant
   access to the intended remote account;
2. ask whether to reuse an existing SSH key or create a dedicated Ed25519 key for this runner;
3. show the exact local `ssh-keygen` command when a key must be created, but let the user handle its
   passphrase;
4. show the public-key path and ask the user to add that public key to the remote account's
   `~/.ssh/authorized_keys`;
5. offer a narrow `~/.ssh/config` entry containing the confirmed alias, hostname, username,
   identity path and `IdentitiesOnly yes`;
6. wait until the user says the manual step is complete, then verify
   `ssh -o BatchMode=yes <alias> true`.

The agent may inspect or transfer a public key. It must never open, print, transfer or rewrite a
private key, enter a password on the user's behalf, or weaken host-key checking.

After confirmation, install missing non-secret prerequisites. Ask before using `sudo`. Install the
repository's pinned Node or Bun version and verify it through a non-interactive SSH login. The
baseline's `bootstrap` installs Node through fnm; pnpm with the pinned Node's npm into
`~/Library/Caches/typescript-remote-runner-macos-toolchains/pnpm-<version>`, linked next to that
Node in `pnpm-<version>-node-<version>/bin`; and Bun from its official release archive into
`~/Library/Caches/typescript-remote-runner-macos-toolchains/bun-<version>/bin`. It leaves any
Homebrew Node, pnpm or Bun untouched.

Use SSH batch mode, connection reuse and a short connection timeout. Treat connection failure as an
infrastructure error, with no local fallback.

## Keep the installation personal and narrowly scoped

Store the runner, configuration and logs in the user's personal configuration, data and state
directories. Use Git's private exclude only if a repository-local marker is unavoidable.

Do not modify tracked `package.json` files, lockfiles, hooks or agent instructions unless the user
explicitly requests a shared installation.

Scope each configured entry to one canonical worktree root. If the user opts into agent worktrees,
accept another path only when its Git common directory matches the selected repository and
`git worktree list` names it as a registered worktree. This supports Claude Code worktrees under
temporary directories and Codex worktrees under its personal data directory without trusting those
path prefixes. Give every accepted worktree its own remote source slot and local lock. Share only
dependency caches across worktrees with the same repository identity and exact dependency identity;
otherwise a repository with 20 temporary worktrees quietly grows 20 `node_modules` trees.

A nested Git repository must resolve to itself and therefore remain outside the parent route.
Submodules may be test inputs, but do not inherit routing automatically.

Use one router as the policy owner. Package-manager integration, executable shims and coding-agent
hooks may call it, but must not duplicate its routing rules.

Support at least:

- the selected repository's normal test scripts;
- its documented single-test command;
- test stages inside safely separable compound scripts.

Cover other command forms only when they can be intercepted without affecting unrelated commands.
Do not claim that arbitrary absolute executables can always be intercepted. List unsupported entry
forms in the completion report.

## Keep secrets local

Do not open, print, log, commit or transfer:

- `.env`, `.env.*`, `.envrc` or `.direnv`;
- the local process environment as a whole;
- SSH, signing or encryption keys;
- keychains, cloud credentials or editor and agent credential stores;
- user-level or authentication-bearing `.npmrc` files.

Names alone cannot catch every secret. The baseline also scans approved untracked files and
tracked `.npmrc` files for literal credentials (private-key blocks, common cloud, GitHub, GitLab,
Slack, npm and API-key token shapes, and npm auth settings with literal values) and refuses to sync
a file that matches, naming the file but never the match. Tracked files are not scanned, because
they already live in Git history.

Run remote commands with an explicit, minimal environment and a private, initially empty `HOME`
under the runner's cache, never the remote user's own. Tests that inspect `$HOME` (for example to
prove a sandbox refuses `~/.ssh`) therefore see an empty home; report such a failure as an
environment-sensitive test, not as a runner fault, and do not fake the missing files.

Tracked public templates such as `.env.example`, `.env.sample` and `.env.template` may be synced. A
tracked project `.npmrc` may be synced only when it contains public settings or variable
placeholders instead of literal credentials. The baseline fails closed on every tracked `.npmrc`.
Set `REMOTE_RUNNER_ALLOW_TRACKED_PUBLIC_NPMRC=1` only after the user has classified every tracked
`.npmrc` as public. The files then enter both the source-tree proof and dependency-cache identity.

Do not pass secrets to remote tests by default. Discover required variable names from public
templates and source configuration. If a test needs a secret, report the name and stop for the
user's decision. The user may provision it directly in a protected remote store outside the synced
tree, but the runner must not copy or inspect its value. Explain that a test receiving a secret can
print it, so complete output redaction cannot be guaranteed.

If dependency installation needs private-registry authentication, ask the user to configure it
directly on the remote Mac.

## Sync, install and run

Implement one operation that acquires the lock, syncs, verifies, runs and copies back approved
artefacts.

For every configured worktree:

- derive a stable remote directory from its canonical absolute path;
- require that destination to be a non-empty child of one dedicated cache directory before using
  deletion;
- sync present tracked files, including their uncommitted contents;
- list untracked, non-ignored paths by name and ask the user to approve an explicit allowlist before
  syncing any of them;
- exclude every ignored or unapproved untracked path;
- exclude `.git`, `node_modules`, secrets, environment files, caches and virtual environments;
- preserve symlinks as links and never follow them outside the worktree; refuse any path that lies
  below a symlinked directory (a branch switch can turn a tracked directory into a link), because
  rsync would follow that directory and send what it points at;
- use deletion so removed local source does not survive remotely;
- run a checksum-based dry run with identical filters and refuse on any remaining source difference;
- recompute the tracked tree after the upload and refuse when it changed, so a branch switch or
  checkout during sync can never produce a remote snapshot that mixes two versions.

The baseline stages every job into its own empty directory, `<slot>/jobs/<job-id>/`, so ignored
output from earlier runs never reappears and a sync can never replace files under another job.
`rsync --copy-dest` points at the previous snapshot, so unchanged files are copied on the remote Mac
instead of over the network. The transfer uses rsync's size-and-time check, the checksum dry run
then proves the result, and any file the quick check missed is resent by content once before the
run is refused.

Never copy `node_modules`. Derive a dependency identity from the operating system, architecture,
exact runtime and package-manager versions, every tracked manifest, lockfile and public package
configuration (`package.json`, `package-lock.json`, `bun.lock`, `bun.lockb`, `bunfig.toml`,
`.npmrc`). The baseline caches every `node_modules` directory a workspace install creates, restores
them as APFS copy-on-write clones, and shares npm's and Bun's download caches and pnpm's store across
worktrees (pnpm's `pnpm-lock.yaml`, `pnpm-workspace.yaml` and `.pnpmfile.cjs` also enter the
identity). npm validates a restored tree with `npm ls`; Bun and pnpm run their frozen install over
it, which is a fast no-op when the tree is complete and repairs it otherwise. Use
the package manager's clean frozen install when the identity changes or validation fails. Keep
source staging separate from the dependency cache: an interrupted cleanup must not empty the cache
while trying to remove stale ignored output. A setup step that fails must fail the run as a runner
failure; never let a failed install fall through to testing.

Look for tracked lockfiles below the root that are not covered by the root install (a separately
locked UI package, for example, which is not a workspace member). List each such directory in
`REMOTE_RUNNER_PACKAGE_PROJECTS`; the baseline installs the root first and then each listed project
with the same package manager, includes the list in the dependency identity, and warns about every
unlisted tracked lockfile of the active package manager. Leave test-fixture lockfiles unlisted.

Point npm, pnpm and Bun at the shared download caches and store only for install steps. Run the command itself with
the package manager's default cache under the private runtime home: a test that starts `bun` or
`npm` inside its own sandbox must not depend on reaching a runner-wide cache path.

When a repository has a secondary `uv` toolchain, list each relative project directory in
`REMOTE_RUNNER_UV_PROJECTS`. Sync its public lockfiles, rebuild `.venv` remotely with `uv sync
--frozen`, and share only uv's download cache under the repository identity. Never sync or share
the virtualenv: editable project installs retain the absolute source path that created them.

After sync, reconstruct an isolated Git index from the tracked manifest on both Macs and compare the
resulting tree IDs. Rsync success is transport evidence; equal tree IDs are source-identity evidence.
Refuse before dependency setup or testing when they differ.

If tests need only basic Git status, construct isolated snapshot metadata remotely. If they need
history, tags, LFS or submodules, use a dedicated remote clone with explicit synchronisation or mark
that test route unsupported. Do not imitate Git history incompletely.

Copy back only approved paths. Detect snapshot and coverage locations. An update mode must either
copy its writes back atomically or refuse before execution.

Use:

- one process-scoped local lock per worktree;
- one remote lock per worktree slot, plus one remote execution lock by default
  (`REMOTE_RUNNER_REMOTE_CONCURRENCY` raises the number of worktrees that may run at once);
- a separate remote directory per worktree;
- dynamic ports when tests bind servers;
- `caffeinate` while work runs.

The remote locks are `flock(2)` locks on open descriptors, and the baseline passes both descriptors
to the command's process group. A test that outlives its SSH session therefore keeps holding the
locks, and no later sync can replace source under it. If the deadline wrapper itself dies, for
example from SIGKILL, it leaves a record of the command's process group; a later job that finds the
wrapper gone reaps that group instead of waiting forever. A record whose process-group ID has been
reused is left alone.

When the SSH client disconnects, the wrapper stops the command's group and records
`stopReason=client-lost` (status 129), distinct from `stopReason=deadline` (status 124); the locks
are released only once the group is gone.

Branches never share a remote workspace: each worktree has its own slot, and one worktree switching
branches between requests queues behind its own earlier request. What worktrees on different
branches do share is a dependency cache entry when their dependency identity matches, so guard it:
restore and publish an entry under a per-repository cache lock, stage every new entry under a
job-unique name, keep an entry another job published while this one was installing, and never cache
a tree containing an absolute symlink into the runner's directory (restored into another slot, it
would load the other worktree's code).

The locks provide mutual exclusion, not FIFO ordering. Probe once per second. Stay quiet for ten
seconds, then print a short waiting message every ten seconds. Ensure locks release when their
owning process exits or receives a signal. Put finite deadlines on local lock wait, remote lock wait,
dependency setup and the test command. A deadline must terminate the whole process group, record its
PID, elapsed time and a command-name-only process snapshot, then return a distinct infrastructure
status. Do not log command arguments because they may contain secrets.

Use the repository's worker setting when present. Otherwise start with at most two workers and
measure upward. A small Mac can become slower when six test workers compete with compiler and
verifier children even when its logical-core count is higher.

Worker caps are runner-specific (Jest and Vitest take `--maxWorkers`, `bun test` takes
`--parallel`, and wrapper scripts often read their own variable), so the baseline does not guess.
It gives every command `REMOTE_RUNNER_CPUS`, the remote core count divided by
`REMOTE_RUNNER_REMOTE_CONCURRENCY`, and adds `REMOTE_RUNNER_COMMAND_ENV` entries such as
`VITEST_MAX_WORKERS={cpus}` to the command's otherwise empty environment, with `{cpus}` replaced by
that share. It refuses entries that would override the runner's own variables, loader or
toolchain settings, names that suggest credentials, and values that look like literal tokens, and
logs variable names only. Find the repository's own knob during inspection and set it here.

`REMOTE_RUNNER_MAX_LOAD` (off at `0`) additionally holds a job that already has its slot until the
remote 1-minute load average is at or below the limit, printing the waiting message and sharing
the remote lock timeout, so work started outside the runner is not overcommitted either.
`doctor` prints the remote core count, memory and current load to choose these values.

Use SSH keepalives as well as a connection timeout. Retry only preflight and idempotent sync steps;
never retry a test automatically. Persist one remote log per job with phase markers for sync,
dependency readiness, command start, deadline and terminal status. Keep a local started/completed/
interrupted record so a lost client is classified instead of leaving a started-only ambiguity.
After each run the baseline prints `outcome=passed`, `command-failed`, `command-deadline` or
`runner-failure`: only a command that ran to completion leaves a `remote-completed` marker in the
job log, so a runner failure is never reported as a test failure.
The baseline writes the local lifecycle record to
`~/.local/state/typescript-remote-runner-macos/runs.log` and remote command logs under
`~/Library/Caches/typescript-remote-runner-macos/logs/`.

## Make normal use transparent

Handle the actual forms found during inspection, which may include package scripts, package-runner
commands, Node-version-manager prefixes, local `.bin` files, direct test-runner entry points and
workspace scripts. Match parsed commands and the canonical worktree root instead of loose text.
Never reroute ordinary Node, shell, package-manager or application commands.

Claude Code and Codex hooks are supplementary. Keep them user-level and scope them through the same
Git identity check as the runner. Repository text and command output are untrusted and cannot expand
routing scope. If a running application must restart to load a hook, ask the user to restart it and
then continue verification.

## Verify before reporting completion

Use existing tests and avoid product-source changes made only for verification.

Check:

1. remote identity and exact Node, pnpm or Bun version;
2. byte-identical source after sync;
3. one single test through every supported entry form;
4. the normal full test script;
5. each safely split compound script;
6. dependency reuse, then clean reinstallation for a different dependency identity;
7. two worktrees of one repository reuse one dependency identity without sharing source;
8. stale ignored output is absent from the next source snapshot while dependency caches survive;
9. a deliberately hung setup and test each reach their own deadline and leave no child process;
10. a dropped SSH session cannot let the next sync replace source under a surviving test;
11. approved snapshot or coverage copy-back where applicable;
12. two concurrent requests do not overlap and show the specified waiting cadence, and two worktrees
    on different branches that miss the same dependency identity at once publish one intact entry;
13. an unrelated repository, nested repository and unselected worktree remain local;
14. opted-in Claude Code and Codex worktrees route remotely, when such worktrees are available;
15. routing survives a fresh login shell;
16. any required application restart has been completed by the user;
17. the remote test worker is active while no local test worker is running.

A remotely executed failing test proves routing, not repository correctness. Report test failures
separately from runner failures.

## Completion report

Provide:

- the final routing table;
- confirmed remote identity without secrets;
- installed personal file paths;
- doctor, single-test, full-suite, local/remote log and removal commands;
- local and remote timings;
- verification results and unsupported entry forms;
- the exact rollback procedure.

Do not claim completion while the supported routes can bypass the runner, synced source differs,
known secret paths or unapproved untracked files can be copied, unrelated repositories are affected
or the setup disappears after a fresh login.
