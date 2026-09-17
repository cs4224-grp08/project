
expt_a0 - performance of baseline design as a function of number of clients for workload A

expt_b0 - performance of baseline design as a function of number of clients for workload B

## Engine Test Status (2026-09-17)

Latest user direction: use the existing /home/stuproj/cs08/pgsql installation.
The team expects disposable database data and a fresh cluster for each job.
Separate binaries were originally intended to protect shared engine behavior,
not to preserve test data; separate installations are no longer the workflow.

Removed the private .engine-test/pgsql installation and .engine-test/citus-14.1.0
source/build copy, and deleted the private-build script. B again fixes INSTALL_DIR
to $HOME/pgsql, as A does. The existing Citus library hash is unchanged.
Build logs, hashes, diagnostic results, and the unapplied candidate patch remain
as evidence; no database data or previous benchmark results were deleted here.

Build history: 854178 used the wrong pg_config and failed; 854191 rebuilt an
unpatched engine because git apply skipped files in a nested worktree; diagnostic
854204 reproduced 18 XX000 cases against that unpatched rebuild. Build 854210
failed the source-content guard after incorrect patch-state detection. None of
these establishes that the proposed engine fix works. No shared binary was
patched, and no full baseline rerun was launched.

## Clean-Slate Review

The existing runner sets DATA_ROOT=/tmp/$PGUSER/citus-$SLURM_JOB_ID on each
allocated node, removes that job-specific directory if present, and calls
initdb before creating the job database and registering workers. A new job
therefore starts with fresh database storage, catalogs, and Citus metadata.
Reinstalling PostgreSQL or Citus is not necessary to reset database data.

Potential changes to decide with the user, not implemented:

| Area | Current behavior | Decision needed |
| --- | --- | --- |
| Warmup | RESET_AFTER_WARMUP=0; warmup writes carry into the timed run | Is the required starting point pre-warmup or post-warmup data? Reloading also changes cache conditions. |
| Client counts | Truncate/reload, ANALYZE, and sequence reset; restart reuses PGDATA | Is logical data reset sufficient, or must each client count get a new cluster too? |
| Old directories | Startup removes only the current job's directory; exit stops servers but leaves data | Add deletion of owned job data after confirmed shutdown, with an option to retain failed-job data? |

A failed warmup currently does not stop the measured run. That is another
benchmark-validity issue, not a failure of initdb: consider making such failures
stop or explicitly invalidate the measurement. Reset policy remains unchanged;
the approved lifecycle checks below are now implemented. Filesystem caches are not cleared by initdb or
PostgreSQL restarts; a fresh database is not necessarily a cold-cache experiment.

### Implemented lifecycle checks

Both worktree runners now source lifecycle/servers.sh and use
lifecycle/port_guard.py. Keep the lifecycle directory alongside the experiment
directories when packaging or copying them. The existing installation is used;
no PostgreSQL or Citus binaries were changed.

- Before initialization, acquire a per-node, per-user/port flock and check that
	the IPv4/IPv6 port can be bound. Abort on a lock or port conflict before
	deleting or loading database data. Never unlink the persistent lock file:
	an empty lock file is normal; its open file descriptor holds the lock.
- Hold reservations across initialization, measurement, and PostgreSQL restarts.
	Check guard processes during health checks and release them after shutdown
	attempts and server-step reaping. Ready markers are removed after guard reaping.
- Check pg_ctl status before removing an existing job data directory; reject a
	live server or an unknown status instead of deleting its data.
- Verify SHOW data_directory on every node before creating the job database and
	during health checks. A responding server using another directory is rejected.
- On restart and exit, use bounded pg_ctl stop with wait and verify stopped
	status. Record per-node shutdown logs. Stop errors are visible, prevent a
	restart, and fail an otherwise successful job; existing failures are preserved.
- SIGINT/SIGTERM exit through cleanup with failure status rather than returning
	to benchmark execution. No new data-deletion policy was added.

The file lock is cooperative: it prevents races between runners using this
helper, not arbitrary processes or older scripts. A port bind check cannot
reserve the TCP port throughout the gap before PostgreSQL binds it. Startup
identity and process checks provide additional detection. Slurm cancellation
or SIGKILL can interrupt cleanup, so do not interpret silence as proof of a
successful shutdown; retain the job's lifecycle logs.

Verification on 2026-09-17:
- 12 focused tests pass: lock contention/release, occupied port, expected/wrong
	server identity, live-directory protection, stop/status errors, verified stop,
	cleanup exit propagation, and readiness-marker cleanup.
- Lifecycle-only job 854254 ran on xcnc[0-4], 11:01:50-11:04:05 Singapore time,
	COMPLETED with exit 0:0 and empty stderr. It started and checked five servers,
	restarted them using the normal restart function, then verified final shutdown.
	Each node has two "Verified stopped" records. No benchmark data was loaded
	and no measurements were taken. The queue was empty afterward.
- Slurm termination left ready-marker files in that smoke job; the subsequent
	marker-removal change passed its focused regression test. No second cluster
	run was needed for that file-cleanup-only change.

Run the focused checks with `python3 -B lifecycle/test_lifecycle.py -v`.
For a lifecycle-only Slurm run, submit from expt_a0 or expt_b0 with
LIFECYCLE_CHECK_ONLY=1, COMMIT_DIAGNOSTIC=0, explicit SCRIPT_DIR, and a separate
RESULT_ROOT. Job 854254 used a five-minute limit and expt_b0/lifecycle-results.
The existing table resets, warmup writes, isolation, and transaction SQL remain
unchanged. These checks do not fix the Citus commit-error conversion.

## Active Worktree

Future changes belong in `/home/stuproj/cs08/citus_project_worktrees/baseline-b-investigation`,
branch `fix/benchmark-lifecycle-checks`, based on `e580c16595d003e901adb2468145d6739afa433e`.
The original `citus_project` checkout remains on `kotaro-test` with its existing
dirty files untouched. Both runners retain the team-ID default correction;
B uses the approved notification email. A's placeholder email must be configured
before any future A submission. No commits, pushes, or reruns were made.

## Baseline B Validation: Job 853208

Evidence is preserved in `/home/stuproj/cs08/citus_project_b_20260916`.
See its README for the submission command and smoke history. Full results are
under `expt_b0/slurm-results/job-853208` within that preserved copy; Slurm logs
are `expt_b0/citus-853208.out` and `.err` there. Do not delete these artifacts.

The runner logged completion at 2026-09-17 00:05:38 Singapore time. All five
servers logged final shutdown by 00:06:05. The cs08 queue was empty at the
morning check. Slurm's final state is unavailable: scontrol no longer recognizes
the job and sacct returned "No space left on device". This is not evidence
that the benchmark ran out of disk; the home filesystem reported free space.

| Clients | Warmup pgbench exit | Measured pgbench exit | Measured serialization failures | Client-abort gate |
| --- | --- | --- | --- | --- |
| 1 | 0 | 0 | 0 | Pass |
| 4 | 0 | 2 | 8 | Fail |
| 8 | 0 | 0 | 84 | Pass |
| 16 | 2 | 2 | 93 | Fail |
| 32 | 2 | 2 | 348 | Fail |
| 64 | 2 | 2 | 337 | Fail |

All twelve tee exits are zero; Slurm stderr is empty. All six summary rows
and 54 transaction-metric rows are present. Recorded scale, client counts,
durations, seeds, isolation, logging, and workload B weights match the intended
baseline. Row presence does not make failed runs valid.

Client aborts report distributed shard-commit errors in T1, T2, and T7.
The c4 log explicitly shows worker serialization failures during commit,
followed by T7 client aborts. Preserve the failed runs as diagnostic evidence,
not clean fixed-concurrency performance measurements. Engine root cause and
database consistency after the commit failures have not been established.
Do not weaken isolation or silently retry benchmarks to conceal these errors.

The old polling terminal disconnected before completion and is no longer active.
No data directories or logs were deleted. Process cleanup is supported by the
saved shutdown logs; temporary node-local data was not inspected or removed.
Next step: use the reproduction below to evaluate a correctness-preserving remedy
before planning baseline reruns. Do not retry arbitrary XX000 errors.

## Commit-Abort Investigation (2026-09-17)

### Observed failure

At 2026-09-16 22:48:26.089 Singapore time, worker xcnc3, backend 424673,
reports a serialization failure during COMMIT. At 22:48:26.097 the coordinator,
backend 625566, reports that worker error as a WARNING. At 22:48:26.098 it
reports a failed commit on xcnc3 followed by an ERROR for shard 102090.
The c4 measured pgbench output records T7 client 0 aborting on that shard.

Evidence in the preserved job directory:
- xcnc3-postgresql.log:160: worker error and COMMIT statement.
- xcnc0-postgresql.log:1186: propagated warning, shard error, and COMMIT statement.
- benchmark-results/result-c4.txt:40: warning/error chain and client abort.

### Source trace

The available Citus 14.1.0 and PostgreSQL 18.6 source explains the mechanism:

1. `FinishRemoteTransactionCommit` uses `raiseErrors=false` when processing
	a failed remote commit. `HandleRemoteTransactionResultError` marks that
	connection failed and reports the worker's error as a WARNING.
2. `ErrorIfPostCommitFailedShardPlacements` raises a new ERROR when a modified
	shard's associated connection failed. Its ereport contains an errmsg but
	no errcode, so PostgreSQL's default ERROR SQLSTATE is XX000 (internal_error),
	not the worker serialization-failure code 40001.
3. pgbench's `getSQLErrorStatus` and `canRetryError` only classify 40001 and
	40P01 (deadlock) as retryable. An XX000 error follows the client-abort path;
	increasing --max-tries does not make this error retryable.

Source references relative to /home/stuproj/cs08:
- citus-14.1.0/src/backend/distributed/transaction/remote_transaction.c:572
- citus-14.1.0/src/backend/distributed/transaction/remote_transaction.c:966
- citus-14.1.0/src/backend/distributed/connection/placement_connection.c:994
- postgresql-18.6/src/backend/utils/error/elog.c:450
- postgresql-18.6/src/bin/pgbench/pgbench.c:3237
- postgresql-18.6/src/bin/pgbench/pgbench.c:3376

The original baseline logs omit SQLSTATE, so its classification was initially
inferred from this source path. Job 854086 subsequently captured XX000 from
the client and the same Citus error location at runtime. This confirms the
mechanism in the reproduction, not the full participant layout of every
original transaction.

### Why not simply retry the shard error?

The non-2PC branch in transaction_management.c:550 commits remote transactions
before the post-commit placement check. CoordinatedRemoteTransactionsCommit
(remote_transaction.c:1132) sends commit commands to participants before
collecting their replies. An error here does not establish that all effects
rolled back; blindly retrying could repeat effects on another participant.
The saved logs do not establish whether a partial commit actually occurred.

Do not infer that the entire transaction lacked 2PC merely because one worker
logged plain COMMIT. CoordinatedRemoteTransactionsPrepare skips connections
classified as read-only (remote_transaction.c:1059). The executor can activate
2PC when modifications expand to another connection
(adaptive_executor.c:3353). Exact participant classification and the protocol
decision for this failed T7 remain unresolved.

### Proposed next diagnostic

Use a separate short Slurm allocation with a minimal inventory dataset, the
same distribution and isolation, and controlled concurrent transactions.
Compare same-worker and cross-worker transfers, including their preliminary
distributed reads. Capture verbose SQLSTATE, participant transaction commands,
and before/after quantities while other writers are stopped. Verify both
atomic transfer effects and error classification, then test any proposed fix.
This diagnostic was implemented and run as job 854086; results follow.
No engine, isolation, retry, or baseline-transaction changes were made.

## Controlled Reproduction: Job 854086

The opt-in `COMMIT_DIAGNOSTIC=1` path in `expt_b0/run.sh` uses the existing
cluster lifecycle, invokes `expt_b0/commit_diagnostic.py`, and exits before
baseline schema/data generation. The normal benchmark path is unchanged.
The diagnostic uses psql and Python's standard library; no dependencies were
installed. It is not a throughput benchmark or an exact replay of T7.

Submission ran from this worktree's expt_b0 directory with:

```bash
sbatch --parsable --time=00:10:00 --nodelist='xcnc[0-4]' \
	--job-name=citus-commit-diag --output=diagnostic-%j.out --error=diagnostic-%j.err \
	--export='ALL,TEAM_ID=8,WORKLOAD=B,PG_ISOLATION_LEVEL=serializable,COMMIT_DIAGNOSTIC=1,SCRIPT_DIR=/home/stuproj/cs08/citus_project_worktrees/baseline-b-investigation/expt_b0,RESULT_ROOT=/home/stuproj/cs08/citus_project_worktrees/baseline-b-investigation/expt_b0/diagnostic-results' \
	run.sh
```

Slurm recorded COMPLETED, exit 0:0, from 10:14:18 to 10:14:36 Singapore time
on 2026-09-17. All five servers logged shutdown, and stderr was empty.
Actual versions were PostgreSQL 18.6 and Citus 14.1.0. Recorded isolation was
serializable everywhere, fsync and synchronous_commit were on, and shard count
was 32. Verbose SQLSTATE and statement logging were enabled only for this job.

### Cases and outcomes

Each case resets 128 inventory rows to quantity 100. Two sessions overlap:
the transfer reads source/destination, then debits/credits one unit; a competing
transaction reads the source and increments a distinct witness row, committing
before the transfer. This creates a controlled SSI dependency cycle. A second
variant adds an explicit witness read to the transfer. Each variant is run
three times with same-worker destinations and three with cross-worker destinations.

| Transfer destination | Explicit witness read | Repetitions | Transfer COMMIT SQLSTATE | Competitor COMMIT | Final quantities |
| --- | --- | --- | --- | --- | --- |
| Same worker | No | 3 | XX000 | 00000 | Match acknowledged effects |
| Same worker | Yes | 3 | XX000 | 00000 | Match acknowledged effects |
| Different worker | No | 3 | 40001 | 00000 | Match acknowledged effects |
| Different worker | Yes | 3 | 40001 | 00000 | Match acknowledged effects |

Mapping: source 1 and witness 15 were on shard 102009 on xcnc2; same-worker
destination 17 was on shard 102017 on xcnc2; cross-worker destination 2 was
on shard 102032 on xcnc1. Source and destination stayed at 100 after each
failed transfer, witness became 101, and all other quantities stayed at 100.
There were no mismatches in the full 128-row comparisons.

The same-worker example (coordinator PID 636397) issued plain COMMIT to its
participants. The coordinator logged XX000 at
ErrorIfPostCommitFailedShardPlacements, placement_connection.c:1004, confirming
the previously inferred error producer against the running installation.
The cross-worker example (coordinator PID 636485) issued PREPARE TRANSACTION;
the conflict surfaced as 40001 and prepared participants received ROLLBACK PREPARED.
Worker clocks have small offsets; use session/transaction IDs rather than
cross-host timestamps alone when interpreting ordering.

### Artifacts and limits

Artifacts are under `expt_b0/diagnostic-results/job-854086`: diagnostic-summary.json,
diagnostic-settings.json, placement-map.json, twelve case JSON files containing
step SQLSTATEs and complete actual/expected quantities, session stderr, server
versions, and five verbose PostgreSQL logs. The Slurm output also records every
SQL command and result. The statements have bounded lock/statement timeouts.

This reproduces the classification difference without weakening isolation:
same-worker commit conflicts become non-retryable XX000, while the cross-worker
prepare path preserves retryable 40001. It does not establish the participant
layout of every failed baseline transaction, universal retry safety, or an
engine fix. The contention pattern is synthetic; no network failures or crashes
were injected. Failed transfer effects rolled back in these cases, but that
does not prove all generic commit failures roll back completely.

Recommended next step: present this reproducible case to the instructor/Citus
maintainers and evaluate a supported way to preserve serialization error handling
before rerunning the baseline. An engine patch, forced protocol workaround, or
weaker isolation would be a separate change requiring correctness validation.

## Remedy Evaluation: Job 854116

The next diagnostic compared the original two-statement transfer with one
multi-row UPDATE. The candidate uses CASE to debit the source and credit the
destination, guards source stock and distinct IDs, and requires exactly both
IDs in RETURNING before COMMIT. Otherwise the entire transaction rolls back.
This candidate exists only in commit_diagnostic.py; baseline SQL is unchanged.

Source motivation: TaskListRequires2PC in executor_util_tasks.c:124 selects
2PC for multi-shard modifying tasks, but not a single task with one placement.
This predicts a limitation for source and destination in the same shard.
No supported public force-2PC setting was identified in the inspected source.

Job 854116 used the same diagnostic submission as 854086, except job name
citus-rewrite-diag. It ran from 10:19:20 to 10:19:59 Singapore time on
2026-09-17, COMPLETED with exit 0:0. All five servers logged shutdown and
Slurm stderr was empty. Results are in expt_b0/diagnostic-results/job-854116.

| Row placement | Original transfer COMMIT | Combined UPDATE COMMIT |
| --- | --- | --- |
| Same shard | XX000 in 6/6 cases | XX000 in 6/6 cases |
| Same worker, different shards | XX000 in 6/6 cases | 40001 in 6/6 cases |
| Different workers | 40001 in 6/6 cases | 40001 in 6/6 cases |

The 36 conflict cases cover both implicit and explicit witness-read variants,
with three repetitions each. Fifteen separate boundary checks cover success,
insufficient stock, missing source, missing destination, and identical IDs,
across all three placements. Every boundary check passed; no full-row effect
mismatches occurred in the conflict cases. The check covers a one-unit transfer
and controlled concurrent inventory writes, not every T7 input or writer.

Decision: reject this rewrite as a general fix for the baseline aborts. It
helps different-shard transfers on one worker, but does not solve same-shard
transfers or establish a remedy for T1/T2. Do not promote it to baseline SQL,
launch a full rerun as if fixed, or add blanket XX000 retries. A robust fix
needs a supported engine-level error-handling/protocol remedy or an explicitly
approved experiment changing the transaction guarantees or workload behavior.
The reproduction is ready to share with the instructor or Citus maintainers.

## Investigation Completion and Proposed Fix

### Completed checks

- [x] Validate all six baseline measurements and twelve process exit pairs.
- [x] Verify saved shutdown records, preserve all evidence, and create the worktree.
- [x] Trace representative T1, T2, and T7 client aborts to worker commit conflicts.
- [x] Confirm actual SQLSTATEs and versions in diagnostic job 854086.
- [x] Compare the original and combined-update implementations in job 854116.
- [x] Validate all 48 controlled conflict cases and 15 transfer boundary cases.
- [x] Check PostgreSQL's serialization-validation ordering before proposing an engine change.

Additional baseline correlations, all on 2026-09-16 (Singapore time):

| Transaction | pgbench record | Coordinator error | Worker evidence |
| --- | --- | --- | --- |
| T2 | result-c16.txt:10, client 8, script 1, shard 102102 | xcnc0-postgresql.log:10633, PID 626768, 23:13:46.456 | xcnc3-postgresql.log:1088, PID 530153, serialization failure on COMMIT |
| T1 | result-c16.txt:43, client 0, script 0, shard 102110 | xcnc0-postgresql.log:12576, PID 626767, 23:15:56.183 | xcnc3-postgresql.log:1241, PID 540029, serialization failure on COMMIT |

Paths in this table are relative to preserved job 853208, with pgbench records
inside benchmark-results. T1's same coordinator session also appears in a
failed PREPARE TRANSACTION at xcnc3-postgresql.log:1240 immediately before the
plain-COMMIT failure. These records do not prove that both commands belonged
to the same attempt. Do not label all original failures as wholly one-phase
transactions based on one worker's command.

T2 performs a single conditional inventory UPDATE. This independently rules
out combining T7's updates as a complete solution for all affected scripts.

### Proposed engine change (not implemented)

Prefer a maintainer-supported Citus correction that preserves serializable
isolation and the supplied SQL. The acceptance rule is: return a retryable
serialization/deadlock error only when the failed transaction's transactional
writes are known to have rolled back; retain a non-retryable error when the
commit outcome is uncertain.

Two implementation options need maintainer review:

1. For a provably single-writer transaction, retain the worker's SQLSTATE and
	 propagate 40001/40P01 only after a definite worker rollback and confirmation
	 that no other remote or local transactional writes committed. A worker
	 hostname or shard count alone is not a sufficient safety test: one worker
	 can have multiple participating connections.
2. Use preparation before irreversible commit for serializable transactions
	 that otherwise reach the affected plain-COMMIT path, including single-shard
	 writes. Preserve errors from preparation and roll back every prepared
	 participant on failure. Define how read-only participants are validated
	 before acknowledging success rather than simply preparing writers and
	 assuming the remaining participants cannot fail.

Option 2 is the preferred general design to evaluate, not a verified fix or
an available user setting. It builds on the observed cross-worker behavior
without changing transaction definitions. It adds preparation/recovery cost
and must be tested. PostgreSQL calls Citus's pre-commit callback before its
own final serialization check (xact.c:2281 and 2339); its preparation path
also checks serialization (xact.c:2591). The design must therefore handle
coordinator errors after remote preparation, not commit workers prematurely.

Do not implement this by changing one errmsg's SQLSTATE, retrying all XX000
errors, adding unrelated writes to force 2PC, or reducing isolation. None of
those is an established equivalent fix.

### Required tests before installing a fix

- Repeat the current 48 conflict and 15 boundary cases with worker command tracing.
- Exercise the supplied T1/T2/T7 scripts under mixed concurrency, including one
	and multiple writer connections on the same worker and different workers.
- Include read-only participant conflicts, coordinator failures, deferred
	constraint failures, and connection loss during prepare and commit.
- Verify failed transactions leave no transactional writes, no unresolved
	prepared transactions after recovery, and no duplicate effects after retries.
- Verify pgbench retries the confirmed 40001/40P01 failures within its existing
	retry budget and preserves failures whose outcome is unknown.
- Only then rerun the full baseline under the approved, consistently deployed
	version. Record the version change and do not mix results across versions.

### Still blocked or deliberately retained

Slurm accounting still returns "No space left on device" for job 853208 on
recheck; final scheduler state cannot be certified. Original baseline data
consistency cannot be reconstructed from the existing logs alone. The small
tests found no unexpected effects, but do not prove the full run was unaffected.
No engine patch or full rerun was made. Implementation and failure-injection
tests require a separate, non-shared installation and approval before replacing
the team's database binaries. All original logs, results, and temporary data
remain preserved; deleting evidence is not part of completing these checks.

