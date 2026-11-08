import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile/models/route_segment_safety.dart';
import 'package:mobile/models/scored_route.dart';
import 'package:mobile/widgets/route_info_card.dart';

void main() {
  testWidgets('ready card fits a narrow screen without overflowing', (
    WidgetTester tester,
  ) async {
    // 296 dp leaves 256 dp inside the card (20 dp padding each side), which is
    // where the Safety/Shade/Heat Row used to overflow by ~18 px.
    tester.view.physicalSize = const Size(296, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RouteInfoCard(
              route: _buildRoute(),
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

    expect(tester.takeException(), isNull);
    expect(find.text('Climate-Smart Route'), findsOneWidget);
  });
}

ScoredRoute _buildRoute() {
  return const ScoredRoute(
    points: <LatLng>[LatLng(18.5200, 73.8560), LatLng(18.5200, 73.8570)],
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
  );
}
