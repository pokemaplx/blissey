#!/usr/bin/env python3
"""Generate `geofences` inserts for Blissey from Koji feature collections.

Reads [koji] api_url / api_token / mon_project / quest_project from config.toml (repository
root, or the file given as first argument) and writes mon_geofences.sql and
quest_geofences.sql next to this script.
"""
import json
import os
import sys

import geojson
import requests

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    import tomli as tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def transform(coordinate):
    return str(coordinate[1]) + " " + str(coordinate[0])


def read_config(path):
    with open(path, "rb") as handle:
        config = tomllib.load(handle).get("koji", {})
    for key in ("api_url", "api_token"):
        if not config.get(key):
            sys.exit(f"[koji] {key} is not set in {path}")
    return config


def feature_collection(config, project):
    url = f"{config['api_url'].rstrip('/')}/api/v1/geofence/feature-collection/{project}"
    response = requests.get(
        url,
        params={"ignoremanualparent": "true", "parent": "true"},
        headers={"Authorization": f"Bearer {config['api_token']}"},
        timeout=30,
    )
    if response.status_code != 200:
        sys.exit(f"Error {response.status_code} from {url}")
    return geojson.loads(json.dumps(response.json()["data"]))["features"]


def write_inserts(features, fence_type, output_file, area_from_parent):
    with open(output_file, "w", encoding="utf-8") as out:
        for feature in features:
            properties = feature["properties"]
            name = properties["name"]
            area = properties["parent"] if area_from_parent else name
            geometry = feature["geometry"]
            if geometry["type"] != "Polygon":
                print(f"skipping {name}: Blissey does not support {geometry['type']}")
                continue
            coords = ",".join(map(transform, geometry["coordinates"][0]))
            out.write(
                f"INSERT INTO geofences (`area`, `fence`, `type`, `coords`) VALUES "
                f"('{area}', '{name}', '{fence_type}', '{coords}') "
                f"ON DUPLICATE KEY UPDATE `coords` = '{coords}';\n"
            )


def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "config.toml")
    config = read_config(config_path)
    mon = feature_collection(config, config.get("mon_project", "golbat"))
    quest = feature_collection(config, config.get("quest_project", "dragonite"))
    write_inserts(mon, "mon", os.path.join(HERE, "mon_geofences.sql"), area_from_parent=True)
    write_inserts(quest, "quest", os.path.join(HERE, "quest_geofences.sql"), area_from_parent=False)
    print("SQL statements written to mon_geofences.sql and quest_geofences.sql")


if __name__ == "__main__":
    main()
