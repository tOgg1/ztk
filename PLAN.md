# ztk Implementation Plan

## Goals
1. **Goal 1:** Have ztk available as a working CLI tool
2. **Goal 2:** Create a single PR stack with two PRs and sync it to GitHub
3. **Goal 3:** Beautiful, Graphite-inspired terminal output that surpasses spr

---

## UX Vision: Beyond spr, Inspired by Graphite

### Design Philosophy

**Human-first, not machine-first.** Every output should be instantly scannable and tell a clear story. No cryptic status bits like `[vvvv]` that require decoding.

### What We're Improving Over spr

| spr's Approach | ztk's Approach |
|----------------|----------------|
| `[vxvv] 123 : title` cryptic status bits | Visual tree with clear icons and colors |
| Dense, hard-to-scan output | Generous whitespace and visual hierarchy |
| No visual stack representation | Graphite-style tree with branch lines |
| Status requires mental decoding | Glanceable status with color + icon |

### Visual Design Principles

1. **Tree Visualization** (Graphite-inspired)
   ```
   ◉  feature/add-auth  ← you are here
   │  PR #42 · ✓ Checks · ✓ Approved · No conflicts
   │
   ◯  feature/add-db-layer
   │  PR #41 · ⏳ Checks running · Needs review
   │
   ◯  main
   ```

2. **Status Icons** (Unicode, not ASCII)
   - `◉` Current branch (filled circle)
   - `◯` Other branches (hollow circle)
   - `✓` Pass / Approved (green)
   - `✗` Failed / Rejected (red)
   - `⏳` Pending / Running (yellow)
   - `⚠` Warning / Needs attention (orange)
   - `─` Merged (dimmed)

3. **Color Semantics**
   - **Green**: Success, ready, approved
   - **Yellow**: Pending, in progress
   - **Red**: Failed, blocked, conflicts
   - **Blue**: Informational, PR links
   - **Dim/Gray**: Secondary info, merged items
   - **Bold White**: Current item, emphasis

4. **Generous Whitespace**
   - Section headers with breathing room
   - Blank lines between stack items
   - Clear visual grouping

### Status Display Mockups

#### `ztk status` - Clean Stack View
```
┌─────────────────────────────────────────────────────────────┐
│  Stack: feature/my-stack  (3 ahead of main)                 │
└─────────────────────────────────────────────────────────────┘

  ◉  Add authentication middleware           ← you are here
  │  #47 · ✓ Checks · ✓ Approved · Ready to merge
  │
  ◯  Add user database schema
  │  #46 · ✓ Checks · ⏳ Awaiting review
  │
  ◯  Add core utilities
  │  #45 · ✓ Checks · ✓ Approved · Ready to merge
  │
  ◯  main

  ─────────────────────────────────────────────────────────────
  Summary: 3 PRs · 2 ready to merge · 1 awaiting review
```

#### `ztk status --compact` - Minimal View
```
  ◉ #47 Add authentication middleware     ✓✓ Ready
  ◯ #46 Add user database schema          ✓⏳ Review
  ◯ #45 Add core utilities                ✓✓ Ready
  ◯ main
```

#### `ztk update` - Progress Feedback
```
  Syncing stack to GitHub...

  ◯ Add core utilities
    └─ Branch: ztk/feature/my-stack/a1b2c3d
    └─ Pushing... done
    └─ PR #45 updated

  ◯ Add user database schema
    └─ Branch: ztk/feature/my-stack/e4f5g6h
    └─ Pushing... done
    └─ Creating PR... done → #46

  ◉ Add authentication middleware
    └─ Branch: ztk/feature/my-stack/i7j8k9l
    └─ Pushing... done
    └─ Creating PR... done → #47

  ✓ Stack synced: 3 PRs (1 created, 2 updated)
```

#### Error States - Clear and Actionable
```
  ✗ Conflict detected

  ◯ Add user database schema
  │  Conflicts with: main
  │
  │  Conflicting files:
  │    - src/db/schema.sql
  │    - src/models/user.go
  │
  │  To resolve:
  │    git rebase main
  │    # fix conflicts
  │    ztk update
```

### Interactive Features (Future)

1. **Numbered Selection** (like Graphite's `gt log short`)
   ```
   Select a commit to amend:
   
     [1] ◉ Add authentication middleware
     [2] ◯ Add user database schema
     [3] ◯ Add core utilities
   
   Enter number (1-3): _
   ```

2. **Progress Bars** for long operations
   ```
   Pushing branches ████████████░░░░░░░░ 60% (3/5)
   ```

3. **Contextual Hints**
   ```
   ◉ Add authentication middleware
   │  Ready to merge · run `ztk merge` to merge bottom-up
   ```

### Terminal Compatibility

- Detect TTY and disable colors/unicode when piping
- Respect `NO_COLOR` environment variable
- Provide `--no-color` and `--ascii` flags for accessibility
- ASCII fallback for limited terminals:
  ```
  * Add authentication middleware    <- you are here
  |  #47 - OK Checks - OK Approved
  |
  o Add user database schema
  |  #46 - OK Checks - Pending review
  ```

### Implementation in `ui.zig`

```zig
pub const Style = struct {
    // Colors
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const red = "\x1b[31m";
    pub const blue = "\x1b[34m";
    pub const dim = "\x1b[2m";
    pub const bold = "\x1b[1m";
    pub const reset = "\x1b[0m";
    
    // Icons (Unicode)
    pub const current = "◉";
    pub const other = "◯";
    pub const check = "✓";
    pub const cross = "✗";
    pub const pending = "⏳";
    pub const warning = "⚠";
    pub const arrow = "←";
    pub const pipe = "│";
};

pub fn printStackItem(item: StackItem, is_current: bool) void {
    const icon = if (is_current) Style.current else Style.other;
    const marker = if (is_current) 
        Style.dim ++ " " ++ Style.arrow ++ " you are here" ++ Style.reset 
    else "";
    
    // ... rich formatting
}
```

---

## Architecture Overview

```
src/
  main.zig      # Entrypoint, arg parsing, dispatch
  cli.zig       # Command registration and handlers
  git.zig       # Git CLI wrapper (shells out to git)
  github.zig    # GitHub REST API client
  stack.zig     # Stack/Commit data model
  config.zig    # Config loading (.ztk.json)
  ui.zig        # Printing/formatting helpers
```

### Key Technical Decisions
- **Config format:** `.ztk.json` (stdlib JSON, no external deps)
- **Git integration:** Shell out to `git` via `std.process.Child`
- **GitHub API:** REST v3 with `GITHUB_TOKEN` env var (GraphQL later)
- **Stack model:** Stateless - reads Git + GitHub each run, no local DB
- **Branch naming:** `ztk/{local-branch}/{short-sha}` for PR branches

---

## Phase 0: Bootstrap (< 1 hour)

**Goal:** `ztk help` runs and dispatches subcommands.

### Tasks
1. Create `build.zig` that builds `src/main.zig` into `ztk`
2. Implement `main.zig`:
   - Parse args with `std.process.argsAlloc`
   - Dispatch to `cli.handleCommand()`
3. Implement `cli.zig`:
   - Define commands: `init`, `status`, `update`, `help`
   - Print "not implemented" for each (except help)
4. Add `--help` / no-args usage output

**Deliverable:** Running `ztk` binary that responds to subcommands.

---

## Phase 1: Core Plumbing (1-3 hours)

### 1.1 Config (`config.zig`)

**File format:** `.ztk.json` in repo root
```json
{
  "owner": "your-gh-user",
  "repo": "your-repo-name",
  "main_branch": "main",
  "remote": "origin"
}
```

**Functions:**
- `findRepoRoot(allocator)` - walk up until `.git` found
- `load(allocator)` - parse `.ztk.json`
- `initDefault(allocator, owner, repo)` - create config file

### 1.2 Git Wrapper (`git.zig`)

**Core functions:**
```zig
pub fn run(allocator, args) ![]u8              // Run git command, capture stdout
pub fn runOrFail(allocator, args) ![]u8        // Run, panic on non-zero exit
pub fn currentBranch(allocator) ![]u8          // git rev-parse --abbrev-ref HEAD
pub fn repoRoot(allocator) ![]u8               // git rev-parse --show-toplevel
pub fn commitRange(allocator, base, head) ![]Commit  // git log base..head
pub fn ensureBranchAt(allocator, branch, sha) !void  // git branch -f <branch> <sha>
pub fn push(allocator, branch, force) !void    // git push origin <branch>
```

**Commit parsing format:**
```
git log --reverse --format=%H%x00%s%x00%b%x00 base..head
```
Uses NUL separators for robust parsing.

### 1.3 GitHub Client (`github.zig`)

**Data types:**
```zig
pub const PullRequest = struct {
    number: u32,
    html_url: []const u8,
    state: []const u8,
    head_ref: []const u8,
    base_ref: []const u8,
};
```

**Functions:**
```zig
pub fn findPR(allocator, cfg, head_branch) !?PullRequest
pub fn createPR(allocator, cfg, head, base, title, body) !PullRequest
pub fn updatePR(allocator, cfg, pr_number, title, body, base) !void
pub fn createOrUpdatePR(allocator, cfg, head, base, title, body) !PullRequest
```

**Implementation:**
- Use `std.http.Client` with `https://api.github.com`
- Auth via `GITHUB_TOKEN` env var
- Find existing: `GET /repos/{owner}/{repo}/pulls?head={owner}:{head}&state=open`
- Create: `POST /repos/{owner}/{repo}/pulls`
- Update: `PATCH /repos/{owner}/{repo}/pulls/{number}`

---

## Phase 2: Stack Model + Status (1-3 hours)

### 2.1 Stack Model (`stack.zig`)

```zig
pub const Commit = struct {
    sha: []const u8,
    short_sha: []const u8,
    title: []const u8,
    body: []const u8,
    is_wip: bool,
};

pub const Stack = struct {
    base_branch: []const u8,
    head_branch: []const u8,
    commits: []Commit,
};

pub fn readStack(allocator, cfg) !Stack
```

**WIP detection:** Title starts with "WIP" or contains "[WIP]"

### 2.2 Status Command

**`ztk status` output:**
```
Stack: feature/my-stack (2 commits ahead of main)

  1  abc1234  Add core plumbing
  2  def5678  Implement status command

Summary: 2 commits, 0 WIP
```

**Implementation:**
1. Load config
2. Read stack via `stack.readStack()`
3. Print via `ui.printStackStatus()`

---

## Phase 3: Update Command (1-2 days)

### 3.1 Branch Naming & Stacking

For each commit `Ci` in order (oldest → newest):
- Branch: `ztk/{local-branch}/{short-sha}`
- Base: `i == 0 ? main_branch : branch[i-1]`

Example stack:
```
main
 └── ztk/feature/demo/abc1234  <- PR1 (base: main)
      └── ztk/feature/demo/def5678  <- PR2 (base: ztk/.../abc1234)
```

### 3.2 PR Spec Generation

```zig
pub const PRSpec = struct {
    sha: []const u8,
    branch_name: []const u8,
    base_ref: []const u8,
    title: []const u8,
    body: []const u8,
    is_wip: bool,
};

pub fn derivePRSpecs(allocator, stack, cfg) ![]PRSpec
```

### 3.3 Update Command Flow

```zig
fn cmdUpdate() !void {
    const cfg = try config.load(allocator);
    const stk = try stack.readStack(allocator, cfg);
    const specs = try derivePRSpecs(allocator, stk, cfg);
    
    for (specs) |spec| {
        // Skip WIP commits for now
        if (spec.is_wip) continue;
        
        // Create/update branch at commit SHA
        try git.ensureBranchAt(allocator, spec.branch_name, spec.sha);
        try git.push(allocator, spec.branch_name, true);
        
        // Create or update PR
        const pr = try github.createOrUpdatePR(
            allocator, cfg,
            spec.branch_name, spec.base_ref,
            spec.title, spec.body
        );
        
        ui.printPRUpdate(pr);
    }
}
```

### 3.4 End-to-End Test

```bash
# Setup
git checkout -b feature/ztk-demo
echo "change 1" > file.txt && git add . && git commit -m "First change"
echo "change 2" >> file.txt && git add . && git commit -m "Second change"

# Run ztk
ztk init          # Creates .ztk.json
ztk status        # Shows 2 commits
ztk update        # Creates 2 PRs

# Verify on GitHub:
# - PR1: base=main, head=ztk/feature/ztk-demo/<sha1>
# - PR2: base=ztk/.../<sha1>, head=ztk/.../<sha2>
```

---

## Future Phases (Post-MVP)

### Graphite-Inspired Commands to Add

Based on Graphite's excellent UX, consider these commands for future versions:

| Command | Graphite Equivalent | Description |
|---------|---------------------|-------------|
| `ztk log` | `gt log` | Tree visualization with PR status |
| `ztk log --short` | `gt log short` | Compact numbered list for quick selection |
| `ztk up` / `ztk down` | `gt up` / `gt down` | Navigate up/down the stack |
| `ztk top` / `ztk bottom` | `gt top` / `gt bottom` | Jump to top/bottom of stack |
| `ztk sync` | `gt sync` | Pull main, restack, clean merged branches |
| `ztk modify` | `gt modify` | Amend current commit + restack above |
| `ztk create` | `gt create` | Create new branch/commit on top of current |
| `ztk submit` | `gt submit` | Submit (push + create/update PRs) |

### Phase 4: Commit ID Markers
- Add `ztk-id: <uuid>` to commit messages for stable PR mapping across rebases
- Required for `ztk amend` to work correctly

### Phase 5: Status with GitHub Info
- Fetch PR status (checks, approvals, conflicts)
- Colorized output with status indicators

### Phase 6: Amend Command
- Interactive commit selection
- Rebase-based workflow to amend commits in middle of stack
- Auto-resync PRs after amend

### Phase 7: Merge Command
- Compute mergeable PRs (checks pass, approved, no conflicts)
- Bottom-up merge via GitHub API
- Close stacked PRs after merge

---

## Risks & Guardrails

1. **Force-push safety:** Only touch `ztk/*` branches; confirm before touching others
2. **Main branch drift:** Show exact base commit in status; warn if behind remote
3. **Token misconfiguration:** Fail loudly with clear error messages
4. **Non-linear history:** Detect merges and bail with helpful message

---

## File Checklist

- [ ] `build.zig`
- [ ] `src/main.zig`
- [ ] `src/cli.zig`
- [ ] `src/config.zig`
- [ ] `src/git.zig`
- [ ] `src/github.zig`
- [ ] `src/stack.zig`
- [ ] `src/ui.zig`
