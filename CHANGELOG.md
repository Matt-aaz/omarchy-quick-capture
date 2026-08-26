# Changelog

All notable changes to Quick Capture will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.2] - 2026-08-27

### Security

- Moved configuration and position reads behind descriptor-validated 64 KiB and 4 KiB limits before their contents enter Omarchy Shell.

## [0.1.1] - 2026-08-25

### Security

- Removed production IPC methods that could replace and save the current draft.
- Reduced IPC status output to three boolean operational fields, excluding note text, paths, source-window metadata, errors, and geometry.
- Added 256 KiB rendered-note and 64 KiB configuration limits, with an independent 256 KiB limit in the append helper.
- Changed capture writes to atomically open the destination with no-follow semantics, require a regular file through `fstat`, and lock, append, and `fsync` the same verified descriptor.
- Added regression coverage for IPC privacy, size boundaries, symlinks and replacement races, non-regular files, normal append, new-file creation, and concurrent writers.

## [0.1.0] - 2026-08-24

### Added

- Native Omarchy panel lifecycle and shell IPC summon path.
- Focused multiline capture editor on the active monitor.
- Always-on-top, mouse-draggable capture card with click-through space outside it.
- Per-monitor restoration of the card's last dragged position.
- Safe serialized Markdown append with write and flush confirmation.
- Configurable destination, tags, timestamps, context, template, panel geometry, and notifications.
- Theme-aware styling and retryable data-preserving errors.
- Automated safety, formatting, validation, and release checks.
- Local-only privacy model and complete installation, usage, and uninstall documentation.

### Design

- Compact layout with minimal header and footer areas, a subtle drag grip, and no close button.
