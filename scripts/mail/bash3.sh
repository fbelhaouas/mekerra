root@mail:/etc/letsencrypt/renewal-hooks/deploy# cat notify-and-reload.sh 
#!/usr/bin/env bash
# notify-and-reload.sh
# Certbot deploy hook: notify via Pushover and reload mail services.
# Usage: notify-and-reload.sh [test]
#
# Expects secrets in /var/lib/secrets/mail/pushover.conf exporting:
#   PUSHOVER_USER and PUSHOVER_TOKEN
#
# Logs to /var/log/certbot-hooks.log

set -euo pipefail

LOGFILE=/var/log/certbot-hooks.log
SECRETS=/var/lib/secrets/mail/pushover.conf
MAIL_SERVICES=(dovecot postfix)
CURL_BIN=$(command -v curl || true)
OPENSSL_BIN=$(command -v openssl || true)

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "$(timestamp) $*" | tee -a "$LOGFILE"; }

# Load secrets
if [ -r "$SECRETS" ]; then
  # file must export PUSHOVER_USER and PUSHOVER_TOKEN
  # e.g. export PUSHOVER_USER='u..' ; export PUSHOVER_TOKEN='t...'
  # shellcheck disable=SC1090
  . "$SECRETS"
else
  log "ERROR: secrets file $SECRETS missing or unreadable; aborting."
  exit 2
fi

: "${PUSHOVER_USER:?missing PUSHOVER_USER in $SECRETS}"
: "${PUSHOVER_TOKEN:?missing PUSHOVER_TOKEN in $SECRETS}"

MODE="${1:-}"

# Build context from certbot environment (if present)
DOMAIN="${RENEWED_DOMAINS:-${CERTBOT_DOMAIN:-unknown}}"
RENEWED_LINE=""
if [ -n "${RENEWED_DOMAINS:-}" ]; then
  RENEWED_LINE="${RENEWED_DOMAINS}"
fi

# Try to determine expiry from cert path if provided by Certbot env or from live path
EXPIRY_STR=""
if [ -n "${RENEWED_LINE:-}" ]; then
  # try inspect /etc/letsencrypt/live/<first domain>/fullchain.pem
  FIRST_DOMAIN=$(echo "$RENEWED_LINE" | awk -F',' '{ print $1 }')
  CERT_PATH="/etc/letsencrypt/live/${FIRST_DOMAIN}/fullchain.pem"
  if [ -r "$CERT_PATH" ] && [ -n "$OPENSSL_BIN" ]; then
    if expiry=$($OPENSSL_BIN x509 -noout -enddate -in "$CERT_PATH" 2>/dev/null); then
      # format: notAfter=Apr 20 20:44:08 2026 GMT
      date_str=${expiry#notAfter=}
      if expiry_ts=$(date -d "$date_str" +%s 2>/dev/null); then
        EXPIRY_STR="$(date -u -d "@$expiry_ts" +"%Y-%m-%dT%H:%M:%SZ") (UTC)"
      else
        EXPIRY_STR="$date_str"
      fi
    fi
  fi
fi

TITLE="Certbot: certificate renewed for ${DOMAIN}"
BODY="$(printf "Certificate renewed: %s\n\nDomains: %s\nExpiry: %s\nHost: %s\nCertbot env: %s\n\n(If this is a dry-run test, the hook may be skipped by certbot.)" \
       "$(timestamp)" "${RENEWED_LINE:-(none)}" "${EXPIRY_STR:-unknown}" "$(hostname -f)" "${RENEWED_LINE:-none}")"

send_pushover() {
  if [ -z "$CURL_BIN" ]; then
    log "WARNING: curl not found; cannot send Pushover notification."
    return 1
  fi

  # send; attempt once with timeout; do not fail hook if network fails
  resp=$($CURL_BIN --max-time 10 -sS \
    --form-string "token=${PUSHOVER_TOKEN}" \
    --form-string "user=${PUSHOVER_USER}" \
    --form-string "title=${TITLE}" \
    --form-string "message=${BODY}" \
    "https://api.pushover.net/1/messages.json" 2>&1) || true

  if printf '%s' "$resp" | grep -q '"status":[[:space:]]*1'; then
    log "Pushover: notification sent."
    return 0
  else
    log "WARNING: Pushover call failed or returned non-OK: $resp"
    return 2
  fi
}

if [ "$MODE" = "test" ]; then
  log "TEST MODE: sending Pushover test notification (no service reload)."
  if send_pushover; then
    log "TEST MODE: Pushover sent."
    exit 0
  else
    log "TEST MODE: Pushover failed."
    exit 3
  fi
fi

# Normal deploy hook run
log "Deploy hook: sending Pushover notification for certificate renewal."
if ! send_pushover; then
  log "ERROR: Pushover notification failed; continuing to reload services."
fi

# Reload configured services (best-effort; do not let failures abort the hook)
for svc in "${MAIL_SERVICES[@]}"; do
  if systemctl list-unit-files --type=service | grep -q -E "^${svc}\.service" || systemctl status "$svc" &>/dev/null; then
    log "Reloading $svc"
    if systemctl reload "$svc" >/dev/null 2>&1; then
      log "Reloaded $svc successfully."
    else
      log "WARNING: reload $svc failed, trying restart."
      if systemctl restart "$svc" >/dev/null 2>&1; then
        log "Restarted $svc successfully."
      else
        log "ERROR: restart $svc failed; check systemctl status $svc."
      fi
    fi
  else
    log "Service $svc not present/enabled; skipping."
  fi
done

log "Deploy hook completed."
exit 0

