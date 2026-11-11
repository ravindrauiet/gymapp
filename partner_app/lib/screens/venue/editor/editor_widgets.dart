part of '../venue_editor_screen.dart';

/// "Step 4 of 10 · Timings & access" + a progress bar of 10 tappable segments (done steps in green).
class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.titles, required this.step, required this.done, required this.onTap});

  final List<String> titles;
  final int step;
  final Set<int> done;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Step ${step + 1} of ${titles.length}',
              style: const TextStyle(color: AppColors.primary, fontSize: 12.5, fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Expanded(
            child: Text('· ${titles[step]}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
          Text('${done.length}/${titles.length - 1} done',
              style: const TextStyle(color: AppColors.text3, fontSize: 11.5, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          for (var i = 0; i < titles.length; i++)
            Expanded(
              child: Tooltip(
                message: '${i + 1}. ${titles[i]}',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(i),
                  child: Padding(
                    padding: EdgeInsets.only(right: i == titles.length - 1 ? 0 : 3, top: 6, bottom: 6),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      height: i == step ? 6 : 5,
                      decoration: BoxDecoration(
                        color: i == step
                            ? AppColors.primary
                            : (done.contains(i) ? AppColors.green : (i < step ? AppColors.primary.withValues(alpha: 0.35) : AppColors.line)),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}

class _StepIntro extends StatelessWidget {
  const _StepIntro(this.title, this.subtitle);

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18, top: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        const SizedBox(height: 6),
        Text(subtitle, style: const TextStyle(color: AppColors.text2, height: 1.4)),
      ]),
    );
  }
}

class _SheetOption extends StatelessWidget {
  const _SheetOption({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      border: true,
      shadow: false,
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        IconBubble(icon, size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(subtitle, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
      ]),
    );
  }
}

/// Placeholder for steps that need a saved venue (documents) before anything is on the server.
class _NeedsDraft extends StatelessWidget {
  const _NeedsDraft({required this.message, required this.onSave});
  final String message;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return EmptyView(
      icon: Icons.save_outlined,
      title: 'Save your draft first',
      message: message,
      action: OutlinedButton.icon(onPressed: onSave, icon: const Icon(Icons.save_outlined), label: const Text('Save draft')),
    );
  }
}

/// Card with a title, subtitle and a trailing switch.
class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      onTap: () => onChanged(!value),
      child: Row(children: [
        IconBubble(icon, color: color, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.3)),
          ]),
        ),
        Switch(value: value, onChanged: onChanged),
      ]),
    );
  }
}

/// Opens the time picker on an `HH:MM` value; returns the new `HH:MM` or null.
Future<String?> _pickTime(BuildContext context, String current, {String? help}) async {
  final mins = toMinutes(current);
  final t = await showTimePicker(
    context: context,
    initialTime: mins < 0 ? const TimeOfDay(hour: 9, minute: 0) : TimeOfDay(hour: mins ~/ 60, minute: mins % 60),
    helpText: help,
  );
  if (t == null) return null;
  return fromMinutes(t.hour * 60 + t.minute);
}

/// Compact "6:00 AM → 10:00 PM" range with tappable ends.
class _RangeTile extends StatelessWidget {
  const _RangeTile({required this.start, required this.end, required this.onStart, required this.onEnd, this.onRemove, this.error = false});

  final String start;
  final String end;
  final VoidCallback onStart;
  final VoidCallback onEnd;
  final VoidCallback? onRemove;
  final bool error;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, String value, VoidCallback onTap) => Expanded(
          child: Tap(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: error ? AppColors.red : AppColors.line, width: error ? 1.5 : 1),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontSize: 10.5, color: AppColors.text3, fontWeight: FontWeight.w700)),
                Text(prettyTime(value), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        );
    return Row(children: [
      chip('FROM', start, onStart),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.arrow_forward_rounded, size: 16, color: AppColors.text3),
      ),
      chip('TO', end, onEnd),
      if (onRemove != null)
        IconButton(
          tooltip: 'Remove',
          onPressed: onRemove,
          icon: const Icon(Icons.remove_circle_outline_rounded, color: AppColors.red),
        ),
    ]);
  }
}

/// Seven round M T W T F S S toggles.
class _DayToggles extends StatelessWidget {
  const _DayToggles({required this.selected, required this.onToggle, this.dense = false});

  final List<String> selected;
  final ValueChanged<String> onToggle;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (final d in weekdays) ...[
        Expanded(
          child: Tap(
            onTap: () => onToggle(d),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: dense ? 38 : 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected.contains(d) ? AppColors.primary : AppColors.surface,
                borderRadius: BorderRadius.circular(dense ? 10 : 14),
                border: Border.all(color: selected.contains(d) ? AppColors.primary : AppColors.line),
              ),
              child: Text(weekdayShort[d]!.substring(0, dense ? 1 : 2),
                  style: TextStyle(
                      fontWeight: FontWeight.w800, color: selected.contains(d) ? Colors.white : AppColors.text2)),
            ),
          ),
        ),
        if (d != 'sun') SizedBox(width: dense ? 4 : 6),
      ],
    ]);
  }
}

/// Small integer field (slot capacity, courts, visit limits).
class _IntField extends StatefulWidget {
  const _IntField({super.key, required this.label, required this.value, required this.onChanged, this.hint, this.icon, this.max = 1000});

  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;
  final String? hint;
  final IconData? icon;
  final int max;

  @override
  State<_IntField> createState() => _IntFieldState();
}

class _IntFieldState extends State<_IntField> {
  late final _c = TextEditingController(text: widget.value?.toString() ?? '');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(widget.max.toString().length)],
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        prefixIcon: widget.icon == null ? null : Icon(widget.icon),
      ),
      onChanged: (s) {
        final v = int.tryParse(s);
        widget.onChanged(v?.clamp(0, widget.max));
      },
    );
  }
}
