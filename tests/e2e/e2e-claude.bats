#!/usr/bin/env bats
# E2E tests for the Claude Code surface against a live cmux nightly.
# All currently `skip` until the SSH harness is wired up. See tests/MANUAL.md.

@test "T-1: single session single tool" { skip "requires SSH harness — see tests/MANUAL.md"; }
@test "T-2: 4 subagents cycling" { skip "requires SSH harness — see tests/MANUAL.md"; }
@test "T-3: cmux daemon kill recovery" { skip "requires SSH harness — see tests/MANUAL.md"; }
@test "T-4: two sessions leader election" { skip "requires SSH harness — see tests/MANUAL.md"; }
@test "T-5: renderer killed mid-loop" { skip "requires SSH harness — see tests/MANUAL.md"; }
@test "T-6: cross-workspace permission alert" { skip "requires SSH harness — see tests/MANUAL.md"; }
@test "T-7: rename before notify pattern" { skip "requires SSH harness — see tests/MANUAL.md"; }
@test "T-9: notify_dest deleted" { skip "requires SSH harness — see tests/MANUAL.md"; }
@test "T-11: disk hygiene" { skip "requires SSH harness — see tests/MANUAL.md"; }
@test "T-12: multi-session union" { skip "requires SSH harness — see tests/MANUAL.md"; }
