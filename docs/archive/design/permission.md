# Permission system — design study

**Status:** draft — open for discussion

Two competing approaches for keeping a franky agent session safe. The agent always has technical ability to run any tool; the question is how to constrain that.

## Problem statement

A typical franky coding session sees 30–100+ tool invocations. The system must:
1. **Bound the damage** if the agent generates a wrong/adversarial command.
2. **Stay out of the way** for >90% of safe calls.
3. **Be auditable** — answer "what did this session actually do".
4. **Survive operator carelessness** — wrong setting shouldn't silently disable safety.

---

## Approach A — Per-tool permission prompts

**Idea:** Every tool call passes through a permission gate. Risky tools pause and prompt the user. Decision remembered per session (optionally per disk-state).

### A.1 Tier policy (default)

| Tool | Default |
|---|---|
| `read`, `ls`, `find`, `grep` | auto-allow inside `workspace_root`, ask outside |
| `write`, `edit` | ask once per tool, remember session-wide |
| `bash` | ask per command fingerprint, remember per fingerprint |

### A.2 Bash command fingerprint

Verb-level: first non-path token (`git`, `rm`, `curl`, `npm`, `zig`). Coarse enough for ~5–10 decisions/session; fine enough that `rm` and `git` are distinct.

### A.3 Decision values

`allow_once`, `deny_once`, `always_allow`, `always_deny`. `always_*` writes to in-memory `PermissionStore` keyed by `{tool, fingerprint}`. Disk persistence opt-in via `--remember-permissions`.

### A.4 Pause / resume protocol

`before_tool_call` hook blocks agent worker while UI thread prompts. New surface: `tool_permission_request` agent event, `Agent.resolvePermission(call_id, Decision)`, `Condition` + `Decision` slot per pending call on `SessionBinding`.

### A.5 Mode-specific UX

| Mode | Behavior |
|---|---|
| Interactive | Modal overlay, single keystroke decides |
| Print | Cannot prompt. Read-only auto-allowed, others auto-denied unless `--allow-tools <csv>` or `--yes` |
| RPC | `tool_permission_request` notification; client replies via `permission/resolve` |

### A.6 Storage

`$FRANKY_HOME/permissions.json`: `default_policy`, `always_allow`, `always_deny` maps.

### A.7 Implementation cost

~810 LOC, ~30 tests across 6 sub-milestones (v1.4.0–v1.4.5).

### A.8 Pros
- Fine-grained: bad `rm -rf` caught before running.
- In-band: no external infrastructure needed.
- Audit-friendly: every gated call in transcript with decision.
- Defense in depth.

### A.9 Cons
- Prompt fatigue: 10–15 prompts/session; users mash `A`.
- Session memory dangerous: "always allow `bash:rm`" → every subsequent `rm` sails through.
- Large implementation surface: async pause/resume, modal UI, RPC surface.
- No supply-chain protection: poisoned model + tired user = failure.
- Doesn't help with reads: model exfiltrating secrets via `read` is a permission-system failure.

---

## Approach B — Roles + sandboxed runtime

**Idea:** User picks a capability role at startup. Role determines which tools are available. Safety bound comes from sandbox (Docker/zerobox).

### B.1 Roles

| Role | Tools enabled | Use case |
|---|---|---|
| `read` | `read`, `ls`, `find`, `grep` (workspace-scoped) | Code review, zero side effects |
| `plan` | read-family + `write` + `edit` (no bash) | Refactors, doc updates |
| `code` | plan tools + `bash` (cwd-locked, env-denylisted) | Default for sandboxed runs |
| `full` | Every tool, no restrictions | Power user in trusted sandbox/VM |

Default: `plan`. Role binds at session init — no mid-session escalation. Selected via `--role <name>`.

### B.2 Implementation

`src/coding/role.zig`: `Role` enum, `ToolSet.forRole(r)`. Session binding only registers allowed tools — model never sees disabled tools. `bash` in `code` role uses existing workspace cwd lock + env denylist + shell-trust policy.

### B.3 Sandbox patterns

1. **`docker/sandbox.Dockerfile`** — minimal Debian, non-root user, `/workspace` mount, `~/.franky` mounted `:ro`, `--network=bridge`.
2. **`docs/sandbox.md`** — recipes for Docker, Podman, devcontainers, Lima, bare-metal.
3. **Startup banner** — when not in container and role is `code`/`full`, prints yellow warning.

### B.4 Mode-specific UX

| Mode | Behavior |
|---|---|
| Interactive | `--role` flag, status bar shows role |
| Print | Role binds at startup; CI defaults to `--role read` |
| RPC | Role in session-init message |

### B.5 Implementation cost

~230 LOC, ~10 tests across 4 sub-milestones.

### B.6 Pros
- Tiny implementation (~3.5× less code than A).
- Zero prompts — no fatigue.
- Stronger safety floor: sandbox isolation beats per-call prompts.
- Model can't ask for what it doesn't see.
- Industry alignment (Claude Code, Cursor, devcontainers).
- Auditability is structural.

### B.7 Cons
- Coarser than per-tool prompts.
- Hard dependency on sandbox setup for safety.
- Higher operational entry barrier (Docker, image, mounts).
- No fine-grained refusal ("allow `git`, deny `curl`" needs A layered on top).
- Sandbox escapes are real.
- Network is the weak spot.

---

## Comparison

| Axis | A: per-tool prompts | B: roles + sandbox |
|---|---|---|
| Safety floor | Bounded by user vigilance | Bounded by sandbox isolation |
| Safety ceiling | Excellent for careful users | Excellent if sandbox configured correctly |
| UX | 5–10 prompts/session | Zero prompts |
| Auditability | Per-call | Per-session (role bound + sandbox boundary) |
| Implementation effort | ~810 LOC, 6 sub-milestones | ~230 LOC, 4 sub-milestones |
| Entry barrier | None | Docker + image + mount |
| Failure mode | Prompt fatigue → dangerous call permitted | Wrong role + bare-metal → no enforcement |

**Key observation:** They're not mutually exclusive. Roles bound capability ceiling; per-tool prompts gate specific calls within that ceiling.

---

## Recommendation

**Ship Approach B first** (v1.4.x line). Reasons:
1. 3.5× less code, 4× faster to ship.
2. Stronger safety floor under realistic conditions.
3. Industry default — matches user muscle memory.
4. Composable — v1.5 can layer Approach A as `--prompts` opt-in.

**Execution order:**
- v1.4.0: `Role` enum + `--role` flag + tool-registry filter + sandbox-detection warning. ~200 LOC.
- v1.4.1: `docker/sandbox.Dockerfile` + `franky-docker` wrapper + `docs/sandbox.md`. Docs-only.
- v1.4.2: Status-bar role indicator + `/role` slash command. ~30 LOC.
- v1.5.0 (later): opt-in per-tool prompts via `--prompts` flag.

**Hybrid in practice:**
- Default user (no sandbox, `--role plan`): zero bash, no prompts, safe by default.
- Power user (sandbox + `--role code`): full capability, damage bounded by container.
- Cautious user (sandbox + `--role code --prompts`): belt-and-braces.

---

## Open questions (Approach B)

1. **Dockerfile + wrapper:** sibling project (deployment concern, not code concern).
2. **Sandbox detection:** check `/.dockerenv`, `/run/.containerenv`, `$container`, `/proc/1/cgroup`.
3. **`--role full`:** ship it, but require `--i-know-what-im-doing` or confirmation prompt.
4. **Per-role cwd policy:** `code`'s `bash` allowed to `cd /tmp` inside sandbox, not on bare metal. Wire through `path_safety`.
5. **Provider-network locking:** deferred to v1.5+.

---

## Roadmap — role-first (✅ all shipped at binary v1.9.0–v1.9.5)

Approach B chosen. Three refinements from second design pass:

1. **Runtime role gate (defense-in-depth).** Two-layer check:
   - Layer 1 (registration): tool registry filtered at session init; model's tool-list reflects filtered set.
   - Layer 2 (runtime gate): if tool_call arrives for known-but-role-disabled tool → emit `tool_execution_end` with `tool_code: "role_denied"` + structured message listing available tools and minimum role needed. Model can recover.
   - New: `errors.ToolCode` constant `"role_denied"`. ~30 LOC.

2. **Mode coverage extends to proxy + Slack-bot.** Each surface expresses active role and reports role-denial cleanly. Proxy: `GET /role` endpoint, header role pill, `is-role-denied` tool-card styling. RPC: role in `version` response + `role` method.

3. **Sandbox via zerobox, not Docker.** Single binary (~7 MB, ~10 ms overhead) using macOS Seatbelt + Linux bubblewrap+seccomp. Domain-level network firewall + credential placeholder system. No daemon, no image, no mount ceremony.

### Roles (final)

| Role | Tools | Workspace policy | Network |
|---|---|---|---|
| `read` | read, ls, find, grep | Read-only inside workspace_root | Provider hosts only |
| `plan` | read-family + write, edit | Read+write inside workspace_root | Provider hosts only |
| `code` | plan + bash (cwd-locked, env-denylisted) | Same + bash writes anywhere reachable | Provider hosts only; `--network=open` opt-in |
| `full` | All tools, no restrictions | Anywhere on host | Open |

Default: `plan`.

### Implementation milestones (✅ all shipped)

| Milestone | Binary | Scope | Tests |
|---|---|---|---|
| v1.4.0 | v1.9.0 | `role.zig` — `Role` enum, `ToolSet.forRole(r)`, `--role` CLI, registry filter, sandbox detection | 8 |
| v1.4.1 | v1.9.1 | Runtime role gate — `RoleDeniedFn` callback, `role_denied` constant, `makeRoleDeniedResult()`, `pushToolEnd` carries `tool_code` | 5 |
| v1.4.2 | v1.9.2 | Mode UX — print stderr banner, interactive `/role` command, rpc `role` method + version response | 4 |
| v1.4.3 | v1.9.3 | Proxy/web-UI — `GET /role`, header role pill, `is-role-denied` styling, `ROLE_DENIED` constant | 3 |
| v1.4.4 | v1.9.4 | Sandbox — `scripts/franky-zerobox` wrapper, `docs/sandbox.md`, sandbox detection at startup | 2 |
| v1.4.5 | v1.9.5 | `/permissions` slash command (show/clear/revoke) | 2 |

**Ship deliverables:**
- `scripts/franky-zerobox` — POSIX shell wrapper mapping `--role` to zerobox flags. ~50 lines.
- `docs/sandbox.md` — recipes for zerobox (primary), Docker, Podman, devcontainers, Lima, bare-metal.
- Sandbox detection at startup: checks `$ZEROBOX_ACTIVE`, `/.dockerenv`, `/run/.containerenv`, `$container`. Yellow warning if role is `code`/`full` outside sandbox.
