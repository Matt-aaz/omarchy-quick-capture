# Contributing to Quick Capture

Thank you for helping make capture on Omarchy faster and safer.

## Principles

1. Protect note content above all else. Never clear or close the editor before a successful write is confirmed.
2. Keep the normal interaction to shortcut → type → `Ctrl+Enter`.
3. Stay native to the current Omarchy shell and follow installed first-party patterns.
4. Keep runtime dependencies minimal and the plugin completely local.
5. Use generic examples and test data.

## Development workflow

1. Inspect the installed Omarchy version and current plugin APIs.
2. Add a failing behavior test.
3. Implement the smallest change that passes it.
4. Run the complete release suite:

   ```bash
   bash tests/test-release.sh
   ```

5. Install the checkout locally, summon it through shell IPC, and exercise both success and failure paths.
6. Check `git diff` and `git status` before submitting a change.

## Pull requests

Keep pull requests focused. Explain the user-visible behavior, test evidence, Omarchy version used, and any new dependency. Do not include personal notes, paths, screenshots, tokens, or specialized/private examples.

Features beyond the focused v0.1 scope should begin as discussion against [ROADMAP.md](ROADMAP.md), informed by real user feedback.
