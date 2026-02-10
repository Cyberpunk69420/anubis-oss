# Anubis OSS - native macOS app for benchmarking local LLMs with real-time hardware telemetry

I built a free, open-source macOS app for benchmarking local LLMs on Apple Silicon. It correlates real-time hardware telemetry (GPU/CPU power, frequency, memory, thermals via IOReport) with inference performance - something I couldn't find in any existing tool.

## What it does

- **Real-time metrics** - tok/s, GPU/CPU utilization, power consumption (watts), GPU frequency, and memory - all charted live during inference
- **Any backend** - works with Ollama, `mlx_lm.server`, LM Studio, vLLM, LocalAI, or any OpenAI-compatible endpoint
- **A/B Arena** - compare two models side-by-side with the same prompt and vote on a winner
- **History & Export** - session history with full replay, CSV export, and one-click image export for sharing results
- **Process monitoring** - auto-detects backend processes and tracks their actual memory footprint (including Metal/GPU allocations)

## Why this might be useful for the HF community

- **Quantization comparisons** - comparing Q4_K_M vs Q8_0 vs FP16 on your hardware? Anubis shows the actual power/performance tradeoff - not just tok/s but **watts-per-token**
- **MLX users** - works with `mlx_lm.server` out of the box. Just start the server and add it as an OpenAI-compatible backend
- **Model cards & benchmarks** - if you're publishing benchmarks for the community, the image export gives you shareable, branded results with one click
- **Apple Silicon insights** - per-core CPU utilization, GPU frequency, ANE/DRAM power - hardware data that no chat wrapper or CLI tool surfaces

## Links

| | |
|---|---|
| **GitHub** | [github.com/uncSoft/anubis-oss](https://github.com/uncSoft/anubis-oss) |
| **Download** | [Latest release (notarized .app)](https://github.com/uncSoft/anubis-oss/releases/latest) |
| **Requirements** | macOS 15+ · Apple Silicon (M1/M2/M3/M4) |
| **License** | GPL-3.0 |

## Looking for feedback

I'd especially love to hear from anyone running MLX or GGUF models locally:

- What metrics matter most to you?
- What backends should I prioritize?
- What would make this useful for your workflow?

Open an [issue](https://github.com/uncSoft/anubis-oss/issues) or start a [discussion](https://github.com/uncSoft/anubis-oss/discussions) on the repo. If Anubis is useful to you, consider [buying me a coffee](https://ko-fi.com/jtatuncsoft/tip) ☕
