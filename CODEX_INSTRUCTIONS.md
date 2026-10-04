# Working on Ghost Display

Ghost Display manages virtual X11 displays and HDMI hotplug on Raspberry Pi.
Preserve the three supported installation paths:

| Path | Entry point | Installer |
| --- | --- | --- |
| Unified v2 | `ghost-display.sh` | `scripts/install-ghost-display.sh` |
| X11-only | `scripts/ghost-display-x11.sh` | `install.sh` |
| Legacy AlwaysX11 | `scripts/hdmi-switch.sh` | `scripts/install-alwaysx11.sh` |

The unified and X11-only paths share `lib/monitor-profile.sh` for validation and
geometry. Keep their public environment variables and CLI flags compatible. The
X11-only installer keeps its copy of this module under
`/usr/local/lib/ghost-display-x11`, so uninstalling v2 does not remove its helper.

Prefer an existing implementation or Bash/system utilities to new dependencies.
Remove duplication and unused code only after checking callers across the repo.
Keep process ownership, locking, validation and failure propagation intact.

Run `bash tests/run-intensive-tests.sh` after relevant changes. It checks syntax,
mocked lifecycle and profile behavior, and the installed X11 helper layout.
ShellCheck runs when available. These checks do not verify a real Xorg server,
desktop session, HDMI transition or RustDesk capture.

Do not run installers on a development host: they modify system and boot files.
The older `tests/stress.sh` suite also deletes global X sockets under `/tmp`;
run it only in a disposable isolated environment.
