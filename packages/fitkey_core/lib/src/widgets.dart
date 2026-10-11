import 'package:flutter/material.dart';

import 'api_client.dart';
import 'categories.dart';
import 'config.dart';
import 'format.dart';
import 'theme.dart';

/// FITKEY wordmark: "F" monogram with a key notch.
class FitKeyLogo extends StatelessWidget {
  const FitKeyLogo({super.key, this.size = 40, this.showWordmark = true, this.tag});

  final double size;
  final bool showWordmark;

  /// Small label after the wordmark, e.g. "PARTNER".
  final String? tag;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: FkColors.lime, borderRadius: BorderRadius.circular(size * 0.28)),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text('F', style: TextStyle(fontSize: size * 0.62, fontWeight: FontWeight.w900, color: Colors.black, height: 1)),
              Positioned(
                right: size * 0.14,
                bottom: size * 0.14,
                child: Icon(Icons.key, size: size * 0.32, color: Colors.black),
              ),
            ],
          ),
        ),
        if (showWordmark) ...[
          SizedBox(width: size * 0.3),
          Text('FITKEY', style: TextStyle(fontSize: size * 0.55, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
          if (tag != null) ...[
            SizedBox(width: size * 0.2),
            Container(
              padding: EdgeInsets.symmetric(horizontal: size * 0.15, vertical: size * 0.04),
              decoration: BoxDecoration(
                border: Border.all(color: FkColors.lime),
                borderRadius: BorderRadius.circular(size * 0.15),
              ),
              child: Text(tag!,
                  style: TextStyle(
                      fontSize: size * 0.24, fontWeight: FontWeight.w800, color: FkColors.lime, letterSpacing: 1)),
            ),
          ],
        ],
      ],
    );
  }
}

/// Loads a future and renders loading / error (with retry) / data states.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.future, required this.builder, this.onRetry});

  final Future<T> future;
  final Widget Function(BuildContext context, T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return ErrorState(message: snap.error.toString(), onRetry: onRetry);
        }
        return builder(context, snap.data as T);
      },
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: FkColors.textSecondary),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: FkColors.textSecondary)),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(120, 44)),
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: FkColors.surfaceHigh, shape: BoxShape.circle),
              child: Icon(icon, size: 36, color: FkColors.lime),
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message!, textAlign: TextAlign.center, style: const TextStyle(color: FkColors.textSecondary)),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 12),
      child: Row(
        children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!, style: const TextStyle(color: FkColors.lime))),
        ],
      ),
    );
  }
}

class CategoryPill extends StatelessWidget {
  const CategoryPill(this.style, {super.key, this.dense = false});

  final CategoryStyle style;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: dense ? 12 : 14, color: style.color),
          const SizedBox(width: 4),
          Text(style.label,
              style: TextStyle(fontSize: dense ? 11 : 12, fontWeight: FontWeight.w600, color: style.color)),
        ],
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.radius = 22, this.color = FkColors.lime});

  final String? name;
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: color.withValues(alpha: 0.18),
      child: Text(initials(name),
          style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: radius * 0.7)),
    );
  }
}

/// Network image with a branded placeholder (for missing / failed photos).
class VenueImage extends StatelessWidget {
  const VenueImage({super.key, required this.url, this.category, this.height, this.borderRadius = 0});

  final String? url;
  final String? category;
  final double? height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final style = venueCategory(category ?? '');
    final placeholder = Container(
      height: height,
      color: style.color.withValues(alpha: 0.12),
      child: Center(child: Icon(style.icon, size: 40, color: style.color)),
    );
    final resolved = resolveMediaUrl(url);
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: resolved == null
          ? placeholder
          : Image.network(
              resolved,
              height: height,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
              loadingBuilder: (context, child, progress) => progress == null ? child : placeholder,
            ),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.icon, this.color = FkColors.lime});

  final String label;
  final String value;
  final IconData? icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) Icon(icon, color: color, size: 20),
            if (icon != null) const SizedBox(height: 10),
            Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12, color: FkColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? FkColors.danger : FkColors.surfaceHigh,
    ));
}

String errorMessage(Object e) => e is ApiException ? e.message : 'Something went wrong. Please try again.';
