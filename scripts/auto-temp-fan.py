#!/usr/bin/env python3
"""Automatic temperature-driven fan controller for local mac-fanctl.

This script intentionally shells out to the local fanctl binary instead of
duplicating SMC writes. Run with --dry-run first. Real writes require sudo.
"""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


FAN_STATUS_RE = re.compile(
    r"Fan (?P<fan>\d+): actual (?P<actual>\d+) RPM, target (?P<target>\d+) RPM, "
    r"min (?P<min>\d+) RPM, max (?P<max>\d+) RPM, mode (?P<mode>\w+)"
)
TEMP_RE = re.compile(r"^(?P<key>\S+)\s+flt\s+(?P<value>-?\d+(?:\.\d+)?)$")

SENSOR_PROFILES: dict[str, list[str]] = {
    # Matches the current 85C-ish temperature shown by the user's system UI on Mac16,10.
    "m4-ui85": ["Te05", "Te0S", "Te09", "Te0H"],
    "m4-cpu": [
        "Te05",
        "Te0S",
        "Te09",
        "Te0H",
        "Tp01",
        "Tp05",
        "Tp09",
        "Tp0D",
        "Tp0V",
        "Tp0Y",
        "Tp0b",
        "Tp0e",
    ],
    "m4-gpu": ["Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
    "case": ["TH0x", "TPSD", "TPSP", "TVS0", "TVS1", "TW0P"],
}


@dataclass
class FanStatus:
    fan: int
    actual: int
    target: int
    minimum: int
    maximum: int
    mode: str


@dataclass
class TempReading:
    key: str
    value: float


class FanctlError(RuntimeError):
    pass


def default_fanctl_path() -> Path:
    script_dir = Path(__file__).resolve().parent
    return script_dir.parent / ".build" / "debug" / "fanctl"


def run_cmd(args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}"
        raise FanctlError(detail)
    return proc


def read_fan_status(fanctl: Path, fan: int) -> FanStatus:
    proc = run_cmd([str(fanctl), "status"])
    for line in proc.stdout.splitlines():
        match = FAN_STATUS_RE.search(line)
        if not match:
            continue
        if int(match.group("fan")) != fan:
            continue
        return FanStatus(
            fan=fan,
            actual=int(match.group("actual")),
            target=int(match.group("target")),
            minimum=int(match.group("min")),
            maximum=int(match.group("max")),
            mode=match.group("mode"),
        )
    raise FanctlError(f"fan {fan} not found in fanctl status")


def parse_temp_line(line: str) -> TempReading | None:
    match = TEMP_RE.match(line.strip())
    if not match:
        return None
    value = float(match.group("value"))
    if value < 10.0 or value > 115.0:
        return None
    return TempReading(match.group("key"), value)


def read_temperature_keys(fanctl: Path, keys: list[str]) -> list[TempReading]:
    readings: list[TempReading] = []
    for key in keys:
        proc = run_cmd([str(fanctl), "read", key], check=False)
        if proc.returncode != 0:
            continue
        reading = parse_temp_line(proc.stdout.strip())
        if reading is not None:
            readings.append(reading)
    return readings


def read_all_temperatures(fanctl: Path, prefixes: list[str]) -> list[TempReading]:
    readings: list[TempReading] = []
    seen: set[str] = set()
    for prefix in prefixes:
        proc = run_cmd([str(fanctl), "keys", prefix])
        for line in proc.stdout.splitlines():
            reading = parse_temp_line(line)
            if reading is None or reading.key in seen:
                continue
            readings.append(reading)
            seen.add(reading.key)
    return readings


def strongest_temperature(readings: list[TempReading]) -> TempReading:
    if not readings:
        raise FanctlError("no usable temperature readings")
    return max(readings, key=lambda item: item.value)


def set_fan(fanctl: Path, fan: int, rpm: int, dry_run: bool) -> None:
    cmd = [str(fanctl), "set", str(fan), str(rpm), "--i-understand-risk"]
    if dry_run:
        return
    run_cmd(cmd)


def auto_fan(fanctl: Path, fan: int, dry_run: bool) -> None:
    cmd = [str(fanctl), "auto", str(fan), "--i-understand-risk"]
    if dry_run:
        return
    run_cmd(cmd)


def clamp(value: float, low: float, high: float) -> float:
    return min(max(value, low), high)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="PI temperature controller for fanctl.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--fanctl", type=Path, default=default_fanctl_path())
    parser.add_argument("--fan", type=int, default=0)
    parser.add_argument("--target", type=float, default=50.0)
    parser.add_argument("--deadband", type=float, default=1.5)
    parser.add_argument("--interval", type=float, default=3.0)
    parser.add_argument("--kp", type=float, default=150.0, help="RPM per degree C above target")
    parser.add_argument("--ki", type=float, default=1.5, help="RPM per degree C-second")
    parser.add_argument("--kd", type=float, default=0.0, help="RPM per degree C/second")
    parser.add_argument("--step-up", type=int, default=1200, help="Maximum RPM increase per loop")
    parser.add_argument("--min-change", type=int, default=50, help="Skip tiny fan target changes")
    parser.add_argument("--max-rpm", type=int, default=0, help="0 means use hardware max")
    parser.add_argument("--min-rpm", type=int, default=0, help="0 means use hardware min")
    parser.add_argument(
        "--active-min-rpm",
        type=int,
        default=1800,
        help="Minimum RPM target while temperature is above target.",
    )
    parser.add_argument(
        "--profile",
        choices=sorted(SENSOR_PROFILES) + ["all"],
        default="m4-ui85",
        help="Temperature sensor profile. --keys overrides this.",
    )
    parser.add_argument(
        "--keys",
        default="",
        help="Comma-separated temperature keys. Overrides --profile.",
    )
    parser.add_argument(
        "--prefixes",
        default="T",
        help="Comma-separated SMC key prefixes for temperature scan.",
    )
    parser.add_argument("--once", action="store_true", help="Run one control step and exit")
    parser.add_argument("--dry-run", action="store_true", help="Print decisions without writing SMC")
    parser.add_argument("--auto-on-exit", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument(
        "--cool-cycles",
        type=int,
        default=3,
        help="Cycles below target-deadband before returning to auto.",
    )
    return parser


def require_root_if_writing(dry_run: bool) -> None:
    if not dry_run and os.geteuid() != 0:
        raise FanctlError("real fan writes require sudo; use --dry-run first")


def main() -> int:
    args = build_parser().parse_args()
    fanctl = args.fanctl.resolve()
    if not fanctl.exists():
        raise FanctlError(f"fanctl binary not found: {fanctl}; run swift build first")
    require_root_if_writing(args.dry_run)

    selected_keys = [item.strip() for item in args.keys.split(",") if item.strip()]
    if not selected_keys and args.profile != "all":
        selected_keys = SENSOR_PROFILES[args.profile]
    prefixes = [item.strip() for item in args.prefixes.split(",") if item.strip()]
    if not selected_keys and not prefixes:
        prefixes = ["T"]

    stop = False

    def request_stop(_signum: int, _frame: object) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    integral = 0.0
    last_error: float | None = None
    cool_count = 0

    try:
        while not stop:
            status = read_fan_status(fanctl, args.fan)
            if selected_keys:
                readings = read_temperature_keys(fanctl, selected_keys)
            else:
                readings = read_all_temperatures(fanctl, prefixes)

            hottest = strongest_temperature(readings)
            error = hottest.value - args.target
            hw_min = args.min_rpm or status.minimum
            hw_max = args.max_rpm or status.maximum
            hw_min = int(clamp(hw_min, status.minimum, status.maximum))
            hw_max = int(clamp(hw_max, hw_min, status.maximum))
            active_min = int(clamp(args.active_min_rpm, hw_min, hw_max))
            action = "hold"
            desired = status.target

            if hottest.value <= args.target - args.deadband:
                cool_count += 1
                integral = 0.0
                last_error = None
                if cool_count >= args.cool_cycles:
                    action = "auto"
                    auto_fan(fanctl, args.fan, args.dry_run)
            elif error > 0:
                cool_count = 0
                derivative = 0.0 if last_error is None else (error - last_error) / args.interval
                integral = clamp(integral + error * args.interval, 0.0, 600.0)
                raw = active_min + args.kp * error + args.ki * integral + args.kd * derivative
                desired = int(round(clamp(raw, hw_min, hw_max)))

                safe_floor = max(status.actual, status.target, hw_min)
                if safe_floor > hw_max:
                    action = f"hold system-rpm-above-cap {safe_floor}>{hw_max}"
                else:
                    desired = max(desired, safe_floor)
                    if desired > status.target + args.step_up:
                        desired = status.target + args.step_up
                    desired = int(clamp(desired, hw_min, hw_max))

                    if abs(desired - status.target) >= args.min_change:
                        action = f"set {desired}"
                        set_fan(fanctl, args.fan, desired, args.dry_run)
                last_error = error
            else:
                cool_count = 0
                integral = 0.0
                last_error = error

            stamp = time.strftime("%Y-%m-%d %H:%M:%S")
            mode = "dry-run" if args.dry_run else "write"
            print(
                f"{stamp} mode={mode} temp={hottest.value:.1f}C key={hottest.key} "
                f"target={args.target:.1f}C fan_actual={status.actual} "
                f"fan_target={status.target} rpm action={action}",
                flush=True,
            )

            if args.once:
                break
            time.sleep(args.interval)
    finally:
        if args.auto_on_exit and not args.dry_run:
            try:
                auto_fan(fanctl, args.fan, dry_run=False)
                print("returned fan to auto", flush=True)
            except Exception as exc:  # noqa: BLE001 - final cleanup should not mask logs.
                print(f"failed to return fan to auto: {exc}", file=sys.stderr, flush=True)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FanctlError as exc:
        print(f"auto-temp-fan: {exc}", file=sys.stderr)
        raise SystemExit(1)
