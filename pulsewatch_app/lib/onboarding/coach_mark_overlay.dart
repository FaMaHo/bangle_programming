import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// One step of a [CoachMarkOverlay] walkthrough — a spotlight on
/// [targetKey]'s widget plus an explanatory tooltip.
class CoachMarkStep {
  final GlobalKey targetKey;
  final String title;
  final String description;

  const CoachMarkStep({
    required this.targetKey,
    required this.title,
    required this.description,
  });
}

/// Wraps [child] with a dismissible, step-by-step spotlight walkthrough —
/// a dimmed scrim with a cutout around each step's target widget in turn,
/// plus a tooltip bubble explaining it. Used for the one-time new-signup
/// walkthrough (see MainNavigation), but generic enough to reuse elsewhere.
class CoachMarkOverlay extends StatefulWidget {
  final List<CoachMarkStep> steps;
  final VoidCallback onFinished;
  final Widget child;

  const CoachMarkOverlay({
    super.key,
    required this.steps,
    required this.onFinished,
    required this.child,
  });

  @override
  State<CoachMarkOverlay> createState() => _CoachMarkOverlayState();
}

class _CoachMarkOverlayState extends State<CoachMarkOverlay> {
  int _step = 0;

  @override
  void initState() {
    super.initState();
    // The target widgets (inside widget.child) are laid out in this same
    // first frame, so their RenderBox geometry isn't valid yet during this
    // build. Scheduling one extra rebuild after the frame completes is
    // enough — from then on the targets are already laid out from the
    // previous frame by the time we read their geometry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _next() {
    if (_step >= widget.steps.length - 1) {
      widget.onFinished();
    } else {
      setState(() => _step++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_step];
    final targetBox = step.targetKey.currentContext?.findRenderObject() as RenderBox?;
    Rect? targetRect;
    if (targetBox != null && targetBox.attached) {
      final topLeft = targetBox.localToGlobal(Offset.zero);
      targetRect = (topLeft & targetBox.size).inflate(6);
    }

    return Stack(
      children: [
        widget.child,
        if (targetRect != null) ...[
          Positioned.fill(
            child: GestureDetector(
              onTap: _next,
              child: CustomPaint(painter: _SpotlightPainter(hole: targetRect)),
            ),
          ),
          _buildTooltip(context, targetRect, step),
        ],
      ],
    );
  }

  Widget _buildTooltip(BuildContext context, Rect targetRect, CoachMarkStep step) {
    final screenHeight = MediaQuery.of(context).size.height;
    final showBelow = targetRect.bottom + 170 < screenHeight;

    return Positioned(
      left: 24,
      right: 24,
      top: showBelow ? targetRect.bottom + 14 : null,
      bottom: showBelow ? null : (screenHeight - targetRect.top + 14),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                step.title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                step.description,
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_step + 1}/${widget.steps.length}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: widget.onFinished,
                        child: const Text('Skip', style: TextStyle(color: AppColors.textSecondary)),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: _next,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primaryGreen,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text(_step == widget.steps.length - 1 ? 'Got it' : 'Next'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  final Rect hole;

  _SpotlightPainter({required this.hole});

  @override
  void paint(Canvas canvas, Size size) {
    final full = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final holeRRect = RRect.fromRectAndRadius(hole, const Radius.circular(16));
    final holePath = Path()..addRRect(holeRRect);
    final scrim = Path.combine(PathOperation.difference, full, holePath);

    canvas.drawPath(scrim, Paint()..color = Colors.black.withOpacity(0.65));
    canvas.drawRRect(
      holeRRect,
      Paint()
        ..color = AppColors.primaryGreen
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) => oldDelegate.hole != hole;
}
