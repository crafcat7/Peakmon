## Summary

Peakmon 1.7.1 is a pre-release focused on CPU and GPU temperature collection across Intel and Apple Silicon Macs.

## Highlights

- **Generation-specific SMC mappings** — select candidate CPU and GPU sensors by SoC generation while retaining the existing SMC reading layer.
- **Sensor fallback** — prefer valid die readings, fall back to proximity sensors, and keep unavailable values explicit when no valid reading is available.
- **Discovery support** — expose low-level SMC key enumeration for sensor discovery.

Sensor availability varies by Mac model. This pre-release needs hardware validation, especially on M5 Pro systems. Please report whether CPU and GPU temperatures appear on your Mac.

## Build Info

| Field | Value |
| --- | --- |
| Version | 1.7.1 |
| Build | 20261102 |
| Minimum macOS | 14 Sonoma |
| Architectures | arm64, x86_64 |
| Archive | `Peakmon.app.zip` |
| Update feed | `appcast.xml` |
| SHA-256 | `64d3550c2a4396761bf2b0db56d62220e5f1bc19ed025aad4b4159df7a2c6f52` |
