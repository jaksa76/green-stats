# green-stats

A Claude Code plugin that measures your Claude Code token usage and estimates the energy and CO2 behind it.

- **Host and devcontainers.** Reads transcripts from `~/.claude/projects` and, if enabled, from Docker/Podman containers, both running and stopped.
- **Incremental.** Remembers byte offsets per transcript and a marker per container, so a daily run reads only new data. On a real setup, the first run over 240 MB / 92 containers took 15 s and later runs about 0.2 s.
- **Keeps history.** Usage records survive Claude Code's transcript cleanup and container deletion.
- **Accurate counts.** Dedupes by message ID. Claude Code writes one transcript line per content block, each repeating the same usage, so naive sums overcount.
- **Minimal dependencies.** bash 3.2+, POSIX awk and standard userland. No jq or Python. On systems without bash, the setup skill ports the script to PowerShell.

## Install

```
/plugin marketplace add jaksa76/green-stats
/plugin install green-stats@green-stats
```

Or try it locally: `claude --plugin-dir /path/to/green-stats`.

## Use

| Skill | What it does |
|---|---|
| `/green-stats:report` | collect new data and print usage + energy, e.g. "last 7 days by day" |
| `/green-stats:setup` | first-run questions: containers, extra transcript dirs, grid intensity, default window |
| `/green-stats:update-model` | view or tune the energy coefficients, research newer estimates, map unknown models |

The report also runs without Claude, at no token cost:

```
scripts/green-stats.sh report [--days N] [--by model|day|source]
scripts/green-stats.sh check | collect | reset
```

Example:

```
                                msgs     input    output  cache write   cache read      total      energy
total                           1497      3.3k     1.44M        6.59M      153.87M    161.90M   12.19 kWh

by model
claude-opus-5-5                  675      1.4k    738.9k        3.05M       86.65M     90.44M    8.08 kWh
claude-sonnet-5-5                639      1.3k    544.1k        2.97M       54.79M     58.31M    3.44 kWh

energy (estimate, model 2026-10): 12.19 kWh (range 3.05 kWh – 30.48 kWh), 5.8 kg CO2e at 475 gCO2/kWh, PUE 1.2
```

## Data

The data directory is `$GREEN_STATS_HOME`, defaulting to `~/.local/share/green-stats`:

- `config.json`: settings and energy coefficients
- `state/`: per-file offsets and per-container markers
- `usage/YYYY-MM.jsonl`: one record per assistant message

Energy is computed at report time, so changing coefficients applies to past data too.

## Energy model

Per-token Wh coefficients per model tier and token type (input, output, cache write, cache read), × PUE, × grid carbon intensity. These are order-of-magnitude estimates. See [docs/energy-model.md](docs/energy-model.md) for the derivation and sources.

Reports cover only transcripts on the machine and containers where the tool runs. They don't include claude.ai chat or cloud sessions.
