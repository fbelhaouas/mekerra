sudo bash -c 'target=/usr/local/bin/oosyroo-health; if [ -e "$target" ]; then cp -a -- "$target" "$target.backup-$(date +%Y%m%d-%H%M%S)"; fi; exec vi "$target"'

sudo bash -n /usr/local/bin/oosyroo-health && echo "Syntax OK"

sudo bash -c 'target=/usr/local/bin/oosyroo-health; cp -a -- "$target" "$target.backup-$(date +%Y%m%d-%H%M%S)" && chown root:root "$target" && chmod 0750 "$target" && stat -c "owner=%U group=%G mode=%a file=%n" "$target"'

sudo /usr/local/bin/oosyroo-health --dry-run

sudo bash -c 'echo "### Host identity"; printf "hostname: "; hostname; printf "FQDN: "; hostname -f 2>/dev/null || true; printf "/etc/mailname: "; cat /etc/mailname 2>/dev/null || echo "missing"; echo; echo "### Effective Postfix identity"; postconf myhostname mydomain myorigin mydestination smtpd_tls_cert_file smtpd_tls_key_file 2>/dev/null; echo; echo "### Effective Dovecot TLS identity"; doveconf -n 2>/dev/null | grep -E "^(hostname|ssl_cert|ssl_key)[[:space:]]*=" || true; echo; echo "### Nginx names and certificates"; nginx -T 2>/dev/null | grep -E "^[[:space:]]*(server_name|ssl_certificate|ssl_certificate_key)[[:space:]]" || true; echo; echo "### Certbot certificates"; certbot certificates 2>/dev/null | grep -E "Certificate Name:|Domains:|Expiry Date:|Certificate Path:" || true; echo; echo "### Health monitor configured domain"; grep -nE "^(HOST|CERT_FILE)=" /usr/local/bin/oosyroo-health 2>/dev/null || true; echo; echo "### References to either domain"; grep -RInE "oosyroo\.com|ooysroo\.com" /etc/hostname /etc/hosts /etc/mailname /etc/postfix /etc/dovecot /etc/nginx /etc/letsencrypt/renewal /etc/opendkim.conf /etc/opendkim /etc/default/opendkim 2>/dev/null || true'

sudo bash -c 'set -e; f=/usr/local/bin/oosyroo-health; cp -a -- "$f" "$f.backup-$(date +%Y%m%d-%H%M%S)"; sed -i '\''s/^HOST=.*/HOST="mail.ooysroo.com"/'\'' "$f"; bash -n "$f"; grep -nE "^(HOST|CERT_FILE)=" "$f"'

sudo journalctl -u certbot.service --since "2026-08-01 08:35:00 UTC" --until "2026-08-01 08:50:00 UTC" --no-pager -o short-iso

sudo journalctl -u certbot.service --since "2026-08-01 08:35:00 UTC" --until "2026-08-01 08:50:00 UTC" --no-pager -o short-iso

sudo sed -n '1,220p' /etc/letsencrypt/renewal/mail.ooysroo.com.conf







