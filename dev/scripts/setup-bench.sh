#!/usr/bin/env bash
# Runs inside the frappe container. Safe to run again: each step skips what exists.
#
# 1. Create the bench (Frappe version-16) and get ERPNext and HRMS version-16.
# 2. Soft-link every app found in /workspace/apps into the bench.
# 3. Create generic.localhost (generic apps only) and marone.localhost (all apps, plus HRMS).
# 4. Compile the French and Arabic translations (.po to .mo), so the desk shows them.
set -euo pipefail

BRANCH=version-16
ROOT=/home/frappe/benches
BENCH=$ROOT/frappe-bench
APPS_SRC=/workspace/apps
GENERIC_APPS=(morocco_localization trade_import fake_company_brand)
TENANT_APP=marone_custom
# Frappe HRMS gives the tenant expense claims (CHW-379). The generic apps never depend on it.
TENANT_EXTRA_APPS=(hrms)

# Docker Desktop DNS needs a few seconds after the container starts.
for _ in $(seq 1 30); do
	getent hosts github.com >/dev/null && break
	sleep 2
done
getent hosts github.com >/dev/null || { echo "DNS: cannot resolve github.com" >&2; exit 1; }

# The bench volume is created empty and owned by root on first start.
sudo chown frappe:frappe "$ROOT"
cd "$ROOT"

# A failed init can leave a Procfile behind, so test that frappe really imports.
if ! "$BENCH/env/bin/python" -c "import frappe" 2>/dev/null; then
	echo ">> bench init ($BRANCH)"
	# The virtualenv stores absolute paths, so the bench is created in place, never moved.
	rm -rf "$BENCH"
	bench init --skip-redis-config-generation --frappe-branch "$BRANCH" --python python3.14 frappe-bench
fi

cd "$BENCH"

bench set-config -g db_host mariadb
bench set-config -g redis_cache redis://redis-cache:6379
bench set-config -g redis_queue redis://redis-queue:6379
bench set-config -g redis_socketio redis://redis-queue:6379
bench set-config -g developer_mode 1
# Chromium makes the PDFs (wkhtmltopdf is deprecated in v16). Without this path,
# Frappe downloads its own copy of Chromium into the bench.
if [ -x /usr/bin/chromium-headless-shell ]; then
	bench set-config -g chromium_path /usr/bin/chromium-headless-shell
fi

# An app counts once it is in sites/apps.txt: bench get-app writes it there last, after the clone,
# pip and yarn. A get-app that failed half-way leaves the folder without the entry; for these
# upstream apps the folder is only a clone, so remove it and fetch again.
registered() { grep -qx "$1" sites/apps.txt; }

for app in erpnext "${TENANT_EXTRA_APPS[@]}"; do
	if ! registered "$app"; then
		if [ -d "apps/$app" ]; then
			echo ">> remove apps/$app left by a failed get-app"
			rm -rf "apps/$app"
		fi
		echo ">> get-app $app ($BRANCH)"
		bench get-app --branch "$BRANCH" "$app"
	fi
done

# Soft-link each custom app that exists on the host.
for app in "${GENERIC_APPS[@]}" "$TENANT_APP"; do
	if [ -f "$APPS_SRC/$app/pyproject.toml" ] && [ ! -e "apps/$app" ]; then
		echo ">> soft-link $app"
		bench get-app --soft-link "$APPS_SRC/$app"
	fi
done

installed() { registered "$1"; }

new_site() {
	local site=$1
	shift
	if [ ! -d "sites/$site" ]; then
		echo ">> new-site $site"
		bench new-site "$site" \
			--db-root-username root \
			--db-root-password "$DB_ROOT_PASSWORD" \
			--admin-password "$ADMIN_PASSWORD" \
			--mariadb-user-host-login-scope='%'
		bench --site "$site" set-config developer_mode 1
		bench --site "$site" execute frappe.db.set_single_value --args '["Print Settings", "pdf_generator", "chrome"]'
		bench --site "$site" execute frappe.db.commit
	fi
	for app in "$@"; do
		if installed "$app" && ! bench --site "$site" list-apps | grep -qx "$app.*"; then
			echo ">> install $app on $site"
			bench --site "$site" install-app "$app"
		fi
	done
}

# generic.localhost proves the generic apps install without the tenant app (ADR 0001).
new_site generic.localhost erpnext "${GENERIC_APPS[@]}"
new_site marone.localhost erpnext "${TENANT_EXTRA_APPS[@]}" "${GENERIC_APPS[@]}" "$TENANT_APP"

# Frappe reads compiled .mo files, not the .po sources. Without them, a site set to French or
# Arabic still shows English. The files go to sites/assets/locale and are shared by every site,
# so one call per language covers both sites. An interrupted compile can leave an empty .mo
# that looks up to date by its date (seen for Arabic) and is then never rebuilt: remove empty
# ones first, so the normal compile rebuilds them and skips every file that is current.
find sites/assets/locale -name '*.mo' -empty -delete 2>/dev/null || true
for locale in fr ar; do
	echo ">> compile translations ($locale)"
	bench --site generic.localhost compile-po-to-mo --locale "$locale"
done
# Translations are cached in Redis per language. Clear it, or a desk that cached the missing
# translations keeps showing English.
for site in generic.localhost marone.localhost; do
	bench --site "$site" clear-cache
done

# No default site: with one set, `bench serve` answers every Host with that site.
# Always pass --site to bench commands.
bench config remove-common-config default_site 2>/dev/null || true
echo ">> done. Start the server with: bench start"
bench --site generic.localhost list-apps
bench --site marone.localhost list-apps
