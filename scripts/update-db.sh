#!/usr/bin/env bash
# Refreshes the bundled AmiiboAPI snapshot (MIT, https://github.com/N3evin/AmiiboAPI).
set -euo pipefail
cd "$(dirname "$0")/../App/Resources"
base=https://raw.githubusercontent.com/N3evin/AmiiboAPI/master/database
curl -fsSL "$base/amiibo.json" -o amiibo.json
curl -fsSL "$base/games_info.json" -o games_info.json
python3 -I -c 'import json,sys; [json.load(open(f)) for f in sys.argv[1:]]' amiibo.json games_info.json
echo "updated $(pwd)"
