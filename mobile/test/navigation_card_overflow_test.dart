import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile/controllers/navigation_controller.dart';
import 'package:mobile/models/route_segment_safety.dart';
import 'package:mobile/models/scored_route.dart';
import 'package:mobile/widgets/navigation_card.dart';

/// Regression test for the "A RenderFlex overflowed by N pixels on the right"
/// error thrown by the active-navigation card on real phones:
/// the collapsed strip's route-selector chips were a plain Row of two
/// fixed-width chips, and the "Navigating" heading row did not give the
/// title / CLIMATE SAFE badge room to shrink.
void main() {
  for (final double width in <double>[320, 360, 393]) {
    for (final double textScale in <double>[1.0, 1.3]) {
      testWidgets('active nav card fits $width dp at text scale $textScale',
          (WidgetTester tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            builder: (BuildContext context, Widget? child) {
              return MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              );
            },
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: NavigationCard(
                  navState: NavigationState.active,
                  route: _buildRoute(),
                  destinationLabel: 'Koregaon Park, Pune',
                  isLoadingRoute: false,
                  isRerouting: false,
                  onStartNavigation: () {},
                  onStopNavigation: () {},
                  onDismissArrival: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Navigating'), findsOneWidget);

        // Expand the card via the header tap and keep asserting no overflow.
        await tester.tap(find.text('Navigating'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text('Active navigation'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
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
