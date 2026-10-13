# Changelog

All notable changes to Claude Usage. Versions follow [Semantic Versioning](https://semver.org):
**major** for changes that break how you use the app, **minor** for new features, **patch**
for fixes.

Add changes under **Unreleased** as you make them. `scripts/release.sh` turns that section
into the new version's section, and the release on GitHub uses it as release notes.

## Unreleased

## 1.1.0 - 2026-10-13

- New usage chart in the dropdown for the current session or week: your usage over time, the
  pace of each stretch of use, where the current pace leads by the session reset, and an
  even-pace line for the week. Hover for values. On by default; Settings → Dropdown turns it off.
- The dropdown estimates how many full 5-hour sessions are left in the weekly limit, learned
  from your own usage history, with a margin of error: `≈ 3.4 ± 0.2 of 7.5 ± 0.3 full
  sessions left`. Recent sessions count most, and data from before a change in the limits
  is ignored. It gets precise quickly by timing when the weekly percentage ticks over.
- Settings toggles and the chart's Session / Week switch use Claude's terracotta instead of
  the system blue.
- The refresh icon spins around its own center.
- Registering the status line keeps `~/.claude/settings.json`'s file permissions, so a
  private settings file stays private.
- The status-line command escapes the app's path for the shell.

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
