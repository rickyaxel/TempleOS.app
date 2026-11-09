# Raw results (performance pass, 2026-11-08)

Machine-readable outputs behind the reports; no device identifiers or local paths.

| File | Contents |
|---|---|
| `host-shellperf/{kotlin,swift}-{base,final}-{1,2,3}.json` | `ShellPerfTest(s)`, 20 samples per scenario, baseline `ad9f15a` and final `b9d1e43`, three alternating rounds (the final table) |
| `host-final-table.txt` | The final table computed from those files: median of the three rounds' p50 (thread CPU), p95, per-round ranges |
| `host-ab/ab1*`, `ab2*`, `ab3*` | Per-change alternating runs (`ab1`: surface uploads; `ab2`: boot and filesystem; `ab3`: redraws and typing; `s` suffix: Swift). `base-*` is `ad9f15a`, `wt-*` the candidate at that step |
| `host-ab/blot-*`, `sblot-*` | GrBlot3 fast path: Kotlin JVM / Swift `PerfTest(s)` before (`old`, `wt`) and after (`new`, `blot`) |
| `host-ab/lex-*`, `slexq-*` | Lexer punctuator matching: Kotlin JVM (`old`/`new`, not kept) and Swift on a quiet host (`blot` = before, `exp` = after, kept) |
| `host-base-perftest-kotlin*.json` | Kotlin `PerfTest` on the baseline without and with the test JVM flag |
| `device-surface-bombergolf.json` | OPPO CPH2669, BomberGolf, baseline against the surface-upload change: perf lines, gfxinfo, PSS per run |
| `device-boot.json` | OPPO CPH2669, bench mode boot plus program load, baseline against final |
| `device-blot3.json` | OPPO CPH2669, bench mode frame composition before and after the GrBlot3 fast path |
| `ios-simulator-bombergolf.json` | iOS Simulator, BomberGolf, baseline against final: app process CPU and perf lines per run |
