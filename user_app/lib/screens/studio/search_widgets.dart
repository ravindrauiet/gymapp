import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/ui.dart';

/// Runs [action] once the user has paused typing for [delay].
class Debouncer {
  Debouncer([this.delay = const Duration(milliseconds: 350)]);

  final Duration delay;
  Timer? _timer;

  void call(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void cancel() => _timer?.cancel();
}

/// "Recent searches" row shown below a search bar while it is empty.
class RecentSearchRow extends StatelessWidget {
  const RecentSearchRow({super.key, required this.recents, required this.onTap, required this.onClear, this.padding});

  final List<String> recents;
  final ValueChanged<String> onTap;
  final VoidCallback onClear;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    if (recents.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding ?? const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.history_rounded, size: 16, color: AppColors.text3),
          const SizedBox(width: 6),
          const Expanded(
            child: Text('Recent searches',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.text2)),
          ),
          GestureDetector(
            onTap: onClear,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Text('Clear',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: AppColors.primary)),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: recents.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) => Tap(
              onTap: () => onTap(recents[i]),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.north_west_rounded, size: 13, color: AppColors.text3),
                  const SizedBox(width: 6),
                  Text(recents[i], style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Wrap of tappable suggestion chips (used in "No results" states).
class SuggestionChips extends StatelessWidget {
  const SuggestionChips({super.key, required this.items, required this.onTap, this.label, this.icon});

  final List<String> items;
  final ValueChanged<String> onTap;
  final String Function(String)? label;
  final IconData? Function(String)? icon;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in items)
          Tap(
            onTap: () => onTap(s),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon?.call(s) case final ic?) ...[Icon(ic, size: 15, color: AppColors.primary), const SizedBox(width: 6)],
                Text(label?.call(s) ?? s, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
      ],
    );
  }
}
