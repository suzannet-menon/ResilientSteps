import 'package:flutter/material.dart';

class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
    this.height = 60,
    this.borderRadius = 24,
    this.gradient = const LinearGradient(
      colors: <Color>[Color(0xFF2F6EF6), Color(0xFF5C98FF)],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    ),
    this.disabledGradient = const LinearGradient(
      colors: <Color>[Color(0xFFB7C6E5), Color(0xFFD3DDF0)],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    ),
    this.textStyle,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget? icon;
  final bool isLoading;
  final double height;
  final double borderRadius;
  final LinearGradient gradient;
  final LinearGradient disabledGradient;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null && !isLoading;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        gradient: enabled ? gradient : disabledGradient,
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: enabled
            ? <BoxShadow>[
                BoxShadow(
                  color: const Color(0xFF2F6EF6).withValues(alpha: 0.28),
                  blurRadius: 28,
                  offset: const Offset(0, 16),
                ),
              ]
            : const <BoxShadow>[],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(borderRadius),
          splashColor: Colors.white.withValues(alpha: 0.12),
          highlightColor: Colors.white.withValues(alpha: 0.08),
          child: SizedBox(
            height: height,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: isLoading
                    ? const SizedBox(
                        key: ValueKey<String>('loading'),
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    : Row(
                        key: ValueKey<String>(label),
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (icon != null) ...<Widget>[
                            icon!,
                            const SizedBox(width: 10),
                          ],
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  textStyle ??
                                  Theme.of(
                                    context,
                                  ).textTheme.titleMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.2,
                                  ),
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
}
