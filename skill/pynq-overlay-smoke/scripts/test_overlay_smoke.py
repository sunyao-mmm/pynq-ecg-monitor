#!/usr/bin/env python3
"""Hardware-independent checks for overlay_smoke.py's parsing and control flow."""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import sys
import tempfile
import types

import overlay_smoke


class FakeMMIO:
    def __init__(self, _base, _length):
        self.regs = {}

    def write(self, offset, value):
        self.regs[offset] = value

    def read(self, offset):
        return self.regs.get(offset, 0)


class FakeOverlay:
    def __init__(self, _path):
        self.ip_dict = {"my_axi_ip": {"phys_addr": 0x40000000}}


def run_case(bit_name, hwh_name, config):
    with tempfile.TemporaryDirectory() as temp_dir:
        root = pathlib.Path(temp_dir)
        bit_path = root / bit_name
        hwh_path = root / hwh_name
        config_path = root / "map.json"
        bit_path.write_bytes(b"bit")
        hwh_path.write_bytes(b"hwh")
        config_path.write_text(json.dumps(config), encoding="utf-8")
        sys.argv = [
            "overlay_smoke.py",
            "--bit", str(bit_path),
            "--hwh", str(hwh_path),
            "--config", str(config_path),
        ]
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = overlay_smoke.main()
        return code, output.getvalue()


def main():
    fake_pynq = types.ModuleType("pynq")
    fake_pynq.Overlay = FakeOverlay
    fake_pynq.MMIO = FakeMMIO
    sys.modules["pynq"] = fake_pynq

    code, output = run_case(
        "demo.bit",
        "demo.hwh",
        {
            "ip_name": "my_axi_ip",
            "id": {"offset": "0x2C", "expected": "0x0EC60001"},
            "roundtrip": [{"name": "SCRATCH", "offset": "0x00", "value": "0xA5A55A5A"}],
        },
    )
    if code == 0 or "RESULT: FAIL" not in output:
        raise SystemExit("expected missing-ID case to fail")

    code, output = run_case(
        "demo.bit",
        "demo.hwh",
        {
            "ip_name": "my_axi_ip",
            "roundtrip": [{"name": "SCRATCH", "offset": "0x00", "value": "0xA5A55A5A"}],
        },
    )
    if code != 0 or "RESULT: PASS" not in output:
        raise SystemExit("expected scratch round-trip case to pass")

    code, output = run_case(
        "demo.bit",
        "wrong.hwh",
        {"ip_name": "my_axi_ip", "roundtrip": []},
    )
    if code == 0 or "same base name" not in output:
        raise SystemExit("expected mismatched bit/hwh case to fail")

    print("checks = 3   failures = 0")
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
