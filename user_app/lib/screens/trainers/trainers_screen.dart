import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';
import 'trainer_detail_screen.dart';

/// 6. FitPro On-Demand (Book a Trainer)
class TrainersScreen extends StatefulWidget {
  const TrainersScreen({super.key});

  @override
  State<TrainersScreen> createState() => _TrainersScreenState();
}

class _TrainersScreenState extends State<TrainersScreen> {
  // Multi-select training modes
  final Set<String> _selectedModes = {'online', 'home', 'gym'};

  // Category filter
  String _selectedCategory = 'all';

  final List<String> _categories = const [
    'all',
    'Gym Training',
    'Yoga',
    'Dance/Zumba',
    'MMA/Boxing',
    'Weightlifting',
    'Swimming',
    'Judo/Karate',
    'Personal Rehab',
  ];

  late Future<List<Trainer>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final modesParam = _selectedModes.isEmpty ? null : _selectedModes.join(',');
    final catParam = _selectedCategory == 'all' ? null : _selectedCategory;
    _future = context.read<Session>().api.trainers(modes: modesParam, category: catParam);
  }

  void _reload() => setState(_load);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FitPro On-Demand'),
        actions: [
          IconButton(
            tooltip: 'My Booked Sessions',
            icon: const Icon(Icons.calendar_month),
            onPressed: () => _openMyBookings(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // Mode multi-selection row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: FkColors.surface,
            child: Row(children: [
              const Text('Modes:', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  children: [
                    _modeFilterChip('online', 'Online/Virtual'),
                    _modeFilterChip('home', 'At Home'),
                    _modeFilterChip('gym', 'At Gym'),
                  ],
                ),
              ),
            ]),
          ),

          // Categories horizontal scroll list
          SizedBox(
            height: 48,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              scrollDirection: Axis.horizontal,
              itemCount: _categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, idx) {
                final cat = _categories[idx];
                final isSelected = _selectedCategory == cat;
                return ChoiceChip(
                  label: Text(cat == 'all' ? 'All Specializations' : cat),
                  selected: isSelected,
                  selectedColor: FkColors.lime,
                  labelStyle: TextStyle(
                    color: isSelected ? Colors.black : Colors.white70,
                    fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                    fontSize: 12,
                  ),
                  onSelected: (val) {
                    if (val) {
                      _selectedCategory = cat;
                      _reload();
                    }
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),

          // Trainers Directory List
          Expanded(
            child: FutureBuilder<List<Trainer>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return ErrorState(message: errorMessage(snap.error!), onRetry: _reload);
                }

                final trainers = snap.data!;
                if (trainers.isEmpty) {
                  return const EmptyState(
                    icon: Icons.sports,
                    title: 'No trainers found',
                    message: 'Try clearing your category or mode filters.',
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: trainers.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, idx) {
                      final t = trainers[idx];
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => TrainerDetailScreen(trainerId: t.id)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 28,
                                      backgroundImage: t.photoUrl != null ? NetworkImage(t.photoUrl!) : null,
                                      backgroundColor: const Color(0xFF252B35),
                                      child: t.photoUrl == null ? const Icon(Icons.person) : null,
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(t.name,
                                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                          const SizedBox(height: 2),
                                          Row(children: [
                                            const Icon(Icons.star, color: Color(0xFFFFC145), size: 14),
                                            const SizedBox(width: 4),
                                            Text('${t.rating} · ${t.reviewCount} reviews',
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                            const Spacer(),
                                            Text(
                                              '${formatInr(t.hourlyRatePaise)}/hr',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w900, color: FkColors.lime, fontSize: 15),
                                            ),
                                          ]),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  t.bio,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: FkColors.textSecondary, fontSize: 13),
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: t.specializations
                                      .map((s) => Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF252B35),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(s,
                                                style: const TextStyle(
                                                    color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.bold)),
                                          ))
                                      .toList(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeFilterChip(String modeKey, String label) {
    final selected = _selectedModes.contains(modeKey);
    return FilterChip(
      label: Text(label),
      selected: selected,
      selectedColor: FkColors.sky.withValues(alpha: 0.2),
      checkmarkColor: FkColors.sky,
      labelStyle: TextStyle(
        fontSize: 11,
        color: selected ? FkColors.sky : Colors.white70,
        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
      ),
      onSelected: (val) {
        setState(() {
          if (val) {
            _selectedModes.add(modeKey);
          } else {
            if (_selectedModes.length > 1) {
              _selectedModes.remove(modeKey);
            }
          }
        });
        _reload();
      },
    );
  }

  void _openMyBookings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('My Trainer Bookings'),
            automaticallyImplyLeading: false,
            actions: [IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx))],
          ),
          body: FutureBuilder<List<TrainerBooking>>(
            future: context.read<Session>().api.myTrainerBookings(),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final bookings = snap.data ?? [];
              if (bookings.isEmpty) {
                return const EmptyState(
                  icon: Icons.calendar_today,
                  title: 'No sessions booked yet',
                  message: 'Book certified trainers for online, home, or gym workouts.',
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: bookings.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, idx) {
                  final b = bookings[idx];
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.person_pin, color: FkColors.lime, size: 30),
                      title: Text(b.trainerName, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                        'Date: ${b.sessionDate} at ${b.slotTime}\nMode: ${b.mode.toUpperCase()} · ${formatInr(b.amountPaise)}',
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
                          style: const TextStyle(color: FkColors.lime, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
