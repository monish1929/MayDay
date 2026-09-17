#!/usr/bin/env python3
"""
Generate real .mbtiles for Wayanad district, Kerala.

This script complies with the OpenStreetMap Foundation Tile Usage Policy
by generating tiles locally from a Geofabrik data extract instead of
scraping OSM tile servers.

Prerequisites:
  - tilemaker (https://github.com/systemed/tilemaker)
  - wget or curl

Steps performed:
1. Downloads the latest Kerala OSM PBF extract from Geofabrik.
2. Runs tilemaker to generate vector/raster tiles bounded to Wayanad.

Wayanad bounding box (approximate):
  SW: 11.55, 75.70
  NE: 11.95, 76.35
"""

import os
import subprocess
import sys

GEOFABRIK_URL = "https://download.geofabrik.de/asia/india/kerala-latest.osm.pbf"
PBF_FILE = "kerala-latest.osm.pbf"
OUTPUT_MBTILES = "wayanad.mbtiles"

# Wayanad bounding box
BBOX = "75.70,11.55,76.35,11.95"

def main():
    print("=== MayDay Tile Generator (Geofabrik + Tilemaker) ===")
    
    # 1. Download PBF
    if not os.path.exists(PBF_FILE):
        print(f"Downloading Kerala extract from {GEOFABRIK_URL}...")
        subprocess.run(["curl", "-O", GEOFABRIK_URL], check=True)
    else:
        print(f"Found existing extract: {PBF_FILE}")
        
    # 2. Check for tilemaker
    try:
        subprocess.run(["tilemaker", "--version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: 'tilemaker' is not installed or not in PATH.")
        print("Please install tilemaker from https://github.com/systemed/tilemaker")
        sys.exit(1)
        
    # 3. Generate MBTiles
    print(f"Generating {OUTPUT_MBTILES} bounded to Wayanad ({BBOX})...")
    # Note: A real tilemaker run would use a config.json and process.lua
    # to filter and style the layers. This command assumes default styling.
    try:
        subprocess.run([
            "tilemaker",
            "--input", PBF_FILE,
            "--output", OUTPUT_MBTILES,
            "--bbox", BBOX
        ], check=True)
        print(f"Successfully generated {OUTPUT_MBTILES}")
    except subprocess.CalledProcessError as e:
        print(f"Tile generation failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
