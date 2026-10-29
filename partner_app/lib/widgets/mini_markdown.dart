import 'package:flutter/material.dart';

import '../ui/ui.dart';

/// Renders the small Markdown subset Mansi uses: `### headings`, `- bullets`, `1. lists` and `**bold**`.
class MiniMarkdown extends StatelessWidget {
  const MiniMarkdown(this.text, {super.key, this.color = AppColors.text, this.fontSize = 14.5});

  final String text;
  final Color color;
  final double fontSize;

  static final _bullet = RegExp(r'^\s*[-*•]\s+');
  static final _numbered = RegExp(r'^\s*(\d+)[.)]\s+');
  static final _heading = RegExp(r'^\s*#{1,6}\s+');

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: fontSize, height: 1.5, color: color, fontWeight: FontWeight.w500);
    final blocks = <Widget>[];
    for (final raw in text.trim().split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        if (blocks.isNotEmpty) blocks.add(const SizedBox(height: 8));
        continue;
      }
      if (_heading.hasMatch(line)) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text.rich(_inline(line.replaceFirst(_heading, ''), base.copyWith(fontWeight: FontWeight.w800, fontSize: fontSize + 1))),
        ));
      } else if (_bullet.hasMatch(line) || _numbered.hasMatch(line)) {
        final n = _numbered.firstMatch(line)?.group(1);
        final body = line.replaceFirst(n == null ? _bullet : _numbered, '');
        final indent = raw.length - raw.trimLeft().length >= 2 ? 14.0 : 0.0;
        blocks.add(Padding(
          padding: EdgeInsets.only(left: indent, bottom: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 18,
              child: n == null
                  ? Padding(
                      padding: EdgeInsets.only(top: fontSize * 0.62),
                      child: Container(
                          width: 5, height: 5, decoration: const BoxDecoration(color: AppColors.purple, shape: BoxShape.circle)),
                    )
                  : Text('$n.', style: base.copyWith(fontWeight: FontWeight.w800, color: AppColors.purple)),
            ),
            Expanded(child: Text.rich(_inline(body, base))),
          ]),
        ));
      } else {
        blocks.add(Text.rich(_inline(line, base)));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: blocks);
  }

  TextSpan _inline(String s, TextStyle style) {
    final spans = <TextSpan>[];
    final parts = s.split('**');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      spans.add(TextSpan(text: parts[i], style: i.isOdd ? style.copyWith(fontWeight: FontWeight.w800) : null));
    }
    return TextSpan(style: style, children: spans);
  }
}
