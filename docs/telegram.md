# Telegram

Hermes can answer on Telegram, with the same agent, tools, skills and memory you use from VS Code. It's optional and off until you configure it.

## How it fits the stack

- **Outbound only.** Hermes *long-polls* `api.telegram.org`. It opens no port and needs no webhook, so the home-LAN-only rule still holds: nothing new is published, and the firewall rules in `windows/setup-lan.ps1` stay as they are.
- **Secrets stay out of git.** The token and allowlist live in `./telegram.env`, which is in `.gitignore` and written with mode `600`. The repo only ships `telegram.env.example`, which holds empty placeholders. Compose loads `telegram.env` into the `hermes` container *only if the file exists* (`env_file … required: false`, so Docker Compose ≥ 2.24 is required). Without the file, Telegram is off.
- **Same model path.** Telegram messages go through Hermes, which calls LiteLLM (`coder`), so usage shows up in LiteLLM's logs like any other client.

## Set up

```bash
scripts/setup-telegram.sh
```

1. In Telegram, talk to **@BotFather**, run `/newbot` and copy the token.
2. Paste it when the script asks. Nothing is echoed, and the token never goes on a command line. The script checks it with Telegram (`getMe`).
3. Send any message to your new bot, then press Enter at the "Allowed user IDs" prompt. The script reads that message and offers your numeric ID. You can also type the ID(s) yourself; @userinfobot shows yours.
4. The script writes `telegram.env` and recreates `hermes`. Then open `https://t.me/<your_bot>` and say hi.

`scripts/doctor.sh` checks the token, the allowlist and that Hermes received them.

**By hand:** `cp telegram.env.example telegram.env && chmod 600 telegram.env`, fill it in, then `docker compose up -d --force-recreate hermes`. A plain `restart` does **not** reload env files.

## Settings (`telegram.env`)

| Variable | Required | Meaning |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | yes | Token from @BotFather |
| `TELEGRAM_ALLOWED_USERS` | yes | Comma-separated **numeric** user IDs (not @usernames). Empty = Hermes denies everyone |
| `TELEGRAM_HOME_CHANNEL` | no | Chat that receives scheduled (cron) results. The script defaults it to the first allowed user, which means your DM |

Hermes supports more Telegram options (groups, topics, admin-only commands). See its [Telegram guide](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/messaging/telegram.md). Environment options go in `telegram.env`, and `platforms.telegram.extra` options go in `data/hermes/config.yaml`. Both locations are git-ignored.

## Security

- **The allowlist is the security boundary.** Anyone on it can make Hermes run shell commands in its container, with your workspace mounted read-write. List only yourself, or people you'd give SSH access to the repo. The script refuses `*` (everyone).
- **Treat the token like a password.** Anyone holding it can impersonate the bot and read the messages sent to it. If it leaks, send `/revoke` to @BotFather, then re-run `scripts/setup-telegram.sh` with the new token.
- Keep the bot out of groups unless you've read Hermes' group options. In a group, every allowed user's message reaches the agent.
- Before every commit, check: `git status` must never list `telegram.env`.

## Turn off

```bash
scripts/setup-telegram.sh --off     # deletes telegram.env and recreates hermes
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Bot doesn't answer | `docker compose logs -f hermes`, then look for Telegram lines. Check that your ID is in `TELEGRAM_ALLOWED_USERS` |
| `409 Conflict` in the log | Another process polls the same bot (a second Hermes, another machine). Stop it, or create a separate bot |
| Script can't reach `api.telegram.org` | The container has no internet access, or a proxy blocks it. Test with `docker run --rm curlimages/curl:8.11.1 -sSI https://api.telegram.org` |
| `env_file … required` error from Compose | Docker Compose is older than 2.24. Upgrade with `scripts/install-docker-wsl.sh` |
