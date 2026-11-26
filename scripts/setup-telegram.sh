#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Connect Hermes to a Telegram bot. Writes ./telegram.env (git-ignored, mode
# 600) and recreates the hermes container so it picks the file up.
#
#   scripts/setup-telegram.sh          # interactive: token, allowed users, test
#   scripts/setup-telegram.sh --off    # remove telegram.env, Telegram off
#
# The token is read without echo and is never passed on a command line (it
# goes to curl on stdin), so it does not show up in `ps` or shell history.
# Docs: docs/telegram.md
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TG_FILE="$ROOT/telegram.env"

tg_get() { [[ -f "$TG_FILE" ]] && grep -E "^$1=" "$TG_FILE" | head -1 | cut -d= -f2- || true; }

# tg_api <token> <method>: Bot API call. The URL (with the token) is sent as a
# curl config on stdin, not as an argument.
tg_api() {
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$1" "$2" \
    | docker run -i --rm "$CURL_IMAGE" -sS --max-time 20 -K -
}

recreate_hermes() {
  if docker compose ps --services --status running 2>/dev/null | grep -qx hermes; then
    log "Recreating hermes so it reads the new settings…"
    docker compose up -d --no-deps --force-recreate hermes >/dev/null
  else
    warn "hermes isn't running. Start the stack (scripts/bootstrap.sh); Telegram comes up with it."
  fi
}

case "${1:-}" in
  -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
  --off)
    rm -f "$TG_FILE"; log "Removed telegram.env"; recreate_hermes
    log "Telegram is off. Revoke the token too if it leaked: @BotFather → /revoke"
    exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac

command -v docker >/dev/null || die "docker not found."
[[ -t 0 ]] || die "Run this in a terminal: it asks for the bot token interactively."

# ── 1. Token ─────────────────────────────────────────────────────────────────
cur_token="$(tg_get TELEGRAM_BOT_TOKEN)"
cat <<'EOF'

  1. In Telegram, open @BotFather → /newbot → pick a name and a username.
  2. Copy the token it gives you (123456789:ABC...).

EOF
prompt="Bot token"; [[ -n "$cur_token" ]] && prompt="Bot token (Enter keeps the current one, …${cur_token: -4})"
read -rsp "$prompt: " token; echo
token="${token:-$cur_token}"
token="${token//[[:space:]]/}"
[[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || die "That doesn't look like a bot token (digits:letters, from @BotFather)."

me="$(tg_api "$token" getMe)" || die "Can't reach api.telegram.org from a container. Check the network/proxy."
[[ "$me" == *'"ok":true'* ]] || die "Telegram rejected the token: $(json_field description <<<"$me")"
bot_user="$(json_field username <<<"$me")"
log "Token OK: bot @$bot_user"

# ── 2. Allowed users ─────────────────────────────────────────────────────────
cur_users="$(tg_get TELEGRAM_ALLOWED_USERS)"
cat <<EOF

  Only the numeric user IDs you allow can talk to the bot (and through it,
  make Hermes run commands on your workspace). To find yours, send any
  message to @$bot_user now, then press Enter on an empty answer below.

EOF
prompt="Allowed user IDs, comma-separated"; [[ -n "$cur_users" ]] && prompt="$prompt (Enter keeps: $cur_users)"
read -rp "$prompt: " users
users="${users//[[:space:]]/}"
if [[ -z "$users" && -n "$cur_users" ]]; then
  users="$cur_users"
elif [[ -z "$users" ]]; then
  upd="$(tg_api "$token" getUpdates)" || die "getUpdates failed."
  if [[ "$upd" == *'"error_code":409'* ]]; then
    die "Hermes is already polling this bot, so its messages can't be read here. Get your ID from @userinfobot and re-run."
  fi
  # "from":{"id":123456789,"is_bot":false,"first_name":"Ana",...
  mapfile -t found < <(grep -oE '"from":\{"id":[0-9]+,"is_bot":false,"first_name":"[^"]*"' <<<"$upd" \
                       | sed -E 's/.*"id":([0-9]+).*"first_name":"([^"]*)"/\1 \2/' | sort -u)
  (( ${#found[@]} )) || die "No messages to @$bot_user yet. Send it one (e.g. /start) and re-run, or get your ID from @userinfobot."
  echo "  People who wrote to @$bot_user:"
  printf '    %s\n' "${found[@]}"
  if (( ${#found[@]} == 1 )); then
    read -rp "Allow ${found[0]}? [Y/n] " yn
    [[ "${yn:-y}" =~ ^[Yy] ]] || die "Nothing saved. Re-run and type the ID(s) yourself."
    users="${found[0]%% *}"
  else
    read -rp "Type the ID(s) to allow, comma-separated: " users
    users="${users//[[:space:]]/}"
  fi
fi
[[ "$users" =~ ^-?[0-9]+(,-?[0-9]+)*$ ]] || die "Allowed users must be numeric IDs, comma-separated (got '$users'). '*' (everyone) is refused on purpose."

# ── 3. Home channel (cron deliveries) ────────────────────────────────────────
home="$(tg_get TELEGRAM_HOME_CHANNEL)"
home="${home:-${users%%,*}}"

# ── 4. Write telegram.env ────────────────────────────────────────────────────
tmp="$(umask 077; mktemp "$ROOT/.telegram.env.XXXXXX")"
cat > "$tmp" <<EOF
# Telegram gateway for Hermes. Written by scripts/setup-telegram.sh.
# SECRET — git-ignored, keep it out of commits, chats and screenshots.
TELEGRAM_BOT_TOKEN=$token
TELEGRAM_ALLOWED_USERS=$users
TELEGRAM_HOME_CHANNEL=$home
EOF
chmod 600 "$tmp"; mv "$tmp" "$TG_FILE"
log "Saved telegram.env (mode 600, git-ignored)"
git check-ignore -q "$TG_FILE" 2>/dev/null || warn "git does not ignore telegram.env here! Check .gitignore before committing."

# ── 5. Apply + check ─────────────────────────────────────────────────────────
recreate_hermes
if docker compose ps --services --status running 2>/dev/null | grep -qx hermes; then
  sleep 8
  if docker logs --since 30s hermes 2>&1 | grep -qi telegram; then
    log "Hermes log mentions Telegram:"
    docker logs --since 30s hermes 2>&1 | grep -i telegram | tail -3 | sed 's/^/    /'
  else
    warn "No Telegram line in Hermes' log yet. Follow it with: docker compose logs -f hermes"
  fi
fi

cat <<EOF

$(printf '\033[1;32m✓ Telegram configured\033[0m')  Open https://t.me/$bot_user and say hi.

  Allowed users:  $users
  Change / test:  scripts/setup-telegram.sh      Turn off:  scripts/setup-telegram.sh --off
EOF
