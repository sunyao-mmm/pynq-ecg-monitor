# ECG Continuous Web Monitor

This directory is the board-side deployment package for the final PYNQ-Z2
overlay. It contains the bitstream, hardware handoff, web server, page, launcher,
off-board helper test, ordinary capture diagnostic, and field diagnosis tools.

## Files

- `ecg_bd_wrapper.bit`: timing-qualified final bitstream.
- `ecg_bd_wrapper.hwh`: hardware handoff matching the final block design.
- `ecg_web.py`: continuous capture and web API server.
- `index.html`: rolling ECG/CLT dashboard.
- `run_web.sh`: board launcher.
- `test_web_logic.py`: off-board helper-logic checks.
- `STATUS.md`: final timing and bitstream hash.

`pynq_ecg.py` is retained in this directory only for engineering diagnosis. It
is not a second product interface.

## Hardware contract

The patched `ecg_core.v` uses bit 31 of the existing `CAP_LEN` register as a
continuous-ring switch. Ordinary capture mode remains unchanged when bit 31 is
zero.

In continuous mode:

- `CAP_LEN[11:0]` is the ring length in samples.
- `CLT_NOW[27:16]` is the completed-sample write position.
- The capture RAM stores waveform and CLT words in pairs.

## Run on the board

Copy this directory to the board and start either source:

```bash
sh run_web.sh 1   # live ADS1292
sh run_web.sh 0   # MIT-BIH ROM demonstration
```

The launcher uses a 2000-sample display window and a 2000-sample analysis
window. It can also be started directly:

```bash
python3 ecg_web.py --bit ecg_bd_wrapper.bit \
  --window 2000 --analysis-window 2000 --source 1
```

Open the printed `http://<board-ip>:8899/` URL. The page supports ROM/live source
switching, start/stop, BPM/RR/beat status, and rolling ECG/CLT canvases.

The server uses Python's standard library `ThreadingHTTPServer`; Flask and an
internet connection are not required.

## Display and classification

The display and analysis windows default to 2000 samples, approximately eight
seconds at the target sample rate. Signal-quality checks cover amplitude,
saturation, baseline behavior, and dense high-frequency noise. Rhythm
regularity is reported separately, so a genuinely irregular rhythm is not
automatically treated as a broken signal.

Live ADS1292 mode uses the same PS morphology review as the ROM path. Green
markers indicate normal beats, and red markers indicate PVC candidates. PAC and
uncertain candidates are not drawn. The page also shows filtered ECG, CLT, BPM,
median RR, beat count, and signal quality.

Out-of-range RR intervals are rejected, and displayed live BPM/RR uses the
median of the latest four valid RR intervals. When signal quality fails, BPM,
RR, and beat count are displayed as unavailable rather than as stale or
artifact-driven values.

The red PVC markers are screening candidates only; they are not a clinical
diagnosis.
