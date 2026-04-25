#!/usr/bin/env bats
# E2E tests for the Codex surface against a live cmux nightly.
# All currently `skip` until the SSH harness is wired up. See tests/MANUAL.md.

@test "T-codex-1: SessionStart smoke" { skip "requires SSH harness"; }
@test "T-codex-2: PreToolUse Bash" { skip "requires SSH harness"; }
@test "T-codex-3: PostToolUse" { skip "requires SSH harness"; }
@test "T-codex-4: Multiple Bash cycling" { skip "requires SSH harness"; }
@test "T-codex-5: PreToolUse deny rule" { skip "requires SSH harness"; }
@test "T-codex-6: PermissionRequest cross-workspace" { skip "requires SSH harness"; }
@test "T-codex-7: Stop clean" { skip "requires SSH harness"; }
@test "T-codex-9: Stop with error" { skip "requires SSH harness"; }
@test "T-codex-10: Mixed Claude + Codex" { skip "requires SSH harness"; }
@test "T-codex-11: PostToolUse feedback" { skip "requires SSH harness"; }
@test "T-codex-12: Hook timeout grace" { skip "requires SSH harness"; }
@test "T-codex-13: Policy bypass" { skip "requires SSH harness"; }
@test "T-codex-14: Renderer crash recovery (live)" { skip "requires SSH harness"; }
@test "T-codex-15: SessionStart matcher=clear (live)" { skip "requires SSH harness"; }
@test "T-codex-16: Per-repo policy overlay" { skip "requires SSH harness"; }
@test "T-codex-17: clear_notifications_on_prompt" { skip "requires SSH harness"; }
@test "T-codex-19: Stop-block ack required" { skip "requires SSH harness"; }
@test "T-codex-20: Doctor diagnostics" { skip "requires SSH harness"; }
