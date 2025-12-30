# ztk

ztk (Ztack) is a tiny, opinionated CLI for stacked pull requests on GitHub. It keeps the model simple (one commit = one PR), focuses on predictable behavior, and provides a clean terminal UX for status, update, review, and merge workflows.

## What ztk does

- Treats your current branch as a stack of commits ahead of `main` (configurable).
- Creates and updates one PR per commit, chained in order.
- Shows stack status with checks, reviews, and conflicts.
- Helps you edit or absorb changes into earlier commits without manual rebase gymnastics.
- Merges the top mergeable portion of the stack and cleans up branches.

## Core concepts

### Stack model

- Stack = all commits on your current branch that are ahead of `main` (or the configured base branch).
- Order matters: the bottom commit targets `main`, each subsequent PR targets the previous PR branch.
- One commit = one PR. Commit subject becomes PR title; commit body becomes PR body.

### Branch naming

ztk creates per-commit branches like:

```
ztk/<current-branch>/<id>
```

`<id>` is taken from a `ztk-id:` marker in the commit message (preferred) or the commit short SHA.

### ztk-id markers

To keep PRs stable across rebases/amends, ztk stores a `ztk-id: <uuid>` line in each non-WIP commit message. If a commit lacks a marker, `ztk update` will rewrite the stack to inject them.

Notes:

- The rewrite uses `git rebase` under the hood and may touch multiple commits.
- ztk stashes and restores working changes, but untracked files are not stashed.
- If you rely on custom commit message formats, keep the `ztk-id:` line intact.

### WIP commits

A commit is treated as WIP if its title starts with `WIP` or contains `[WIP]`. WIP commits:

- Appear in `ztk status` as WIP.
- Are skipped by `ztk update`, `ztk merge`, and `ztk open`.

## Requirements

- Git
- Zig (to build)
- GitHub auth for PR operations:
  - `GITHUB_TOKEN` environment variable, or
  - `gh auth login` (ztk reads `gh auth token`)

## Install / build

Build the binary:

```
zig build -Doptimize=ReleaseFast
```

Run it from the build output:

```
./zig-out/bin/ztk --help
```

Or run directly with Zig:

```
zig build run -- status
```

## Quick start

1. Initialize config in your repo:

```
ztk init
```

This creates `.ztk.json` with the GitHub owner/repo and default branch.

2. Authenticate with GitHub (for update/status/merge/review/open):

```
export GITHUB_TOKEN=...   # or: gh auth login
```

3. Make commits on your feature branch.

4. Sync to GitHub:

```
ztk update
```

5. Check status:

```
ztk status
```

## Configuration

ztk stores config in `.ztk.json` at the repo root.

Example:

```json
{
  "owner": "octocat",
  "repo": "hello-world",
  "main_branch": "main",
  "remote": "origin"
}
```

Fields:

- `owner`: GitHub org/user.
- `repo`: GitHub repo name.
- `main_branch`: base branch used to compute the stack.
- `remote`: git remote name (defaults to `origin`).

## Command reference

### init

```
ztk init
```

- Reads your `origin` GitHub remote and writes `.ztk.json`.
- Fails if not in a git repo or the remote is not GitHub.

### status (aliases: `s`, `st`)

```
ztk status
```

- Shows commits in the current stack (bottom to top).
- With GitHub auth, includes PR number, checks, review status, and conflicts.

### update (aliases: `push`, `u`, `up`)

```
ztk update
```

- Ensures each non-WIP commit has a `ztk-id` marker (may rewrite the stack).
- Creates or updates per-commit branches and PRs on GitHub.
- Uses commit subject as PR title and commit body as PR body.

### sync

```
ztk sync
```

- Fetches from remote.
- Rebases current branch on `remote/main_branch`.
- Cleans up merged `ztk/<branch>/*` branches (requires GitHub auth).

### modify

```
ztk modify [--update]
```

- Requires staged changes.
- Lets you select a commit in the stack.
- Creates a fixup commit and autosquashes via interactive rebase.
- With `--update` (or `-u`), runs `ztk update` after rewriting.

### absorb (aliases: `a`, `ab`)

```
ztk absorb [--update]
```

- Requires staged changes.
- Uses `git blame` to map hunks to a single commit in the stack.
- Shows an absorb plan and asks for confirmation.
- Creates fixup commits and autosquashes.
- With `--update` (or `-u`), runs `ztk update` after rewriting.

### merge (alias: `m`)

```
ztk merge [options]
```

- Finds the largest contiguous mergeable portion of the stack.
- Updates the top PR base to `main_branch`, merges it, and closes lower PRs.
- Deletes the merged PR branches.

Options:

- `-i`, `--interactive`: pick how many mergeable PRs to merge.
- `-r`, `--rebase`: rebase your local branch on updated `main_branch` after merge.
- `-n`, `--no-review`: do not require approved reviews.
- `-f`, `--force`: only block on conflicts (ignores checks/reviews).

### review (aliases: `r`, `rv`)

```
ztk review [--stack] [--pr <num>] [--list]
```

- Interactive TUI for PR review summaries and inline comments.
- Defaults to the PR for the top commit on the stack.
- `--stack` shows feedback for all PRs in the stack (use `h`/`l` to switch).
- `--list` prints feedback without TUI (useful for scripting).

### open (alias: `o`)

```
ztk open
```

- Opens the PR in your browser.
- If multiple PRs exist, you select which one to open.

## Common workflows

### Create a new stack

```
git checkout -b my-feature
git commit ...
git commit ...
ztk update
```

### Amend an earlier commit

```
git add -p
ztk modify -u
```

### Absorb staged fixes into the right commits

```
git add -p
ztk absorb -u
```

### Review feedback across the stack

```
ztk review --stack
```

## Safety notes

- `ztk update`, `modify`, and `absorb` can rewrite commits in your stack.
- Keep your working tree clean before running rewrite-heavy commands.
- Untracked files are not stashed automatically.
- `ztk merge` can close PRs and delete branches; use `--interactive` if you want tighter control.

## GitHub-only (for now)

ztk targets GitHub and the GitHub API today. Other forges are not supported yet.
