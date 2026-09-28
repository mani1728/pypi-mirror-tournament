# PyPI Mirror Tournament

A lightweight Linux automation tool for benchmarking PyPI mirrors, selecting a fast and healthy package index, and keeping `pip` configured to use the best available mirror.

The project is designed primarily for environments where PyPI mirror performance and availability can vary significantly over time.

## Goals

PyPI Mirror Tournament aims to:

- benchmark multiple PyPI mirrors using real package downloads;
- reject unavailable, slow, or broken mirrors;
- select mirrors based on measured download throughput;
- avoid unnecessary switching between similarly performing mirrors;
- detect failure of the currently selected mirror;
- automatically recover by selecting another healthy mirror;
- keep benchmark logs for later inspection;
- operate without relying on configured HTTP/HTTPS proxies during mirror tests.

## Architecture

The intended automation model is:

```text
                     PyPI Mirror Tournament
                              |
              +---------------+---------------+
              |                               |
       Daily Quick Check              Weekly Tournament
              |                               |
       Current mirror only             All configured mirrors
              |                               |
       +------+-------+                 Real download tests
       |              |                        |
    Healthy         Failed                Select winner
       |              |                        |
     Keep         Emergency               Apply hysteresis
    current       Tournament                    |
                   |                       Keep / Switch
                   |
              Select fastest
              healthy mirror
                   |
              Switch immediately
```

## Selection Policy

### Daily check

The currently selected mirror is checked every 24 hours.

If it is healthy, no configuration change is made.

If it fails, an emergency tournament can be triggered to find a replacement.

### Weekly tournament

A full tournament benchmarks all configured mirrors.

When the current winner is still healthy, another mirror must exceed it by the configured switch threshold before replacing it.

The default threshold is:

```text
15%
```

This hysteresis prevents frequent switching caused by small or temporary performance differences.

### Emergency tournament

If the current mirror becomes unhealthy, the normal switch threshold is ignored.

The fastest qualified mirror can replace it immediately.

## Benchmark Method

The full tournament currently uses `numpy` as the benchmark package.

For every mirror:

1. Perform an HTTP health check.
2. Verify HTTP status and Time To First Byte (TTFB).
3. Perform three real `pip download` runs.
4. Require all configured runs to succeed.
5. Calculate actual throughput from downloaded bytes and elapsed time.
6. Use the median throughput as the mirror score.

Using the median reduces the influence of a single unusually fast or slow run.

## Operating Modes

The tournament engine supports three modes.

### Dry Run

```bash
./bin/pypi-mirror-tournament.sh --dry-run
```

Runs the complete tournament without modifying the active pip configuration.

### Apply

```bash
./bin/pypi-mirror-tournament.sh --apply
```

Runs the tournament and applies the normal switching policy.

A healthy current winner is replaced only when a challenger exceeds the configured performance threshold.

### Emergency

```bash
./bin/pypi-mirror-tournament.sh --emergency
```

Runs a full tournament intended for recovery from a failed current mirror.

The fastest qualified mirror can be selected without applying the normal hysteresis threshold.

## Daily Quick Check

The quick-check script is:

```bash
./bin/pypi-mirror-daily-check.sh
```

It checks the currently selected mirror using the project's configured health limits.

Further automation can use a failed daily check to initiate an emergency tournament.

## Configuration

Runtime settings are stored in:

```text
config/tournament.conf
```

Important settings include:

```text
BENCHMARK_PACKAGE
DOWNLOAD_RUNS
CONNECT_TIMEOUT
HEALTH_TIMEOUT
MAX_TTFB
DOWNLOAD_TIMEOUT
SWITCH_THRESHOLD_PERCENT
```

The mirror list is stored in:

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

## Current Mirror Set

The project currently benchmarks:

- NovinCloud
- ITO
- Liara
- Ferdowsi Cloud
- Runflare
- Official PyPI

Mirror availability and performance are determined dynamically by the tournament rather than assumed from this list.

## pip Configuration

The selected index is managed through pip's user configuration:

```bash
python3 -m pip config --user set global.index-url <INDEX_URL>
```

The project intentionally manages a single primary `index-url`.

It does not use `extra-index-url` as an automatic fallback mechanism.

## Direct Network Testing

Mirror benchmarks intentionally bypass configured HTTP/HTTPS proxies.

This ensures the tournament measures the direct route between the host and each mirror rather than the performance of a proxy server.

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
├── .gitignore
└── README.md
```

### `bin/`

Executable scripts.

### `config/`

Mirror definitions and tournament policy.

### `logs/`

Runtime benchmark and health-check logs.

Generated logs are intentionally excluded from Git.

### `state/`

Local runtime state, including the currently selected mirror.

Runtime state is intentionally excluded from Git because it is machine-specific.

## Logs

Tournament and daily-check results are written under:

```text
logs/
```

Logs are retained locally for diagnostics and historical inspection.

The project does not automatically delete historical logs.

## Safety

The project is designed so that:

- `--dry-run` never changes pip configuration;
- mirrors must qualify before selection;
- failed downloads disqualify a mirror when all runs are required;
- downloads have explicit time limits;
- the selected pip URL is verified after configuration changes;
- runtime state is updated only after successful pip configuration;
- local state and logs are not committed to the repository.

## Platform

Currently developed and tested on Linux.

Primary environment:

```text
Ubuntu Desktop 26.04 LTS
Bash
Python 3
pip
curl
timeout
```

## Status

The project is under active development.

Implemented:

- mirror configuration;
- HTTP health checks;
- TTFB limits;
- real package-download benchmarks;
- median throughput scoring;
- download timeouts;
- mirror qualification;
- dry-run tournament mode;
- normal apply mode;
- emergency mode;
- persistent current-winner state;
- daily quick health check.

Planned:

- automatic emergency tournament invocation;
- systemd daily timer;
- systemd weekly timer;
- concurrency protection;
- final end-to-end automation validation.

## License

No license has been selected yet.
