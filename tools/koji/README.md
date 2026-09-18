# Koji → geofences helper

Generates SQL that inserts/updates the rows of Blissey's `geofences` table from Koji feature
collections, through Koji's HTTP API. Use it when you keep your fences in Koji but run Blissey
with `[geofences] use_koji = false` (for example because the SQL user must not read the Koji
database).

Requirements: Python 3.11+ (or `tomli` on older versions) with `requests` and `geojson`
(`pip3 install requests geojson`).

## Usage

1. Fill in the `[koji]` section of `config.toml` (API URL, bearer token, project names).

2. Run the script from anywhere (it reads `config.toml` in the repository root, or the file
   given as argument):

   ```bash
   python3 tools/koji/koji.py
   ```

   It writes `mon_geofences.sql` and `quest_geofences.sql` next to the script.

3. Review the files, load them into the stats database, then let Blissey compute the geometry:

   ```bash
   mysql -u<user> -p <stats db> < tools/koji/mon_geofences.sql
   mysql -u<user> -p <stats db> < tools/koji/quest_geofences.sql
   bin/blissey geofences        # or: docker compose exec blissey blissey geofences
   ```

Multi-polygon fences are skipped (Blissey only supports single polygons).
