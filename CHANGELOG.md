# Changelog

All notable changes to Claude Usage. Versions follow [Semantic Versioning](https://semver.org):
**major** for changes that break how you use the app, **minor** for new features, **patch**
for fixes.

Add changes under **Unreleased** as you make them. `scripts/release.sh` turns that section
into the new version's section, and the release on GitHub uses it as release notes.

## Unreleased

## 1.0.0 - 2026-10-12

Initial release.

- Menu bar item with the 5-hour session percentage and a choice of icons. Optionally the
  weekly limit too: `13% / 5%`. When usage can't be fetched and the data has gone stale,
  it shows `?`, and the dropdown keeps the last known numbers.
- Dropdown with session and weekly usage bars, reset times, and an "updated 42s ago"
  counter.
- Refreshes Claude Code's OAuth token in step with Claude Code, so it keeps working without
  opening Claude Code and never logs Claude Code out.
- Uses usage data from Claude Code's status line and polls the rate-limited usage API only
  as a fallback, with exponential backoff.
- Settings: icon, weekly usage in the menu bar, refresh interval, live updates from Claude
  Code, launch at login.
- Universal app (Apple silicon and Intel) for macOS 15 and later.
