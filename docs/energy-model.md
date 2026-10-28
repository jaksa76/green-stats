# Energy model (version 2026-10)

Energy is estimated per assistant message:

```
Wh = (input·c_in + output·c_out + cache_write·c_cw + cache_read·c_cr) / 1e6 × PUE
```

The coefficients `c_*` are Wh per million tokens, per model tier (`wh_per_mtok.<tier>.<type>` in `config.json`). CO2e = kWh × `grid_gco2_per_kwh`. The reported range multiplies the result by `estimate_low_factor` (0.25) and `estimate_high_factor` (2.5).

**These are order-of-magnitude estimates.** Anthropic doesn't publish per-token energy figures. The real figure depends on hardware, batching, context length and data-center efficiency.

## Defaults and how they were derived

| tier | input | cache write | cache read | output |
|---|---|---|---|---|
| sonnet (and default) | 300 | 300 | 30 | 600 |
| opus | 510 | 510 | 51 | 1020 |
| haiku | 100 | 100 | 10 | 200 |

- **Output, sonnet tier: 600 Wh/Mtok.** Epoch AI estimates about 0.3 Wh for a typical GPT-4o query of about 500 output tokens: 0.6 Wh per 1k output tokens.
- **Input: 300 Wh/Mtok.** Epoch's long-input appendix puts a 10k-token input at about 2.5 Wh and a 100k-token input at about 40 Wh, which is 250–400 Wh/Mtok. Claude Code contexts are usually 20k–150k tokens.
- **Cache write: same as input.** It's a full prefill, and the KV cache is then stored.
- **Cache read: 10% of input.** A cache hit skips the prefill compute, which leaves only KV memory traffic and storage. 10% mirrors the API price ratio for cache reads and is the least certain coefficient. Cache reads usually dominate Claude Code token counts, so this value drives most of the total.
- **Tier scaling: by API price ratio,** as a proxy for active compute. Opus is 1.7× sonnet and haiku is about 0.33× sonnet.
- **PUE 1.2.** A typical hyperscale data center.
- **Grid 475 gCO2/kWh.** The approximate world-average electricity carbon intensity.
- **Range 0.25×–2.5×.** Oviedo et al. argue that many public estimates overstate per-query energy by 4–20×, which justifies the low end. Long-context attention costs and lower-utilisation serving justify the high end.

## Sources

- Epoch AI, *How much energy does ChatGPT use?* (2025): https://epoch.ai/gradient-updates/how-much-energy-does-chatgpt-use
- Oviedo et al., *Energy Use of AI Inference: Efficiency Pathways and Test-Time Compute* (Microsoft Research, 2025): https://arxiv.org/abs/2509.20241
- *Energy Considerations of LLM Inference and Efficiency Optimizations* (2025): https://arxiv.org/abs/2504.17674

Update these with `/green-stats:update-model`.
