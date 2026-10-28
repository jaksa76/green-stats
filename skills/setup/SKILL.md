---
name: setup
description: First-run setup for green-stats — detects the environment (shell, tools, docker/podman), asks the user where and how to collect Claude Code usage, writes the config, and ports the collector to PowerShell if bash is unavailable. Use on first use, or when the user wants to reconfigure green-stats (e.g. enable/disable devcontainer collection).
---

# green-stats setup

The data directory is `$GREEN_STATS_HOME`, defaulting to `~/.local/share/green-stats` (`%LOCALAPPDATA%\green-stats` on native Windows). The config is `config.json` there.

## 1. Detect the environment

Try:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/green-stats.sh" check
```

- If it runs, note from its output whether `docker` and/or `podman` are present, and any `missing:` tools.
- If bash is not available at all (native Windows without Git Bash), go to step 4 (PowerShell port) after the questions. Detect a runtime there with `Get-Command docker, podman`.

If a config already exists, this is a reconfigure: read it and use its current values as the defaults for the questions.

## 2. Ask the user

Use one AskUserQuestion call with only the questions that apply:

- **Containers.** Ask this only if docker or podman was detected. "Analyse Claude Code usage inside your containers/devcontainers?"
  - Yes (recommended if any containers exist): devcontainer transcripts are copied out incrementally, and usage stays recorded after containers are deleted.
  - No: host only.
  - If both runtimes exist, also ask which one.
  - **If neither is installed, do not ask and do not mention containers.** Set `"devcontainers": false`.
- **Extra transcript locations.** "Any other directories with Claude Code transcripts?" Typical answers: a mounted `~/.claude` from another machine, or a custom `CLAUDE_CONFIG_DIR`. The default is none.
- **Grid carbon intensity.** Options:
  - world average, 475 gCO2/kWh (default)
  - EU average, about 250
  - US average, about 370
  - a custom value
- **Default report window.**
  - 30 days (default)
  - 7 days
  - 90 days

## 3. Write the config

1. Copy `${CLAUDE_PLUGIN_ROOT}/config/default-config.json` to the data directory as `config.json`, unless one exists.
2. Edit only these keys:
   - `devcontainers`
   - `container_runtime`
   - `extra_paths` (colon-separated)
   - `grid_gco2_per_kwh`
   - `default_days`
   - `script`
3. Keep the file flat, with one `"key": value` per line. The script reads it with grep/sed.

Settings are always changed through the config, never by editing the script. That covers podman vs docker, extra roots, and container home directories (`container_homes`).

## 4. Adapt the collector, only if needed

- **bash works:** set `"script": "bash"`. Done.
- **No bash** (native Windows):
  1. Port `${CLAUDE_PLUGIN_ROOT}/scripts/green-stats.sh` to `<data dir>/green-stats.ps1`. Keep the same subcommands, options, config keys and file formats (`state/*.jsonl`, `usage/YYYY-MM.jsonl`), so the data stays compatible.
  2. Keep the same rules: dedupe by `message.id|requestId` with max per counter, read only from stored byte offsets, process complete lines only, and match only the first `"usage":{"input_tokens":` object.
  3. Set `"script": "powershell"`.
  4. Run `pwsh -File <data dir>/green-stats.ps1 check` and then `report --days 7` to confirm it works.
- **bash present but a required tool is missing** (see `missing:` in check output):
  1. Copy the script to `<data dir>/green-stats.sh` and patch only the affected commands.
  2. Set `"script"` to that path.
  3. Never edit the plugin's own copy.

## 5. Finish

Run the report once:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/green-stats.sh" report
```

The first run reads everything, so it takes longer. Later runs only read new data. Show the output, and tell the user they can re-run `/green-stats:setup` to change settings.
