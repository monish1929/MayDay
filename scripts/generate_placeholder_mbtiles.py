"""
Generate a minimal valid .mbtiles placeholder for MayDay.

MBTiles is a SQLite database containing map tiles.
This script creates a minimal one with a few blank/colored tiles
covering a small area around Bengaluru (matching mock data coordinates).

Usage: python scripts/generate_placeholder_mbtiles.py
Output: assets/tiles/placeholder.mbtiles
"""

import sqlite3
import io
import struct
import zlib
import os
import math

def lat_lon_to_tile(lat, lon, zoom):
    """Convert lat/lon to tile x,y at given zoom level."""
    n = 2 ** zoom
    x = int((lon + 180.0) / 360.0 * n)
    lat_rad = math.radians(lat)
    y = int((1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) / 2.0 * n)
    return x, y

def create_blank_png(r, g, b, alpha=255):
    """Create a minimal 256x256 single-color PNG tile."""
    width = 256
    height = 256

    def make_png():
        # PNG signature
        signature = b'\x89PNG\r\n\x1a\n'

        # IHDR chunk
        ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)  # 8-bit RGB
        ihdr_crc = zlib.crc32(b'IHDR' + ihdr_data) & 0xffffffff
        ihdr = struct.pack('>I', 13) + b'IHDR' + ihdr_data + struct.pack('>I', ihdr_crc)

        # IDAT chunk - image data
        raw_data = b''
        row = bytes([r, g, b] * width)
        for _ in range(height):
            raw_data += b'\x00' + row  # filter byte 0 (None) + row data

        compressed = zlib.compress(raw_data)
        idat_crc = zlib.crc32(b'IDAT' + compressed) & 0xffffffff
        idat = struct.pack('>I', len(compressed)) + b'IDAT' + compressed + struct.pack('>I', idat_crc)

        # IEND chunk
        iend_crc = zlib.crc32(b'IEND') & 0xffffffff
        iend = struct.pack('>I', 0) + b'IEND' + struct.pack('>I', iend_crc)

        return signature + ihdr + idat + iend

    return make_png()

def main():
    output_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'assets', 'tiles')
    os.makedirs(output_dir, exist_ok=True)
    output_path = os.path.join(output_dir, 'placeholder.mbtiles')

    # Remove existing file
    if os.path.exists(output_path):
        os.remove(output_path)

    conn = sqlite3.connect(output_path)
    c = conn.cursor()

    # Create MBTiles schema (spec: https://github.com/mapbox/mbtiles-spec)
    c.execute('''CREATE TABLE metadata (name TEXT, value TEXT)''')
    c.execute('''CREATE TABLE tiles (
        zoom_level INTEGER,
        tile_column INTEGER,
        tile_row INTEGER,
        tile_data BLOB
    )''')
    c.execute('''CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)''')

    # Metadata — centered on Bengaluru area (matches mock data ~12.97°N, 77.59°E)
    center_lat = 12.9716
    center_lon = 77.5946
    metadata = {
        'name': 'MayDay Placeholder',
        'format': 'png',
        'bounds': f'{center_lon - 0.05},{center_lat - 0.05},{center_lon + 0.05},{center_lat + 0.05}',
        'center': f'{center_lon},{center_lat},12',
        'minzoom': '8',
        'maxzoom': '14',
        'type': 'baselayer',
        'description': 'Placeholder tiles for MayDay offline map. Replace with real district tiles at campaign time.',
        'version': '1',
    }

    for k, v in metadata.items():
        c.execute('INSERT INTO metadata VALUES (?, ?)', (k, v))

    # Generate tiles at multiple zoom levels
    # Light cream/neutral themed tiles to match MayDay light palette
    land_tile = create_blank_png(238, 234, 224)    # #EEEAE0 — warm light cream (land)
    water_tile = create_blank_png(220, 230, 238)   # #DCE6EE — soft muted light blue-gray (edges/water)

    tiles_added = 0
    for zoom in range(8, 15):
        cx, cy = lat_lon_to_tile(center_lat, center_lon, zoom)

        # Add tiles in a small radius around center
        radius = min(2 ** (zoom - 8), 8)  # grows with zoom but stays bounded
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                tx = cx + dx
                ty = cy + dy

                # MBTiles uses TMS tiling (y-axis flipped from standard)
                tms_y = (2 ** zoom - 1) - ty

                # Center tiles are "land", edges are "water"
                is_center = abs(dx) <= radius // 2 and abs(dy) <= radius // 2
                tile_data = land_tile if is_center else water_tile

                c.execute(
                    'INSERT OR REPLACE INTO tiles VALUES (?, ?, ?, ?)',
                    (zoom, tx, tms_y, tile_data)
                )
                tiles_added += 1

    conn.commit()
    conn.close()

    size_kb = os.path.getsize(output_path) / 1024
    print(f'Created {output_path}')
    print(f'  Center: {center_lat}, {center_lon} (Bengaluru area)')
    print(f'  Zoom levels: 8-14')
    print(f'  Tiles: {tiles_added}')
    print(f'  Size: {size_kb:.1f} KB')

if __name__ == '__main__':
    main()
