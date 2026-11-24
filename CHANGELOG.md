# Changelog

## [Unreleased]

## [1.1.0] - 2026-11-24

### Added

- Launch at login: a footer toggle registers a per-user LaunchAgent, so BatteryFlow starts automatically after login. The item follows the app if it is moved, and warns when the app runs from a temporary (translocated) path.

### Fixed

- Idle CPU: the hidden menu-bar panel no longer keeps the display link alive. The Sankey bubble timeline is capped at 20 fps and paused when the panel is closed, and value springs settle inside the 1 s sampling interval (a 2.4 s spring never settled). Closed-panel CPU drops from ~13% to ~0.3%.
- Sampling follows visibility: 1 s SMC reads while the panel is open, 5 s IOPS-only polling while it is closed, so charge limiting still reacts to plug and percentage changes without paying for 1 Hz SMC round trips off-screen.

## [1.0.0] - 2026-10-23

### Added

- Menu bar battery monitor with 1s SMC telemetry.
- Dual-branch power-flow Sankey view.
- Charge limiting on recent macOS via a minimal privileged helper.
- English / Chinese UI that follows the system language.
- Hardware details panel for voltage, current, power, temperature and capacity.
