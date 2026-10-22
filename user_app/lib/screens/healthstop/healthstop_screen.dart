import 'package:fitkey_core/fitkey_core.dart' show formatPaise;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';

/// A directory result plus whether we had to widen the search beyond the member's city.
typedef _Listing<T> = ({List<T> items, bool widened});

/// HealthStop near you — nearby chemists and sports-medicine / family clinics.
class HealthStopScreen extends StatefulWidget {
  const HealthStopScreen({super.key});

  @override
  State<HealthStopScreen> createState() => _HealthStopScreenState();
}

class _HealthStopScreenState extends State<HealthStopScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  String? _userCity;
  String? _city; // null = all cities

  late Future<_Listing<HealthChemist>> _chemists;
  late Future<_Listing<HealthClinic>> _clinics;

  @override
  void initState() {
    super.initState();
    final c = context.read<Session>().user?.city?.trim();
    _userCity = (c == null || c.isEmpty) ? null : c;
    _city = _userCity;
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _load() {
    final api = context.read<Session>().api;
    _chemists = _withFallback((city) => api.healthChemists(city: city));
    _clinics = _withFallback((city) => api.healthClinics(city: city));
  }

  /// Queries the selected city; if nothing is listed there yet, shows every city instead.
  Future<_Listing<T>> _withFallback<T>(Future<List<T>> Function(String? city) fetch) async {
    final city = _city;
    final items = await fetch(city);
    if (items.isNotEmpty || city == null) return (items: items, widened: false);
    return (items: await fetch(null), widened: true);
  }

  Future<void> _refresh() async {
    setState(_load);
    await Future.wait([_chemists, _clinics].map((f) => f.then((_) {}, onError: (_) {})));
  }

  void _setCity(String? city) {
    if (city == _city) return;
    _city = city;
    setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('HealthStop near you')),
      body: Column(
        children: [
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Column(
              children: [
                _Segmented(controller: _tabs),
                if (_userCity != null) ...[
                  const SizedBox(height: 12),
                  ChoiceChips<String?>(
                    padding: EdgeInsets.zero,
                    options: [_userCity, null],
                    selected: _city,
                    label: (c) => c ?? 'All cities',
                    icon: (c) => c == null ? Icons.public_rounded : Icons.location_on_rounded,
                    onSelected: _setCity,
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _DirectoryList<HealthChemist>(
                  future: _chemists,
                  city: _city,
                  onRefresh: _refresh,
                  banner: const PhotoBanner(
                    image: AppImages.supplements,
                    eyebrow: 'Chemists',
                    title: 'Medicines from pharmacies near you',
                    subtitle: 'Call ahead to check stock, or get directions.',
                    height: 140,
                  ),
                  empty: const ('No chemists listed yet', Icons.local_pharmacy_rounded),
                  itemBuilder: (c) => _ChemistCard(chemist: c),
                ),
                _DirectoryList<HealthClinic>(
                  future: _clinics,
                  city: _city,
                  onRefresh: _refresh,
                  banner: const PhotoBanner(
                    image: AppImages.running,
                    eyebrow: 'Clinics',
                    title: 'Sports medicine & physio care',
                    subtitle: 'Doctors, facilities and consultation fees at a glance.',
                    height: 140,
                  ),
                  empty: const ('No clinics listed yet', Icons.local_hospital_rounded),
                  itemBuilder: (c) => _ClinicCard(clinic: c),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill-style segmented control bound to a [TabController].
class _Segmented extends StatelessWidget {
  const _Segmented({required this.controller});
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
      child: TabBar(
        controller: controller,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        indicator: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(11),
          boxShadow: AppShadows.soft,
        ),
        labelColor: AppColors.text,
        unselectedLabelColor: AppColors.text2,
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        tabs: const [
          Tab(
            height: 38,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.local_pharmacy_rounded, size: 18, color: AppColors.green),
                SizedBox(width: 6),
                Text('Chemists'),
              ],
            ),
          ),
          Tab(
            height: 38,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.local_hospital_rounded, size: 18, color: AppColors.red),
                SizedBox(width: 6),
                Text('Clinics'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DirectoryList<T> extends StatelessWidget {
  const _DirectoryList({
    required this.future,
    required this.city,
    required this.onRefresh,
    required this.banner,
    required this.empty,
    required this.itemBuilder,
  });

  final Future<_Listing<T>> future;
  final String? city;
  final Future<void> Function() onRefresh;
  final Widget banner;
  final (String, IconData) empty;
  final Widget Function(T) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: onRefresh,
      child: FutureBuilder<_Listing<T>>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const SkeletonList(itemHeight: 88);
          if (snap.hasError) return _fill(ErrorView(error: snap.error!, onRetry: onRefresh));
          final data = snap.data!;
          if (data.items.isEmpty) {
            return _fill(
              EmptyView(
                icon: empty.$2,
                color: AppColors.teal,
                title: empty.$1,
                message: "We're onboarding partners in your area. Pull down to check again.",
                action: SizedBox(
                  width: 160,
                  child: OutlinedButton.icon(
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Refresh'),
                  ),
                ),
              ),
            );
          }
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              banner,
              if (data.widened && city != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.amberSoft, borderRadius: BorderRadius.circular(14)),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.amber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Nothing listed in $city yet — showing all cities.',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.text),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              SectionTitle(
                '${data.items.length} near you',
                subtitle: data.widened || city == null
                    ? 'Across all cities · nearest first'
                    : 'In $city · nearest first',
                padding: const EdgeInsets.fromLTRB(0, 22, 0, 12),
              ),
              for (final item in data.items) ...[itemBuilder(item), const SizedBox(height: 12)],
            ],
          );
        },
      ),
    );
  }

  Widget _fill(Widget child) => LayoutBuilder(
    builder: (context, c) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: c.maxHeight),
        child: child,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Actions — only things that really work: dial the number, open Google Maps.
// ---------------------------------------------------------------------------

Future<void> _call(BuildContext context, String phone) async {
  final number = phone.replaceAll(RegExp(r'[^\d+]'), '');
  final ok = number.isNotEmpty && await _launch(Uri(scheme: 'tel', path: number));
  if (!ok && context.mounted) toast(context, "Couldn't open the dialer. Call $phone", error: true);
}

Future<void> _directions(BuildContext context, String name, String address, double? lat, double? lng) async {
  final dest = (lat != null && lng != null) ? '$lat,$lng' : '$name, $address';
  final uri = Uri.https('www.google.com', '/maps/dir/', {'api': '1', 'destination': dest});
  final ok = await _launch(uri, external: true);
  if (!ok && context.mounted) toast(context, "Couldn't open maps on this device", error: true);
}

/// Launches directly: `canLaunchUrl` reports false on Android 11+ unless the
/// scheme is declared in the manifest's `<queries>`, even though launching works.
Future<bool> _launch(Uri uri, {bool external = false}) async {
  try {
    return await launchUrl(uri, mode: external ? LaunchMode.externalApplication : LaunchMode.platformDefault);
  } catch (_) {
    return false;
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.onCall, required this.onDirections});
  final VoidCallback onCall;
  final VoidCallback onDirections;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            onPressed: onDirections,
            icon: const Icon(Icons.directions_rounded, size: 19, color: AppColors.blue),
            label: const Text('Directions'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              backgroundColor: AppColors.green,
              textStyle: const TextStyle(fontFamily: kFont, fontWeight: FontWeight.w800, fontSize: 15),
            ),
            onPressed: onCall,
            icon: const Icon(Icons.call_rounded, size: 18),
            label: const Text('Call'),
          ),
        ),
      ],
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 15, color: AppColors.text3),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, color: AppColors.text2, fontWeight: FontWeight.w600, height: 1.35),
          ),
        ),
      ],
    );
  }
}

Widget _distanceTag(double km) =>
    Tag('${km.toStringAsFixed(1)} km', color: AppColors.blue, icon: Icons.near_me_rounded, dense: true);

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

class _ChemistCard extends StatelessWidget {
  const _ChemistCard({required this.chemist});
  final HealthChemist chemist;

  @override
  Widget build(BuildContext context) {
    final c = chemist;
    final allDay = c.operationalHours.toLowerCase().contains('24');
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const IconBubble(Icons.local_pharmacy_rounded, color: AppColors.green, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      c.address,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: AppColors.text2, height: 1.35),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _distanceTag(c.distanceKm),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (allDay)
                const Tag('OPEN 24×7', color: AppColors.green, icon: Icons.schedule_rounded, dense: true)
              else
                Tag(
                  c.operationalHours,
                  color: AppColors.text2,
                  bg: AppColors.surfaceAlt,
                  icon: Icons.schedule_rounded,
                  dense: true,
                ),
              if (c.deliveryAvailable)
                Tag(c.deliveryTimeEst, color: AppColors.primary, icon: Icons.delivery_dining_rounded, dense: true)
              else
                const Tag(
                  'Store pickup only',
                  color: AppColors.text2,
                  bg: AppColors.surfaceAlt,
                  icon: Icons.storefront_rounded,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: 14),
          _ActionRow(
            onCall: () => _call(context, c.phone),
            onDirections: () => _directions(context, c.name, c.address, c.latitude, c.longitude),
          ),
        ],
      ),
    );
  }
}

class _ClinicCard extends StatelessWidget {
  const _ClinicCard({required this.clinic});
  final HealthClinic clinic;

  @override
  Widget build(BuildContext context) {
    final c = clinic;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const IconBubble(Icons.local_hospital_rounded, color: AppColors.red, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      c.address,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: AppColors.text2, height: 1.35),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _distanceTag(c.distanceKm),
            ],
          ),
          if (c.doctors.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
              child: Column(
                children: [
                  for (var i = 0; i < c.doctors.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          PersonAvatar(name: c.doctors[i].name, size: 38),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  c.doctors[i].name,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                                ),
                                if (c.doctors[i].specialty.isNotEmpty)
                                  Text(
                                    c.doctors[i].specialty,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                if (c.doctors[i].degree.isNotEmpty)
                                  Text(
                                    c.doctors[i].degree,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.text2,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (c.facilities.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final f in c.facilities) Tag(f, color: AppColors.teal, dense: true)],
            ),
          ],
          const SizedBox(height: 12),
          _Meta(Icons.schedule_rounded, c.slotTimings),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text(
                'Consultation fee',
                style: TextStyle(color: AppColors.text2, fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const Spacer(),
              Text(
                formatPaise(c.consultationFeePaise),
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _ActionRow(
            onCall: () => _call(context, c.phone),
            onDirections: () => _directions(context, c.name, c.address, c.latitude, c.longitude),
          ),
        ],
      ),
    );
  }
}
