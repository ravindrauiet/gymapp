import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';

/// 6.1 Trainer Directory & Booking: Listing with rating, bio, certifications,
/// hourly rate, dynamic slot picker, and 1-tap checkout.
class TrainerDetailScreen extends StatefulWidget {
  const TrainerDetailScreen({super.key, required this.trainerId});

  final String trainerId;

  @override
  State<TrainerDetailScreen> createState() => _TrainerDetailScreenState();
}

class _TrainerDetailScreenState extends State<TrainerDetailScreen> {
  late Future<({Trainer trainer, List<String> availableSlots})> _future;

  String _selectedMode = 'online';
  DateTime _selectedDate = DateTime.now().add(const Duration(days: 1));
  String? _selectedSlot;
  bool _booking = false;

  @override
  void initState() {
    super.initState();
    _future = context.read<Session>().api.trainer(widget.trainerId);
  }

  Future<void> _book(Trainer trainer) async {
    if (_selectedSlot == null) {
      showSnack(context, 'Please pick a time slot for your session', error: true);
      return;
    }

    setState(() => _booking = true);
    try {
      final dateStr = '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
      await context.read<Session>().api.bookTrainer(
            trainerId: trainer.id,
            mode: _selectedMode,
            sessionDate: dateStr,
            slotTime: _selectedSlot!,
          );

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(children: [
              Icon(Icons.check_circle, color: FkColors.lime),
              SizedBox(width: 8),
              Text('Session Confirmed!'),
            ]),
            content: Text(
              'Your $_selectedMode session with ${trainer.name} is scheduled for $dateStr at $_selectedSlot.\n\n'
              'Total paid: ${formatInr(trainer.hourlyRatePaise)}',
              style: const TextStyle(height: 1.4),
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                },
                child: const Text('Great!'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Book Certified Trainer'),
      ),
      body: FutureBuilder<({Trainer trainer, List<String> availableSlots})>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ErrorState(message: errorMessage(snap.error!), onRetry: () => setState(() {}));
          }

          final trainer = snap.data!.trainer;
          final slots = snap.data!.availableSlots;
          _selectedSlot ??= slots.first;

          final modes = trainer.trainingModes.isNotEmpty ? trainer.trainingModes : ['online', 'home', 'gym'];
          if (!modes.contains(_selectedMode)) _selectedMode = modes.first;

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              // Trainer Header Card
              Row(children: [
                CircleAvatar(
                  radius: 38,
                  backgroundImage: trainer.photoUrl != null ? NetworkImage(trainer.photoUrl!) : null,
                  backgroundColor: const Color(0xFF252B35),
                  child: trainer.photoUrl == null ? const Icon(Icons.person, size: 40) : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(trainer.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.star, color: Color(0xFFFFC145), size: 16),
                      const SizedBox(width: 4),
                      Text('${trainer.rating} (${trainer.reviewCount} reviews)',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ]),
                    const SizedBox(height: 4),
                    Text('${formatInr(trainer.hourlyRatePaise)} / hour session',
                        style: const TextStyle(color: FkColors.lime, fontWeight: FontWeight.w800, fontSize: 15)),
                  ]),
                ),
              ]),
              const SizedBox(height: 20),

              // Specialization Badges
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: trainer.specializations
                    .map((s) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: FkColors.lime.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: FkColors.lime.withValues(alpha: 0.4)),
                          ),
                          child: Text(s, style: const TextStyle(color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.w700)),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 16),

              // Bio
              const SectionHeader('About Trainer'),
              Text(trainer.bio, style: const TextStyle(color: FkColors.textSecondary, height: 1.4, fontSize: 14)),
              const SizedBox(height: 16),

              // Certifications
              const SectionHeader('Certifications & Credentials'),
              ...trainer.certifications.map((c) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      const Icon(Icons.verified, size: 16, color: FkColors.sky),
                      const SizedBox(width: 8),
                      Expanded(child: Text(c, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                    ]),
                  )),
              const SizedBox(height: 20),

              // Training Mode Selection
              const SectionHeader('Training Mode'),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: modes.map((m) => ButtonSegment(
                  value: m,
                  label: Text(m == 'online'
                      ? 'Online / Virtual'
                      : m == 'home'
                          ? 'At Your Place'
                          : 'At Partner Gym'),
                )).toList(),
                selected: {_selectedMode},
                onSelectionChanged: (s) => setState(() => _selectedMode = s.first),
              ),
              const SizedBox(height: 20),

              // Date Picker
              const SectionHeader('Select Date'),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(formatDayDate(_selectedDate)),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _selectedDate,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 30)),
                      );
                      if (picked != null) setState(() => _selectedDate = picked);
                    },
                  ),
                ),
              ]),
              const SizedBox(height: 20),

              // Dynamic Slot Picker
              const SectionHeader('Available Time Slots'),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: slots.map((s) {
                  final isSelected = _selectedSlot == s;
                  return ChoiceChip(
                    label: Text(s),
                    selected: isSelected,
                    selectedColor: FkColors.lime,
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.black : Colors.white,
                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                    ),
                    onSelected: (val) {
                      if (val) setState(() => _selectedSlot = s);
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 32),

              // 1-Tap Checkout Button
              FilledButton(
                onPressed: _booking ? null : () => _book(trainer),
                child: _booking
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : Text('1-Tap Checkout · Book for ${formatInr(trainer.hourlyRatePaise)}'),
              ),
            ],
          );
        },
      ),
    );
  }
}
