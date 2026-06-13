# Instructions for OpenAI Codex / ChatGPT

Paste this entire file into Codex or ChatGPT Code Interpreter, then follow the prompt below.

---

## PROMPT TO PASTE INTO CODEX:

```
I have uploaded a zip file called alwaysx11-v3.zip that contains a GitHub repository.
Please do the following steps for me:

1. Unzip the file alwaysx11-v3.zip
2. Go into the folder alwaysx11-repo/
3. Run these git commands in order:
   - git init -b main
   - git add -A
   - git commit -m "feat: AlwaysX11 v3 — DM-agnostic HDMI hotplug watcher for Raspberry Pi 5"
4. Then give me the exact commands I need to run on my own computer to push it to GitHub,
   with placeholders for my GitHub username and repo name.
5. Also show me the one-liner install command for my Raspberry Pi once it is on GitHub.
```

---

## What the repo does

AlwaysX11 is a daemon for Raspberry Pi 5 that:
- Detects when HDMI is plugged/unplugged via Linux DRM sysfs
- Switches to a dummy Xorg session when headless (so GPU stays alive)
- Starts your display manager (GDM/SDDM/LightDM/any) when HDMI is connected
- Has 149 automated tests, 0 failures

## Repo structure

```
alwaysx11-repo/
├── README.md                     ← Full documentation
├── CHANGELOG.md                  ← Version history
├── LICENSE                       ← MIT
├── INSTALL-ONE-LINER.sh          ← Quick installer
├── scripts/
│   ├── hdmi-switch.sh            ← Main daemon
│   ├── dm-detect.sh              ← Display manager detection
│   ├── install-alwaysx11.sh      ← Full installer
│   └── verify-alwaysx11.sh       ← Post-install checks
├── systemd/
│   └── hdmi-watch.service        ← Systemd unit
├── x11/
│   └── xorg-dummy.conf           ← Xorg headless config
├── conf/
│   └── alwaysx11.conf            ← Runtime configuration
├── assets/edid/                  ← EDID firmware blob
└── tests/
    ├── stress.sh                 ← 149-test suite
    └── sim/                      ← Simulation harness
```

## After Codex sets it up — commands to push to GitHub

Replace YOUR_USERNAME and run these on your own computer:

```bash
# 1. Create a new repo on github.com/new  (name: alwaysx11, public, no README)
# 2. Then run:
git remote add origin https://github.com/YOUR_USERNAME/alwaysx11.git
git push -u origin main
```

## Install on Raspberry Pi (after GitHub upload)

```bash
git clone https://github.com/YOUR_USERNAME/alwaysx11.git
cd alwaysx11
sudo bash scripts/install-alwaysx11.sh --user "$USER"
sudo reboot
```
