import 'package:flutter/material.dart';

import '../models/results.dart';
import '../theme.dart';

/// `1 rule` / `76 rules` — picks the right singular/plural form.
String counted(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// The tree from the app icon. Its background matches `TF.bg` (the title bar
/// color), so it blends in without a visible bounding box.
class TFLogo extends StatelessWidget {
  final double size;
  const TFLogo({super.key, this.size = 26});
  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/logo.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
      );
}

/// Title bar with the logo to the left of the title.
///
/// The logo sits in the title row, not in `leading`: sub-screens place the
/// back arrow there, and it would be displaced otherwise.
AppBar tfAppBar(String title, {List<Widget>? actions}) => AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const TFLogo(size: 24),
          const SizedBox(width: 10),
          Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
        ],
      ),
      actions: actions,
    );

/// Small uppercase section label.
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8, left: 2),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: TF.text2,
            fontSize: 11,
            letterSpacing: 3,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

/// Live progress panel bound to an [OpProgress] notifier.
class ProgressPanel extends StatelessWidget {
  final OpProgress progress;
  const ProgressPanel(this.progress, {super.key});

  @override
  Widget build(BuildContext context) {
    if (progress.status == 'idle') return const SizedBox.shrink();
    final color = progress.isError
        ? TF.danger
        : (progress.isDone ? TF.ok : TF.accent);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (progress.isRunning)
                  const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(progress.isError ? Icons.error_outline : Icons.check_circle,
                      size: 18, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    progress.message,
                    style: TextStyle(color: color, fontSize: 13),
                  ),
                ),
              ],
            ),
            if (progress.total > 0) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress.isDone ? 1.0 : progress.fraction,
                  minHeight: 6,
                  color: color,
                ),
              ),
              const SizedBox(height: 4),
              Text('${progress.current} / ${progress.total}',
                  style: const TextStyle(color: TF.text2, fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Big action button used on the dashboard.
class ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? color;

  const ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? TF.accent;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: c, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: TF.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(color: TF.text2, fontSize: 12)),
                  ],
                ),
              ),
              if (onTap != null)
                const Icon(Icons.chevron_right, color: TF.text2),
            ],
          ),
        ),
      ),
    );
  }
}

/// Simple empty-state placeholder.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const EmptyState({super.key, required this.icon, required this.message});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: TF.text2),
              const SizedBox(height: 14),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: TF.text2)),
            ],
          ),
        ),
      );
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? TF.danger : TF.surface2,
    ));
}
