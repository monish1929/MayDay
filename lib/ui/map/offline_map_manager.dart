import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Manages offline map tiles for MayDay — PERSON_C.md §3 Day 2.
///
/// Serves raster tiles directly from the bundled SQLite .mbtiles database
/// via a lightweight, localhost-only HttpServer.
///
/// Invariants:
/// - Bound strictly to localhost (127.0.0.1) on a dynamic port (port 0).
///   Never binds to 0.0.0.0 — this app has no external network paths.
///   CLAUDE.md §1.
/// - MBTiles uses TMS tiling (y-axis inverted from XYZ standard):
///   tmsY = (2^z - 1 - y).
/// - Returns HTTP 200 with PNG bytes on match, HTTP 404 with log message on miss.
/// - Extends [ChangeNotifier] to report running tile loading counts to the UI.
class OfflineMapManager extends ChangeNotifier {
  static const String _mbtilesAssetPath = 'assets/tiles/placeholder.mbtiles';
  static const String _mbtilesFileName = 'placeholder.mbtiles';
  static final RegExp _tilePathRegex = RegExp(r'^/(\d+)/(\d+)/(\d+)\.png$');

  bool _isReady = false;
  String? _tilesPath;
  HttpServer? _server;
  Database? _db;
  PreparedStatement? _tileStatement;
  int? _serverPort;

  // ─── Tile request counters (debug/status aid) ───────────────────
  int _loadedTileCount = 0;
  int _failedTileCount = 0;

  bool get isReady => _isReady && _server != null;
  String? get tilesPath => _tilesPath;
  int? get serverPort => _serverPort;
  int get loadedTileCount => _loadedTileCount;
  int get failedTileCount => _failedTileCount;

  /// Copy bundled .mbtiles from assets to the documents directory, open the
  /// SQLite database, and launch the localhost HTTP tile server.
  Future<void> initialize() async {
    if (_isReady && _server != null) return;

    final appDir = await getApplicationDocumentsDirectory();
    final tilesDir = Directory('${appDir.path}/tiles');
    if (!tilesDir.existsSync()) {
      tilesDir.createSync(recursive: true);
    }

    final destFile = File('${tilesDir.path}/$_mbtilesFileName');

    // Copy from assets on first launch or if file doesn't exist.
    if (!destFile.existsSync()) {
      final data = await rootBundle.load(_mbtilesAssetPath);
      await destFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }

    _tilesPath = destFile.path;

    // Open SQLite database and prepare tile lookup query.
    _db = sqlite3.open(_tilesPath!);
    _tileStatement = _db!.prepare(
      'SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1',
    );

    // Bind strictly to loopback (127.0.0.1) on dynamic port 0.
    // Loopback only — not reachable from external interfaces.
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _serverPort = _server!.port;
    debugPrint('[OfflineMapManager] Tile server listening on http://127.0.0.1:$_serverPort');

    _server!.listen(_handleRequest);
    _isReady = true;
    notifyListeners();
  }

  /// Handle incoming /{z}/{x}/{y}.png tile requests.
  void _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final match = _tilePathRegex.firstMatch(path);

    if (match == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not found: $path');
      await request.response.close();
      _failedTileCount++;
      notifyListeners();
      return;
    }

    final z = int.parse(match.group(1)!);
    final x = int.parse(match.group(2)!);
    final y = int.parse(match.group(3)!);

    // Convert XYZ y to TMS y (MBTiles standard: y is inverted)
    final tmsY = (1 << z) - 1 - y;

    try {
      final result = _tileStatement!.select([z, x, tmsY]);

      if (result.isNotEmpty) {
        final row = result.first;
        final tileData = row['tile_data'] as Uint8List;

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.headers.set('Cache-Control', 'max-age=3600');
        request.response.headers.contentLength = tileData.length;
        request.response.add(tileData);
        await request.response.close();

        _loadedTileCount++;
        notifyListeners();

        debugPrint('[OfflineMapManager] 200 OK: tile z=$z x=$x y=$y (TMS y=$tmsY, ${tileData.length} bytes)');
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('Tile not in database: z=$z x=$x y=$y');
        await request.response.close();

        _failedTileCount++;
        notifyListeners();

        debugPrint('[OfflineMapManager] 404 Not Found: tile z=$z x=$x y=$y (TMS y=$tmsY)');
      }
    } catch (e, st) {
      debugPrint('[OfflineMapManager] Error querying tile z=$z x=$x y=$y: $e\n$st');
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Internal server error');
      await request.response.close();

      _failedTileCount++;
      notifyListeners();
    }
  }

  /// Build a fully local MapLibre style JSON pointing to the localhost tile server.
  /// No remote URLs — tiles served from `http://127.0.0.1:<port>/{z}/{x}/{y}.png` only.
  String buildLocalStyleJson() {
    if (_serverPort == null) {
      return _backgroundOnlyStyle();
    }

    final tileUrl = 'http://127.0.0.1:$_serverPort/{z}/{x}/{y}.png';

    return '''
{
  "version": 8,
  "name": "MayDay Offline",
  "sources": {
    "offline-tiles": {
      "type": "raster",
      "tiles": ["$tileUrl"],
      "tileSize": 256,
      "minzoom": 8,
      "maxzoom": 14
    }
  },
  "layers": [
    {
      "id": "background",
      "type": "background",
      "paint": {
        "background-color": "#F4F0E8"
      }
    },
    {
      "id": "offline-raster",
      "type": "raster",
      "source": "offline-tiles",
      "minzoom": 8,
      "maxzoom": 14
    }
  ]
}
''';
  }

  /// Minimal style with just a background — no tile source.
  String _backgroundOnlyStyle() {
    return '''
{
  "version": 8,
  "name": "MayDay Offline (no tiles)",
  "sources": {},
  "layers": [
    {
      "id": "background",
      "type": "background",
      "paint": {
        "background-color": "#F4F0E8"
      }
    }
  ]
}
''';
  }

  /// Stop the local tile server and close the SQLite database.
  @override
  Future<void> dispose() async {
    _tileStatement?.dispose();
    _tileStatement = null;
    _db?.dispose();
    _db = null;
    await _server?.close(force: true);
    _server = null;
    _serverPort = null;
    _isReady = false;
    debugPrint('[OfflineMapManager] Tile server stopped');
    super.dispose();
  }
}
