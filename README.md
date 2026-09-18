# Blissey

Statistics processor for a [Dragonite](https://github.com/UnownHash) / [Golbat](https://github.com/UnownHash/Golbat)
Pokémon GO scanning stack. Every 5 minutes Blissey reads the raw data those tools produce
(worker stats, per-area Pokémon stats, pokestop quests, accounts and `dragonite.log`) and
writes compact time series into its own **stats** database, then rolls them up into 15 minute,
hourly, daily and weekly buckets. A set of Grafana dashboards visualises the result.

Fork of [UnownHash/Blissey](https://github.com/UnownHash/Blissey) (includes everything from its
`develop` branch: schema v90, remote-auth/background-token metrics, multi-instance mode),
restructured around a single CLI, with a Docker image and bug fixes.

```
 Dragonite ──► dragonite.stats_workers ──┐
           ──► dragonite.account        ─┤
           ──► logs/dragonite.log       ─┤        ┌──────────────┐        ┌─────────┐
                                         ├──────► │   Blissey    │ ─────► │ stats   │ ──► Grafana
 Golbat    ──► golbat.pokemon_area_stats ─┤        │ (every 5 m)  │        │ database│
           ──► golbat.pokestop           ─┘        └──────────────┘        └─────────┘
 Fortwatcher ► stats.stats_forts ────────────────────────┘
```

## Contents

- [What gets processed](#what-gets-processed)
- [Requirements](#requirements)
- [Quick start: Docker](#quick-start-docker)
- [Quick start: manual install](#quick-start-manual-install)
- [Configuration reference](#configuration-reference)
- [Geofences](#geofences)
- [Multi-instance setup](#multi-instance-setup)
- [Grafana](#grafana)
- [Command line](#command-line)
- [Schedule](#schedule)
- [Data retention and backups](#data-retention-and-backups)
- [Upgrading](#upgrading)
- [Migrating from the old layout](#migrating-from-the-old-layout)
- [Troubleshooting](#troubleshooting)
- [Tools](#tools)
- [Repository layout](#repository-layout)

## What gets processed

| Source | Stats table(s) | Intervals | Enabled by |
|---|---|---|---|
| `dragonite.stats_workers` | `stats_worker` | 5 → 15 → 60 → 1440 → 10080 | `[processing] worker_stats = true` (Dragonite config needs `stats = true`) |
| `golbat.pokemon_area_stats` | `stats_mon_area` | 5 → 15 → 60 → 1440 → 10080 | `mon_area_stats = true` (Golbat needs area fences, see [Geofences](#geofences)) |
| `golbat.pokestop` × quest fences | `stats_quest_area` | 5 → 15 → 60 → 1440 → 10080 | `quest_area_stats = true` |
| `dragonite.account` | `accounts` | 15 | `account_stats = true` |
| `dragonite.log` (+ `dragonite.stats_accounts` for short sessions) | `dragoLog`, `dragoLog_fort`, `dragoLog_invasion`, `stats_worker_fort`, `stats_prioraid`, `stats_invasion` | 5 → 15 → 60 → 1440 → 10080 | `[dragonite] parse_log = true` (Dragonite must write `logs/dragonite.log`) |
| `stats_forts` (written by Fortwatcher) | `stats_forts` | 15 → 60 → 1440 → 10080 | `fortwatcher = true` |
| Rotom API | Discord webhook | 5 | `[rotom] outage_report = true` |

`rpl` in the tables is the bucket length in minutes (5, 15, 60, 1440, 10080).

`dragoLog` counts per 5 minutes: RPC status codes, MITM/websocket errors, auth requests and
times, account switches by reason (suspended, banned, shadow banned, disabled, daily limit,
out of range, connection time, cooldown, low level API, quest distance, consecutive RPC
errors, backoff), remote auth attempts/failures/times, background refreshes, background token
requests/times, cleared tokens and sessions shorter than 20 s (`lowDuration`). Fort workers
and the invasion worker get their own tables so they do not skew the area workers.

## Requirements

- **MariaDB 10.6+** (tested) hosting the Dragonite and Golbat databases. The stats database must
  live on the **same server** as the Dragonite database (the queries join across databases).
  Golbat may run on another server, see `golbat_host`.
- A SQL user with full rights on the stats database and `SELECT` on the Dragonite and Golbat
  databases (`DELETE` on `dragonite.stats_workers` / `golbat.pokemon_area_stats` if you let
  Blissey prune the raw tables, `SELECT` on Koji when `use_koji = true`).
- Dragonite with `stats = true` in its config (worker stats) and file logging enabled (log parsing).
- Golbat configured with area fences (`geojson/geofence.json` or Koji) so it fills
  `pokemon_area_stats`.
- Docker, **or** a Linux host with `bash`, `python3` (3.11+, or 3.x with `python3-tomli`),
  `mariadb-client` (`mysql`, `mysqldump`), `jq`, `curl`, `gawk`, `gzip`, `tar`, `flock` and
  optionally `geographiclib-tools` (fence area in km²).
- Grafana with the MySQL datasource for the dashboards.

## Quick start: Docker

```bash
git clone https://github.com/pokemaplx/blissey.git && cd blissey
cp config.toml.example config.toml
nano config.toml                      # database credentials + what to process
cp .env.example .env
nano .env                             # TZ + host path of Dragonite's log folder
docker compose up -d --build
docker compose logs -f                # config check, schema setup, then one tick every 5 minutes
```

On start the container waits for the database, validates `config.toml`, creates/upgrades the
tables and procedures (idempotent) and starts the scheduler.

Things to know:

- `.env` holds the per-host settings (the same names work as environment variables in
  Coolify/Portainer): `BLISSEY_CONFIG_PATH`, `BLISSEY_DATA_PATH` and `DRAGONITE_LOGS` are the
  host paths of `config.toml`, the data folder (logs, temp files, backups) and Dragonite's log
  folder. The log folder is mounted read-only at `/dragonite/logs`, the default
  `[dragonite] log_dir`; not parsing the log? Set `parse_log = false` and drop that volume.
- Timezone: the compose file mounts the host's `/etc/localtime`, so the container uses the
  host's zone; it must be the **same timezone as your database server** (all 5 minute buckets
  are computed from the current time). To pin it explicitly, replace that mount by
  `environment: TZ: <zone>`.
- The container joins the compose network, so `[database] host` and the Rotom/Dragonite
  `api_host` must be reachable from there (container names when they run in Docker on the same
  network, see the commented `networks` block). Uncomment `network_mode: host` to mirror a
  manual install where everything is on `127.0.0.1`.
- Fences: with `use_koji = false` insert your fences into table `geofences` (see
  [Geofences](#geofences)) and run `docker compose exec blissey blissey geofences` once.
- Any CLI command can be run inside the container: `docker compose exec blissey blissey check`.

## Quick start: manual install

```bash
sudo apt install python3 mariadb-client jq curl gawk gzip tar util-linux geographiclib-tools
git clone https://github.com/pokemaplx/blissey.git && cd blissey
cp config.toml.example config.toml
nano config.toml
bin/blissey check                     # config, commands and database access
bin/blissey setup                     # tables, migrations, procedures
bin/blissey geofences                 # only with use_koji = false, after inserting fences
bin/blissey crontab                   # prints the crontab line
(crontab -l; bin/blissey crontab) | crontab -
```

Everything Blissey writes goes to `data/` next to the repository (override with
`BLISSEY_DATA_DIR`).

## Configuration reference

`config.toml` ([TOML](https://toml.io)); start from `config.toml.example`, which documents every
key. Old `config.ini` files convert with `bin/blissey migrate-config config.ini > config.toml`.

| Section / key | Default | Description |
|---|---|---|
| `[database]` `host`, `port` | `127.0.0.1`, `3306` | Database server hosting the Dragonite and stats databases |
| `user`, `password` | | Database credentials (required) |
| `dragonite`, `golbat`, `stats`, `koji` | `dragonite`, `golbat`, `stats`, `koji` | Database names (`stats` must exist; tables are created by `setup`; `koji` only with `use_koji`) |
| `golbat_host` | | Set when Golbat's database is on another server (same port/credentials). The quest procedure is then created in the Golbat database. |
| `[processing]` `worker_stats` | `true` | Process `dragonite.stats_workers` |
| `mon_area_stats` | `true` | Process `golbat.pokemon_area_stats` |
| `quest_area_stats` | `true` | Process quests per fence from `golbat.pokestop` |
| `account_stats` | `true` | Snapshot `dragonite.account` every 15 minutes |
| `fortwatcher` | `false` | Aggregate `stats_forts` written by Fortwatcher |
| `[geofences]` `use_koji` | `false` | `true`: fences come from Koji's database, `false`: from table `geofences` |
| `koji_project` | | Koji project holding the quest fences (usually the Dragonite project) |
| `[dragonite]` `parse_log` | `true` | Parse `dragonite.log` |
| `log_dir` | `/dragonite/logs` | Folder containing `dragonite.log` and the rotated `dragonite-*.gz` |
| `api_host`, `api_port` | `127.0.0.1`, `7272` | Dragonite API, used to request the hourly log rotation |
| `fort_areas` | `[]` | Fort area names whose workers are counted separately |
| `invasion_worker` | | Invasion worker name whose lines are counted separately |
| `[rotom]` `outage_report`, `discord_webhook` | `false` | Post devices without data for 3 minutes to a Discord webhook |
| `api_host`, `api_port` | `127.0.0.1`, `7072` | Rotom API (outage report, `tools/jobexecutor`) |
| `[backups]` `golbat`, `golbat_days` | `true`, `7` | Daily Golbat backup (structure + gym/pokestop/spawnpoint data) in `data/backups/golbat` |
| `dragonite`, `dragonite_days` | `true`, `7` | Daily full Dragonite dump in `data/backups/dragonite` |
| `[retention]` `stats` | `{ rpl5 = 30, rpl15 = 90, rpl60 = 180, rpl1440 = 365, rpl10080 = 0 }` | Days to keep `stats_worker`, `stats_mon_area`, `stats_quest_area` per interval (0 = forever) |
| `dragonite_log` | same | Same for the `dragonite.log` derived tables |
| `accounts` | `90` | Days to keep table `accounts` |
| `stats_account` | `90` | Days to keep the legacy table `stats_account` |
| `raw_workers`, `raw_areas` | `1`, `1` | Days to keep the raw `dragonite.stats_workers` / `golbat.pokemon_area_stats` (0 = do not touch) |
| `[multi_instance]` `enabled` | `false` | Also feed a central database shared by several Blissey instances (see [Multi-instance setup](#multi-instance-setup)) |
| `role` | `master` | `master` (owns the central database) or `slave` |
| `database` | `allblissey` | Name of the central database (must exist) |
| `user`, `password` | | Credentials for the central database (empty = `[database]` user/password) |
| `[koji]` `api_url`, `api_token`, `mon_project`, `quest_project` | | Only for `tools/koji/koji.py` (Koji HTTP API) |

Environment variables (mostly for Docker): `BLISSEY_CONFIG` (path to config.toml),
`BLISSEY_DATA_DIR`, `BLISSEY_LOG_STDOUT=1` (also print log lines to stdout),
`BLISSEY_DRY_RUN=1` (print the SQL that would run instead of executing it).

## Geofences

Blissey needs the **mon** fences (matching what Golbat uses for `pokemon_area_stats`) and the
**quest** fences (the areas your quest workers cover). Two options:

### Option 1: Koji

Set `[geofences] use_koji = true`, `koji_project = "<koji project with the quest fences>"` and
grant the SQL user `SELECT` on the Koji database. Mon fences are not needed (Golbat already aggregates by
area/fence name); quest fences are read straight from Koji at every run.

### Option 2: table `geofences`

Set `use_koji = false` and insert the fences into table `geofences` of the stats database:

```sql
-- mon fences: area + optional sub fence (Grafana groups by the text before the first "_")
insert ignore into geofences (area, fence, type, coords) values
  ('Newyork', 'Newyork_centre', 'mon', 'lat1 lon1,lat2 lon2,lat3 lon3,lat1 lon1'),
  ('Newyork', 'Newyork_south',  'mon', 'lat1 lon1,lat2 lon2,lat3 lon3,lat1 lon1');

-- quest fence (fence defaults to the area name)
insert ignore into geofences (area, type, coords) values
  ('Newyork', 'quest', 'lat1 lon1,lat2 lon2,lat3 lon3,lat1 lon1');
```

- `coords` is `lat lon` pairs separated by commas; the first and last coordinate must be equal.
- `type` is `mon`, `quest` or `both`.
- Mon `area`/`fence` names must match the names Golbat writes to `pokemon_area_stats`.

Then run `blissey geofences` (or `docker compose exec blissey blissey geofences`). It fills the
polygon columns used by the quest queries, the area in km² (needs Planimeter) and the UTC
offset / country code of every area (one lookup per area on api.wheretheiss.at). Rerun it
whenever fences change.

[tools/koji](tools/koji/README.md) can generate these inserts from Koji feature collections.

## Multi-instance setup

Running several Dragonite/Golbat stacks, each with its own Blissey? Every instance can add its
5 minute numbers to one **central database** so a single set of dashboards
(`grafana/dashboards/multi-instance/`) shows the whole fleet. Areas and workers are collapsed
to `all` in the central database; per-area detail stays in each instance's own stats database.

- All instances must use the same database server (`dbip`) and a central database that
  already exists; the SQL user (or `[multi_instance] user`) needs full rights on it.
- Set `[multi_instance] enabled = true` on every instance, `role = "master"` on exactly one of
  them and `"slave"` on the others. The master creates the tables of the central database on
  `blissey setup`, rolls it up to 15/60/1440/10080 minutes and applies the retention settings;
  slaves only add their rpl 5 rows (and the 15 minute account snapshot).
- Every instance waits 10 s before writing to the central database so the others can finish
  their own rpl 5 processing first; keep the clocks in sync.
- Import `grafana/dashboards/multi-instance/*.json` against a datasource pointing at the
  central database.

## Grafana

1. Install Grafana ([apt](https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/)
   or [Docker](https://hub.docker.com/r/grafana/grafana)).
2. Add a **MySQL** datasource for the stats database. Dashboards 06, 30 and 31 also use a
   datasource pointing at the Dragonite database.
3. Import the JSON files from `grafana/dashboards/` (Dashboards → New → Import) and pick the
   datasource(s) when asked.

| Dashboard | Shows | Needs |
|---|---|---|
| 00 KPIs | Overview: Pokémon scanned, IV %, quest coverage, proto times | stats |
| 01 Area performance overview | Encounter times/TTH per area | `mon_area_stats` |
| 02 Area worker stats | Locations, GMO failures, delays per worker | `worker_stats` |
| 03 Area stats | Mon stats per area/fence | `mon_area_stats` |
| 05 Quest stats | AR / non-AR quest progress per area | `quest_area_stats` |
| 06 Account stats | Account pool, sessions and switch reasons | `account_stats`, `parse_log`, Dragonite datasource |
| 07 Invasion stats | Invasion worker throughput and line-ups | `parse_log`, `invasion_worker` |
| 09 Fort mode stats | Fort workers, raid watcher | `parse_log`, `fort_areas` |
| 10 Dragonite log | RPC status codes, MITM/WS errors, auth times | `parse_log` |
| 30 draGOnite dimensioning overview | Sizing from `dragonite.account` | Dragonite datasource |
| 31 draGOnite accounts | Account states over time | stats + Dragonite datasources |
| 32 Fortwatcher | Fort changes per area | `fortwatcher` |
| `multi-instance/*` | The same views over the central database of a [multi-instance setup](#multi-instance-setup) | `[multi_instance]` |

## Command line

`bin/blissey <command>` (inside Docker: `docker compose exec blissey blissey <command>`)

| Command | What it does |
|---|---|
| `check` | Validate `config.toml`, required commands and database connectivity |
| `setup` | Create tables, apply pending migrations (`sql/migrations`), (re)create the quest procedure. Safe to rerun. |
| `geofences` | Compute geometry, km² and timezone for table `geofences` (`use_koji = false`) |
| `run <rpl>` | Process one interval now: `5`, `15`, `60`, `1440` or `10080` |
| `tick` | Cron entry point: runs every interval that is due at the current minute |
| `logrotate` | Ask Dragonite to rotate its log |
| `crontab` | Print the crontab line for a manual install |
| `migrate-config <config.ini>` | Print the `config.toml` equivalent of an old `config.ini` |
| `health` | Exit 0 when the config loads, the stats database answers and a tick completed in the last 15 minutes (the Docker `HEALTHCHECK`) |

Every step writes a line `[start] [stop] [duration] name` to `data/logs/log_YYYYMM.log`
(`FAILED (rc=N)` when it errored; stderr of the failing command is in the same file).

## Schedule

One cron entry (`*/5 * * * * blissey tick`) replaces the old 26 line crontab. Each tick runs, in
this order:

| When | What |
|---|---|
| every 5 minutes | rpl 5: worker, mon area, quest area, outage report, dragonite.log, raw table cleanup |
| :00 :15 :30 :45 | rpl 15 |
| :00 | Dragonite log rotation request (before rpl 5), then rpl 60 |
| 00:00 | rpl 1440, backups, retention cleanup |
| Monday 00:10 | rpl 10080 |

Ticks are serialised with a lock; a tick that has to wait more than 4 minutes for the previous
one is skipped and logged.

## Data retention and backups

- Aggregated tables are pruned daily per interval according to `[retention]` (days, 0 = forever).
- Raw source tables (`dragonite.stats_workers`, `golbat.pokemon_area_stats`) are pruned every
  5 minutes when `raw_workers` / `raw_areas` are above 0. Golbat only needs them for Blissey.
- Daily backups land in `data/backups/{golbat,dragonite}/` as `.sql.tar.gz` and are removed
  after `*_backup_days` days.

## Upgrading

```bash
git pull
docker compose up -d --build          # Docker: setup runs automatically on start
# manual install:
bin/blissey setup
```

Compare `config.toml.example` with your `config.toml` for new keys and re-import changed
dashboards from `grafana/dashboards/`.

## Migrating from the old layout

If you ran the previous version (`settings.run`, `cron_files/`, `default_files/`):

1. The configuration is now `config.toml`: `bin/blissey migrate-config config.ini > config.toml`
   converts the old file (all keys, including the old `controllerdb` name), then review the
   result. `tools/koji/config.ini` and `tools/jobexecutor/config.ini` are gone: the Koji API
   settings live in `[koji]`, the job executor uses `[rotom]`.
2. Remove the old Blissey lines from your crontab and add the single line from `bin/blissey crontab`.
3. Run `bin/blissey setup` once (equivalent of `settings.run`; `geofences` is now a separate
   command).
4. `logs/`, `tmp/`, `golbatbackup/` and `dragobackup/` moved to `data/logs`, `data/tmp`,
   `data/backups/golbat` and `data/backups/dragonite`. Delete the old folders when you no
   longer need them.
5. The generated files `procedures.sql`, `crontab.txt` and `cron_files/*.sql` no longer exist;
   database names are substituted at run time.
6. `blissey setup` applies migration 90 from upstream: the unused `gmo*` columns of the
   `dragoLog*` tables are dropped and the new counters added. Re-import the dashboards, they
   changed accordingly. The per-account request table `stats_account` is no longer filled
   (Dragonite provides `stats_accounts` itself).

## Troubleshooting

- **Empty dashboards / no rows in `stats_*`**: run `bin/blissey check`, then
  `bin/blissey run 5` and read `data/logs/log_YYYYMM.log`; SQL errors are printed above the
  step's timing line.
- **Buckets are shifted by hours**: the timezone of the machine running Blissey differs from
  the database server. In Docker set `TZ`; on a host align `/etc/localtime` or MariaDB's
  `time_zone`.
- **`stats_quest_area` stays empty** with `use_koji = false`: the quest fences have no geometry.
  Run `bin/blissey geofences` after inserting them.
- **`LOAD DATA LOCAL` errors** (external Golbat without Koji): enable `local_infile` on the
  Golbat MariaDB server.
- **`No dragonite logfile found`**: check `[dragonite] log_dir` (`/dragonite/logs` in Docker
  together with the volume mounted there).
- **Dry run**: `BLISSEY_DRY_RUN=1 bin/blissey tick` prints everything that would be executed
  without touching the database.

## Tools

- [tools/koji](tools/koji/README.md): generate `geofences` inserts through the Koji HTTP API
  (`[koji]` section of `config.toml`).
- [tools/jobexecutor](tools/jobexecutor/job.sh): interactive helper to run a Rotom job (as
  defined in Rotom's `jobs.json`) on one or all devices through the Rotom API (`[rotom]`).
- `tools/discord.sh`: [discord.sh](https://github.com/fieu/discord.sh) by ChaoticWeg and fieu,
  used for the outage report.

## Repository layout

```
bin/blissey            command line entry point
lib/                   bash modules (config, logging/mysql helpers, setup, geofences, intervals, dragonite.log parsing, maintenance)
sql/schema.sql         base tables
sql/migrations/        numbered schema upgrades, applied by `blissey setup`
sql/procedures/        quest-per-fence procedure (local and external-Golbat variants)
sql/rpl/<rpl>/         one SQL file per interval and step (worker, mon_area, quest_area, ...)
grafana/dashboards/    Grafana dashboards to import
docker/                container entrypoint and crontab
tools/                 optional helpers
config.toml.example    configuration template (every key documented)
data/                  runtime files (created on first run, git-ignored)
```

Database names inside the SQL files (`blissey.`, `golbat.`, `dragonite.`, `koji.`) are
placeholders replaced with the configured names when a file is executed.
