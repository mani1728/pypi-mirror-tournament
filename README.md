# PyPI Mirror Tournament

A Linux automation tool for benchmarking PyPI mirrors, selecting a fast and healthy package index, keeping `pip` configured to use the selected mirror, and automatically recovering when the active mirror becomes unhealthy.

The project is intended for environments where PyPI mirror availability and performance can vary significantly over time.

## Features

- Benchmarks multiple PyPI mirrors using real package downloads.
- Rejects unavailable, slow, or broken mirrors.
- Measures real download throughput rather than relying only on HTTP latency.
- Uses median throughput to reduce sensitivity to individual outliers.
- Avoids unnecessary mirror switching with configurable hysteresis.
- Performs a lightweight daily health and real-download check.
- Automatically starts an emergency tournament when the active mirror fails.
- Updates and verifies pip configuration before committing runtime state.
- Prevents concurrent full tournaments with a non-blocking `flock`.
- Runs automatically through systemd daily and weekly timers.
- Bypasses configured HTTP/HTTPS proxies during mirror tests.
- Retains local logs for diagnostics and historical inspection.

## Architecture

```text
                         systemd
                            |
              +-------------+-------------+
              |                           |
         Daily Timer                   Weekly Timer
          every 24h                     every 7d
              |                           |
              v                           v
       Daily Quick Check          Full Tournament --apply
              |                           |
       Current mirror only         All configured mirrors
              |                           |
       +------+-------+             Health + real downloads
       |              |                    |
    Healthy         Failed             Qualification
       |              |                    |
      Keep            v                 Median score
    current      Emergency                  |
                 Tournament             Hysteresis
                     |                      |
                     v                  Keep / Switch
               Fastest qualified
                    mirror
                     |
                     v
                Update pip
                     |
                     v
                Verify pip
                     |
                     v
                Update state
```

Full tournament executions share a non-blocking lock so two tournament processes cannot benchmark or modify pip configuration concurrently.

## Requirements

The current implementation requires:

- Linux
- Bash
- Python 3
- pip
- curl
- `timeout` from GNU coreutils
- `flock` from util-linux
- awk
- standard GNU/Linux command-line utilities
- systemd for automatic scheduling

The project has been developed and tested on Ubuntu Desktop 26.04 LTS.

## Installation

Clone the repository and enter the project directory:

```bash
git clone git@github.com:mani1728/pypi-mirror-tournament.git
cd pypi-mirror-tournament
```

Ensure both scripts are executable:

```bash
chmod +x bin/pypi-mirror-tournament.sh
chmod +x bin/pypi-mirror-daily-check.sh
```

Review the runtime configuration before enabling automation:

```text
config/tournament.conf
config/mirrors.conf
```

### Machine-specific paths

The current implementation is configured for:

```text
User:         mani
Project root: /workspace/projects/pypi-mirror-tournament
pip config:   /home/mani/.config/pip/pip.conf
```

These paths are currently embedded in the scripts, configuration, and systemd units.

If the repository is installed under another user or path, those values must be adjusted before use.

## Configuration

Runtime settings are stored in:

```text
config/tournament.conf
```

Current settings include:

| Setting | Purpose |
|---|---|
| `BENCHMARK_PACKAGE` | Package used for full throughput benchmarks |
| `DAILY_TEST_PACKAGE` | Package used by the daily real-download test |
| `DAILY_DOWNLOAD_TIMEOUT` | Maximum time for the daily package download |
| `DOWNLOAD_RUNS` | Number of benchmark downloads per mirror |
| `CONNECT_TIMEOUT` | Maximum connection-establishment time |
| `HEALTH_TIMEOUT` | Maximum complete HTTP health-check time |
| `MAX_TTFB` | Maximum accepted Time To First Byte |
| `DOWNLOAD_TIMEOUT` | Maximum time for each full benchmark download |
| `REQUIRE_ALL_RUNS` | Require every configured download run to succeed |
| `WINNER_METRIC` | Winner-scoring method |
| `SWITCH_THRESHOLD_PERCENT` | Required improvement before replacing a healthy winner |
| `PIP_CONFIG` | Managed pip configuration path |
| `PROJECT_ROOT` | Absolute project path |
| `LOG_DIR` | Runtime log directory |
| `STATE_DIR` | Runtime state directory |

The current defaults use:

```text
Benchmark package:       numpy
Daily test package:      packaging
Benchmark runs:          3
Connect timeout:         2 seconds
Health timeout:          5 seconds
Maximum TTFB:            2 seconds
Benchmark timeout:       30 seconds
Daily download timeout:  15 seconds
Switch threshold:        15%
```

### Important limitation: DOWNLOAD_RUNS

Although `DOWNLOAD_RUNS` is defined in configuration, the current median implementation requires exactly:

```text
DOWNLOAD_RUNS=3
```

Changing it to another value is not currently supported by the tournament engine.

## Mirror Configuration

Mirrors are defined in:

```text
config/mirrors.conf
```

Format:

```text
NAME|INDEX_URL
```

Example:

```text
ExampleMirror|https://mirror.example.com/simple
```

The current mirror set contains:

- NovinCloud
- ITO
- Liara
- Ferdowsi
- Runflare
- Official PyPI

Inclusion in this list does not imply that a mirror is currently healthy or fast. Qualification is determined dynamically during each tournament.

## Benchmark Method

For each configured mirror, the full tournament:

1. Builds the package-specific Simple API URL.
2. Performs a direct HTTP health request.
3. Requires HTTP status `200`.
4. Checks TTFB against `MAX_TTFB`.
5. Performs three real `pip download` attempts.
6. Disables the pip cache and dependencies.
7. Applies a hard timeout to each download.
8. Verifies that a package file was actually downloaded.
9. Measures downloaded bytes and wall-clock duration.
10. Calculates throughput in MiB/s.
11. Requires all configured runs when `REQUIRE_ALL_RUNS=true`.
12. Calculates the median of the three measured speeds.
13. Qualifies the mirror only when all required checks succeed.

The qualified mirror with the highest median throughput becomes the tournament candidate.

Temporary benchmark downloads are created under `/tmp` and removed after use.

## Selection Policy

### Normal apply mode

When the current winner still qualifies, another mirror is not selected merely because it is slightly faster.

The challenger must reach:

```text
current median × (1 + SWITCH_THRESHOLD_PERCENT / 100)
```

With the current threshold this means the challenger must be at least **15% faster**.

This hysteresis reduces unnecessary configuration changes caused by temporary performance variation.

If the current winner does not qualify, the fastest qualified mirror can replace it immediately.

### Emergency mode

Emergency mode ignores the normal hysteresis threshold.

The fastest qualified mirror is selected and applied immediately because emergency mode is intended to recover from an unhealthy active mirror.

### No qualified mirrors

If no configured mirror qualifies:

- pip configuration is not changed;
- current state is not replaced;
- the tournament exits with code `2`.

## Operating Modes

### Dry Run

```bash
./bin/pypi-mirror-tournament.sh --dry-run
```

Runs the complete benchmark and selection process but never modifies pip configuration or runtime winner state.

### Apply

```bash
./bin/pypi-mirror-tournament.sh --apply
```

Runs the complete tournament and applies the normal selection and hysteresis policy.

### Emergency

```bash
./bin/pypi-mirror-tournament.sh --emergency
```

Runs the complete tournament and selects the fastest qualified mirror without applying the normal hysteresis threshold.


## Daily Quick Check

The daily quick-check script is:

```bash
./bin/pypi-mirror-daily-check.sh
```

Unlike the full tournament, the daily check tests only the currently selected mirror.

It performs:

1. A direct HTTP health request for the configured daily test package.
2. HTTP status validation.
3. TTFB validation.
4. A real `pip download` of the daily test package.
5. Verification that a package file was actually downloaded.

The current daily test package is:

```text
packaging
```

The real download has its own independent timeout.

Temporary daily downloads are created under `/tmp` and automatically removed when the script exits.

### Healthy result

When all checks pass:

```text
STATUS: HEALTHY
ACTION: KEEP_CURRENT_WINNER
```

No tournament is started and pip configuration is not changed.

### Failed result

The following conditions trigger recovery:

- curl/network failure;
- non-200 HTTP status;
- TTFB above the configured limit;
- real pip download failure;
- daily download timeout;
- successful pip exit without an actual downloaded file.

The daily script then automatically starts:

```bash
./bin/pypi-mirror-tournament.sh --emergency
```

## Emergency Recovery

Emergency recovery is automatic.

The recovery flow is:

```text
Daily Check
    |
    v
Current mirror failed
    |
    v
Emergency Tournament
    |
    +--> No qualified mirror --------> Recovery failed
    |
    v
Fastest qualified mirror
    |
    v
Update pip index-url
    |
    v
Verify pip configuration
    |
    +--> Verification failed --------> State unchanged
    |
    v
Atomically update current-winner
    |
    v
Recovery successful
```

A successful emergency tournament causes the daily check to finish successfully:

```text
STATUS: RECOVERED
ACTION: EMERGENCY_TOURNAMENT_SUCCEEDED
```

If emergency recovery fails, the daily script propagates the recovery exit code and reports:

```text
STATUS: RECOVERY_FAILED
ACTION: MANUAL_ATTENTION_REQUIRED
```

## Concurrency Protection

Full tournament executions use a single non-blocking `flock`:

```text
state/tournament.lock
```

The lock is acquired before benchmark work begins.

If another tournament already holds the lock, the second process fails immediately instead of waiting:

```text
ERROR: Another PyPI Mirror Tournament is already running.
```

The process exits with:

```text
75
```

The lock is held by an open file descriptor for the lifetime of the tournament process and is automatically released when that process exits.

The daily check itself does not hold this lock. This is intentional: a failed daily check must be able to invoke the emergency tournament without deadlocking itself.

## pip Configuration

The selected mirror is managed through pip's user configuration:

```bash
python3 -m pip config --user set global.index-url <INDEX_URL>
```

The project manages a single primary:

```text
global.index-url
```

It does not configure `extra-index-url` as an automatic fallback.

### Verified state transition

When a switch is required, the tournament follows this order:

```text
Select winner
    |
    v
Update pip configuration
    |
    v
Read pip configuration back
    |
    v
Verify expected URL
    |
    v
Write temporary state file
    |
    v
Atomic rename to current-winner
```

If pip configuration cannot be updated, runtime winner state is not changed.

If pip configuration verification fails, runtime winner state is also not changed.

This prevents the state file from claiming that a mirror is active when pip is actually configured differently.

## Runtime State

Runtime state is stored under:

```text
state/
```

The selected mirror is recorded in:

```text
state/current-winner
```

The file contains shell-safe values similar to:

```text
NAME=ExampleMirror
URL=https://mirror.example.com/simple
SELECTED_AT=2026-01-01T12:00:00+00:00
SELECTION_REASON=Challenger\ exceeded\ switch\ threshold
```

The concurrency lock is:

```text
state/tournament.lock
```

Runtime state is machine-specific and intentionally excluded from Git.

The tournament writes winner state through a temporary file and then renames it into place only after pip configuration has been successfully verified.

## Direct Network Testing

Health checks and package downloads intentionally bypass configured HTTP/HTTPS proxies.

The scripts:

- use curl with `--noproxy '*'`;
- unset uppercase proxy environment variables;
- unset lowercase proxy environment variables;
- set `NO_PROXY=*`;
- set `no_proxy=*`.

This ensures benchmark results measure the direct route between the machine and each mirror rather than the performance of an external proxy.

## systemd Automation

Four systemd units are included:

```text
systemd/
├── pypi-mirror-daily.service
├── pypi-mirror-daily.timer
├── pypi-mirror-weekly.service
└── pypi-mirror-weekly.timer
```

### Daily automation

The daily timer starts:

```text
pypi-mirror-daily.service
```

which executes:

```text
bin/pypi-mirror-daily-check.sh
```

Current timer policy:

```text
OnBootSec=10min
OnUnitActiveSec=24h
Persistent=true
```

### Weekly automation

The weekly timer starts:

```text
pypi-mirror-weekly.service
```

which executes:

```text
bin/pypi-mirror-tournament.sh --apply
```

Current timer policy:

```text
OnBootSec=30min
OnActiveSec=7d
Persistent=true
```

The different boot delays reduce the chance of the daily and weekly jobs starting together. Tournament-level `flock` provides an additional concurrency guard.

### Install systemd units

From the repository root:

```bash
sudo cp systemd/pypi-mirror-*.service \
        systemd/pypi-mirror-*.timer \
        /etc/systemd/system/
```

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Enable and start both timers:

```bash
sudo systemctl enable --now \
    pypi-mirror-daily.timer \
    pypi-mirror-weekly.timer
```

### Verify automation

Check whether both timers are enabled:

```bash
systemctl is-enabled \
    pypi-mirror-daily.timer \
    pypi-mirror-weekly.timer
```

Check whether both timers are active:

```bash
systemctl is-active \
    pypi-mirror-daily.timer \
    pypi-mirror-weekly.timer
```

Inspect the next scheduled executions:

```bash
systemctl list-timers \
    pypi-mirror-daily.timer \
    pypi-mirror-weekly.timer
```

Inspect the daily service:

```bash
systemctl status pypi-mirror-daily.service
```

Inspect the weekly service:

```bash
systemctl status pypi-mirror-weekly.service
```

## Logs

Runtime logs are stored under:

```text
logs/
```

Full tournament logs use names similar to:

```text
tournament_YYYY-MM-DD_HH-MM-SS.log
```

Daily checks use:

```text
daily_YYYY-MM-DD_HH-MM-SS.log
```

The logs include health-check results, HTTP status, TTFB, download results, benchmark speeds, qualification decisions, winner selection, recovery results, and configuration actions.

Generated logs are intentionally excluded from Git.

### Log retention

The project currently does **not** automatically rotate, compress, or delete historical logs.

Log retention must therefore be monitored manually or managed externally if the project runs for a long period.

### systemd journal

Service output can also be inspected through the system journal:

```bash
journalctl -u pypi-mirror-daily.service
```

```bash
journalctl -u pypi-mirror-weekly.service
```

For recent entries:

```bash
journalctl -u pypi-mirror-daily.service -n 100 --no-pager
```

```bash
journalctl -u pypi-mirror-weekly.service -n 100 --no-pager
```

## Exit Codes

### Tournament engine

| Code | Meaning |
|---:|---|
| `0` | Successful execution, including dry-run or keeping the current winner |
| `1` | Required configuration or mirror-list file could not be read |
| `2` | No mirror qualified |
| `3` | pip configuration update failed |
| `4` | pip configuration verification failed |
| `64` | Invalid command-line usage or unsupported argument |
| `75` | Another tournament already holds the concurrency lock |

### Daily quick check

The daily script exits with `0` when:

- the current mirror is healthy; or
- the current mirror failed but emergency recovery succeeded.

It exits with `1` when its required configuration or current-winner state cannot be read.

If the tournament script is not executable during recovery, the recovery path returns:

```text
10
```

If an emergency tournament fails, the daily script propagates that tournament's exit code.

For example, a concurrent tournament can cause recovery to propagate exit code `75`.

## Operational Verification

### Check the active pip mirror

```bash
python3 -m pip config --user get global.index-url
```

### Inspect current winner state

```bash
cat state/current-winner
```

The URL in `state/current-winner` should match pip's active `global.index-url`.

### Run a safe full benchmark

```bash
./bin/pypi-mirror-tournament.sh --dry-run
```

This performs the full benchmark without changing pip configuration.

### Run the daily check manually

```bash
./bin/pypi-mirror-daily-check.sh
```

### Run the normal selection policy manually

```bash
./bin/pypi-mirror-tournament.sh --apply
```

### Run emergency selection manually

```bash
./bin/pypi-mirror-tournament.sh --emergency
```

## Troubleshooting

### Another tournament is already running

Message:

```text
ERROR: Another PyPI Mirror Tournament is already running.
```

Meaning:

Another full tournament currently owns `state/tournament.lock`.

The second process exits with code `75`.

Do not delete the lock file merely because it exists. `flock` ownership, not the existence of the filename alone, determines whether the lock is held.

### No mirror qualified

If the tournament reports:

```text
ERROR: No mirror qualified.
```

Possible causes include:

- network connectivity problems;
- all mirrors failing health checks;
- HTTP responses other than `200`;
- excessive TTFB;
- package download failures;
- download timeouts;
- the benchmark package being unavailable from the tested indexes.

No pip configuration change is made in this condition.

### HTTP health succeeds but pip download fails

An HTTP `200` response does not by itself qualify a mirror.

The project deliberately performs real package downloads because a mirror can serve its Simple API successfully while failing actual package retrieval.

### Daily check reports recovery failure

Inspect:

```bash
systemctl status pypi-mirror-daily.service
```

and:

```bash
journalctl -u pypi-mirror-daily.service -n 100 --no-pager
```

Then inspect the latest files under:

```text
logs/
```

The propagated recovery exit code indicates why the emergency tournament failed.

### Timer has no next execution

Inspect:

```bash
systemctl status pypi-mirror-daily.timer
systemctl status pypi-mirror-weekly.timer
```

and:

```bash
systemctl list-timers \
    pypi-mirror-daily.timer \
    pypi-mirror-weekly.timer
```

The current tested weekly configuration uses:

```text
OnActiveSec=7d
```

rather than `OnUnitActiveSec=7d`.

## Disable or Uninstall Automation

### Disable timers without deleting files

```bash
sudo systemctl disable --now \
    pypi-mirror-daily.timer \
    pypi-mirror-weekly.timer
```

This stops automatic scheduling but leaves the service and timer files installed.

### Remove installed systemd units

First disable the timers:

```bash
sudo systemctl disable --now \
    pypi-mirror-daily.timer \
    pypi-mirror-weekly.timer
```

Then remove only this project's installed units:

```bash
sudo rm \
    /etc/systemd/system/pypi-mirror-daily.service \
    /etc/systemd/system/pypi-mirror-daily.timer \
    /etc/systemd/system/pypi-mirror-weekly.service \
    /etc/systemd/system/pypi-mirror-weekly.timer
```

Finally reload systemd:

```bash
sudo systemctl daemon-reload
```

Removing the systemd units does not delete the repository, runtime logs, state files, or pip configuration.

## Project Structure

```text
pypi-mirror-tournament/
├── bin/
│   ├── pypi-mirror-daily-check.sh
│   └── pypi-mirror-tournament.sh
├── config/
│   ├── mirrors.conf
│   └── tournament.conf
├── logs/
│   └── .gitkeep
├── state/
│   └── .gitkeep
├── systemd/
│   ├── pypi-mirror-daily.service
│   ├── pypi-mirror-daily.timer
│   ├── pypi-mirror-weekly.service
│   └── pypi-mirror-weekly.timer
├── .gitignore
└── README.md
```

### `bin/`

Executable tournament and daily-check scripts.

### `config/`

Mirror definitions and runtime policy.

### `logs/`

Machine-local runtime logs. Generated log files are excluded from Git.

### `state/`

Machine-local selected-winner state and tournament lock. Runtime files are excluded from Git.

### `systemd/`

Version-controlled service and timer definitions used for automatic operation.

## Safety and Failure Behavior

The implementation is designed so that:

- `--dry-run` does not modify pip configuration;
- mirrors must qualify before normal selection;
- real package downloads are required;
- benchmark downloads have hard time limits;
- daily downloads have an independent hard time limit;
- configured proxies are bypassed during mirror tests;
- a healthy winner is protected by hysteresis;
- emergency recovery can replace an unhealthy winner immediately;
- pip configuration is verified after a requested switch;
- winner state is not updated if pip configuration fails;
- winner state is not updated if pip verification fails;
- state replacement occurs through a temporary file and rename;
- concurrent full tournaments are rejected with `flock`;
- benchmark temporary files are removed on exit;
- daily temporary files are removed on exit;
- logs and runtime state are excluded from Git.

## Known Limitations

The current implementation has several intentional limitations:

1. The tournament median implementation currently requires exactly three download runs.
2. Paths are currently machine-specific rather than dynamically discovered.
3. systemd units currently run explicitly as user `mani`.
4. The project manages one pip `index-url`; it does not configure fallback indexes.
5. Log rotation and automatic log pruning are not implemented.
6. There is no notification mechanism for failed recovery.
7. Mirror performance is measured from the local machine only and should not be interpreted as globally representative.
8. A mirror can change behavior between tournament runs; selection reflects observed conditions at test time.
9. The project currently targets Linux and systemd-based automation.
10. There is currently no installer that rewrites paths or user names for another machine.

## Current Implementation Status

Implemented and validated:

- mirror configuration;
- direct HTTP health checks;
- HTTP status validation;
- TTFB limits;
- real package-download testing;
- three-run throughput benchmarking;
- median throughput scoring;
- download timeouts;
- mirror qualification and disqualification;
- dry-run mode;
- normal apply mode;
- 15% switching hysteresis;
- emergency mode;
- automatic emergency tournament invocation;
- pip configuration updates;
- post-update pip verification;
- persistent current-winner state;
- atomic state replacement;
- daily real-download health checking;
- automatic recovery after daily failure;
- non-blocking tournament concurrency protection;
- daily systemd service;
- weekly systemd service;
- daily 24-hour timer;
- weekly 7-day timer;
- persistent systemd scheduling;
- local runtime logging;
- end-to-end healthy-path validation;
- end-to-end emergency-recovery validation;
- concurrency-lock validation;
- systemd service execution validation;
- active timer scheduling validation.

## License

No license has been selected yet.
