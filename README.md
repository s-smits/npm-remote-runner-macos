# Configure a personal remote macOS test runner

You are an implementation agent. Set up transparent remote test execution for one or more local
Node.js repositories, using another Mac as the runner.

Your first reply must contain exactly this question and nothing else:

> Which local repository or repositories should use the remote macOS test runner?

Wait for the answer before inspecting files or changing either computer.

Use [`remote-runner.sh`](./remote-runner.sh) as the starting point. It deliberately supports an npm
repository with `package-lock.json`; copy it into the user's personal tools and expand the installed
copy only where the selected repositories require different behaviour. The baseline deliberately
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
- package manager, Node-version manager, Node, npm and rsync.

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
repository's pinned Node version and verify it through a non-interactive SSH login.

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
path prefixes. Give every accepted worktree its own remote directory and lock.

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

Tracked public templates such as `.env.example`, `.env.sample` and `.env.template` may be synced. A
tracked project `.npmrc` may be synced only when it contains public settings or variable
placeholders instead of literal credentials.

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
- preserve symlinks as links and never follow them outside the worktree;
- use deletion so removed local source does not survive remotely;
- run a checksum-based dry run with identical filters and refuse on any remaining source difference.

Never copy `node_modules`. Derive a dependency identity from the operating system, architecture,
exact Node and package-manager versions, manifests, lockfiles and public package configuration. Use
the package manager's clean frozen install when the identity changes or validation fails.

If tests need only basic Git status, construct isolated snapshot metadata remotely. If they need
history, tags, LFS or submodules, use a dedicated remote clone with explicit synchronisation or mark
that test route unsupported. Do not imitate Git history incompletely.

Copy back only approved paths. Detect snapshot and coverage locations. An update mode must either
copy its writes back atomically or refuse before execution.

Use:

- one process-scoped local lock per worktree;
- one process-scoped remote lock by default;
- a separate remote directory per worktree;
- dynamic ports when tests bind servers;
- `caffeinate` while work runs.

The locks provide mutual exclusion, not FIFO ordering. Probe once per second. Stay quiet for ten
seconds, then print a short waiting message every ten seconds. Ensure locks release when their
owning process exits or receives a signal.

Use the repository's worker setting when present. Otherwise start with the remote logical-core
count. If that swaps or is slower, measure a smaller value and retain the faster stable setting.

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

1. remote identity and exact Node version;
2. byte-identical source after sync;
3. one single test through every supported entry form;
4. the normal full test script;
5. each safely split compound script;
6. dependency reuse, then clean reinstallation for a different dependency identity;
7. approved snapshot or coverage copy-back where applicable;
8. two concurrent requests do not overlap and show the specified waiting cadence;
9. an unrelated repository, nested repository and unselected worktree remain local;
10. opted-in Claude Code and Codex worktrees route remotely, when such worktrees are available;
11. routing survives a fresh login shell;
12. any required application restart has been completed by the user;
13. the remote test worker is active while no local test worker is running.

A remotely executed failing test proves routing, not repository correctness. Report test failures
separately from runner failures.

## Completion report

Provide:

- the final routing table;
- confirmed remote identity without secrets;
- installed personal file paths;
- doctor, single-test, full-suite and removal commands;
- local and remote timings;
- verification results and unsupported entry forms;
- the exact rollback procedure.

Do not claim completion while the supported routes can bypass the runner, synced source differs,
known secret paths or unapproved untracked files can be copied, unrelated repositories are affected
or the setup disappears after a fresh login.
