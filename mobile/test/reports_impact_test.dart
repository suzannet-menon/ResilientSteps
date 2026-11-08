import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile/models/route_segment_safety.dart';
import 'package:mobile/models/scored_route.dart';
import 'package:mobile/services/routing_service.dart';
import 'package:mobile/widgets/map_layers_builder.dart';
import 'package:mobile/widgets/route_info_card.dart';

void main() {
  testWidgets('ready card shows the verified-reports before/after impact', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RouteInfoCard(
              route: _buildRoute(
                baselineSafetyScore: 90,
                incidentScoreDelta: 8.2,
                incidentPoints: const <RouteIncidentPoint>[
                  RouteIncidentPoint(
                    point: LatLng(18.52995, 73.86327),
                    id: '23',
                    category: 'unsafe_infrastructure',
                    severity: 5,
                  ),
                ],
              ),
              isLoading: false,
              buttonLabel: 'START NAVIGATION',
              onPrimaryPressed: () {},
              destinationLabel: 'Destination',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Before/after line present, with both numbers.
    expect(find.text('Reports impact: 90% → 82% safety'), findsOneWidget);
    expect(
      find.textContaining('8.2 pts from 1 verified report'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('card stays clean when reports do not move the score', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RouteInfoCard(
              route: _buildRoute(
                baselineSafetyScore: 82,
                incidentScoreDelta: 0.0,
              ),
              isLoading: false,
              buttonLabel: 'START NAVIGATION',
              onPrimaryPressed: () {},
              destinationLabel: 'Destination',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Reports impact'), findsNothing);
  });

  test('buildIncidentMarkers pins one marker per verified point', () {
    final List<Marker> markers = MapLayersBuilder.buildIncidentMarkers(<
      RouteIncidentPoint
    >[
      const RouteIncidentPoint(point: LatLng(18.52995, 73.86327)),
      const RouteIncidentPoint(point: LatLng(18.53347, 73.87697)),
    ]);
    expect(markers, hasLength(2));

    expect(MapLayersBuilder.buildIncidentMarkers(const <RouteIncidentPoint>[]), isEmpty);
  });

  test('coincident reports become one frame with individually hoverable dots', () {
    // Reports #22/#23/#24 share one verified coordinate (BPCL underpass).
    // One marker frame must contain all three dots as siblings — stacked
    // full-frame opaque MouseRegions would swallow the hover for everyone
    // but the topmost report.
    final List<Marker> markers = MapLayersBuilder.buildIncidentMarkers(<
      RouteIncidentPoint
    >[
      const RouteIncidentPoint(
        point: LatLng(18.5299478, 73.8632719),
        id: '24',
        category: 'heat_stress',
        severity: 4,
      ),
      const RouteIncidentPoint(
        point: LatLng(18.5299478, 73.8632719),
        id: '22',
        category: 'suspicious_activity',
        severity: 3,
      ),
      const RouteIncidentPoint(
        point: LatLng(18.5299478, 73.8632719),
        id: '23',
        category: 'unsafe_infrastructure',
        severity: 5,
      ),
    ]);
    expect(markers, hasLength(1));

    final Stack stack = markers.first.child as Stack;
    final List<Align> slots = stack.children.cast<Align>();
    expect(slots, hasLength(3));
    final List<Tooltip> dots = slots
        .map((Align slot) => slot.child as Tooltip)
        .toList(growable: false);

    // Every report in the frame has its own tooltip.
    final Set<String?> messages = dots.map((Tooltip dot) => dot.message).toSet();
    expect(messages, hasLength(3));

    // Distinct ring slots: no pixel-identical stacking inside the frame.
    final Set<AlignmentGeometry?> alignments = slots
        .map((Align slot) => slot.alignment)
        .toSet();
    expect(alignments, hasLength(3));
    expect(alignments, isNot(contains(Alignment.center)));

    // Two reports on the exact same verified coordinate merge into one
    // frame; a report on a different block still gets its own marker.
    final List<Marker> mixed = MapLayersBuilder.buildIncidentMarkers(<
      RouteIncidentPoint
    >[
      const RouteIncidentPoint(point: LatLng(18.52995, 73.86327)),
      const RouteIncidentPoint(point: LatLng(18.52995, 73.86327)),
      const RouteIncidentPoint(point: LatLng(18.53347, 73.87697)),
    ]);
    expect(mixed, hasLength(2));
  });

  test('routing service parses incident_points into route pins', () {
    final ScoredRoute? route = RoutingService(
      apiBaseUrl: 'http://localhost:8000',
    ).scoredRouteFromPayload(
      <String, dynamic>{
        'safety_score': 67.5,
        'base_safety_score': 78.0,
        'incident_score_delta': 10.5,
        'incident_points': <Object?>[
          <String, Object?>{
            'id': 23,
            'lat': 18.52995,
            'lon': 73.86327,
            'category': 'unsafe_infrastructure',
            'severity': 5,
          },
          <String, Object?>{'lat': null, 'lon': 73.8},
          'garbage',
        ],
      },
      const <LatLng>[LatLng(18.52, 73.85), LatLng(18.525, 73.855)],
    );

    expect(route, isNotNull);
    expect(route!.baselineSafetyScore, 78.0);
    expect(route.incidentScoreDelta, 10.5);
    expect(route.incidentPoints, hasLength(1));
    expect(route.incidentPoints[0].id, '23');
    expect(route.incidentPoints[0].severity, 5);
    expect(
      route.incidentPoints[0].tooltipLabel,
      'Unsafe infrastructure (severity 5)',
    );
  });
}

ScoredRoute _buildRoute({
  double? baselineSafetyScore,
  double? incidentScoreDelta,
  List<RouteIncidentPoint> incidentPoints = const <RouteIncidentPoint>[],
}) {
  return ScoredRoute(
    points: const <LatLng>[LatLng(18.5200, 73.8560), LatLng(18.5200, 73.8570)],
    segments: <RouteSegmentSafety>[
      RouteSegmentSafety(
        start: LatLng(18.5200, 73.8560),
        end: LatLng(18.5200, 73.8570),
        distanceMeters: 110,
        safetyScore: 82,
        incidentRisk: 0.1,
        timeOfDayRisk: 0.1,
        lightingLevel: 0.8,
        crowdDensity: 0.4,
        distanceWeight: 1,
        safetyPenalty: 2,
        risk: 3,
        safetyLevel: 'SAFE',
        shadeScore: 35,
        heatPenalty: 22,
        comfortScore: 70,
      ),
    ],
    totalDistanceMeters: 110,
    averageSafetyScore: 82,
    totalRisk: 3,
    durationMinutes: 12,
    comfortScore: 70,
    comfortLevel: 'Moderate',
    baselineSafetyScore: baselineSafetyScore,
    incidentScoreDelta: incidentScoreDelta,
    incidentPoints: incidentPoints,
  );
}
