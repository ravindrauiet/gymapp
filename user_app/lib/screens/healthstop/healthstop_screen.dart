import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';

/// 7. Homepage Modules: HealthStop Near You (Clinics & Chemists)
class HealthStopScreen extends StatefulWidget {
  const HealthStopScreen({super.key});

  @override
  State<HealthStopScreen> createState() => _HealthStopScreenState();
}

class _HealthStopScreenState extends State<HealthStopScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  late Future<List<HealthChemist>> _chemistFuture;
  late Future<List<HealthClinic>> _clinicFuture;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
  }

  void _loadData() {
    final api = context.read<Session>().api;
    _chemistFuture = api.healthChemists();
    _clinicFuture = api.healthClinics();
  }

  Future<void> _makeCall(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) showSnack(context, 'Unable to dial phone: $phone', error: true);
    }
  }

  Future<void> _openGoogleMaps(String name, String address, double? lat, double? lng) async {
    final Uri uri;
    if (lat != null && lng != null) {
      uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    } else {
      uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent('$name $address')}');
    }

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) showSnack(context, 'Unable to launch Google Maps', error: true);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HealthStop Near You'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.local_pharmacy), text: 'Chemist Directory'),
            Tab(icon: Icon(Icons.local_hospital), text: 'Clinic Directory'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildChemistsTab(),
          _buildClinicsTab(),
        ],
      ),
    );
  }

  // ============================================================================
  // Chemist Directory (Pharmacies)
  // ============================================================================
  Widget _buildChemistsTab() {
    return FutureBuilder<List<HealthChemist>>(
      future: _chemistFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return ErrorState(message: errorMessage(snap.error!), onRetry: () => setState(_loadData));
        }

        final chemists = snap.data!;
        if (chemists.isEmpty) {
          return const EmptyState(
            icon: Icons.local_pharmacy_outlined,
            title: 'No pharmacies nearby',
            message: 'No chemists listed in this area yet.',
          );
        }

        return RefreshIndicator(
          onRefresh: () async => setState(_loadData),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: chemists.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, idx) {
              final c = chemists[idx];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: FkColors.sky.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(children: [
                            const Icon(Icons.near_me, size: 12, color: FkColors.sky),
                            const SizedBox(width: 4),
                            Text('${c.distanceKm} km away',
                                style: const TextStyle(color: FkColors.sky, fontSize: 11, fontWeight: FontWeight.bold)),
                          ]),
                        ),
                      ]),
                      const SizedBox(height: 6),
                      Text(c.address, style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
                      const SizedBox(height: 10),
                      Row(children: [
                        const Icon(Icons.access_time, size: 14, color: FkColors.orange),
                        const SizedBox(width: 6),
                        Text(c.operationalHours,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: FkColors.orange)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.deliveryAvailable ? FkColors.lime.withValues(alpha: 0.15) : Colors.white10,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            c.deliveryAvailable ? '✓ ${c.deliveryTimeEst}' : 'Store Pickup Only',
                            style: TextStyle(
                              color: c.deliveryAvailable ? FkColors.lime : FkColors.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ]),
                      const Divider(height: 24),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.directions, color: FkColors.sky, size: 18),
                            label: const Text('Directions', style: TextStyle(color: FkColors.sky)),
                            onPressed: () => _openGoogleMaps(c.name, c.address, c.latitude, c.longitude),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.phone, size: 18),
                            label: const Text('Emergency Call'),
                            onPressed: () => _makeCall(c.phone),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  // ============================================================================
  // Clinic Directory (Medical Clinics)
  // ============================================================================
  Widget _buildClinicsTab() {
    return FutureBuilder<List<HealthClinic>>(
      future: _clinicFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return ErrorState(message: errorMessage(snap.error!), onRetry: () => setState(_loadData));
        }

        final clinics = snap.data!;
        if (clinics.isEmpty) {
          return const EmptyState(
            icon: Icons.local_hospital_outlined,
            title: 'No clinics nearby',
            message: 'No medical clinics listed in this area yet.',
          );
        }

        return RefreshIndicator(
          onRefresh: () async => setState(_loadData),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: clinics.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, idx) {
              final cl = clinics[idx];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(cl.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: FkColors.lime.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('${cl.distanceKm} km',
                              style: const TextStyle(color: FkColors.lime, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Text(cl.address, style: const TextStyle(color: FkColors.textSecondary, fontSize: 13)),
                      const SizedBox(height: 12),

                      // Doctors & Qualifications
                      const Text('Listed Doctors & Qualifications',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      const SizedBox(height: 4),
                      ...cl.doctors.map((doc) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.person, size: 16, color: FkColors.sky),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '${doc.name} · ${doc.degree} (${doc.specialty})',
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          )),
                      const SizedBox(height: 10),

                      // Available Facilities & Equipment
                      const Text('Available Facilities & Specialized Equipment',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: cl.facilities
                            .map((f) => Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF252B35),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(f,
                                      style: const TextStyle(
                                          color: FkColors.textSecondary, fontSize: 11, fontWeight: FontWeight.bold)),
                                ))
                            .toList(),
                      ),
                      const SizedBox(height: 12),

                      // Slot Timings & Fee
                      Row(children: [
                        const Icon(Icons.schedule, size: 14, color: FkColors.orange),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(cl.slotTimings,
                              style: const TextStyle(fontSize: 12, color: FkColors.orange, fontWeight: FontWeight.w600)),
                        ),
                        Text('Fee: ${formatInr(cl.consultationFeePaise)}',
                            style: const TextStyle(fontWeight: FontWeight.w900, color: FkColors.lime, fontSize: 13)),
                      ]),
                      const Divider(height: 24),

                      // Direct Call & Maps
                      Row(children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.directions, color: FkColors.sky, size: 18),
                            label: const Text('Directions', style: TextStyle(color: FkColors.sky)),
                            onPressed: () => _openGoogleMaps(cl.name, cl.address, cl.latitude, cl.longitude),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.call, size: 18),
                            label: const Text('Direct Call'),
                            onPressed: () => _makeCall(cl.phone),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
