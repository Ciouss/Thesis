import 'dart:ui' as ui;
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class WebsiteMapPage extends StatefulWidget {
  const WebsiteMapPage({super.key});

  @override
  State<WebsiteMapPage> createState() => _WebsiteMapPageState();
}

class _WebsiteMapPageState extends State<WebsiteMapPage>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final SupabaseClient _supabase = Supabase.instance.client;

  AnimationController? _fitAnimController;

  List<Map<String, dynamic>> _allPins = [];
  bool _loading = true;
  String? _error;

  LatLng _center = const LatLng(8.0, 125.0);

  final Set<String> _speciesFilter = {};
  String _statusFilter = 'All';
  DateTime? _lastUpdated;
  DateTime? _dateFrom;
  DateTime? _dateTo;
  String? _selectedSpecies;

  static const int _pageSize = 10;
  int _currentPage = 0;

  Map<String, dynamic>? _selectedPin;
  bool _sidebarVisible = true;
  bool _drawerOpen = false;

  // ── Map style switcher ────────────────────────────────────────────────────
  String _mapStyle = 'satellite';

  static const _mapStyles = {
    'satellite': _MapStyleOption(
      label: 'Satellite',
      icon: Icons.satellite_alt_rounded,
      url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    ),
    'terrain': _MapStyleOption(
      label: 'Terrain',
      icon: Icons.terrain_rounded,
      url: 'https://tiles.stadiamaps.com/tiles/stamen_terrain/{z}/{x}/{y}.png',
    ),
    'clean': _MapStyleOption(
      label: 'Clean',
      icon: Icons.map_rounded,
      url: 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
    ),
  };

  double _currentZoom = 13.0;

  bool _showHeatmap = false;
  bool _showHint = true;

  @override
  void initState() {
    super.initState();
    _loadPins();
    _mapController.mapEventStream.listen((event) {
      if (mounted) {
        setState(() => _currentZoom = _mapController.camera.zoom);
      }
    });
    // Auto-hide the hint after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showHint = false);
    });
  }

  @override
  void dispose() {
    _fitAnimController?.dispose();
    super.dispose();
  }

  Future<void> _loadPins() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final data = await _supabase
          .from('observations')
          .select()
          .order('created_at', ascending: false);

      final pins = List<Map<String, dynamic>>.from(data);

      if (pins.isNotEmpty) {
        final first = pins.first;
        _center = LatLng(
          (first['lat'] as num).toDouble(),
          (first['lng'] as num).toDouble(),
        );
      }

      if (!mounted) return;
      setState(() {
        _allPins = pins;
        _loading = false;
        _lastUpdated = DateTime.now();
      });

      if (_allPins.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _mapController.move(_center, 13);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load: $e';
        _loading = false;
      });
    }
  }

  String _observationTitle(Map<String, dynamic> o) {
    final processed = o['processed'] == true;
    final detected = o['detected'] == true;
    final species = o['species']?.toString();
    if (!processed) return 'Awaiting processing';
    if (detected && species != null && species.isNotEmpty) return species;
    if (!detected) return 'Not a pitcher plant';
    return 'Pitcher plant detected';
  }

  List<String> get _speciesOptions {
    final species = _allPins
        .map((e) => e['species']?.toString())
        .where((e) => e != null && e.isNotEmpty)
        .cast<String>()
        .toSet()
        .toList()
      ..sort();
    return ['All', ...species];
  }

  List<Map<String, dynamic>> get _filteredPins {
    return _allPins.where((o) {
      final detected = o['detected'] == true;
      final species = o['species']?.toString() ?? '';
      final speciesMatch =
          _speciesFilter.isEmpty || _speciesFilter.contains(species);
      final statusMatch = switch (_statusFilter) {
        'Detected' => detected,
        'Not detected' => !detected,
        _ => true,
      };
      // Date range filter
      bool dateMatch = true;
      if (_dateFrom != null || _dateTo != null) {
        final raw = o['created_at']?.toString();
        if (raw != null) {
          final dt = DateTime.tryParse(raw)?.toLocal();
          if (dt != null) {
            if (_dateFrom != null && dt.isBefore(_dateFrom!)) dateMatch = false;
            if (_dateTo != null && dt.isAfter(_dateTo!.add(const Duration(days: 1)))) dateMatch = false;
          } else {
            dateMatch = false;
          }
        } else {
          dateMatch = false;
        }
      }
      return speciesMatch && statusMatch && dateMatch;
    }).toList();
  }

  static const _speciesColors = <String, Color>{
    'N. alfredoi':        Color(0xFF6E8E59),
    'N. hamiguitanensis': Color(0xFF4A7A8A),
    'N. justinae':        Color(0xFF8E6E59),
    'N. micramphora':     Color(0xFF7A5A8E),
    'N. peltata':         Color(0xFF8E7A40),
  };

  Color _pinColor(Map<String, dynamic> o) {
    final detected = o['detected'] == true;
    final processed = o['processed'] == true;
    if (!processed) return Colors.grey.shade400;
    if (!detected) return const Color(0xFFB86B6B);
    final species = o['species']?.toString() ?? '';
    return _speciesColors[species] ?? const Color(0xFF6E8E59);
  }

  void _selectPin(Map<String, dynamic> o) {
    final lat = (o['lat'] as num?)?.toDouble();
    final lng = (o['lng'] as num?)?.toDouble();
    if (lat != null && lng != null) {
      final startCenter = _mapController.camera.center;
      final startZoom = _mapController.camera.zoom;
      final targetCenter = LatLng(lat, lng);
      const targetZoom = 16.0;

      _fitAnimController?.dispose();
      _fitAnimController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      );
      final latTween = Tween<double>(
          begin: startCenter.latitude, end: targetCenter.latitude);
      final lngTween = Tween<double>(
          begin: startCenter.longitude, end: targetCenter.longitude);
      final zoomTween = Tween<double>(begin: startZoom, end: targetZoom);
      final curve = CurvedAnimation(
          parent: _fitAnimController!, curve: Curves.easeInOutCubic);

      _fitAnimController!.addListener(() {
        _mapController.move(
          LatLng(latTween.evaluate(curve), lngTween.evaluate(curve)),
          zoomTween.evaluate(curve),
        );
      });
      _fitAnimController!.forward();
    }

    // Jump to the correct page
    final filtered = _filteredPins;
    final index = filtered.indexWhere((p) => p['id'] == o['id']);
    if (index != -1) {
      final targetPage = (index / _pageSize).floor();
      _currentPage = targetPage;
    }

    setState(() => _selectedPin = o);
  }

  void _clearPin() => setState(() => _selectedPin = null);

  void _fitAllPins() {
    final pins = _filteredPins;
    if (pins.isEmpty) return;

    double minLat = (pins.first['lat'] as num).toDouble();
    double maxLat = minLat;
    double minLng = (pins.first['lng'] as num).toDouble();
    double maxLng = minLng;

    for (final p in pins) {
      final lat = (p['lat'] as num).toDouble();
      final lng = (p['lng'] as num).toDouble();
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    }

    // Compute target center + zoom from bounds
    final targetLat = (minLat + maxLat) / 2;
    final targetLng = (minLng + maxLng) / 2;
    final targetCenter = LatLng(targetLat, targetLng);

    // Use CameraFit.bounds to calculate the correct zoom
    final bounds = LatLngBounds(
      LatLng(minLat, minLng),
      LatLng(maxLat, maxLng),
    );
    final cameraFit = CameraFit.bounds(
      bounds: bounds,
      padding: const EdgeInsets.all(48),
    );
    final fitted = cameraFit.fit(_mapController.camera);
    final targetZoom = fitted.zoom;

    // Animate from current camera to target
    final startCenter = _mapController.camera.center;
    final startZoom = _mapController.camera.zoom;

    _fitAnimController?.dispose();
    _fitAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    final latTween =
        Tween<double>(begin: startCenter.latitude, end: targetCenter.latitude);
    final lngTween = Tween<double>(
        begin: startCenter.longitude, end: targetCenter.longitude);
    final zoomTween = Tween<double>(begin: startZoom, end: targetZoom);
    final curve =
        CurvedAnimation(parent: _fitAnimController!, curve: Curves.easeInOutCubic);

    _fitAnimController!.addListener(() {
      _mapController.move(
        LatLng(latTween.evaluate(curve), lngTween.evaluate(curve)),
        zoomTween.evaluate(curve),
      );
    });

    _fitAnimController!.forward();
  }

  void _zoomToSpecies(String? species) {
    final pins = (species == null)
        ? _allPins
        : _allPins
            .where((o) => o['species']?.toString() == species)
            .toList();
    if (pins.isEmpty) return;

    double minLat = (pins.first['lat'] as num).toDouble();
    double maxLat = minLat;
    double minLng = (pins.first['lng'] as num).toDouble();
    double maxLng = minLng;

    for (final p in pins) {
      final lat = (p['lat'] as num).toDouble();
      final lng = (p['lng'] as num).toDouble();
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    }

    final targetLat = (minLat + maxLat) / 2;
    final targetLng = (minLng + maxLng) / 2;

    // Guard against zero-size bounds (all pins at same point)
    final double zoom;
    if ((maxLat - minLat).abs() < 0.0001 && (maxLng - minLng).abs() < 0.0001) {
      zoom = 16.0;
    } else {
      final bounds = LatLngBounds(
          LatLng(minLat, minLng), LatLng(maxLat, maxLng));
      zoom = CameraFit.bounds(
              bounds: bounds, padding: const EdgeInsets.all(80))
          .fit(_mapController.camera)
          .zoom;
    }

    final startCenter = _mapController.camera.center;
    final startZoom = _mapController.camera.zoom;

    _fitAnimController?.dispose();
    _fitAnimController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600));
    final curve = CurvedAnimation(
        parent: _fitAnimController!, curve: Curves.easeInOutCubic);
    final latTween = Tween<double>(
        begin: startCenter.latitude, end: targetLat);
    final lngTween = Tween<double>(
        begin: startCenter.longitude, end: targetLng);
    final zoomTween =
        Tween<double>(begin: startZoom, end: zoom);

    _fitAnimController!.addListener(() {
      _mapController.move(
        LatLng(latTween.evaluate(curve), lngTween.evaluate(curve)),
        zoomTween.evaluate(curve),
      );
    });
    _fitAnimController!.forward();
  }

  void _exportCsv() {
    final filtered = _filteredPins;
    if (filtered.isEmpty) return;

    final buf = StringBuffer();
    buf.writeln('id,species,detected,processed,lat,lng,confidence,created_at');
    for (final o in filtered) {
      final sp = (o['species'] ?? '').toString().replaceAll(',', ' ');
      final conf = o['species_conf'] != null
          ? ((o['species_conf'] as num) * 100).toStringAsFixed(1)
          : '';
      buf.writeln('${o['id'] ?? ''},$sp,${o['detected'] == true},'
          '${o['processed'] == true},${o['lat'] ?? ''},'
          '${o['lng'] ?? ''},$conf,${o['created_at'] ?? ''}');
    }

    final blob = html.Blob([buf.toString()], 'text/csv');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', 'picchure_sightings.csv')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  String _formatDate(String? createdAt) {
    if (createdAt == null) return '—';
    try {
      final dt = DateTime.parse(createdAt).toLocal();
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}  '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return createdAt;
    }
  }

  Widget _buildDetailPanel(Map<String, dynamic> o) {
    final detected = o['detected'] == true;
    final processed = o['processed'] == true;
    final species = o['species']?.toString();
    final conf = (o['species_conf'] as num?)?.toDouble();
    final lat = (o['lat'] as num?)?.toDouble();
    final lng = (o['lng'] as num?)?.toDouble();
    final acc = (o['accuracy'] as num?)?.toDouble();
    final imageUrl = o['image_url']?.toString();

    // Status pill colors — consistent with logbook
    final Color pillBg = !processed
        ? const Color(0xFFF4F0EC)
        : detected
            ? const Color(0xFFEEF4EA)
            : const Color(0xFFF8EFEF);
    final Color pillText = !processed
        ? const Color(0xFF9A8880)
        : detected
            ? const Color(0xFF4A7A30)
            : const Color(0xFFA04040);
    final String statusLabel = !processed
        ? 'Pending'
        : detected
            ? 'Detected'
            : 'Not detected';

    // Species accent color
    final Color accentColor = detected && species != null
        ? (_speciesColors[species] ?? const Color(0xFF6E8E59))
        : detected
            ? const Color(0xFF6E8E59)
            : const Color(0xFFB86B6B);

    final obsIndex = _filteredPins.indexWhere((p) => p['id'] == o['id']);
    final obsTotal = _filteredPins.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        // ── Header ───────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: const BoxDecoration(
            color: Color(0xFFF5EEEF),
            border: Border(
                bottom: BorderSide(color: Color(0x18000000), width: 0.5)),
          ),
          child: Row(
            children: [
              // Species color left accent
              Container(
                width: 3,
                height: 28,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Expanded(
                child: Text(
                  obsIndex != -1
                      ? 'Sighting ${obsIndex + 1} of $obsTotal'
                      : 'Sighting detail',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4A2830)),
                ),
              ),
              // Prev
              if (obsIndex > 0) ...[
                GestureDetector(
                  onTap: () => _selectPin(_filteredPins[obsIndex - 1]),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFEDE4DC),
                      border: Border.all(
                          color: const Color(0xFF4A2830).withOpacity(0.15),
                          width: 0.5),
                    ),
                    child: const Icon(Icons.chevron_left_rounded,
                        size: 15, color: Color(0xFF4A2830)),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              // Next
              if (obsIndex != -1 && obsIndex < obsTotal - 1) ...[
                GestureDetector(
                  onTap: () => _selectPin(_filteredPins[obsIndex + 1]),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFEDE4DC),
                      border: Border.all(
                          color: const Color(0xFF4A2830).withOpacity(0.15),
                          width: 0.5),
                    ),
                    child: const Icon(Icons.chevron_right_rounded,
                        size: 15, color: Color(0xFF4A2830)),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              // Close
              GestureDetector(
                onTap: _clearPin,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFEDE4DC),
                    border: Border.all(
                        color: const Color(0xFF4A2830).withOpacity(0.15),
                        width: 0.5),
                  ),
                  child: const Icon(Icons.close_rounded,
                      size: 13, color: Color(0xFF4A2830)),
                ),
              ),
            ],
          ),
        ),

        // ── Photo ─────────────────────────────────────────────────
        Stack(
          children: [
            ClipRect(
              child: SizedBox(
                height: 200,
                width: double.infinity,
                child: imageUrl != null && imageUrl.isNotEmpty
                    ? Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _photoPlaceholder(),
                      )
                    : _photoPlaceholder(),
              ),
            ),
            if (detected && species != null && species.isNotEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 24, 14, 12),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: Text(
                    species,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      fontStyle: FontStyle.italic,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
          ],
        ),

        // ── Title + status pill ───────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Text(
            _observationTitle(o),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.black,
              fontStyle: _observationTitle(o).startsWith('N. ')
                  ? FontStyle.italic
                  : FontStyle.normal,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: pillBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(statusLabel,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: pillText)),
              ),
              if (conf != null) ...[
                const SizedBox(width: 8),
                Text('${(conf * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: accentColor)),
              ],
            ],
          ),
        ),

        // ── Confidence bar ────────────────────────────────────────
        if (conf != null && detected) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('confidence',
                    style: TextStyle(
                        fontSize: 9.5,
                        color: Colors.grey.shade400,
                        letterSpacing: 0.3)),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 5,
                    child: Row(
                      children: [
                        Flexible(
                          flex: (conf * 100).round(),
                          child: Container(color: accentColor),
                        ),
                        Flexible(
                          flex: 100 - (conf * 100).round(),
                          child: Container(color: const Color(0xFFEDE6DA)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 14),

        // ── Detail rows ───────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(
            children: [
              _DetailRow(
                icon: Icons.pest_control_rounded,
                label: 'Species',
                value: (detected && species != null && species.isNotEmpty)
                    ? species
                    : '—',
              ),
              _DetailRow(
                icon: Icons.location_on_outlined,
                label: 'Coordinates',
                value: (lat != null && lng != null)
                    ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
                    : '—',
                onCopy: (lat != null && lng != null)
                    ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
                    : null,
              ),
              if (acc != null)
                _DetailRow(
                  icon: Icons.my_location_rounded,
                  label: 'GPS accuracy',
                  value: '±${acc.toStringAsFixed(0)} m',
                ),
              _DetailRow(
                icon: Icons.access_time_rounded,
                label: 'Date & time',
                value: _formatDate(o['created_at']?.toString()),
                isLast: acc == null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _photoPlaceholder() {
    return Container(
      color: Colors.white,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_not_supported_outlined,
              size: 28, color: Colors.grey.shade300),
          const SizedBox(height: 6),
          Text('No photo',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
        ],
      ),
    );
  }

  int get _totalPins => _allPins.length;
  int get _totalDetected => _allPins.where((e) => e['detected'] == true).length;
  int get _totalNotDetected => _allPins.where((e) => e['detected'] != true && e['processed'] == true).length;
  int get _totalPages => (_filteredPins.length / _pageSize).ceil().clamp(1, 99999);
  int get _safePage => _currentPage.clamp(0, _totalPages - 1);

  Widget _buildSidebarBody() {
    final filteredPins = _filteredPins;
    final totalPins = _totalPins;
    final totalDetected = _totalDetected;
    final totalNotDetected = _totalNotDetected;
    final totalPages = _totalPages;
    final safePage = _safePage;
    final pageStart = safePage * _pageSize;
    final pageEnd = (pageStart + _pageSize).clamp(0, filteredPins.length);
    final pagedPins = filteredPins.sublist(pageStart, pageEnd);

    // Species counts
    final speciesCounts = <String, int>{};
    for (final o in _allPins) {
      final sp = o['species']?.toString();
      if (sp != null && sp.isNotEmpty && o['detected'] == true) {
        speciesCounts[sp] = (speciesCounts[sp] ?? 0) + 1;
      }
    }
    final sortedSpecies = speciesCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxSpeciesVal = sortedSpecies.isEmpty ? 1 : sortedSpecies.first.value;

    const Color fallbackColor = Color(0xFF888078);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Stats ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total sightings',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade400,
                            fontWeight: FontWeight.w400,
                            letterSpacing: 0.2)),
                    const SizedBox(height: 3),
                    Text('$totalPins',
                        style: const TextStyle(
                            fontSize: 42,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF140208),
                            height: 1,
                            letterSpacing: -1)),
                  ],
                ),
                Container(
                    height: 40,
                    width: 0.5,
                    color: const Color(0x14000000),
                    margin: const EdgeInsets.only(left: 22, right: 18, bottom: 4)),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Species identified',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade400,
                            letterSpacing: 0.2)),
                    const SizedBox(height: 2),
                    Text('${speciesCounts.length}',
                        style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF4A2830),
                            height: 1,
                            letterSpacing: -0.5)),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 0.5, thickness: 0.5, color: Color(0x0A000000)),

          // ── Species breakdown ─────────────────────────────────────
          if (sortedSpecies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Species breakdown',
                      style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade400,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.3)),
                  const SizedBox(height: 16),
                  ...sortedSpecies.map((e) {
                    final isActive = _speciesFilter.contains(e.key);
                    final barFraction = e.value / maxSpeciesVal;
                    final speciesColor = _speciesColors[e.key] ?? fallbackColor;
                    return GestureDetector(
                      onTap: () {
                        final wasActive = _speciesFilter.length == 1 &&
                            _speciesFilter.contains(e.key);
                        setState(() {
                          _speciesFilter.clear();
                          if (!wasActive) _speciesFilter.add(e.key);
                          _statusFilter = 'All';
                          _currentPage = 0;
                          _selectedSpecies = wasActive ? null : e.key;
                        });
                        if (wasActive) {
                          _fitAllPins();
                        } else {
                          _zoomToSpecies(e.key);
                        }
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        decoration: BoxDecoration(
                          color: isActive
                              ? Color.lerp(speciesColor, Colors.white, 0.90)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          color: speciesColor,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      const SizedBox(width: 7),
                                      Text(e.key,
                                          style: TextStyle(
                                              fontSize: 11.5,
                                              fontStyle: FontStyle.italic,
                                              color: isActive
                                                  ? speciesColor
                                                  : const Color(0xFF220810),
                                              fontWeight: isActive
                                                  ? FontWeight.w600
                                                  : FontWeight.w400)),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Stack(children: [
                                    Container(
                                        height: 3,
                                        decoration: BoxDecoration(
                                            color: const Color(0xFFF0EBE4),
                                            borderRadius: BorderRadius.circular(2))),
                                    FractionallySizedBox(
                                      widthFactor: barFraction,
                                      child: Container(
                                          height: 3,
                                          decoration: BoxDecoration(
                                              color: isActive
                                                  ? speciesColor
                                                  : speciesColor.withOpacity(0.55),
                                              borderRadius: BorderRadius.circular(2))),
                                    ),
                                  ]),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text('${e.value}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: isActive
                                        ? speciesColor
                                        : Colors.grey.shade400,
                                    fontWeight: isActive
                                        ? FontWeight.w600
                                        : FontWeight.w400)),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),

          const Divider(height: 0.5, thickness: 0.5, color: Color(0x0A000000)),

          // ── Date range ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Date range',
                    style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade400,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _DatePickerField(
                        label: 'From',
                        value: _dateFrom,
                        onPicked: (d) => setState(() {
                          _dateFrom = d;
                          _currentPage = 0;
                        }),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text('—',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade300)),
                    ),
                    Expanded(
                      child: _DatePickerField(
                        label: 'To',
                        value: _dateTo,
                        onPicked: (d) => setState(() {
                          _dateTo = d;
                          _currentPage = 0;
                        }),
                      ),
                    ),
                  ],
                ),
                if (_dateFrom != null || _dateTo != null) ...[
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEEF4EA),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          '${_filteredPins.length} in range',
                          style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF4A7A30)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setState(() {
                          _dateFrom = null;
                          _dateTo = null;
                          _currentPage = 0;
                        }),
                        child: Text('Clear',
                            style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade400,
                                decoration: TextDecoration.underline)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          const Divider(height: 0.5, thickness: 0.5, color: Color(0x0A000000)),

          // ── Filter ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Filter',
                    style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade400,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _FilterPill(
                        label: 'All',
                        isActive: _speciesFilter.isEmpty && _statusFilter == 'All',
                        onTap: () {
                          setState(() {
                            _speciesFilter.clear();
                            _statusFilter = 'All';
                            _currentPage = 0;
                          });
                          _fitAllPins();
                        }),
                    ..._speciesOptions
                        .where((s) => s != 'All')
                        .map((s) => _FilterPill(
                              label: s,
                              isActive: _speciesFilter.contains(s),
                              onTap: () {
                                final wasActive = _speciesFilter.contains(s);
                                setState(() {
                                  if (wasActive) {
                                    _speciesFilter.remove(s);
                                  } else {
                                    _speciesFilter.add(s);
                                  }
                                  _statusFilter = 'All';
                                  _currentPage = 0;
                                });
                                if (wasActive) {
                                  if (_speciesFilter.isEmpty) _fitAllPins();
                                  else _fitAllPins();
                                } else {
                                  if (_speciesFilter.length == 1) {
                                    _zoomToSpecies(s);
                                  } else {
                                    _fitAllPins();
                                  }
                                }
                              },
                            )),
                    _FilterPill(
                        label: 'Not detected ($totalNotDetected)',
                        isActive: _statusFilter == 'Not detected',
                        onTap: () {
                          setState(() {
                            _statusFilter = _statusFilter == 'Not detected'
                                ? 'All'
                                : 'Not detected';
                            _speciesFilter.clear();
                            _currentPage = 0;
                          });
                          _fitAllPins();
                        }),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 0.5, thickness: 0.5, color: Color(0x0A000000)),

          // ── Sightings list ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 4),
            child: Row(
              children: [
                Text('Sightings',
                    style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade400,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3)),
                const Spacer(),
                if (filteredPins.length != totalPins)
                  Text('${filteredPins.length} of $totalPins',
                      style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade400)),
              ],
            ),
          ),

          if (filteredPins.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 22),
              child: Text('No sightings match',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade400,
                      fontStyle: FontStyle.italic)),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              itemCount: pagedPins.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (_, i) {
                final o = pagedPins[i];
                final obsId = o['id']?.toString() ?? '—';
                final detected = o['detected'] == true;
                final processed = o['processed'] == true;
                final species = o['species']?.toString();
                final isSelected = _selectedPin?['id'] == o['id'];
                final label = !processed
                    ? 'Awaiting processing'
                    : detected && species != null && species.isNotEmpty
                        ? species
                        : detected
                            ? 'Pitcher plant detected'
                            : 'Not a pitcher plant';
                final dotColor = !processed
                    ? Colors.grey.shade300
                    : detected
                        ? (_speciesColors[species ?? ''] ?? const Color(0xFF6E8E59))
                        : const Color(0xFFB86B6B);

                return GestureDetector(
                  onTap: () => setState(() {
                    _selectedPin = o;
                    _drawerOpen = false;
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFFF0E8EA)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: isSelected
                              ? const Color(0xFF4A2830)
                              : const Color(0xFFE8DCE0),
                          width: isSelected ? 1 : 0.5),
                    ),
                    child: Row(
                      children: [
                        // Observation ID
                        SizedBox(
                          width: 28,
                          child: Text(
                            '#$obsId',
                            style: TextStyle(
                                fontSize: 9,
                                color: Colors.grey.shade400,
                                fontWeight: FontWeight.w400),
                          ),
                        ),
                        Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                                color: dotColor,
                                shape: BoxShape.circle)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(label,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontStyle: detected &&
                                          species != null &&
                                          species.isNotEmpty
                                      ? FontStyle.italic
                                      : FontStyle.normal,
                                  color: Colors.black87,
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.w400),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

          // Pagination
          if (totalPages > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: safePage > 0
                        ? () => setState(() => _currentPage = safePage - 1)
                        : null,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: safePage > 0
                                  ? const Color(0xFF4A2830).withOpacity(0.25)
                                  : const Color(0x10000000),
                              width: 0.5)),
                      child: Icon(Icons.chevron_left_rounded,
                          size: 16,
                          color: safePage > 0
                              ? const Color(0xFF4A2830)
                              : Colors.grey.shade300),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('${safePage + 1} / $totalPages',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade400,
                          fontWeight: FontWeight.w400)),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: safePage < totalPages - 1
                        ? () => setState(() => _currentPage = safePage + 1)
                        : null,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: safePage < totalPages - 1
                                  ? const Color(0xFF4A2830).withOpacity(0.25)
                                  : const Color(0x10000000),
                              width: 0.5)),
                      child: Icon(Icons.chevron_right_rounded,
                          size: 16,
                          color: safePage < totalPages - 1
                              ? const Color(0xFF4A2830)
                              : Colors.grey.shade300),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredPins = _filteredPins;
    final safePage = _safePage;
    final pageStart = safePage * _pageSize;
    final pageEnd = (pageStart + _pageSize).clamp(0, filteredPins.length);
    final pagedPins = filteredPins.sublist(pageStart, pageEnd);
    final pagedPinIds = pagedPins.map((o) => o['id']).toSet();

    // ── Pin clustering ────────────────────────────────────────────────────────
    // Cluster radius shrinks as zoom increases — pins dissolve at zoom >= 16
    final clusterRadius = _currentZoom >= 16
        ? 0.0      // fully dissolved — show all individual pins
        : _currentZoom >= 14
            ? 0.01 // small clusters only for very close pins
            : _currentZoom >= 13
                ? 0.03
                : 0.06; // wide clusters at low zoom

    final clustered = <_PinCluster>[];
    final assigned = <int>{};

    for (int i = 0; i < filteredPins.length; i++) {
      if (assigned.contains(i)) continue;
      final o = filteredPins[i];
      final lat = (o['lat'] as num).toDouble();
      final lng = (o['lng'] as num).toDouble();
      final group = [o];
      assigned.add(i);

      for (int j = i + 1; j < filteredPins.length; j++) {
        if (assigned.contains(j)) continue;
        final o2 = filteredPins[j];
        final lat2 = (o2['lat'] as num).toDouble();
        final lng2 = (o2['lng'] as num).toDouble();
        if ((lat - lat2).abs() < clusterRadius &&
            (lng - lng2).abs() < clusterRadius) {
          group.add(o2);
          assigned.add(j);
        }
      }

      // centroid
      final cLat = group.map((e) => (e['lat'] as num).toDouble()).reduce((a, b) => a + b) / group.length;
      final cLng = group.map((e) => (e['lng'] as num).toDouble()).reduce((a, b) => a + b) / group.length;
      clustered.add(_PinCluster(pins: group, lat: cLat, lng: cLng));
    }

    final markers = clustered.map((cluster) {
      final isSingle = cluster.pins.length == 1;
      final o = cluster.pins.first;
      final color = isSingle
          ? _pinColor(o)
          : const Color(0xFF4A2830); // clusters always green

      if (isSingle) {
        final isSelected = _selectedPin?['id'] == o['id'];
        return Marker(
          point: LatLng(cluster.lat, cluster.lng),
          width: isSelected ? 36 : 26,
          height: isSelected ? 36 : 26,
          child: GestureDetector(
            onTap: () => _selectPin(o),
            child: Tooltip(
              message: _observationTitle(o),
              child: isSelected
                  ? Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.25),
                        border: Border.all(color: Colors.white, width: 2.5),
                      ),
                      child: Center(
                        child: CustomPaint(
                          size: const Size(22, 22),
                          painter: _CirclePinPainter(color: color),
                        ),
                      ),
                    )
                  : CustomPaint(
                      size: const Size(26, 26),
                      painter: _CirclePinPainter(color: color),
                    ),
            ),
          ),
        );
      }

      // Cluster bubble
      return Marker(
        point: LatLng(cluster.lat, cluster.lng),
        width: 42,
        height: 42,
        child: GestureDetector(
          onTap: () {
            // Zoom in to expand cluster
            _mapController.move(
              LatLng(cluster.lat, cluster.lng),
              _mapController.camera.zoom + 2,
            );
          },
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF4A2830),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Text(
                '${cluster.pins.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();

    return Title(
      title: _allPins.isEmpty
          ? 'Picchure — Sightings Map'
          : 'Picchure — ${_allPins.length} Sightings',
      color: Colors.black,
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 600;
          return _loading
          ? Stack(
              children: [
                // Grey map placeholder
                Container(color: const Color(0xFFE0DDD8)),
                // Floating skeleton sidebar
                Positioned(
                  top: 16, left: 16, bottom: 16, width: 320,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: 20,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header skeleton
                          Container(
                            height: 52,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            decoration: const BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                    color: Color(0x10000000), width: 0.5)),
                            ),
                            child: Row(
                              children: [
                                _SkeletonBox(width: 70, height: 14,
                                    radius: 6),
                                const SizedBox(width: 8),
                                _SkeletonBox(width: 50, height: 12,
                                    radius: 6),
                              ],
                            ),
                          ),
                          // Stats skeleton
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                            child: Row(
                              children: [
                                Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    _SkeletonBox(width: 60, height: 10,
                                        radius: 4),
                                    const SizedBox(height: 6),
                                    _SkeletonBox(width: 50, height: 32,
                                        radius: 6),
                                  ],
                                ),
                                const SizedBox(width: 20),
                                Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    _SkeletonBox(width: 50, height: 10,
                                        radius: 4),
                                    const SizedBox(height: 4),
                                    _SkeletonBox(width: 36, height: 20,
                                        radius: 4),
                                    const SizedBox(height: 8),
                                    _SkeletonBox(width: 70, height: 10,
                                        radius: 4),
                                    const SizedBox(height: 4),
                                    _SkeletonBox(width: 36, height: 20,
                                        radius: 4),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 0.5, thickness: 0.5,
                              color: Color(0x12000000)),
                          // Filter skeleton
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                            child: Row(
                              children: [
                                _SkeletonBox(width: 36, height: 28,
                                    radius: 20),
                                const SizedBox(width: 6),
                                _SkeletonBox(width: 70, height: 28,
                                    radius: 20),
                                const SizedBox(width: 6),
                                _SkeletonBox(width: 90, height: 28,
                                    radius: 20),
                              ],
                            ),
                          ),
                          const Divider(height: 0.5, thickness: 0.5,
                              color: Color(0x12000000)),
                          // List skeleton
                          Expanded(
                            child: ListView.separated(
                              padding: const EdgeInsets.all(12),
                              itemCount: 8,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (_, i) => Container(
                                height: 44,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: const Color(0x08000000),
                                      width: 0.5),
                                ),
                                child: Row(
                                  children: [
                                    _SkeletonBox(width: 8, height: 8,
                                        radius: 4),
                                    const SizedBox(width: 10),
                                    _SkeletonBox(
                                        width: 80 + (i % 3) * 20.0,
                                        height: 10, radius: 4),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            )
          : _error != null
              ? Container(
                  color: const Color(0xFFE8E8E8),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 40, color: Colors.grey.shade400),
                        const SizedBox(height: 10),
                        Text(_error!,
                            style: TextStyle(color: Colors.grey.shade500)),
                        const SizedBox(height: 14),
                        GestureDetector(
                          onTap: _loadPins,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text('Retry',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500)),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : Stack(
                  children: [
                    // ── Full-screen map ───────────────────────────────────
                    Positioned.fill(
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _center,
                          initialZoom: 13,
                          minZoom: 10,
                          maxZoom: 18,
                          onTap: (_, __) => _clearPin(),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                _mapStyles[_mapStyle]!.url,
                            userAgentPackageName: 'com.example.version1',
                          ),
                          if (_showHeatmap)
                            IgnorePointer(
                              child: CustomPaint(
                                painter: _HeatmapPainter(
                                  pins: _filteredPins,
                                  mapController: _mapController,
                                ),
                                size: Size.infinite,
                              ),
                            ),
                          if (!_showHeatmap)
                            MarkerLayer(markers: markers),
                        ],
                      ),
                      
                    ),
                    

                    // ── Floating left sidebar — desktop only ──────────────
                    if (!isMobile)
                    Positioned(
                      top: 16,
                      left: 16,
                      bottom: 16,
                      width: 320,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF4A2830).withOpacity(0.15),
                              blurRadius: 24,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // ── Sidebar header: brand + actions ──────────
                              Container(
                                padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFF5EEEF),
                                  border: Border(
                                    bottom: BorderSide(
                                        color: Color(0x18000000), width: 0.5),
                                  ),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Picchure',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF4A2830),
                                            letterSpacing: -0.3,
                                            fontFamily: 'LibreBaskerville',
                                          ),
                                        ),
                                        const Text(
                                          'Mt. Hamiguitan Range · Sightings Map',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w400,
                                            color: Color(0xFF9A8880),
                                            fontStyle: FontStyle.italic,
                                            letterSpacing: 0.1,
                                          ),
                                        ),
                                        if (_lastUpdated != null) ...[
                                          const SizedBox(height: 1),
                                          Text(
                                            'Updated ${_formatDate(_lastUpdated!.toIso8601String())}',
                                            style: const TextStyle(
                                              fontSize: 9,
                                              color: Color(0xFFB8A8A8),
                                              fontWeight: FontWeight.w400,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const Spacer(),
                                    // Export CSV
                                    GestureDetector(
                                      onTap: _exportCsv,
                                      child: Container(
                                        width: 30,
                                        height: 30,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF5EEEF),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: const Color(0xFF4A2830).withOpacity(0.12), width: 0.5),
                                        ),
                                        child: const Icon(
                                            Icons.download_rounded,
                                            size: 15,
                                            color: Color(0xFF4A2830)),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    // Refresh
                                    GestureDetector(
                                      onTap: _loadPins,
                                      child: Container(
                                        width: 30,
                                        height: 30,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF5EEEF),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: const Color(0xFF4A2830).withOpacity(0.12), width: 0.5),
                                        ),
                                        child: const Icon(
                                            Icons.refresh_rounded,
                                            size: 15,
                                            color: Color(0xFF4A2830)),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // ── Sidebar body ──────────────────────────────
                              Expanded(
                                child: _buildSidebarBody(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // ── Detail panel — right on desktop, bottom sheet on mobile
                    if (_selectedPin != null && !isMobile)
                      Positioned(
                        top: 16,
                        right: 16,
                        bottom: 16,
                        width: 300,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF4A2830).withOpacity(0.20),
                                  blurRadius: 40,
                                  offset: const Offset(0, 8),
                                ),
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.15),
                                  blurRadius: 12,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Scrollbar(
                              thumbVisibility: true,
                              child: SingleChildScrollView(
                                primary: false,
                                child: _buildDetailPanel(_selectedPin!),
                              ),
                            ),
                          ),
                        ),
                      ),

                    // ── Species info panel ────────────────────────────────
                    if (_selectedSpecies != null && !isMobile)
                      Positioned(
                        top: 16,
                        right: _selectedPin != null ? 332 : 16,
                        bottom: 16,
                        width: 280,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF4A2830).withOpacity(0.15),
                                  blurRadius: 24,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: SingleChildScrollView(
                              child: _buildSpeciesPanel(
                                _selectedSpecies!,
                                onClose: () => setState(() => _selectedSpecies = null),
                              ),
                            ),
                          ),
                        ),
                      ),

                    // ── Mobile bottom sheet detail ────────────────────────
                    if (_selectedPin != null && isMobile)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.vertical(
                                top: Radius.circular(20)),
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x22000000),
                                blurRadius: 20,
                                offset: Offset(0, -4),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(height: 10),
                              Container(
                                width: 36,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE8DCE0),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(height: 4),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 340),
                                child: SingleChildScrollView(
                                  child: _buildDetailPanel(_selectedPin!),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // ── Mobile hamburger button ───────────────────────────
                    if (isMobile)
                      Positioned(
                        top: 12,
                        left: 12,
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _drawerOpen = !_drawerOpen),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF4A2830).withOpacity(0.18),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Icon(
                              _drawerOpen ? Icons.close_rounded
                                  : Icons.menu_rounded,
                              size: 18,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ),

                    // ── Mobile drawer ────────────────────────────────────
                    if (isMobile && _drawerOpen) ...[
                      // Scrim
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: () => setState(() => _drawerOpen = false),
                          child: Container(
                            color: Colors.black.withOpacity(0.35),
                          ),
                        ),
                      ),
                      // Drawer panel
                      Positioned(
                        top: 0,
                        left: 0,
                        bottom: 0,
                        width: 320,
                        child: Container(
                          color: Colors.white,
                          child: SafeArea(
                            child: ClipRect(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Header
                                  Container(
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 12, 12, 12),
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFF5EEEF),
                                      border: Border(
                                        bottom: BorderSide(
                                            color: Color(0x18000000),
                                            width: 0.5),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Picchure',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFF4A2830),
                                                fontFamily: 'LibreBaskerville',
                                              ),
                                            ),
                                            const Text(
                                              'Mt. Hamiguitan Range · Sightings Map',
                                              style: TextStyle(
                                                fontSize: 9.5,
                                                color: Color(0xFF9A8880),
                                                fontStyle: FontStyle.italic,
                                              ),
                                            ),
                                            if (_lastUpdated != null) ...[
                                              const SizedBox(height: 1),
                                              Text(
                                                'Updated ${_formatDate(_lastUpdated!.toIso8601String())}',
                                                style: const TextStyle(
                                                  fontSize: 9,
                                                  color: Color(0xFFB8A8A8),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const Spacer(),
                                        GestureDetector(
                                          onTap: () => setState(
                                              () => _drawerOpen = false),
                                          child: Icon(Icons.close_rounded,
                                              size: 18,
                                              color: Colors.grey.shade400),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Reuse the same sidebar content
                                  Expanded(
                                    child: SingleChildScrollView(
                                      child: _buildSidebarBody(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    // ── Mobile top-right count pill ───────────────────────
                    if (isMobile)
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFFE8DCE0), width: 1),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF4A2830).withOpacity(0.15),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            '${_allPins.length} sighting${_allPins.length == 1 ? '' : 's'}',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87),
                          ),
                        ),
                      ),
                    if (!_drawerOpen)
                    Positioned(
                      bottom: 24,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Map style switcher
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: const Color(0xFF4A2830).withOpacity(0.12),
                                  width: 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF4A2830).withOpacity(0.10),
                                    blurRadius: 20,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: _mapStyles.entries.map((entry) {
                                  final isActive = _mapStyle == entry.key;
                                  return GestureDetector(
                                    onTap: () =>
                                        setState(() => _mapStyle = entry.key),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 180),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: isActive
                                            ? const Color(0xFFEDE4DC)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            entry.value.icon,
                                            size: 13,
                                            color: isActive
                                                ? const Color(0xFF4A2830)
                                                : Colors.grey.shade500,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            entry.value.label,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: isActive
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                              color: isActive
                                                  ? const Color(0xFF4A2830)
                                                  : Colors.grey.shade500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Heatmap toggle
                            GestureDetector(
                              onTap: () => setState(() => _showHeatmap = !_showHeatmap),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: _showHeatmap
                                      ? const Color(0xFF4A2830)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: const Color(0xFF4A2830).withOpacity(0.12),
                                    width: 1,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF4A2830).withOpacity(0.10),
                                      blurRadius: 20,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.blur_on_rounded,
                                      size: 13,
                                      color: _showHeatmap
                                          ? Colors.white
                                          : Colors.grey.shade500,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Heatmap',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: _showHeatmap
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: _showHeatmap
                                            ? Colors.white
                                            : Colors.grey.shade500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ── Empty state hint ──────────────────────────────────
                    if (_selectedPin == null && !_loading && _showHint)
                      Positioned(
                        bottom: 80,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.55),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.touch_app_rounded,
                                    size: 13, color: Colors.white.withOpacity(0.8)),
                                const SizedBox(width: 6),
                                Text(
                                  'Click a pin to view details',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withOpacity(0.8),
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
        },
      ),

      ),  // Scaffold
    );   // Title
  }

  Widget _buildSpeciesPanel(String species, {required VoidCallback onClose}) {
    final info = _kSpeciesInfo[species];
    final color = _speciesColors[species] ?? const Color(0xFF888078);
    final Color pillBg = Color.lerp(color, Colors.white, 0.85)!;

    final pins = _allPins
        .where((o) => o['species']?.toString() == species && o['detected'] == true)
        .toList();
    final count = pins.length;

    DateTime? firstDate;
    for (final p in pins) {
      final raw = p['created_at']?.toString();
      if (raw == null) continue;
      final dt = DateTime.tryParse(raw)?.toLocal();
      if (dt == null) continue;
      if (firstDate == null || dt.isBefore(firstDate)) firstDate = dt;
    }
    final firstStr = firstDate != null
        ? '${firstDate.year}-${firstDate.month.toString().padLeft(2, '0')}-${firstDate.day.toString().padLeft(2, '0')}'
        : '—';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: const BoxDecoration(
            color: Color(0xFFF5EEEF),
            border: Border(bottom: BorderSide(color: Color(0x18000000), width: 0.5)),
          ),
          child: Row(
            children: [
              Container(
                width: 3, height: 26,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(species,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600,
                            color: Color(0xFF4A2830), fontStyle: FontStyle.italic)),
                    if (info != null)
                      Text(info['full']!,
                          style: const TextStyle(fontSize: 9, color: Color(0xFF9A8880))),
                  ],
                ),
              ),
              GestureDetector(
                onTap: onClose,
                child: Container(
                  width: 26, height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFEDE4DC),
                    border: Border.all(color: const Color(0xFF4A2830).withOpacity(0.15), width: 0.5),
                  ),
                  child: const Icon(Icons.close_rounded, size: 13, color: Color(0xFF4A2830)),
                ),
              ),
            ],
          ),
        ),
        Container(
          height: 140,
          color: pillBg,
          child: Center(
            child: Icon(Icons.local_florist_rounded, size: 40, color: color.withOpacity(0.4)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Wrap(
            spacing: 6, runSpacing: 6,
            children: [
              _infoBadge('Endemic', const Color(0xFFEEF4EA), const Color(0xFF4A7A30)),
              if (info != null)
                _infoBadge(info['status']!, const Color(0xFFF8EFEF), const Color(0xFFA04040)),
              _infoBadge('$count sighting${count == 1 ? '' : 's'}', pillBg, color),
            ],
          ),
        ),
        const Divider(height: 0.5, thickness: 0.5, color: Color(0x10000000)),
        if (info != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ABOUT',
                    style: TextStyle(fontSize: 9, color: Color(0xFFBBBBBB),
                        fontWeight: FontWeight.w500, letterSpacing: 0.4)),
                const SizedBox(height: 6),
                Text(info['about']!,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF444444), height: 1.6)),
              ],
            ),
          ),
        const Divider(height: 0.5, thickness: 0.5, color: Color(0x10000000)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(children: [
                  Text('$count',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF4A2830))),
                  const SizedBox(height: 2),
                  const Text('Sightings', style: TextStyle(fontSize: 9, color: Color(0xFFBBBBBB))),
                ]),
              ),
              Container(width: 0.5, height: 36, color: const Color(0xFFE8DCE0)),
              Expanded(
                child: Column(children: [
                  Text(firstStr,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF4A2830))),
                  const SizedBox(height: 2),
                  const Text('First discovered', style: TextStyle(fontSize: 9, color: Color(0xFFBBBBBB))),
                ]),
              ),
            ],
          ),
        ),

        // ── Photo gallery ─────────────────────────────────────────
        if (pins.isNotEmpty) ...[
          const Divider(height: 0.5, thickness: 0.5, color: Color(0x10000000)),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Text('Photos',
                style: TextStyle(
                    fontSize: 9,
                    color: Colors.grey.shade400,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.4)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 5,
                mainAxisSpacing: 5,
              ),
              itemCount: pins.length,
              itemBuilder: (_, i) {
                final imageUrl = pins[i]['image_url']?.toString();
                final isSelected = _selectedPin?['id'] == pins[i]['id'];
                return GestureDetector(
                  onTap: () => _selectPin(pins[i]),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? color
                            : const Color(0xFFE8DCE0),
                        width: isSelected ? 2 : 0.5,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: imageUrl != null && imageUrl.isNotEmpty
                          ? Image.network(
                              imageUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: pillBg,
                                child: Icon(Icons.image_not_supported_outlined,
                                    size: 18, color: color.withOpacity(0.3)),
                              ),
                            )
                          : Container(
                              color: pillBg,
                              child: Icon(Icons.local_florist_rounded,
                                  size: 18, color: color.withOpacity(0.3)),
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _infoBadge(String label, Color bg, Color text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(label,
          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: text)),
    );
  }
}

// ── Filter pill ───────────────────────────────────────────────────────────────
class _FilterPill extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _FilterPill(
      {required this.label,
      required this.isActive,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFFEDE4DC) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? const Color(0xFF4A2830) : const Color(0xFFE8DCE0),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            color: isActive ? const Color(0xFF4A2830) : Colors.grey.shade600,
            fontStyle: label.startsWith('N. ')
                ? FontStyle.italic
                : FontStyle.normal,
          ),
        ),
      ),
    );
  }
}

// ── Detail row ────────────────────────────────────────────────────────────────
class _DetailRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool isLast;
  final String? onCopy;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.isLast = false,
    this.onCopy,
  });

  @override
  State<_DetailRow> createState() => _DetailRowState();
}

class _DetailRowState extends State<_DetailRow> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: widget.isLast
            ? null
            : const Border(
                bottom: BorderSide(color: Color(0x10000000), width: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(widget.icon, size: 13, color: Colors.grey.shade300),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade400,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.value,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
          if (widget.onCopy != null)
            GestureDetector(
              onTap: () async {
                await Clipboard.setData(
                    ClipboardData(text: widget.onCopy!));
                if (!mounted) return;
                setState(() => _copied = true);
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted) setState(() => _copied = false);
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _copied
                      ? const Color(0xFF4A2830)
                      : const Color(0xFFF5EEEF),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _copied
                          ? Icons.check_rounded
                          : Icons.copy_rounded,
                      size: 11,
                      color: _copied
                          ? Colors.white
                          : Colors.grey.shade400,
                    ),
                    if (_copied) ...[
                      const SizedBox(width: 3),
                      const Text('Copied',
                          style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w500)),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Circle pin painter ────────────────────────────────────────────────────────
class _CirclePinPainter extends CustomPainter {
  final Color color;
  const _CirclePinPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2 - 2;

    // Outer soft shadow
    canvas.drawCircle(
      Offset(cx, cy + 2.5),
      r + 1,
      Paint()
        ..color = Colors.black.withOpacity(0.18)
        ..maskFilter =
            const ui.MaskFilter.blur(ui.BlurStyle.normal, 5),
    );

    // Inner tight shadow for depth
    canvas.drawCircle(
      Offset(cx, cy + 1),
      r,
      Paint()
        ..color = Colors.black.withOpacity(0.25)
        ..maskFilter =
            const ui.MaskFilter.blur(ui.BlurStyle.normal, 2),
    );

    // Fill
    canvas.drawCircle(Offset(cx, cy), r, Paint()..color = color);

    // White border
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_CirclePinPainter old) => old.color != color;
}

// ── Map style option ──────────────────────────────────────────────────────────
class _MapStyleOption {
  final String label;
  final IconData icon;
  final String url;
  const _MapStyleOption({
    required this.label,
    required this.icon,
    required this.url,
  });
}

// ── Pin cluster ───────────────────────────────────────────────────────────────
class _PinCluster {
  final List<Map<String, dynamic>> pins;
  final double lat;
  final double lng;
  const _PinCluster({required this.pins, required this.lat, required this.lng});
}

// ── Skeleton box ──────────────────────────────────────────────────────────────
class _SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  const _SkeletonBox(
      {required this.width, required this.height, required this.radius});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

// ── Search bar ────────────────────────────────────────────────────────────────
class _SearchBar extends StatefulWidget {
  final ValueChanged<String> onSearch;
  const _SearchBar({required this.onSearch});

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x18000000), width: 0.5),
      ),
      child: Row(
        children: [
          const SizedBox(width: 10),
          Icon(Icons.search_rounded, size: 14, color: Colors.grey.shade400),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: widget.onSearch,
              style: const TextStyle(fontSize: 12, color: Colors.black87),
              decoration: InputDecoration(
                hintText: 'Search species or coordinates…',
                hintStyle:
                    TextStyle(fontSize: 12, color: Colors.grey.shade400),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_controller.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _controller.clear();
                widget.onSearch('');
              },
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.close_rounded,
                    size: 13, color: Colors.grey.shade400),
              ),
            ),
        ],
      ),
    );
  }
}
// ── Heatmap painter ───────────────────────────────────────────────────────────
class _HeatmapPainter extends CustomPainter {
  final List<Map<String, dynamic>> pins;
  final MapController mapController;

  const _HeatmapPainter({
    required this.pins,
    required this.mapController,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (pins.isEmpty) return;

    // Species colors matching the app palette
    const speciesColors = <String, Color>{
      'N. alfredoi':        Color(0xFF6E8E59),
      'N. hamiguitanensis': Color(0xFF4A7A8A),
      'N. justinae':        Color(0xFF8E6E59),
      'N. micramphora':     Color(0xFF7A5A8E),
      'N. peltata':         Color(0xFF8E7A40),
    };

    final camera = mapController.camera;
    final zoom = camera.zoom;

    // Radius scales with zoom — bigger at higher zoom
    final radius = 20.0 + zoom * 4.0;

    for (final pin in pins) {
      final lat = (pin['lat'] as num?)?.toDouble();
      final lng = (pin['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;

      final detected = pin['detected'] == true;
      final species = pin['species']?.toString() ?? '';

      final baseColor = detected
          ? (speciesColors[species] ?? const Color(0xFF6E8E59))
          : const Color(0xFFB86B6B);

      // Convert lat/lng to screen pixel position
      final point = camera.latLngToScreenPoint(LatLng(lat, lng));
      final offset = Offset(point.x, point.y);

      // Radial gradient — dense center, fade to transparent
      final gradient = RadialGradient(
        colors: [
          baseColor.withOpacity(0.55),
          baseColor.withOpacity(0.25),
          baseColor.withOpacity(0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      );

      final paint = Paint()
        ..shader = gradient.createShader(
          Rect.fromCircle(center: offset, radius: radius),
        )
        ..blendMode = BlendMode.screen;

      canvas.drawCircle(offset, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.pins != pins || old.mapController != mapController;
}

// ── Species info data ─────────────────────────────────────────────────────────
const _kSpeciesInfo = <String, Map<String, String>>{
  'N. alfredoi': {
    'full': 'Nepenthes alfredoi Cheek',
    'status': 'Critically Endangered',
    'about': 'Endemic to Mt. Hamiguitan Range Wildlife Sanctuary. Distinguished by its elongated lower pitchers and distinctive lid morphology.',
  },
  'N. hamiguitanensis': {
    'full': 'Nepenthes hamiguitanensis Jaime & Fernando',
    'status': 'Critically Endangered',
    'about': 'Named after Mt. Hamiguitan, where it is exclusively found. Notable for its flask-shaped pitchers with a distinctive peristome.',
  },
  'N. justinae': {
    'full': 'Nepenthes justinae Jaime',
    'status': 'Critically Endangered',
    'about': 'A recently described species endemic to the ultramafic soils of Mt. Hamiguitan. Features slender pitchers with a narrow peristome.',
  },
  'N. micramphora': {
    'full': 'Nepenthes micramphora Cheek & Jebb',
    'status': 'Critically Endangered',
    'about': 'One of the smallest Nepenthes species known. Found exclusively on the mossy forests of Mt. Hamiguitan at high elevations.',
  },
  'N. peltata': {
    'full': 'Nepenthes peltata Cheek & Jebb',
    'status': 'Critically Endangered',
    'about': 'Named for its peltate leaf attachment, a rare trait in Nepenthes. Found in the pygmy forest zone of Mt. Hamiguitan.',
  },
};

// ── Date picker field ─────────────────────────────────────────────────────────
class _DatePickerField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onPicked;

  const _DatePickerField({
    required this.label,
    required this.value,
    required this.onPicked,
  });

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime.now(),
          builder: (ctx, child) => Theme(
            data: Theme.of(ctx).copyWith(
              colorScheme: const ColorScheme.light(
                primary: Color(0xFF4A2830),
                onPrimary: Colors.white,
                surface: Colors.white,
              ),
            ),
            child: child!,
          ),
        );
        onPicked(picked);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 9, color: Colors.grey.shade400)),
          const SizedBox(height: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFDFBF9),
              border: Border.all(color: const Color(0xFFE8DCE0), width: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_today_outlined,
                    size: 11, color: Colors.grey.shade400),
                const SizedBox(width: 5),
                Text(
                  value != null ? _fmt(value!) : 'Select date',
                  style: TextStyle(
                      fontSize: 11,
                      color: value != null
                          ? const Color(0xFF4A2830)
                          : Colors.grey.shade400),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}