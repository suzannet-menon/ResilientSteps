import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/navigation_controller.dart';
import '../models/route_segment_safety.dart';
import '../models/scored_route.dart';
import '../services/navigation_math.dart';
import '../models/nearby_place.dart';

class MapLayersBuilder {
  MapLayersBuilder._();

  static const LinearGradient _userMarkerGradient = LinearGradient(
    colors: <Color>[Color(0xFF34B3FF), Color(0xFF2E7CF6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const Border _userMarkerBorder = Border.fromBorderSide(
    BorderSide(color: Colors.white, width: 4),
  );
  static const List<BoxShadow> _userMarkerShadows = <BoxShadow>[
    BoxShadow(color: Color(0x422E7CF6), blurRadius: 20, offset: Offset(0, 10)),
  ];
  static const BoxDecoration _destinationMarkerDecoration = BoxDecoration(
    shape: BoxShape.circle,
    color: Colors.white,
    border: Border.fromBorderSide(
      BorderSide(color: Color(0xFF2E7CF6), width: 5),
    ),
    boxShadow: <BoxShadow>[
      BoxShadow(
        color: Color(0x24000000),
        blurRadius: 18,
        offset: Offset(0, 10),
      ),
    ],
  );

  static List<Polyline> buildRoutePolylines({
    required ScoredRoute route,
    required RouteProgressSplit? progress,
    required NavigationState navState,
  }) {
    final List<LatLng> routePoints = route.points;
    if (routePoints.isEmpty) {
      return const <Polyline>[];
    }

    final List<RouteSegmentSafety> scoredSegments = route.segments
        .where((RouteSegmentSafety segment) => segment.safetyLevel != 'UNKNOWN')
        .toList(growable: false);
    final List<Polyline> polylines = <Polyline>[];
    final bool showActiveProgress =
        progress != null &&
        (navState == NavigationState.active ||
            navState == NavigationState.arrived);

    if (showActiveProgress) {
      if (progress.completedPoints.length > 1) {
        polylines.addAll(<Polyline>[
          Polyline(
            points: progress.completedPoints,
            strokeWidth: 11,
            color: Colors.white.withValues(alpha: 0.28),
          ),
          Polyline(
            points: progress.completedPoints,
            strokeWidth: 6,
            color: const Color(0xFF2F6EF6).withValues(alpha: 0.10),
          ),
        ]);
      }

      final List<LatLng> remainingPoints = progress.remainingPoints.length > 1
          ? progress.remainingPoints
          : routePoints;
      polylines.addAll(<Polyline>[
        Polyline(
          points: remainingPoints,
          strokeWidth: 16,
          color: Colors.white.withValues(alpha: 0.88),
        ),
        Polyline(
          points: remainingPoints,
          strokeWidth: 11,
          color: const Color(0xFF2F6EF6).withValues(alpha: 0.18),
        ),
      ]);

      if (scoredSegments.isEmpty) {
        polylines.add(
          Polyline(
            points: remainingPoints,
            strokeWidth: 8,
            color: const Color(0xFF30C56A),
            borderStrokeWidth: 4.4,
            borderColor: Colors.white.withValues(alpha: 0.96),
          ),
        );
        return polylines;
      }

      polylines.addAll(_buildActiveRouteSegmentOverlays(route, progress));
      return polylines;
    }

    polylines.addAll(<Polyline>[
      Polyline(
        points: routePoints,
        strokeWidth: 16,
        color: Colors.white.withValues(alpha: 0.84),
      ),
      Polyline(
        points: routePoints,
        strokeWidth: 11,
        color: const Color(0xFF2F6EF6).withValues(alpha: 0.14),
      ),
    ]);

    if (scoredSegments.isEmpty) {
      polylines.add(
        Polyline(
          points: routePoints,
          strokeWidth: 8,
          color: const Color(0xFF30C56A),
          borderStrokeWidth: 4.4,
          borderColor: Colors.white.withValues(alpha: 0.96),
        ),
      );
      return polylines;
    }

    for (final RouteSegmentSafety segment in scoredSegments) {
      polylines.add(
        Polyline(
          points: <LatLng>[segment.start, segment.end],
          strokeWidth: 8.2,
          color: _routeSegmentColor(segment),
          borderStrokeWidth: 2.8,
          borderColor: Colors.white.withValues(alpha: 0.90),
        ),
      );
    }

    return polylines;
  }

  static List<Marker> buildNavigationMarkers({
    required LatLng start,
    required LatLng? destination,
    required String destinationLabel,
    required double heading,
    required double zoom,
    LatLng? origin,
    String? originLabel,
  }) {
    final double userMarkerDiameter = _userMarkerDiameterForZoom(zoom);
    final double userMarkerFrame = _userMarkerFrameForZoom(zoom);
    final double userIconSize = (userMarkerDiameter * 0.46)
        .clamp(18.0, 24.0)
        .toDouble();
    final List<Marker> markers = <Marker>[
      _buildMapMarker(
        point: start,
        label: 'Your location',
        size: userMarkerFrame,
        child: Container(
          width: userMarkerDiameter,
          height: userMarkerDiameter,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: _userMarkerGradient,
            border: _userMarkerBorder,
            boxShadow: _userMarkerShadows,
          ),
          child: Transform.rotate(
            angle: heading * math.pi / 180,
            child: Icon(
              Icons.navigation_rounded,
              color: Colors.white,
              size: userIconSize,
            ),
          ),
        ),
      ),
    ];

    if (destination != null) {
      markers.add(
        _buildMapMarker(
          point: destination,
          label: destinationLabel,
          child: Container(
            width: 52,
            height: 52,
            decoration: _destinationMarkerDecoration,
            child: Center(
              child: Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(
                  color: Color(0xFF2E7CF6),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Route-start pill: floats just above the origin point so the user can
    // see where the walk begins even while their live blue dot is elsewhere
    // (typed origin) or overlapping it.
    if (origin != null) {
      markers.add(
        Marker(
          point: origin,
          width: 104,
          height: 64,
          child: Align(
            alignment: Alignment.topCenter,
            child: Tooltip(
              message: originLabel ?? 'Route start',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF30C56A), width: 3),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 8,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.flag_rounded,
                        size: 16,
                        color: Color(0xFF1B6B3A),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'Start',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1B6B3A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return markers;
  }

  /// R-104: verified-report pins for the coordinates that were matched to
  /// the current route's segments, so the user can see exactly which points
  /// moved the safety score.
  ///
  /// Coincident reports (near-identical pin coordinates — e.g. reports
  /// #22/#23/#24 at the BPCL underpass share one coordinate) need special
  /// handling: one Marker per report would stack full-frame opaque hover
  /// regions over the same point and only the topmost tooltip would ever
  /// fire. Every marker, however many reports it holds, is therefore ONE
  /// frame whose dots are laid out as siblings — each dot owns its own
  /// 16 px hover area, so every report stays individually hoverable.
  static List<Marker> buildIncidentMarkers(List<RouteIncidentPoint> points) {
    if (points.isEmpty) {
      return const <Marker>[];
    }
    final Map<String, List<RouteIncidentPoint>> groups =
        <String, List<RouteIncidentPoint>>{};
    for (final RouteIncidentPoint incident in points) {
      final String key =
          '${incident.point.latitude.toStringAsFixed(4)},'
          '${incident.point.longitude.toStringAsFixed(4)}';
      (groups[key] ??= <RouteIncidentPoint>[]).add(incident);
    }
    return <Marker>[
      for (final List<RouteIncidentPoint> group in groups.values)
        group.length == 1
            ? _incidentMarker(group.first)
            : _incidentGroupMarker(group),
    ];
  }

  static Widget _incidentDot() {
    return Container(
      width: 16,
      height: 16,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFFE24A3B),
        border: Border.fromBorderSide(
          BorderSide(color: Colors.white, width: 2.4),
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0x40E24A3B),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
    );
  }

  static Marker _incidentMarker(RouteIncidentPoint incident) {
    return Marker(
      point: incident.point,
      width: 34,
      height: 34,
      child: Tooltip(
        message: incident.tooltipLabel,
        child: Center(child: _incidentDot()),
      ),
    );
  }

  static Marker _incidentGroupMarker(List<RouteIncidentPoint> group) {
    // Ring spread headroom: alignment ±0.8 maps to ±12 px inside a 46 px
    // frame, so a dot at top (0, -12) and dots at bottom-left/right never
    // overlap their 16 px hit areas.
    const double frame = 46.0;
    return Marker(
      point: group.first.point,
      width: frame,
      height: frame,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          for (int slot = 0; slot < group.length; slot++)
            Align(
              alignment: _ringAlignment(slot, group.length),
              child: Tooltip(
                message: group[slot].tooltipLabel,
                child: _incidentDot(),
              ),
            ),
        ],
      ),
    );
  }

  static Alignment _ringAlignment(int slot, int slotCount) {
    // Top slot first (angle -90°), then clockwise.
    final double angle = (2 * math.pi * slot / slotCount) - math.pi / 2;
    return Alignment(0.8 * math.cos(angle), 0.8 * math.sin(angle));
  }

  static List<Marker> buildNearbyMarkers(List<NearbyPlace> places) {
    return places
        .map(
          (NearbyPlace place) => Marker(
            point: place.point,
            width: 48,
            height: 58,
            child: Tooltip(
              message: place.name,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF0F6B63), width: 3),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Color(0x33000000), blurRadius: 8),
                  ],
                ),
                child: Icon(
                  _nearbyIcon(place.category),
                  color: const Color(0xFF0F6B63),
                  size: 24,
                ),
              ),
            ),
          ),
        )
        .toList(growable: false);
  }

  static IconData _nearbyIcon(NearbyCategory category) {
    switch (category) {
      case NearbyCategory.all:
        return Icons.near_me_rounded;
      case NearbyCategory.hospital:
        return Icons.local_hospital_rounded;
      case NearbyCategory.police:
        return Icons.local_police_rounded;
      case NearbyCategory.metro:
        return Icons.subway_rounded;
      case NearbyCategory.bus:
        return Icons.directions_bus_rounded;
    }
  }

  static List<Polyline> _buildActiveRouteSegmentOverlays(
    ScoredRoute route,
    RouteProgressSplit progress,
  ) {
    if (route.segments.isEmpty) {
      return const <Polyline>[];
    }

    final double totalRouteDistance = NavigationMath.polylineDistanceMeters(
      route.points,
    );
    if (totalRouteDistance <= 0) {
      return const <Polyline>[];
    }

    double totalSegmentDistance = 0;
    for (final RouteSegmentSafety segment in route.segments) {
      totalSegmentDistance += _routeSegmentDistance(segment);
    }
    if (totalSegmentDistance <= 0) {
      return const <Polyline>[];
    }

    final double completedRatio =
        (progress.distanceAlongRouteMeters / totalRouteDistance)
            .clamp(0.0, 1.0)
            .toDouble();
    final double completedSegmentDistance =
        totalSegmentDistance * completedRatio;
    final List<Polyline> overlays = <Polyline>[];

    double traveled = 0;
    for (final RouteSegmentSafety segment in route.segments) {
      final double segmentDistance = _routeSegmentDistance(segment);
      final double segmentStart = traveled;
      final double segmentEnd = traveled + segmentDistance;
      traveled = segmentEnd;

      if (segment.safetyLevel == 'UNKNOWN' || segmentDistance <= 0) {
        continue;
      }
      if (completedSegmentDistance >= segmentEnd) {
        continue;
      }

      LatLng overlayStart = segment.start;
      if (completedSegmentDistance > segmentStart) {
        final double t =
            ((completedSegmentDistance - segmentStart) / segmentDistance)
                .clamp(0.0, 1.0)
                .toDouble();
        overlayStart = NavigationMath.interpolateBetween(
          segment.start,
          segment.end,
          t,
        );
      }

      if (NavigationMath.distanceMeters(overlayStart, segment.end) < 0.5) {
        continue;
      }

      overlays.add(
        Polyline(
          points: <LatLng>[overlayStart, segment.end],
          strokeWidth: 8.2,
          color: _routeSegmentColor(segment),
          borderStrokeWidth: 2.8,
          borderColor: Colors.white.withValues(alpha: 0.92),
        ),
      );
    }

    return overlays;
  }

  static double _routeSegmentDistance(RouteSegmentSafety segment) {
    if (segment.distanceMeters > 0) {
      return segment.distanceMeters;
    }
    return NavigationMath.distanceMeters(segment.start, segment.end);
  }

  static Color _routeSegmentColor(RouteSegmentSafety segment) {
    if (segment.safetyPenalty >= 8 || segment.incidentRisk >= 0.6) {
      return const Color(0xFFE24A3B);
    }
    if (segment.safetyScore >= 75) {
      return const Color(0xFF30C56A);
    }
    if (segment.safetyScore >= 55) {
      return const Color(0xFFF2A53B);
    }
    return const Color(0xFFD7644F);
  }

  static double _userMarkerDiameterForZoom(double zoom) {
    final double scaledDiameter = 36 + ((19 - zoom) * 4);
    return scaledDiameter.clamp(36.0, 56.0).toDouble();
  }

  static double _userMarkerFrameForZoom(double zoom) =>
      _userMarkerDiameterForZoom(zoom) + 12;

  static Marker _buildMapMarker({
    required LatLng point,
    required String label,
    required Widget child,
    double size = 64,
  }) {
    return Marker(
      point: point,
      width: size,
      height: size,
      child: Tooltip(
        message: label,
        child: Center(child: child),
      ),
    );
  }
}
