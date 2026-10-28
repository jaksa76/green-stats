---
name: update-model
description: View or update green-stats' energy estimation model — per-token Wh coefficients per model tier, PUE, grid carbon intensity — optionally researching newer published estimates, and assign tiers to models the report lists as unmapped. Use when the user wants to see, tune, refresh or question the energy/CO2 assumptions.
---

# Update the energy model

The config is `${GREEN_STATS_HOME:-$HOME/.local/share/green-stats}/config.json`. If it's missing, run `green-stats:setup` first. The methodology and sources are in `${CLAUDE_PLUGIN_ROOT}/docs/energy-model.md`.

Energy is computed at report time from these values, so every change applies to past data too. There's no need to re-collect.

## Show the current model

Read the config and present a compact table:
- rows are tiers (`opus`, `sonnet`, `haiku`, `default`)
- columns are `input`, `cache_write`, `cache_read`, `output`, in Wh per million tokens (keys `wh_per_mtok.<tier>.<type>`)

Below it, show:
- `pue`
- `grid_gco2_per_kwh`
- `estimate_low_factor` / `estimate_high_factor`
- `energy_model_version`
- any `tier_map.*` entries

Then ask what they want to change.

## Edit values

Change only the requested keys. Keep one `"key": value` per line. If a coefficient changed, set `energy_model_version` to the current `YYYY-MM` plus a short suffix, e.g. `2026-11-custom`, so reports show which model produced them.

## Research newer estimates (only when asked)

1. Search for recent published estimates of LLM inference energy: per query, per token, input vs output, frontier vs small models, KV-cache reuse.
2. Derive Wh per million tokens per tier and token type. Show the derivation, the sources and how each value changes from the current one.
3. Write the values only after the user approves.
4. Update `energy_model_version` and add the sources to `docs/energy-model.md` if the user is working in the plugin repo. Otherwise, mention them in your reply.

## Map unknown models

When a report lists **unmapped models**, ask which tier each belongs to. Add a line to the config:

```
"tier_map.<distinctive substring of the model id>": "<tier>",
```

Tier maps are checked before the built-in opus/sonnet/haiku matching. A new tier name also needs its four `wh_per_mtok.<tier>.*` keys.
