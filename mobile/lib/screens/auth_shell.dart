import 'package:flutter/material.dart';

/// Shared layout shell for Login / Signup.
///
/// Phones keep the previous compact single-column layout. Laptops (wide and
/// reasonably tall viewports) get a two-pane Google-style layout: a brand
/// panel on the left and the form card on the right, so the whole screen fits
/// without scrolling instead of loading below the fold.
class AuthScreenShell extends StatelessWidget {
  const AuthScreenShell({
    super.key,
    required this.headlineText,
    required this.sublineText,
    required this.formWidgets,
    required this.formKey,
  });

  final String headlineText;
  final String sublineText;
  final List<Widget> formWidgets;
  final GlobalKey<FormState> formKey;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints viewport) {
        final bool twoPane =
            viewport.maxWidth >= 640 && viewport.maxHeight >= 440;

        final Widget formFields = Form(
          key: formKey,
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: formWidgets,
            ),
          ),
        );

        if (twoPane) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                flex: 5,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 36),
                    child: _BrandPanel(
                      headlineText: headlineText,
                      sublineText: sublineText,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 6,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 30,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 22,
                      ),
                      child: formFields,
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        // Phone layout (same as before, slightly tightened).
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: viewport.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: _BrandColumn(
                  headlineText: headlineText,
                  sublineText: sublineText,
                  child: formFields,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel({required this.headlineText, required this.sublineText});

  final String headlineText;
  final String sublineText;

  @override
  Widget build(BuildContext context) {
    final List<String> bullets = <String>[
      'Routes that weigh shade, heat, and incident zones',
      'Save places, report hazards, and alert trusted contacts',
      'Live weather-aware comfort score for every trip',
    ];

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Center(
            child: Image.asset(
              'assets/f-logo.png',
              width: 180,
              fit: BoxFit.contain,
              semanticLabel: 'ResilientSteps Logo',
            ),
          ),
          const SizedBox(height: 18),
          Text(
            headlineText,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: Color(0xFF142032),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            sublineText,
            style: const TextStyle(fontSize: 14, color: Color(0xFF5E6D80)),
          ),
          const SizedBox(height: 22),
          for (int i = 0; i < bullets.length; i++) ...<Widget>[
            _FeatureRow(text: bullets[i]),
            if (i != bullets.length - 1) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5EE),
            borderRadius: BorderRadius.circular(9),
          ),
          child: const Icon(
            Icons.check_rounded,
            size: 17,
            color: _brandGreenIcon,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF3D4F62),
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

const Color _brandGreenIcon = Color(0xFF1B6B3A);

class _BrandColumn extends StatelessWidget {
  const _BrandColumn({
    required this.headlineText,
    required this.sublineText,
    required this.child,
  });

  final String headlineText;
  final String sublineText;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(
          child: Image.asset(
            'assets/f-logo.png',
            width: 120,
            fit: BoxFit.contain,
            semanticLabel: 'ResilientSteps Logo',
          ),
        ),
        const SizedBox(height: 10),
        Text(
          headlineText,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Color(0xFF142032),
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          sublineText,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Color(0xFF5E6D80)),
        ),
        const SizedBox(height: 14),
        child,
      ],
    );
  }
}
