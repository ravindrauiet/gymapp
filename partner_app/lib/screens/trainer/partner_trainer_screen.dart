import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/partner_session.dart';

/// 6.2 Merchant Scope (FITKEY Partner App - Trainer Module)
class PartnerTrainerScreen extends StatefulWidget {
  const PartnerTrainerScreen({super.key});

  @override
  State<PartnerTrainerScreen> createState() => _PartnerTrainerScreenState();
}

class _PartnerTrainerScreenState extends State<PartnerTrainerScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late Future<({PartnerTrainerProfile? profile, List<TrainerBookingItem> bookings})> _future;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _load();
  }

  void _load() {
    final api = context.read<PartnerSession>().api;
    _future = Future.wait([
      api.trainerProfile(),
      api.trainerBookings(),
    ]).then((results) => (
          profile: results[0] as PartnerTrainerProfile?,
          bookings: results[1] as List<TrainerBookingItem>,
        ));
  }

  void _reload() => setState(_load);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FitPro Trainer Management'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.tune), text: 'Profile & Slots Control'),
            Tab(icon: Icon(Icons.event_available), text: 'Booked Sessions'),
          ],
        ),
      ),
      body: FutureBuilder<({PartnerTrainerProfile? profile, List<TrainerBookingItem> bookings})>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ErrorState(message: errorMessage(snap.error!), onRetry: _reload);
          }

          final data = snap.data!;
          return TabBarView(
            controller: _tabController,
            children: [
              _TrainerSettingsTab(
                initialProfile: data.profile,
                onSaved: _reload,
              ),
              _TrainerBookingsTab(bookings: data.bookings, onReload: _reload),
            ],
          );
        },
      ),
    );
  }
}

class _TrainerSettingsTab extends StatefulWidget {
  const _TrainerSettingsTab({required this.initialProfile, required this.onSaved});

  final PartnerTrainerProfile? initialProfile;
  final VoidCallback onSaved;

  @override
  State<_TrainerSettingsTab> createState() => _TrainerSettingsTabState();
}

class _TrainerSettingsTabState extends State<_TrainerSettingsTab> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _bio;
  late final TextEditingController _hourlyRate;
  late final TextEditingController _bufferMinutes;
  late final TextEditingController _certifications;

  final Set<String> _specializations = {'Gym Training', 'Weightlifting'};
  final Set<String> _modes = {'online', 'home', 'gym'};
  bool _saving = false;

  final List<String> _availableSpecs = const [
    'Gym Training',
    'Yoga',
    'Dance/Zumba',
    'MMA/Boxing',
    'Weightlifting',
    'Swimming',
    'Judo/Karate',
    'Personal Rehab',
  ];

  @override
  void initState() {
    super.initState();
    final p = widget.initialProfile;
    _name = TextEditingController(text: p?.name ?? 'Coach Vikram');
    _bio = TextEditingController(
      text: p?.bio ??
          'Certified strength and conditioning coach with 8+ years experience guiding clients toward peak hypertrophy and safe compound lifting.',
    );
    _hourlyRate = TextEditingController(text: p != null ? (p.hourlyRatePaise / 100).round().toString() : '1200');
    _bufferMinutes = TextEditingController(text: p?.bufferMinutes.toString() ?? '30');
    _certifications = TextEditingController(
      text: p != null ? p.certifications.join(', ') : 'ACSM Certified Personal Trainer, CSCS Specialist',
    );

    if (p != null && p.specializations.isNotEmpty) {
      _specializations.clear();
      _specializations.addAll(p.specializations);
    }
    if (p != null && p.trainingModes.isNotEmpty) {
      _modes.clear();
      _modes.addAll(p.trainingModes);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _hourlyRate.dispose();
    _bufferMinutes.dispose();
    _certifications.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_specializations.isEmpty) {
      showSnack(context, 'Select at least one specialization', error: true);
      return;
    }
    if (_modes.isEmpty) {
      showSnack(context, 'Select at least one training mode', error: true);
      return;
    }

    setState(() => _saving = true);
    try {
      final certsList = _certifications.text
          .split(',')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .toList();

      final ratePaise = (int.tryParse(_hourlyRate.text) ?? 1200) * 100;
      final buffer = int.tryParse(_bufferMinutes.text) ?? 30;

      await context.read<PartnerSession>().api.saveTrainerProfile({
        'name': _name.text.trim(),
        'bio': _bio.text.trim(),
        'certifications': certsList,
        'specializations': _specializations.toList(),
        'trainingModes': _modes.toList(),
        'hourlyRatePaise': ratePaise,
        'bufferMinutes': buffer,
        'workingHours': {'start': '06:00', 'end': '21:00'},
      });

      widget.onSaved();
      if (mounted) showSnack(context, 'Trainer profile, verification tags & pricing updated!');
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Verification status banner
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: FkColors.lime.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: FkColors.lime.withValues(alpha: 0.4)),
            ),
            child: const Row(children: [
              Icon(Icons.verified, color: FkColors.lime, size: 22),
              SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Trainer Verification: VERIFIED',
                      style: TextStyle(fontWeight: FontWeight.w800, color: FkColors.lime, fontSize: 13)),
                  SizedBox(height: 2),
                  Text('Background check complete. Profile active for on-demand bookings.',
                      style: TextStyle(color: FkColors.textSecondary, fontSize: 11)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Trainer Full Name'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Enter trainer name' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _bio,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Professional Bio & Experience'),
            validator: (v) => (v ?? '').trim().length < 10 ? 'Enter detailed bio' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _certifications,
            decoration: const InputDecoration(
              labelText: 'Certifications (comma-separated)',
              hintText: 'e.g. ACSM, CSCS, ACE, Yoga Alliance RYT 500',
            ),
          ),
          const SizedBox(height: 20),

          // Specialization Tagging
          const Text('Specialization Tagging (Category Filter)', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _availableSpecs.map((s) {
              final selected = _specializations.contains(s);
              return FilterChip(
                label: Text(s),
                selected: selected,
                selectedColor: FkColors.lime.withValues(alpha: 0.2),
                checkmarkColor: FkColors.lime,
                labelStyle: TextStyle(
                  color: selected ? FkColors.lime : Colors.white70,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 12,
                ),
                onSelected: (val) {
                  setState(() {
                    if (val) {
                      _specializations.add(s);
                    } else {
                      _specializations.remove(s);
                    }
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 20),

          // Training Modes
          const Text('Supported Training Modes', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('Online / Virtual'),
                selected: _modes.contains('online'),
                onSelected: (val) => setState(() => val ? _modes.add('online') : _modes.remove('online')),
              ),
              FilterChip(
                label: const Text('At Client Place / Home'),
                selected: _modes.contains('home'),
                onSelected: (val) => setState(() => val ? _modes.add('home') : _modes.remove('home')),
              ),
              FilterChip(
                label: const Text('At Partner Gym'),
                selected: _modes.contains('gym'),
                onSelected: (val) => setState(() => val ? _modes.add('gym') : _modes.remove('gym')),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Pricing & Buffer Control
          const SectionHeader('Slot & Pricing Control'),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _hourlyRate,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Hourly Rate (₹)', prefixText: '₹'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Enter rate' : null,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: TextFormField(
                controller: _bufferMinutes,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Home Visit Buffer',
                  suffixText: 'mins',
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Enter buffer' : null,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          const Text(
            'Buffer zone allows travel and prep time between consecutive offline appointments.',
            style: TextStyle(color: FkColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 28),

          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('Save Trainer Settings'),
          ),
        ],
      ),
    );
  }
}

class _TrainerBookingsTab extends StatelessWidget {
  const _TrainerBookingsTab({required this.bookings, required this.onReload});

  final List<TrainerBookingItem> bookings;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    if (bookings.isEmpty) {
      return const EmptyState(
        icon: Icons.event_busy,
        title: 'No member sessions booked',
        message: 'Bookings scheduled by FITKEY members will appear here with contact details.',
      );
    }

    return RefreshIndicator(
      onRefresh: () async => onReload(),
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: bookings.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, idx) {
          final b = bookings[idx];
          return Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: FkColors.lime,
                foregroundColor: Colors.black,
                child: Icon(Icons.fitness_center),
              ),
              title: Text(b.memberName, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(
                'Phone: ${b.memberPhone}\nDate: ${b.sessionDate} at ${b.slotTime}\nMode: ${b.mode.toUpperCase()} · Fee: ${formatInr(b.amountPaise)}',
              ),
              isThreeLine: true,
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: FkColors.lime.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  b.status.toUpperCase(),
                  style: const TextStyle(color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
