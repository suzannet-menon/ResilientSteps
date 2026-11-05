import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../models/safety_zone.dart';

class SafetyZoneOverlay extends StatelessWidget {
  const SafetyZoneOverlay({
    super.key,
    required this.zones,
  });

  final List<SafetyZone> zones;

  @override
  Widget build(BuildContext context) {
    if (zones.isEmpty) {
      return const SizedBox.shrink();
    }

    final List<Polygon> polygons = zones
        .map(_buildPolygon)
        .whereType<Polygon>()
        .toList(growable: false);

    return IgnorePointer(child: PolygonLayer(polygons: polygons));
  }

  Polygon? _buildPolygon(SafetyZone zone) {
    if (zone.polygonPoints.length < 3) {
      return null;
    }

    final _ZonePolygonStyle style = _styleForZone(zone.classification);
    return Polygon(
      points: zone.polygonPoints,
      color: style.fillColor,
      borderColor: style.borderColor,
      borderStrokeWidth: style.borderWidth,
    );
  }

  static const _ZonePolygonStyle _safeStyle = _ZonePolygonStyle(
    fillColor: Color(0x4743A047),
    borderColor: Color(0xFF43A047),
    borderWidth: 1,
  );

  static const _ZonePolygonStyle _cautiousStyle = _ZonePolygonStyle(
    fillColor: Color(0x52F57C00),
    borderColor: Color(0xFFF57C00),
    borderWidth: 1,
  );

  static const _ZonePolygonStyle _riskyStyle = _ZonePolygonStyle(
    fillColor: Color(0x61D32F2F),
    borderColor: Color(0xFFD32F2F),
    borderWidth: 1.5,
  );

  static const _ZonePolygonStyle _defaultStyle = _ZonePolygonStyle(
    fillColor: Color(0x339E9E9E),
    borderColor: Color(0xFF9E9E9E),
    borderWidth: 1,
  );

  _ZonePolygonStyle _styleForZone(String? classification) {
    switch ((classification ?? '').toLowerCase()) {
      case 'safe':
        return _safeStyle;
      case 'cautious':
        return _cautiousStyle;
      case 'risky':
        return _riskyStyle;
      default:
        return _defaultStyle;
    }
  }
}

class _ZonePolygonStyle {
  const _ZonePolygonStyle({
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
  });

  final Color fillColor;
  final Color borderColor;
  final double borderWidth;
}
