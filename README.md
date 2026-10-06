# denvr-bug-report

Collects the diagnostics Denvr Support needs for bare-metal GPU issues and builds a single offline HTML report plus a `.tar.gz` that can be attached to a support ticket.

> Status: v0.1.0, not yet validated on a live GPU node. Parsers were written from the documented output formats and smoke-tested only against hand-made mock data. Expect to iterate after the first real runs.

## What it does

Default run:

1. `nvidia-smi -q` (plus `nvidia-smi -L` as a GPU-count cross-check)
2. `dmesg -T`
3. `nvidia-bug-report.sh` (runs last, with a timeout; the large output is archived but not embedded)

Opt-in (`--thermal`): the OEM Master GPU Thermal Script under `vendor/`. It is a stress test (about 15 min on Hopper, 30 min on Blackwell) and needs `ipmitool` and DCGM, so it never runs by default.

Everything is plain bash plus standard tools (`awk`, `sed`, `grep`, `tar`, `gzip`). No Python, no network, no external assets.

## Usage

```bash
sudo ./denvr-bug-report.sh                      # default collection
sudo ./denvr-bug-report.sh --skip-bugreport     # faster, skips nvidia-bug-report.sh
sudo ./denvr-bug-report.sh --thermal --thermal-platform hopper
sudo ./denvr-bug-report.sh --thermal-csv thermal_results.host.csv   # analyse an existing CSV only
```

The script must be run as root (`sudo`); it exits immediately otherwise, since `dmesg -T` and `nvidia-bug-report.sh` are unreliable without it.

| Option | Meaning |
|---|---|
| `-o, --output-dir DIR` | Where the report folder and archive are created (default: current directory) |
| `--skip-bugreport` | Do not run `nvidia-bug-report.sh` |
| `--bugreport-timeout S` | Timeout for `nvidia-bug-report.sh` in seconds (default 1200 = 20 min) |
| `--max-embed-kb N` | Max KB of each raw output embedded in the HTML (default 4096) |
| `--no-archive` | Do not create the `.tar.gz` |
| `-y, --yes` | Skip confirmations (required for `--thermal` outside a terminal), and skip the timeout prompts below |
| `--thermal` | Run the bundled OEM thermal test |
| `--thermal-platform P` | `hopper` or `blackwell` (asked interactively if omitted) |
| `--thermal-script PATH` | Use a different thermal script |
| `--thermal-timeout S` | Timeout for the thermal test in seconds (default 1200 = 20 min) |
| `--thermal-csv FILE` | Analyse a thermal CSV without running the test |

If `--bugreport-timeout` / `--thermal-timeout` are not given and the script is run from a terminal, it asks for each timeout interactively, in minutes (converted to seconds internally); the defaults above are offered and accepted on an empty reply. Pass `-y`/`--yes`, or the flags above, to run non-interactively.

## Output

```
denvr-bug-report-<host>-<UTC timestamp>/
  report.html      single-file report, open in any browser (no network needed)
  raw/             every raw output as collected
  .work/           intermediate files: manifest and findings (TSV)
denvr-bug-report-<host>-<UTC timestamp>.tar.gz
```

The report has a left-hand navigation with one page per source (Overview, System, nvidia-smi -q, dmesg -T, nvidia-bug-report, optional Thermal test, Run log). Each page shows findings first, then summary tables, then the collapsible raw output.

Findings are graded Critical / Warn / Info / OK. They come from simple pattern checks (for example row-remap failures, uncorrectable ECC, throttle reasons, Xid codes in dmesg). They are indicators, not a diagnosis, and every finding shows the evidence it is based on. Checks whose fields are missing from the output are reported as "Not evaluated" rather than passed.

The report embeds hostnames, GPU serial numbers and kernel log lines. There is no redaction yet.

## Known limitations

- `nvidia-smi -q` field names vary by driver version; parsing is tolerant, but some checks may show "Not evaluated".
- The thermal script is run unmodified; platform choice is piped to its prompt. Its own bugs (hardcoded GPU list on Blackwell, fixed fan PWM column) are not fixed here.
- `vendor/Master_GPU_Thermal_Script/` is an OEM utility. Confirm redistribution terms before publishing releases that include it.

## Development

```bash
bash -n denvr-bug-report.sh
shellcheck -s bash denvr-bug-report.sh
```

Planned: release workflow (GitHub Releases), optional `--redact`, tuning of findings after live-node runs.
