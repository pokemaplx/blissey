#!/usr/bin/env python3
"""Print a TOML file as bash assignments so lib/config.sh can `eval` it.

Tables are flattened with "_" ([database] host -> database_host, [retention] stats.rpl5 ->
retention_stats_rpl5), booleans become the strings true/false, arrays become bash arrays.
Needs Python >= 3.11 (tomllib) or the tomli package on older versions.
"""
import re
import shlex
import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        sys.exit("toml2sh: Python >= 3.11 or the 'tomli' module is required (apt install python3-tomli)")

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def emit(prefix, value, out):
    if isinstance(value, dict):
        for key, item in value.items():
            if not NAME.fullmatch(key):
                sys.exit(f"toml2sh: key '{key}' cannot be used as a shell variable name")
            emit(f"{prefix}_{key}" if prefix else key, item, out)
    elif isinstance(value, list):
        if any(isinstance(item, (dict, list)) for item in value):
            sys.exit(f"toml2sh: '{prefix}' must be an array of plain values")
        out.append(f"{prefix}=({' '.join(shlex.quote(scalar(item)) for item in value)})")
    else:
        out.append(f"{prefix}={shlex.quote(scalar(value))}")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: toml2sh.py <file.toml>")
    try:
        with open(sys.argv[1], "rb") as handle:
            data = tomllib.load(handle)
    except tomllib.TOMLDecodeError as error:
        sys.exit(f"toml2sh: {sys.argv[1]}: {error}")
    lines = []
    emit("", data, lines)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
