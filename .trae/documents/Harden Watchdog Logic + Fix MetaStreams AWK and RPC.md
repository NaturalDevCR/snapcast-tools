## Watchdog Logic Hardening
- Remove false freeze detection for clean streams: only consider log-staleness when the log file is non-empty and `LOG_STALE_SECONDS > 0`.
- Add safe fallbacks to avoid `set -e` exits: wrap `systemctl show` and other reads with `|| echo 0` and check values before computing uptime deltas; consider `set -Eeuo pipefail` with guarded calls.
- Preserve error history instead of truncating: rotate `ffmpeg-<id>.log` to `ffmpeg-<id>.log.prev.$(date +%s)` before restart, then recreate log and set ownership.
- Resolve config duplication: choose one method for env injection (keep `EnvironmentFile` in unit; remove `.` sourcing in the script) to avoid redundant parsing.
- Stabilize regex handling: store `ERROR_PATTERN_REGEX` quoted in config and always pass to `grep -E` as a single quoted argument.
- Provide a “Force refresh watchdog templates” action: overwrite unit/timer and executor script unconditionally, then `systemctl daemon-reload` to eliminate legacy inline ExecStart remnants.
- Consolidate bulk-enable logic: merge `enable_watchdog_for_existing` into `enable_watchdog_for_all_safe` to reduce maintenance and edge cases.
- Respect version bump policy: bump header and banner versions before commits (e.g., `v1.0.8`).

## MetaStreams AWK Bug Fix
- Replace incorrect regex interpolation with `index()` in `add_or_replace_metastream_line()` to detect existing `meta:///<source_name>/Silence` lines reliably.
- Keep insertion logic: write `new_line` at section end when not replaced; ensure idempotency.
- Validate with a sample config: run function and diff result to confirm replacement vs insertion behavior.

## RPC Error Handling Fix
- Simplify stderr capture by using `2>&1` in a single command substitution; treat non-zero exit as failure and print the captured message.
- Keep return code and echo response on success; avoid process substitution variable scope issues.

## First-Run Robustness
- Move or guard early `chown` calls so they don’t run before `ensure_prereqs` creates `snapserver` user; add `2>/dev/null || true` where appropriate.
- Ensure `install_prereqs` creates user, directories, and ownership deterministically.

## Implementation Steps
1. Update watchdog executor script: log-stale gating, safe fallbacks, preserve logs, remove redundant sourcing.
2. Update unit template: keep `EnvironmentFile`, call external script; add force-refresh path and daemon reload.
3. Fix MetaStreams AWK function with `index()`.
4. Update `rpc()` to single substitution with `2>&1` and proper failure handling.
5. Version bump (header + banner) before each commit.
6. Run `bash -n` syntax check and manual end-to-end verification (enable all watchdogs, status-all, view logs, trigger error patterns).
7. Commit with Conventional Commits and push.

## Validation Plan
- Verify watchdog service runs without regex or unset-var errors; confirm freeze logic does not restart clean streams.
- Confirm logs rotate on restart and historical `.prev.*` files exist.
- Run `status-all` to ensure enable/active columns are correct for every stream.
- Test MetaStreams function by replacing and inserting lines across variants.
- Exercise `rpc()` against a known unreachable endpoint to confirm error path prints stderr.

## Deliverables
- Updated `snap-server-manager.sh` with hardened watchdog logic, fixed AWK replacement, corrected RPC handling, and version bump.
- Verified behavior on a target machine with clean streams (no periodic restarts) and proper error-triggered restarts.
- Conventional Commit history for traceability.