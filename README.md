<p align="center">
  <img src="https://capsule-render.vercel.app/api?type=slice&color=gradient&height=250&section=header&text=LazyRDP&fontSize=70&fontAlignY=40" />
</p>

<p align="center">
    <img src="https://img.shields.io/badge/Version-v8.0-blue?style=for-the-badge">
    <img src="https://img.shields.io/badge/Platform-Windows-0078D6?style=for-the-badge&logo=windows">
    <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge">
</p>

A fully automated, customizable remote desktop session deployed from GitHub Actions and reachable only through your own private Tailscale network. Credentials are delivered **privately** to your Telegram or Discord the moment the session is ready. Sessions are ephemeral: the machine exists for the lifetime of the workflow run and is destroyed afterwards.

> LazyRDP continues the `Windows-11-Ultimate-RDP` v7.5 lineage with a rebuilt delivery and resilience layer.

---

## ⚠️ Read before running

- **This is not CI/CD.** Running an interactive desktop on GitHub-hosted runners falls outside GitHub's intended use for Actions ("any other activity unrelated to the production, testing, deployment, or publication of the software project associated with the repository"). GitHub actively monitors for this pattern and may suspend accounts that abuse Actions resources. Run sparingly, and understand that you accept this risk yourself.
- **The environment is ephemeral.** Everything on the machine is destroyed when the session ends or the run is cancelled. Never store personal or sensitive data inside it.
- **No gaming.** The runner has no GPU, and running games or anti-cheat-protected software on it violates those products' terms on top of the risks above.
- **Concurrency:** starting a NEW run cancels the live session immediately (see the warning in every run Summary).

### What you actually get

| Property | Value |
|----------|-------|
| Operating system | Windows Server 2025 (GitHub's `windows-latest` image — despite the historical project name, it is not a Windows 11 desktop) |
| Hardware | 4 vCPUs, 16 GB RAM, ~14 GB free disk (up to ~90 GB with `storage_boost`) |
| Session lifetime | 1–6 hours, your choice (default 6) |
| Access | RDP over Tailscale only — no public IPs, no open ports |
| Accounts | `runneradmin` (main, personalized) and `lazyuser` (clean spare), **randomly generated passwords per run** |
| Credentials | Delivered to your **Telegram and/or Discord**; shown in the Summary only as a fallback |

---

## 🚀 Quick Start

### 1. Fork this repository

Click **Fork**, then work from your fork — not from this upstream copy.

### 2. Create a Tailscale auth key (required)

1. Open [Tailscale Admin Console > Settings > Keys](https://login.tailscale.com/admin/settings/keys).
2. Generate an auth key that is **Ephemeral** and **Reusable** (a pre-signed key also works if your tailnet uses Tailnet Lock).
3. Ephemeral nodes are removed from your tailnet automatically when the session ends.

### 3. Set up credential delivery (optional but recommended)

Without these secrets the workflow still works — credentials simply fall back to the run Summary.

**Telegram:**
1. Message [@BotFather](https://t.me/BotFather) → `/newbot` → follow the prompts → copy the **bot token** (`123456:ABC-...`).
2. Send any message to your new bot, then open `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser and find `"chat":{"id":<NUMBER>}` — that number is your **chat ID**. (Or message [@userinfobot](https://t.me/userinfobot).)

**Discord:**
1. Server Settings → **Integrations** → **Webhooks** → **New Webhook** → pick a channel → **Copy Webhook URL**.

### 4. Store the secrets

In your fork: **Settings > Secrets and variables > Actions > New repository secret**

| Secret | Required | Purpose |
|--------|----------|---------|
| `TAILSCALE_AUTH_KEY` | ✅ | Network access (ephemeral + reusable key) |
| `TELEGRAM_BOT_TOKEN` | optional | Telegram credential delivery |
| `TELEGRAM_CHAT_ID` | optional | Telegram credential delivery |
| `DISCORD_WEBHOOK_URL` | optional | Discord credential delivery |

### 5. Run the workflow

Go to **Actions > LazyRDP > Run workflow** and pick your options:

| Input | Choices | Meaning |
|-------|---------|---------|
| Theme | `dark` / `light` | Desktop color mode |
| Application bundle | `all` / `streaming` / `minimal` / `clean` | `all`: Chrome, Steam, OBS, Google Drive, Rainmeter + Mond · `streaming`: Chrome, OBS, Rainmeter + Mond · `minimal`: Chrome · `clean`: nothing |
| Wallpaper URL | any direct image URL | Optional; validated before setup starts, ignored if it is not a reachable image |
| Session hours | `1` – `6` | How long the session stays up (shuts down gracefully before the platform cap) |
| Storage boost | `no` / `yes` | Removes unused preinstalled toolchains (Android SDK, Docker images, Go, Haskell, CodeQL, caches) and frees tens of GB |
| Timezone | any Windows time zone Id | Optional; e.g. `Egypt Standard Time`. Empty keeps UTC. Invalid values warn and keep UTC |

If a second run starts while a session is live, the new run replaces the old one — **the previous session is cancelled immediately**.

### 6. Connect

1. Wait for the run — when the session is ready, **your Telegram/Discord receives the IP, both accounts, and passwords**.
2. The run **Summary** always shows the address, the end time, and step-by-step instructions; it shows passwords only if no channel was configured or delivery failed.
3. Install the Tailscale client on your device, sign in to the same tailnet, then connect with any RDP client to the `100.x.x.x` address.
4. **Sign in as `runneradmin`** — that account carries all personalization (theme, wallpaper, mouse tuning, OBS profile).

---

## ✨ What the setup does

- **Pre-flight validation** — fails in seconds with a clear message if the Tailscale key is missing, the theme is invalid, or the wallpaper URL is not an image, instead of wasting minutes of setup first.
- **Secure provisioning** — enables RDP with Network Level Authentication and creates two accounts whose passwords are cryptographically random per run. Registry writes go through a hardened ladder (existing-value write → create → `reg.exe` → take key ownership) borrowed from XyRDP's documented findings about TrustedInstaller-owned keys.
- **Debloat and tuning** — removes consumer bloatware, disables telemetry services, activates the Ultimate Performance power plan, and disables mouse acceleration.
- **Storage boost (optional)** — frees tens of gigabytes by removing SDKs and toolchains a desktop session never uses, reporting the real freed number.
- **Personalization** — applies the chosen theme, validated wallpaper, and optional timezone.
- **Application bundles** — installs Chrome directly from Google's signed enterprise MSI (winget's community manifest repeatedly trailed Google's rolling installer), and the remaining packages in parallel via winget with a source-refresh retry; a failed package never blocks the session, and its winget log is printed into the run log.
- **Private credential delivery** — the moment the session is ready, Telegram and/or Discord receive the full connection details; the Summary hides passwords unless no channel delivered.
- **Self-repairing keep-alive** — every 5 minutes the session verifies the Tailscale service, the actual tailnet connection, and the RDP listener. If the node drops off the tailnet, it re-joins automatically (up to 3 attempts); if the IP changes, the Summary gains an "IP UPDATED" section and your channels receive the new address.
- **Quality gate** — pull requests and direct pushes to `main` are linted with actionlint (workflow files) and PSScriptAnalyzer (PowerShell scripts) so a broken change never reaches a run.

All provisioning logic lives in `scripts/*.ps1`; the workflow file is a thin orchestrator that passes user inputs through environment variables (never text interpolation), which closes the script-injection vector that earlier versions had.

---

## 🩺 Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| Run fails at pre-flight: `TAILSCALE_AUTH_KEY secret is not set` | Add the secret as described in step 4 |
| Run fails at the Tailscale step | The auth key expired, is single-use, or was already consumed — generate a new Ephemeral + Reusable key |
| No Telegram/Discord message | Check the "Publish summary" step log — each channel prints its delivery failure reason; the credentials are in the Summary meanwhile |
| Cannot connect from your device | Your device must be signed in to the **same tailnet**; check the Tailscale client status before blaming the session |
| IP stopped working mid-session | The watchdog repaired a drop and the IP changed — the Summary has an "IP UPDATED" section and your channels got the new address |
| Wrong credentials | Credentials differ per run; read them from the **notification channel or the Summary of that specific run** |
| An application failed to install | The session still comes up; the last lines of the winget log are printed in the install step log — review them there, then rerun |
| Session ended earlier than expected | The `session_hours` input elapsed, or a newer run replaced this one; the Summary shows the planned end time |
| Job killed at exactly 6 hours | The platform cap — choose a lower `session_hours` value for graceful shutdown |
| Desktop black but pointer visible | Press Ctrl+Alt+End > Task Manager > Run new task > `explorer.exe` |

---

## 📜 Changelog

### v8.0
- **Private credential delivery:** Telegram and/or Discord receive the full connection details when the session is ready; the Summary hides passwords unless no channel delivered (fallback keeps them reachable). New optional secrets: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `DISCORD_WEBHOOK_URL`.
- **Self-repairing sessions:** the keep-alive watchdog now verifies the actual Tailscale tailnet connection (not just the service), re-joins automatically after a drop (max 3 attempts), and if the IP changes it updates the Summary with an "IP UPDATED" section and re-notifies your channels.
- **XyRDP-inspired hardening:** a registry-write ladder (existing-value write → create → `reg.exe add` → take key ownership) protects every registry write against TrustedInstaller-owned key denials documented on the 2025 runner images.
- **New inputs:** `storage_boost` (frees tens of GB by removing Android SDK, Docker images, Go, Haskell, CodeQL and caches, reporting the real freed number) and `timezone` (validated Windows time zone Id applied to the session).
- **Summary improvements:** explicit concurrency warning (a new run cancels the live session), timezone and storage notes, and the `explorer.exe` recovery tip.
- **Lineage:** starts from `Windows-11-Ultimate-RDP` v7.5 — which itself carried the v7.4 overhaul (random masked-then-unmasked credentials, env-based input passing, official pinned Tailscale action, Chrome direct signed-MSI install, explicit `exit 0` for pwsh runner semantics, per-step timeouts, pre-flight validation, Quality Gate CI).

### v7.5 and earlier
See the `Windows-11-Ultimate-RDP` repository history.

---

## ⚖️ Disclaimer

This project is for educational and experimental purposes. It is an **ephemeral environment** — the machine and all its data are permanently destroyed when the workflow is cancelled or completes. Do not store critical or sensitive data in a session, and use GitHub's resources responsibly and in accordance with their terms of service.

## 📄 License

[MIT](LICENSE)

Maintained by **[LazyByte0x](https://github.com/LazyByte0x)** — registry hardening, storage-boost and session-resilience patterns inspired by [XyRDP](https://github.com/xykal/XyRDP).
