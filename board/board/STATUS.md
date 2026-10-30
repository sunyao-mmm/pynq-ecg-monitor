# Deployment Status

## Timing

- WNS: +0.036 ns
- TNS: 0.000 ns
- WHS: +0.039 ns
- THS: 0.000 ns
- Failing endpoints: 0
- Vivado result: All user specified timing constraints are met
- Authoritative report: `../build/timing.rpt`

The `routed` report stored inside the Vivado run is an intermediate result from
before physical optimization. Do not use it as the final timing result.

## Bitstream

- File: `ecg_bd_wrapper.bit`
- SHA256: `535B1660655551585D79024665AFD06D7D1F3F10D3D5ABA351C6BCEB6AC48790`
- HWH SHA256: `ACA19BBEA5259BFA011C4B896B5957A248021764DD0E54FCC7D2212597662084`
- Bitstream generated: 2026-10-30 11:30:11

## Run

```bash
sh run_web.sh 1   # live ADS1292
sh run_web.sh 0   # MIT-BIH ROM demonstration
```

Equivalent live command:

```bash
python3 ecg_web.py --bit ecg_bd_wrapper.bit --window 2000 --analysis-window 2000 --source 1
```

The web page is the only user-facing capture interface. The ordinary capture
script is retained under `../verification/` for engineering diagnosis only.
