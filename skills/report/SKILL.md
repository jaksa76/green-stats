---
name: report
description: Report Claude Code token usage and estimated energy/CO2 for a time window, broken down by model, day or source (host or devcontainer). Collects new transcript data incrementally first. Use when the user asks how many tokens they used, their Claude usage, or the energy or carbon footprint of their Claude usage.
---

# Usage and energy report

Keep this lean: one script call, relay its output. The user cares about the numbers, not commentary.

## 1. Make sure setup is done

```bash
test -f "${GREEN_STATS_HOME:-$HOME/.local/share/green-stats}/config.json" && echo configured || echo missing
```

If `missing`, run the `green-stats:setup` skill first, then continue.

## 2. Map the request to options

- Window: "last 7 days" → `--days 7`, "this year" → days since Jan 1. Default: omit `--days` (uses `default_days` from config).
- Breakdown: "by day" / "per day" → `--by day`, "by container" / "by machine" / "by source" → `--by source`, otherwise `--by model`.

## 3. Run it

Read `"script"` from the config.

- `bash` (default):
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/green-stats.sh" report --days N --by X
  ```
- `powershell`:
  ```
  pwsh -File "<GREEN_STATS_HOME>/green-stats.ps1" report --days N --by X
  ```
- A path to an adapted script: run that path with the same arguments.

## 4. Relay

Show the script output verbatim in a code block. Add at most one sentence of interpretation, e.g. which model or source dominates.

- If the output lists **unmapped models**, mention that `/green-stats:update-model` can assign them a tier.
- Don't add numbers of your own, and don't estimate the energy of this report itself.

The same report runs without Claude: `bash <plugin>/scripts/green-stats.sh report`.
