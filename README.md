# denvr-bug-report

Collects the diagnostics Denvr Support needs for bare-metal GPU issues into a single archive, so customers can attach it to a ticket in one step.

> Status: scaffold only. The script is not implemented yet.

## Planned collection

1. `nvidia-smi -q` (error counters, row-remap failures)
2. `nvidia-bug-report.sh` (NVLink/switch and GPU detail)
3. OEM `gpu-thermal-script` output (download link or bundling to be confirmed)
4. `dmesg -T`

A power-cycle of the node is a manual step that stays outside the script; the ticket page and docs should say when to do it.

## Distribution

Releases are published via GitHub Releases so the support ticket page can link to a stable download URL.

## Open questions

- Redistribution terms for the OEM thermal utility
- Whether to also capture network configuration
- Any additional logs to include
