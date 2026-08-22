# Test architecture (live vs proposal)

This file records the live Pester topology on `origin/main` at
`028ac38e87c56fc582db42210ed620693dc3ce29` (VERSION `0.36.35`). It does not
change runners, pins, CI, or tests.

Live facts and future constraints are separate. A sentence in the proposal
section is not in force until a later product PR lands it.

## Live

Operator and CI Pester is exact `5.7.1`.

- Resolver: `scripts/winsmux-pester.psm1` `Resolve-WinsmuxPester571` (line 209).
  It keeps only modules whose `Version` is the string `5.7.1` (lines 220 and
  267).
- Shard import re-checks that identity: `scripts/run-pester-shard.ps1` line 167
  calls the resolver; line 194 throws unless the imported module version is
  `5.7.1`.
- CI install pins the same version:
  `.github/workflows/test.yml` lines 443, 713, and 1154
  (`Install-Module ... -RequiredVersion 5.7.1`).
- Consumer envelopes reject any other resolved identity: `test.yml` lines 376
  and 646.
- TASK-810 / TASK-811 tests bind that resolver body
  (`tests/Task811OperatorInfraGate.Tests.ps1` lines 266-273).

`tests/README.md` line 3 says development may use Pester `5.0` or later. That is
not the operator or CI identity. Full-suite entry points still go through
`scripts/run-tests.ps1` (`tests/README.md` lines 7 and 13).

CI runs the shard runner (`scripts/run-pester-shard.ps1`). Local full-suite
parallelism is the custom child-`pwsh` path `Invoke-ParallelSuite` in
`scripts/run-tests.ps1` lines 2340-2375. That path is not Pester 6
`Run.Parallel`. `Run.Parallel` is absent on this tree.

TASK-792 measured a Pester `5.7.1` full run: 1570/1570 passed in 1333.166s with
46 workers. That measurement is not a Pester 6 comparison. Official full-suite
acceptance at 180 seconds is therefore unproven.

The comment marker `#pester:no-parallel` is not live. It does not currently
force serial execution. Coverage, golden updates (`WINSMUX_UPDATE_GOLDEN=1`),
and files that mutate shared session, process, environment, repository, or
fixed paths already stay serial through the existing runner flags, not through
that marker.

`docs/project/pester-suite-reduction-plan.md` is coverage-reduction policy
(TASK-407). It is not this topology record.

## Proposal only (not live)

Pester 6 product migration is closed until an isolated benchmark against live
`5.7.1` shows the same test count and the same outcomes, existing
`Should -...` assertions remain compatible, an official full run is at most
180 seconds, and CI is green.

When that evidence exists, the intended official settings are
`Run.Parallel = $true` with `Run.ParallelThrottleLimit`.
`Run.MaxConcurrency` is not a Pester setting. Parallelism is file-level.

A later product change may warn when the slowest file is more than 1.5 times
the mean. Automatic shard balancing is not in scope. Retiring
`Invoke-ParallelSuite` is not in scope until the benchmark exists.

Do not describe `#pester:no-parallel` as currently enforcing serial files.
Do not relabel the live `5.7.1` custom runner as Pester 6.
