# mac-fanctl

Small personal CLI for reading and, when explicitly requested, writing Apple SMC fan targets on this Mac.

This is intentionally not a UI app and not a LaunchDaemon. The default commands are read-only.

## Build

```bash
swift build
```

## Read Status

```bash
.build/debug/fanctl status
.build/debug/fanctl keys F0
.build/debug/fanctl read F0Ac
```

Validated on this machine:

- Model: Mac16,10
- macOS: 26.5.1
- Fan count: 1
- Fan 0 keys: `F0Ac`, `F0Tg`, `F0Mn`, `F0Mx`, `F0Md`
- Observed range: 1000-4900 RPM
- `Ftst` key: not present on this machine

## Write Fan Target

Only run this after confirming the current status. The command refuses writes unless the explicit risk flag is present.

```bash
sudo .build/debug/fanctl set 0 1800 --i-understand-risk
sudo .build/debug/fanctl auto 0 --i-understand-risk
```

Safety behavior:

- `set` requires root.
- `set` refuses to lower the target below the current safe floor: max of min RPM, actual RPM, and target RPM.
- `set` refuses anything above the SMC max RPM.
- If target write fails after entering manual mode, it tries to return the fan to auto.
- `auto` hands control back to macOS thermal management.

This uses private AppleSMC behavior through IOKit. It can interfere with macOS thermal management. Do not use it to reduce cooling.

## Automatic Temperature Control

The helper script `scripts/auto-temp-fan.py` runs a simple PI controller:

- Reads temperatures from SMC.
- Uses the hottest selected sensor as the control temperature.
- Raises fan RPM when temperature is above target.
- Samples every 3 seconds by default.
- Uses a responsive active floor of 1800 RPM while above target.
- Returns to macOS automatic fan control after temperature stays below the target deadband.
- Returns to auto on exit by default.

Build first:

```bash
swift build
```

Dry-run one control step:

```bash
scripts/auto-temp-fan.py --once --dry-run --target 50
```

Default control profile is `m4-ui85`, matched to the current 85C-ish system UI reading:

```text
Te05, Te0S, Te09, Te0H
```

Run the controller in the foreground:

```bash
sudo scripts/auto-temp-fan.py --target 50 --max-rpm 3000
```

For faster cooling with more audible fan response:

```bash
sudo scripts/auto-temp-fan.py --target 50 --max-rpm 3500
```

Use all M4 CPU core sensors instead:

```bash
sudo scripts/auto-temp-fan.py --target 50 --max-rpm 3000 --profile m4-cpu
```

Use a less aggressive sensor set closer to case/heatsink temperature:

```bash
sudo scripts/auto-temp-fan.py --target 50 --max-rpm 3000 --profile case
```

Use every readable `T*` thermal key, including hotspots:

```bash
sudo scripts/auto-temp-fan.py --target 50 --max-rpm 3000 --profile all
```

Stop with `Ctrl-C`; the script returns fan 0 to auto unless `--no-auto-on-exit` is used.

## License

This project is licensed under the **MIT License**, with the additional restriction that **commercial use is not permitted**. You may freely use, modify, and share this software for personal, non-commercial purposes. If you make changes, please fork the repository rather than pushing directly to this one.
