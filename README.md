# fake-company-infra

Infrastructure and architecture records for the Fake Company ERPNext apps (Linear project MaroneERP).

| Path | Content |
| -- | -- |
| `docs/adr/` | Architecture decision records. Start with `0001-app-split.md`. |
| `dev/` | Local development stack (CHW-86). |

## Local development

The workspace layout is:

```
MaroneERP/
  apps/                morocco_localization, trade_import, fake_company_brand, marone_custom (one git repo each)
  fake-company-infra/  this repo
  erpnext/             upstream ERPNext version-16, read-only reference
```

Requirements: Docker Desktop and Git Bash.

1. Clone the four app repos into `MaroneERP/apps/`.
2. Run `fake-company-infra/dev/up.sh`. The first run takes 15 to 20 minutes.
3. Start the server: `docker compose -f fake-company-infra/dev/compose.yml exec frappe bash -lc "cd frappe-bench && bench start"`.
4. Open `http://marone.localhost:8000` (all apps, plus Frappe HRMS for expense claims) or `http://generic.localhost:8000` (generic apps only). Log in as `Administrator` / `admin`.

`up.sh` is safe to run again. It skips each step that is already done.

The bench lives in the Docker volume `fake-company-dev_bench`. The apps stay on the host in `MaroneERP/apps/` and are soft-linked into the bench, so you edit them with your normal tools.

### Moving from the old `bangicode-dev` stack

The Docker Compose project was renamed from `bangicode-dev` to `fake-company-dev`. A machine set up before the rename still has the old containers and volumes, and `up.sh` does not reuse them:

1. Stop the old containers, so they free ports 8000 and 9000: `docker stop bangicode-dev-frappe-1 bangicode-dev-mariadb-1 bangicode-dev-redis-cache-1 bangicode-dev-redis-queue-1`.
2. Run `dev/up.sh`. It builds a new bench in `fake-company-dev_bench` and creates both sites again (15 to 20 minutes). Nothing is copied from the old volumes.
3. Do not point the new stack at the old volumes: their sites still list the brand app as `bangicode_brand`, and `bench migrate` fails on them.
4. When you no longer need the old data, remove it: `docker rm bangicode-dev-frappe-1 bangicode-dev-mariadb-1 bangicode-dev-redis-cache-1 bangicode-dev-redis-queue-1`, then `docker volume rm bangicode-dev_bench bangicode-dev_mariadb-data`. This deletes the old sites for good.

## New app

```bash
docker compose -f dev/compose.yml exec -T frappe bash /workspace/scripts/new-app.sh <app_name> "<App Title>" "<description>"
python dev/scripts/apply_app_standards.py   # add the app to APPS in this script first
```

`apply_app_standards.py` writes `required_apps`, `[tool.bench.frappe-dependencies]`, the CI workflow, Dependabot, an install smoke test and `CLAUDE.md` for each app.

## CI secret

`marone_custom` CI checks out the three private generic apps. It needs a repository secret `APPS_READ_TOKEN`: a fine-grained GitHub token with read access to the contents of `morocco_localization`, `trade_import` and `fake_company_brand`.
