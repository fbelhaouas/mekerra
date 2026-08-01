sudo bash -c 'target=/usr/local/bin/oosyroo-health; if [ -e "$target" ]; then cp -a -- "$target" "$target.backup-$(date +%Y%m%d-%H%M%S)"; fi; exec vi "$target"'

sudo bash -n /usr/local/bin/oosyroo-health && echo "Syntax OK"

sudo bash -c 'target=/usr/local/bin/oosyroo-health; cp -a -- "$target" "$target.backup-$(date +%Y%m%d-%H%M%S)" && chown root:root "$target" && chmod 0750 "$target" && stat -c "owner=%U group=%G mode=%a file=%n" "$target"'

sudo /usr/local/bin/oosyroo-health --dry-run








