import 'package:flutter/material.dart';

import '../models/route_segment_safety.dart';
import '../models/scored_route.dart';

class RouteInfoCard extends StatelessWidget {
  const RouteInfoCard({
    super.key,
    required this.route,
    required this.isLoading,
    required this.buttonLabel,
    required this.onPrimaryPressed,
    this.destinationLabel,
  });

  final ScoredRoute? route;
  final bool isLoading;
  final String buttonLabel;
  final VoidCallback? onPrimaryPressed;
  final String? destinationLabel;

  @override
  Widget build(BuildContext context) {
    if (!isLoading && route == null) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);

    // Loading state uses a compact card; ready state uses the bottom-sheet style
    if (isLoading) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(28),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 32,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: _LoadingState(theme: theme),
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 32,
              offset: Offset(0, -8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          child: _ReadyState(
            route: route!,
            destinationLabel: destinationLabel,
            buttonLabel: buttonLabel,
            onPrimaryPressed: onPrimaryPressed,
            theme: theme,
          ),
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey<String>('loading'),
      children: <Widget>[
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xFFF3F7FF),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: CircularProgressIndicator(
              strokeWidth: 2.8,
              color: Color(0xFF2F6EF6),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Finding the safest route',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: const Color(0xFF0E1B2A),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Checking nearby streets and safety signals around your path.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF5E6D80),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReadyState extends StatelessWidget {
  const _ReadyState({
    required this.route,
    required this.destinationLabel,
    required this.buttonLabel,
    required this.onPrimaryPressed,
    required this.theme,
  });

  final ScoredRoute route;
  final String? destinationLabel;
  final String buttonLabel;
  final VoidCallback? onPrimaryPressed;
  final ThemeData theme;

  String _routeWhyText(_RouteCardSummary summary) {
    // Real climate reasoning first (comfort score + shade/heat drivers),
    // then any backend warning, and the heuristic advice only as a last
    // fallback for routes with no comfort data.
    final List<String> parts = <String>[
      if (route.comfortSummary != null) route.comfortSummary!,
    ];
    final String? warning = route.warning?.trim();
    if (warning != null && warning.isNotEmpty) {
      parts.add(warning);
    }
    if (parts.isNotEmpty) {
      return parts.join(' · ');
    }
    return summary.advice;
  }

  @override
  Widget build(BuildContext context) {
    final int safetyScore = route.averageSafetyScore.round().clamp(0, 100);
    final _RouteCardSummary summary = _RouteCardSummary.fromRoute(route);

    // Real tree-canopy shade from the backend (null when no shade data).
    final String shadeLabel = shadeLabelFor(route);

    final double distKm = route.totalDistanceMeters / 1000;
    final String distLabel = distKm >= 1
        ? '${distKm.toStringAsFixed(1)} km'
        : '${route.totalDistanceMeters.round()} m';

    // R-104: verified reports moved this score — show before -> after.
    final double? scoreDelta = route.incidentScoreDelta;
    final double? baseline = route.baselineSafetyScore;
    final bool showReportImpact =
        scoreDelta != null && scoreDelta >= 0.5 && baseline != null;
    final int reportCount = route.incidentPoints.length;

    const Color deepGreen = Color(0xFF1B6B3A);

    return Column(
      key: const ValueKey<String>('ready'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Drag handle
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFD0D8E4),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Heading row: "Climate-Smart Route" + recommended badge
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Climate-Smart Route',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: const Color(0xFF0E1B2A),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${summary.etaMinutes} min  •  $distLabel',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF5E6D80),
                    ),
                  ),
                ],
              ),
            ),
            if (route.heatIndexLabel != null && route.comfortScore != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFDCF5E8),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Recommended\nfor today\'s heat',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: deepGreen,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        // Why this route? explanation
        RichText(
          text: TextSpan(
            children: <TextSpan>[
              TextSpan(
                text: 'Why this route? ',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: deepGreen,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextSpan(
                text: _routeWhyText(summary),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF3D4F62),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // Safety & Shade scores
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF6F8FC),
            borderRadius: BorderRadius.circular(14),
          ),
          // Wrap, not Row: on narrow phones (and with large text scale) the
          // three labels are wider than the card, which overflowed the Row.
          child: Wrap(
            spacing: 20,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.wb_sunny_outlined,
                    size: 18,
                    color: Color(0xFF8A9BB0),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Safety: $safetyScore%',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF3D4F62),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              Text(
                'Shade: $shadeLabel',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF3D4F62),
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (route.heatIndexLabel != null)
                Text(
                  'Heat: ${route.heatIndexLabel}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF3D4F62),
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
        if (route.shadeCoveragePct != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            'Shade data: ${route.shadeCoveragePct}% of legs '
            '(${route.shadeMatchedCount} of ${route.shadeLegCount})',
            style: theme.textTheme.labelSmall?.copyWith(
              color: route.shadeCoveragePct! >= 95
                  ? const Color(0xFF8A9BB0)
                  : const Color(0xFFB08030),
            ),
          ),
        ],
        if (showReportImpact) ...<Widget>[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFDF3E7),
              borderRadius: BorderRadius.circular(12),
            ),
            // Wrap, not Row: the before/after text plus report count must
            // stack instead of overflowing on narrow screens (same pattern
            // as the stats strip above).
            child: Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                const Icon(
                  Icons.location_on_rounded,
                  size: 18,
                  color: Color(0xFFB07020),
                ),
                Text(
                  'Reports impact: ${baseline.round()}% → '
                  '${route.averageSafetyScore.round()}% safety',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF7A4B10),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '−${scoreDelta.toStringAsFixed(1)} pts from '
                  '$reportCount verified report${reportCount == 1 ? '' : 's'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: const Color(0xFFB07020),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        // Route selector chips (Wrap so they stack instead of overflowing
        // on narrow screens).
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            _RouteOptionChip(
              label: 'Climate-Smart',
              selected: true,
              onTap: () {},
            ),
            if (route.durationMinutes != null)
              _RouteOptionChip(
                label: 'Fastest • ${route.durationMinutes!.round()} min',
                selected: false,
                onTap: () {},
              ),
          ],
        ),
        const SizedBox(height: 18),
        // Start Walking button
        SizedBox(
          width: double.infinity,
          height: 54,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: <Color>[Color(0xFF1B6B3A), Color(0xFF2E8B50)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(27),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: const Color(0xFF1B6B3A).withValues(alpha: 0.30),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onPrimaryPressed,
                borderRadius: BorderRadius.circular(27),
                splashColor: Colors.white.withValues(alpha: 0.12),
                child: Center(
                  child: Text(
                    'Start Walking →',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RouteOptionChip extends StatelessWidget {
  const _RouteOptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected ? const Color(0xFF0E1B2A) : const Color(0xFFD0D8E4),
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (selected) ...<Widget>[
              const Icon(
                Icons.check_rounded,
                size: 14,
                color: Color(0xFF0E1B2A),
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: selected
                      ? const Color(0xFF0E1B2A)
                      : const Color(0xFF8A9BB0),
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteCardSummary {
  const _RouteCardSummary({
    required this.etaMinutes,
    required this.headline,
    required this.watchOutLabel,
    required this.incidentLabel,
    required this.advice,
    required this.highlightColor,
  });

  final int etaMinutes;
  final String headline;
  final String watchOutLabel;
  final String incidentLabel;
  final String advice;
  final Color highlightColor;

  factory _RouteCardSummary.fromRoute(ScoredRoute route) {
    final List<RouteSegmentSafety> matchedSegments = route.segments
        .where((RouteSegmentSafety segment) => segment.safetyLevel != 'UNKNOWN')
        .toList(growable: false);
    final int riskySegments = matchedSegments
        .where(
          (RouteSegmentSafety segment) => _segmentTier(segment) == _Tier.risky,
        )
        .length;
    final int cautiousSegments = matchedSegments
        .where(
          (RouteSegmentSafety segment) =>
              _segmentTier(segment) == _Tier.cautious,
        )
        .length;
    final int incidentHotspots = matchedSegments
        .where(
          (RouteSegmentSafety segment) =>
              segment.safetyPenalty > 0.5 || segment.incidentRisk > 0.05,
        )
        .length;
    final int etaMinutes = (route.totalDistanceMeters / 75)
        .clamp(1, 180)
        .round();

    if (route.averageSafetyScore >= 75) {
      return _RouteCardSummary(
        etaMinutes: etaMinutes,
        headline: 'Steadier route',
        watchOutLabel: riskySegments > 0
            ? 'Moderate'
            : (cautiousSegments > 0 ? 'Low' : 'Minimal'),
        incidentLabel: incidentHotspots > 0
            ? '$incidentHotspots live hotspots'
            : 'No live hotspots',
        advice: incidentHotspots > 0
            ? 'Recent incident activity is lowering safety on a few nearby stretches.'
            : 'This route is staying on the calmer side right now.',
        highlightColor: const Color(0xFF2C8C63),
      );
    }

    if (route.averageSafetyScore >= 55) {
      return _RouteCardSummary(
        etaMinutes: etaMinutes,
        headline: 'Mostly okay with caution',
        watchOutLabel: riskySegments > 0 ? 'High' : 'Moderate',
        incidentLabel: incidentHotspots > 0
            ? '$incidentHotspots active hotspots'
            : 'Low incident activity',
        advice: incidentHotspots > 0
            ? 'Stay alert near the highlighted sections where recent reports are clustered.'
            : 'A few stretches need extra attention, especially after dark.',
        highlightColor: const Color(0xFFD79C29),
      );
    }

    return _RouteCardSummary(
      etaMinutes: etaMinutes,
      headline: 'Stay extra alert',
      watchOutLabel: riskySegments > 0 ? 'High' : 'Moderate',
      incidentLabel: incidentHotspots > 0
          ? '$incidentHotspots higher-risk hotspots'
          : 'Safety score is low',
      advice: incidentHotspots > 0
          ? 'Recent incident clusters are materially affecting this route.'
          : 'Keep to brighter, busier roads and reassess if conditions feel off.',
      highlightColor: const Color(0xFFD45A47),
    );
  }

  static _Tier _segmentTier(RouteSegmentSafety segment) {
    final String normalizedLevel = (segment.safetyLevel ?? '').toUpperCase();
    if (normalizedLevel == 'RISKY') {
      return _Tier.risky;
    }
    if (normalizedLevel == 'CAUTIOUS') {
      return _Tier.cautious;
    }
    if (segment.safetyScore < 40) {
      return _Tier.risky;
    }
    if (segment.safetyScore < 70) {
      return _Tier.cautious;
    }
    return _Tier.safe;
  }
}

enum _Tier { safe, cautious, risky }
