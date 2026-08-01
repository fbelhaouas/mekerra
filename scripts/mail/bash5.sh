#!/usr/bin/env bash
set -uo pipefail

export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

HOST=mail.oosyroo.com
CONNECT_HOST=127.0.0.1
CERT=/etc/letsencrypt/live/$HOST/fullchain.pem
SECRETS=/var/lib/secrets/mail/pushover.conf
STATE_DIR=/var/lib/mail-monitor
STATE_FILE=$STATE_DIR/oosyroo-health.state
LOCK_FILE=$STATE_DIR/oosyroo-health.lock
LOG=/var/log/oosyroo-health.log
MONITOR_USER=${MONITOR_USER:-no-reply}
WARN_DAYS=${WARN_DAYS:-30}
FAIL_DAYS=${FAIL_DAYS:-14}
COOLDOWN=${COOLDOWN:-21600}

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 64 ;;
esac

STATUS=PASS
RESULTS=()
ISSUES=()
LOCAL_FP=

raise() {
  case "$1:$STATUS" in
    FAIL:*) STATUS=FAIL ;;
    WARN:PASS) STATUS=WARN ;;
  esac
}
ok()   { local detail="${2:-}"; RESULTS+=("$1: OK${detail:+ ($detail)}"); }
info() { RESULTS+=("$1: $2"); }
warn() { raise WARN; RESULTS+=("$1: WARN ($2)"); ISSUES+=("$1: $2"); }
fail() { raise FAIL; RESULTS+=("$1: FAIL ($2)"); ISSUES+=("$1: $2"); }

summary() {
  printf 'Oosyroo Mail Health: %s\n\n' "$STATUS"
  printf '%s\n' "${RESULTS[@]}"
}

notification_body() {
  local prefix= line body
  ((DRY_RUN)) && prefix='TEST MODE - '
  body="${prefix}Oosyroo Mail Health: $STATUS"$'\n'"Host: $HOST"$'\n'"Time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if ((${#ISSUES[@]})); then
    body+=$'\n\nProblems:'
    for line in "${ISSUES[@]}"; do body+=$'\n'"- $line"; done
  else
    body+=$'\n\nAll local checks passed.'
    body+=$'\n'"Certificate: ${days:-unknown} days remaining."
    body+=$'\n'"Outside-in authentication probe: not configured."
  fi
  printf %s "${body:0:1000}"
}

listening() {
  ss -lntH 2>/dev/null | awk -v p=":$1" '$4 ~ p "$" {ok=1} END {exit !ok}'
}

service() {
  systemctl is-active --quiet "$1" 2>/dev/null && ok "$2" || fail "$2" "$1 is not active"
}

presented_tls() {
  local port=$1 mode=$2 label=$3 output cert fp end epoch days
  local -a args=(s_client -connect "$CONNECT_HOST:$port" -servername "$HOST" -verify_hostname "$HOST" -verify_return_error -CApath /etc/ssl/certs)
  [[ $mode == smtp ]] && args+=(-starttls smtp)

  output=$(timeout 15 openssl "${args[@]}" </dev/null 2>&1) || true
  if ! grep -Eq 'Verify return code: 0 \(ok\)|Verification: OK' <<<"$output"; then
    fail "$label" "TLS connection or hostname validation failed"
    return
  fi

  cert=$(awk '/BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{exit}' <<<"$output")
  fp=$(openssl x509 -noout -fingerprint -sha256 2>/dev/null <<<"$cert") || fp=
  fp=${fp#*=}
  if [[ -z $fp ]]; then
    fail "$label" "presented certificate could not be read"
    return
  fi
  if [[ -n $LOCAL_FP && $fp != "$LOCAL_FP" ]]; then
    fail "$label" "service is presenting a different certificate from $CERT"
    return
  fi

  end=$(openssl x509 -noout -enddate 2>/dev/null <<<"$cert") || end=
  epoch=$(date -d "${end#notAfter=}" +%s 2>/dev/null) || epoch=
  if [[ -z $epoch ]]; then
    fail "$label" "presented certificate expiry could not be parsed"
    return
  fi
  days=$(( (epoch - $(date +%s)) / 86400 ))
  ok "$label" "$port, $days days remaining"
}

send_pushover() {
  local title=$1 message=$2 user token push_tmp
  [[ -r $SECRETS ]] || return 1

  set +u
  # shellcheck disable=SC1090
  . "$SECRETS"
  user=${PUSHOVER_USER:-}
  token=${PUSHOVER_TOKEN:-}
  unset PUSHOVER_USER PUSHOVER_TOKEN
  set -u
  [[ -n $user && -n $token ]] || return 1

  push_tmp=$(mktemp -d "$STATE_DIR/.pushover.XXXXXX") || return 1
  chmod 700 "$push_tmp"
  printf %s "$token" >"$push_tmp/token"
  printf %s "$user" >"$push_tmp/user"
  printf %s "$title" >"$push_tmp/title"
  printf %s "${message:0:1000}" >"$push_tmp/message"

  if curl --silent --show-error --fail --max-time 15 \
      --form "token=<$push_tmp/token" \
      --form "user=<$push_tmp/user" \
      --form "title=<$push_tmp/title" \
      --form "message=<$push_tmp/message" \
      --output "$push_tmp/response" \
      https://api.pushover.net/1/messages.json \
      && grep -Eq '"status"[[:space:]]*:[[:space:]]*1' "$push_tmp/response"; then
    rm -rf "$push_tmp"
    return 0
  fi

  rm -rf "$push_tmp"
  return 1
}

if ((EUID != 0)); then
  printf 'Oosyroo Mail Health: FAIL\n\nPrivileges: FAIL (run as root)\n'
  exit 2
fi

if ! mkdir -p "$STATE_DIR" || ! chmod 700 "$STATE_DIR" || ! touch "$LOG" || ! chmod 600 "$LOG"; then
  printf 'Oosyroo Mail Health: FAIL\n\nState/log initialization: FAIL\n'
  exit 2
fi
if ! { exec 9>"$LOCK_FILE"; }; then
  printf 'Oosyroo Mail Health: FAIL\n\nLock initialization: FAIL\n'
  exit 2
fi
flock -n 9 || { echo 'Oosyroo health check is already running.'; exit 0; }

service postfix.service Postfix
service dovecot.service Dovecot
service opendkim.service OpenDKIM
service nginx.service 'Nginx systemd state'

missing=()
for port in 25 80 143 443 993; do listening "$port" || missing+=("$port"); done
submission=()
listening 587 && submission+=(587)
listening 465 && submission+=(465)
if ((${#missing[@]} == 0 && ${#submission[@]})); then
  ok 'Required listeners' "25,80,143,443,993; submission ${submission[*]}"
else
  text=${missing[*]:+missing ${missing[*]}}
  ((${#submission[@]})) || text="${text:+$text; }neither 587 nor 465 is listening"
  fail 'Required listeners' "$text"
fi

main_pid=$(systemctl show nginx.service -p MainPID --value 2>/dev/null || true)
mapfile -t masters < <(ps -eo pid=,args= | awk '/nginx: master process/ && !/awk/ {print $1}')
if [[ $main_pid =~ ^[1-9][0-9]*$ ]] && ((${#masters[@]} == 1)) && [[ ${masters[0]} == "$main_pid" ]]; then
  owned=1
  for port in 80 443; do
    ss -lntpH 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" && /"nginx"/ {ok=1} END {exit !ok}' || owned=0
  done
  ((owned)) && ok 'Nginx process ownership' "systemd master PID $main_pid" || fail 'Nginx process ownership' 'nginx does not own both ports 80 and 443'
else
  fail 'Nginx process ownership' "systemd MainPID=${main_pid:-none}; master PIDs=${masters[*]:-none}"
fi

if [[ -r $CERT ]] && openssl x509 -noout -checkhost "$HOST" -in "$CERT" >/dev/null 2>&1; then
  end=$(openssl x509 -noout -enddate -in "$CERT" 2>/dev/null) || end=
  epoch=$(date -d "${end#notAfter=}" +%s 2>/dev/null) || epoch=
  if [[ -n $epoch ]]; then
    days=$(( (epoch - $(date +%s)) / 86400 ))
    ((days < 0)) && fail Certificate "expired $((-days)) days ago" \
      || { ((days <= FAIL_DAYS)) && fail Certificate "$days days remaining" \
      || { ((days <= WARN_DAYS)) && warn Certificate "$days days remaining" \
      || info Certificate "$days days remaining"; }; }
  else
    fail Certificate 'expiry could not be parsed'
  fi
  LOCAL_FP=$(openssl x509 -noout -fingerprint -sha256 -in "$CERT" 2>/dev/null || true)
  LOCAL_FP=${LOCAL_FP#*=}
  target=$(readlink -f "$CERT" 2>/dev/null || true)
  mtime=$(stat -c %Y "$target" 2>/dev/null || true)
  [[ $mtime =~ ^[0-9]+$ ]] && info 'Last renewal' "$(date -u -d "@$mtime" '+%Y-%m-%d %H:%M UTC')" || warn 'Last renewal' 'unknown'
else
  fail Certificate "$CERT is missing, unreadable, or invalid for $HOST"
fi

presented_tls 993 direct 'IMAPS TLS'
for port in "${submission[@]}"; do
  if [[ $port == 587 ]]; then
    presented_tls "$port" smtp "SMTP TLS $port"
  else
    presented_tls "$port" direct "SMTP TLS $port"
  fi
done

if systemctl is-enabled --quiet certbot.timer 2>/dev/null && systemctl is-active --quiet certbot.timer 2>/dev/null; then
  ok 'Certbot timer'
else
  fail 'Certbot timer' "enabled=$(systemctl is-enabled certbot.timer 2>/dev/null || true), active=$(systemctl is-active certbot.timer 2>/dev/null || true)"
fi
next=$(systemctl show certbot.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
[[ -n $next && $next != n/a ]] && info 'Next Certbot run' "$next" || warn 'Next Certbot run' 'unknown'

result=$(systemctl show certbot.service -p Result --value 2>/dev/null || true)
exit_status=$(systemctl show certbot.service -p ExecMainStatus --value 2>/dev/null || true)
last_run=$(systemctl show certbot.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
[[ -n $last_run ]] || last_run=$(systemctl show certbot.service -p InactiveExitTimestamp --value 2>/dev/null || true)
if [[ $result == success && ${exit_status:-0} == 0 ]]; then
  last_epoch=$(date -d "$last_run" +%s 2>/dev/null || true)
  if [[ $last_epoch =~ ^[0-9]+$ ]] && (( $(date +%s) - last_epoch <= 129600 )); then
    ok 'Last Certbot run' "${last_run:-time unknown}"
  elif [[ $last_epoch =~ ^[0-9]+$ ]]; then
    warn 'Last Certbot run' "${last_run}; more than 36 hours ago"
  else
    warn 'Last Certbot run' 'latest result succeeded, but its completion time is unknown'
  fi
elif [[ -z $result ]]; then
  warn 'Last Certbot run' 'no systemd result is available yet'
else
  fail 'Last Certbot run' "result=${result:-unknown}, exit=${exit_status:-unknown}, time=${last_run:-unknown}"
fi

recent=$(journalctl -u certbot.service --since '7 days ago' --no-pager -o cat 2>/dev/null \
  | grep -Eic '(^|[^a-z])(failed|failure|error|unauthorized|challenge failed|all renewals failed)([^a-z]|$)' || true)
if ((recent == 0)); then
  ok 'Recent Certbot errors' 'none in 7 days'
elif [[ $result == success && ${exit_status:-0} == 0 ]]; then
  info 'Recent Certbot errors' "$recent found; latest run succeeded"
else
  fail 'Recent Certbot errors' "$recent found in 7 days"
fi

hook_errors=()
for hook in /etc/letsencrypt/renewal-hooks/deploy/notify-and-reload.sh /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh; do
  if [[ ! -f $hook ]]; then
    hook_errors+=("missing $hook")
  elif [[ ! -x $hook ]]; then
    hook_errors+=("not executable $hook")
  fi
done
if [[ -f /etc/letsencrypt/renewal-hooks/deploy/notify-and-reload.sh ]] && ! grep -Fq "$SECRETS" /etc/letsencrypt/renewal-hooks/deploy/notify-and-reload.sh; then
  hook_errors+=("notification hook does not use $SECRETS")
fi
((${#hook_errors[@]} == 0)) && ok 'Certbot deploy hooks' || fail 'Certbot deploy hooks' "${hook_errors[*]}"

queue=$(postqueue -j 2>/dev/null)
if (($? == 0)); then
  total=$(grep -cve '^[[:space:]]*$' <<<"$queue" || true)
  deferred=$(grep -Ec '"queue_name"[[:space:]]*:[[:space:]]*"deferred"' <<<"$queue" || true)
  ((deferred == 0)) && info 'Mail queue' "0 deferred ($total total)" \
    || { ((deferred <= 10)) && warn 'Mail queue' "$deferred deferred ($total total)" || fail 'Mail queue' "$deferred deferred ($total total)"; }
else
  fail 'Mail queue' 'postqueue could not be read'
fi

timeout 15 doveadm mailbox status -u "$MONITOR_USER" messages INBOX >/dev/null 2>&1 \
  && ok 'Local mailbox access' "$MONITOR_USER" \
  || fail 'Local mailbox access' "cannot read INBOX for $MONITOR_USER"
info 'Outside-in probe' 'not configured; this script validates the mail server locally'

socket_errors=()
[[ -S /var/spool/postfix/private/dovecot-lmtp ]] || socket_errors+=('LMTP socket missing')
[[ -S /var/spool/postfix/private/auth ]] || socket_errors+=('auth socket missing')
((${#socket_errors[@]} == 0)) && ok 'Postfix-Dovecot sockets' || fail 'Postfix-Dovecot sockets' "${socket_errors[*]}"

if [[ -r $SECRETS ]]; then
  dir_mode=$(stat -c '%U:%G %a' "$(dirname "$SECRETS")" 2>/dev/null || true)
  file_mode=$(stat -c '%U:%G %a' "$SECRETS" 2>/dev/null || true)
  if [[ $dir_mode == 'root:root 700' && $file_mode == 'root:root 600' ]]; then
    ok 'Pushover secrets'
  else
    warn 'Pushover secrets' "expected directory root:root 700 and file root:root 600; found directory=${dir_mode:-unknown}, file=${file_mode:-unknown}"
  fi
else
  fail 'Pushover secrets' "$SECRETS is missing or unreadable"
fi

notice=
if ((DRY_RUN)); then
  body=$(notification_body)
  send_pushover "[TEST] Oosyroo Mail Health: $STATUS" "$body" \
    && notice='Pushover: TEST notification sent' \
    || fail Pushover 'TEST notification failed'
elif [[ $STATUS != PASS ]]; then
  fingerprint=$(printf '%s\n%s\n' "$STATUS" "${ISSUES[*]}" | sha256sum | awk '{print $1}')
  now=$(date +%s)
  old_time=0
  old_fingerprint=
  [[ -r $STATE_FILE ]] && IFS='|' read -r old_time old_fingerprint <"$STATE_FILE" || true
  if [[ $old_time =~ ^[0-9]+$ && $old_fingerprint == "$fingerprint" ]] && ((now - old_time < COOLDOWN)); then
    notice='Pushover: identical alert suppressed by cooldown'
  else
    body=$(notification_body)
    if send_pushover "Oosyroo Mail Health: $STATUS" "$body"; then
      tmp=$(mktemp "$STATE_DIR/oosyroo-health.XXXXXX")
      printf '%s|%s\n' "$now" "$fingerprint" >"$tmp"
      chmod 600 "$tmp"
      mv -f "$tmp" "$STATE_FILE"
      notice='Pushover: alert sent'
    else
      fail Pushover 'alert failed'
    fi
  fi
else
  rm -f "$STATE_FILE"
  notice='Pushover: not sent (healthy)'
fi

output=$(summary)
[[ -n $notice ]] && output="$output"$'\n'"$notice"
printf '%s\n' "$output"
{
  printf '%s ' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '%s' "$STATUS"
  ((${#ISSUES[@]})) && printf ' - %s' "${ISSUES[*]}"
  printf '\n'
} >>"$LOG" 2>/dev/null || true

case $STATUS in
  PASS) exit 0 ;;
  WARN) exit 1 ;;
  FAIL) exit 2 ;;
esac
