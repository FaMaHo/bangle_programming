import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A gently pulsing heart in place of a bare spinner — used wherever a
/// screen's first load takes a noticeable moment (large local queries,
/// or a cold start after Android killed the process while backgrounded).
/// Purely reassurance: makes it obvious the app is working rather than
/// showing stale-looking placeholder numbers with nothing explaining why.
class LoadingState extends StatefulWidget {
  final String message;

  const LoadingState({super.key, this.message = 'Getting your data ready…'});

  @override
  State<LoadingState> createState() => _LoadingStateState();
}

class _LoadingStateState extends State<LoadingState> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Centered explicitly rather than relying on the parent: callers embed
    // this directly inside Columns with crossAxisAlignment.start (for their
    // real content once loaded), which would otherwise shrink-wrap this
    // widget to its content width and left-anchor it instead of centering
    // it on screen.
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 56),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: Tween<double>(begin: 0.85, end: 1.08).animate(
                CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
              ),
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: AppColors.primaryGreen.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.favorite_rounded, color: AppColors.primaryGreen, size: 28),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.message,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13.5),
            ),
          ],
        ),
      ),
    );
  }
}
