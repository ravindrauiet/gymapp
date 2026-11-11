part of '../venue_editor_screen.dart';

// ---------------------------------------------------------------------------
// Step 6 — trainer, amenities, equipment (quick-add filtered by the selected categories / sports)
// ---------------------------------------------------------------------------
class _FacilitiesStep extends StatefulWidget {
  const _FacilitiesStep({required this.venue, required this.onChanged});

  final PartnerVenue venue;
  final VoidCallback onChanged;

  @override
  State<_FacilitiesStep> createState() => _FacilitiesStepState();
}

class _FacilitiesStepState extends State<_FacilitiesStep> {
  final _equipment = TextEditingController();

  void _addEquipment(String item) {
    final value = item.trim();
    if (value.isEmpty) return;
    if (value.length > 80) {
      toast(context, 'Keep each item under 80 characters', error: true);
      return;
    }
    if (!widget.venue.equipment.any((e) => e.toLowerCase() == value.toLowerCase())) {
      setState(() => widget.venue.equipment.add(value));
      widget.onChanged();
    }
    _equipment.clear();
  }

  @override
  void dispose() {
    _equipment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    final suggestions = equipmentSuggestions(v.categories, v.sports)
        .where((s) => !v.equipment.any((e) => e.toLowerCase() == s.toLowerCase()))
        .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('Facilities & features', 'Help members know what to expect.'),
        _SwitchCard(
          icon: Icons.sports_rounded,
          color: AppColors.teal,
          title: 'Trainer available',
          subtitle: 'A coach is on the floor to guide members',
          value: v.trainerAvailable,
          onChanged: (on) {
            setState(() => v.trainerAvailable = on);
            widget.onChanged();
          },
        ),
        const SectionTitle('Amenities', subtitle: 'Tap everything you offer'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: amenityLabels.entries.map((a) {
            final selected = v.amenities.contains(a.key);
            return Tap(
              onTap: () {
                setState(() => selected ? v.amenities.remove(a.key) : v.amenities.add(a.key));
                widget.onChanged();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: selected ? AppColors.primarySoft : AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: selected ? AppColors.primary : AppColors.line, width: selected ? 1.5 : 1),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(selected ? Icons.check_rounded : a.value.$2, size: 17, color: selected ? AppColors.primary : AppColors.text2),
                  const SizedBox(width: 6),
                  Text(a.value.$1,
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13, color: selected ? AppColors.primary : AppColors.text)),
                ]),
              ),
            );
          }).toList(),
        ),
        const SectionTitle('Equipment', subtitle: 'What members can use'),
        TextField(
          controller: _equipment,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: 'Add equipment, e.g. Leg press',
            prefixIcon: const Icon(Icons.fitness_center_rounded),
            suffixIcon: IconButton(
              icon: const Icon(Icons.add_circle_rounded, color: AppColors.primary),
              onPressed: () => _addEquipment(_equipment.text),
            ),
          ),
          onSubmitted: _addEquipment,
        ),
        if (v.equipment.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: v.equipment
                .map((e) => InputChip(
                      label: Text(e),
                      backgroundColor: AppColors.surfaceAlt,
                      side: BorderSide.none,
                      deleteIcon: const Icon(Icons.close_rounded, size: 16),
                      onDeleted: () {
                        setState(() => v.equipment.remove(e));
                        widget.onChanged();
                      },
                    ))
                .toList(),
          ),
        ],
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'QUICK ADD · ${v.categories.map((c) => venueVisual(c).label.toUpperCase()).join(' · ')}',
            style: _caps,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: suggestions
                .map((s) => ActionChip(
                      avatar: const Icon(Icons.add_rounded, size: 16, color: AppColors.primary),
                      label: Text(s),
                      onPressed: () => _addEquipment(s),
                    ))
                .toList(),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step 8 — slot length, capacity, FitKey-pass cap, courts / lanes, auto-accept
// ---------------------------------------------------------------------------
class _SlotsStep extends StatefulWidget {
  const _SlotsStep({
    required this.venue,
    required this.onChanged,
    required this.onPassCapCleared,
    required this.onPassCapSet,
  });

  final PartnerVenue venue;
  final VoidCallback onChanged;
  final VoidCallback onPassCapCleared;
  final VoidCallback onPassCapSet;

  @override
  State<_SlotsStep> createState() => _SlotsStepState();
}

class _SlotsStepState extends State<_SlotsStep> {
  late bool _passCap = widget.venue.passSlotCap != null;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    final sports = v.categories.contains('sports_club');
    final sport = v.sports.firstOrNull;
    final unit = sportUnit[sport] ?? ('court', 'courts');
    String mins(int m) => m < 60 ? '$m min' : (m % 60 == 0 ? '${m ~/ 60} hr' : '${m / 60} hr');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('Slots & capacity', 'How members book a time with you, and how many fit at once.'),
        const Text('SLOT LENGTH', style: _caps),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in slotLengths)
            ChoiceChip(
              label: Text(mins(m)),
              selected: v.slotMinutes == m,
              showCheckmark: false,
              selectedColor: AppColors.ink,
              labelStyle: TextStyle(fontWeight: FontWeight.w800, color: v.slotMinutes == m ? Colors.white : AppColors.text),
              onSelected: (_) {
                v.slotMinutes = m;
                _changed();
              },
            ),
        ]),
        const SizedBox(height: 20),
        _IntField(
          label: sports ? 'Players per ${unit.$1} per slot' : 'Max members per slot',
          hint: 'e.g. 20',
          icon: Icons.groups_rounded,
          value: v.slotCapacity,
          onChanged: (n) {
            v.slotCapacity = n ?? 0;
            _changed();
          },
        ),
        if (sports) ...[
          const SizedBox(height: 14),
          _IntField(
            label: 'Number of ${sport == null ? 'courts / lanes' : unit.$2}',
            hint: 'e.g. 3',
            icon: Icons.grid_view_rounded,
            max: 100,
            value: v.courts,
            onChanged: (n) {
              v.courts = n ?? 0;
              _changed();
            },
          ),
          if (v.courts > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(courtsLine(v.courts, sport, v.slotMinutes),
                  style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800)),
            ),
        ],
        const SizedBox(height: 16),
        _SwitchCard(
          icon: Icons.confirmation_number_rounded,
          color: AppColors.purple,
          title: 'Separate cap for FitKey pass users',
          subtitle: 'Keep room for your own members in busy slots',
          value: _passCap,
          onChanged: (on) {
            setState(() => _passCap = on);
            if (on) {
              v.passSlotCap ??= (v.slotCapacity / 2).ceil().clamp(1, 1000);
              widget.onPassCapSet();
            } else {
              v.passSlotCap = null;
              widget.onPassCapCleared();
            }
            _changed();
          },
        ),
        if (_passCap) ...[
          const SizedBox(height: 12),
          _IntField(
            key: ValueKey('cap-${v.passSlotCap == null}'),
            label: 'Max FitKey pass users per slot',
            icon: Icons.confirmation_number_outlined,
            value: v.passSlotCap,
            onChanged: (n) {
              v.passSlotCap = n;
              _changed();
            },
          ),
          if (v.passSlotCap != null && v.passSlotCap! > v.slotCapacity)
            const Padding(padding: EdgeInsets.only(top: 8), child: _ErrorLine('Can\'t be more than the slot capacity')),
        ],
        const SizedBox(height: 12),
        _SwitchCard(
          icon: Icons.bolt_rounded,
          color: AppColors.green,
          title: 'Auto-accept bookings',
          subtitle: v.autoAcceptBookings ? 'Members get instant confirmation' : 'You accept or reject each booking request',
          value: v.autoAcceptBookings,
          onChanged: (on) {
            v.autoAcceptBookings = on;
            _changed();
          },
        ),
        const SizedBox(height: 18),
        AppCard(
          color: AppColors.blueSoft,
          shadow: false,
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info_outline_rounded, color: AppColors.blue, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Each ${mins(v.slotMinutes)} slot: up to ${sports ? v.slotCapacity * (v.courts < 1 ? 1 : v.courts) : v.slotCapacity} '
                'members${_passCap && v.passSlotCap != null ? ', of which at most ${v.passSlotCap} on a FitKey pass' : ''}.',
                style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w600, height: 1.4),
              ),
            ),
          ]),
        ),
      ],
    );
  }
}
