---
name: macunclog
description: Check why this Mac is slow and what other agent sessions have left running (simulators, dev servers, builds) with the MacUnclog command line. Use before booting a simulator, starting a heavy build or test run, when commands are unusually slow, when the user asks why the Mac is slow or what is using memory, CPU or disk, and to stop simulators or dev servers that no session uses any more.
---

# MacUnclog

MacUnclog is a Mac app with a command line in its binary. Find it once per session:

```bash
MU=/Applications/MacUnclog.app/Contents/MacOS/MacUnclog; [ -x "$MU" ] || MU="$(mdfind 'kMDItemCFBundleIdentifier == "io.github.anderskraken.macunclog"' | head -1)/Contents/MacOS/MacUnclog"; [ -x "$MU" ] && echo "$MU" || echo missing
```

Each shell command starts fresh, so write the printed path out in full in every later command; `$MU` won't be set there. If it prints `missing`, MacUnclog isn't installed. Tell the user and carry on without it.

The examples below write `MacUnclog` for that path.

## Check the Mac

```bash
MacUnclog --diagnose --json            # one measurement, about 1 second
MacUnclog --diagnose --for 15 --json   # 15 seconds; use this when CPU load matters
```

Read `verdict.severity` (`good`, `notice`, `warning`, `critical`) and `verdict.headline`. Each entry in `findings` has a fixed `kind` (for example `memoryPressure`, `cpuHog`, `simulators`, `orphanedTools`, `lowDisk`, `thermal`) and `remedies`, which carry a `command` when the command line can do the same.

A single measurement can't tell a spike from a lasting load, so a `cpuHog` without `sustainedSeconds` is only a notice. Measure with `--for 15` before you blame a process for being slow.

`agents` lists every Claude and Codex session with its folder, the booted simulators, and the tools (dev servers, emulators, builds, watchers) with the session that owns them.

## What you may do without asking

- Run `--diagnose`, `--scan` and `--files`. They only read. `--scan` checks every project folder and can take half a minute; `--scan packageCaches xcode` limits it to those categories.
- Shut down a simulator whose `idle` is `true`: run its `command` (`--act shutdown-simulator UDID`).
- Stop a tool whose `stoppable` is `true`: run its `command` (`--act stop-tool PID`). Only these are left over from a session that has ended.

MacUnclog checks again before each action and refuses if anything changed.

## What needs the user's yes

- Quitting, force-quitting, pausing or resuming an app or process (`--act quit|forceQuit|pause|resume PID`). Name the process and why first.
- Installing or removing the skill (`--skill install|remove`).
- Any clean-up that deletes files. Show what `--scan --json` found (`cleanableBytes` per category, and `blocked` reasons) and let the user clean up in the app.
- Large files and installers from `--files --json`. These are the user's own files; only the user moves them to the Bin, in the app's Storage tab.

## Never

- Kill a process with `kill`, `pkill` or `killall` instead of MacUnclog. It can't tell whether another session uses it.
- Stop a tool whose `owner` is `session` or `terminal`, or a simulator that isn't idle. Another session or the user is using it.
- Run `--agent` (except `--agent --dry-run`, which only reads), `--automation` with `on` or `off`, or `--protect`. Those clean up or change MacUnclog's settings.

## When the Mac is busy

If the verdict is `warning` or `critical` before you boot a simulator or start a big build, tell the user what MacUnclog found, shut down idle simulators and stop stoppable tools, and reuse a simulator that's already booted instead of booting another.
