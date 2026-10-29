import 'package:fitkey_core/fitkey_core.dart' show formatPaise, formatDayDate;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../data/partner_api.dart';
import '../../data/vendor_trainer_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';
import '../notifications/notifications_screen.dart';
import '../ratings/partner_ratings_screen.dart';

part 'trainer_bookings.dart';
part 'trainer_profile_editor.dart';

/// FITKEY Partner — trainer module: profile & categories, bookings and earnings.
class PartnerTrainerScreen extends StatefulWidget {
  const PartnerTrainerScreen({super.key});

  @override
  State<PartnerTrainerScreen> createState() => _PartnerTrainerScreenState();
}

class _PartnerTrainerScreenState extends State<PartnerTrainerScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  late Future<TrainerProfileDetails?> _profile;
  late Future<List<TrainerBookingItem>> _bookings;

  PartnerApi get _api => context.read<PartnerSession>().api;

  @override
  void initState() {
    super.initState();
    _profile = _api.trainerProfileDetails();
    _bookings = _api.trainerBookings();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reloadAll() async {
    setState(() {
      _profile = _api.trainerProfileDetails();
      _bookings = _api.trainerBookings();
    });
    await Future.wait([_profile.then((_) {}, onError: (_) {}), _bookings.then((_) {}, onError: (_) {})]);
  }

  Future<void> _reloadBookings() async {
    setState(() => _bookings = _api.trainerBookings());
    await _bookings.then((_) {}, onError: (_) {});
  }

  void _profileSaved(TrainerProfileDetails saved) {
    setState(() => _profile = Future.value(saved));
    _tabs.animateTo(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Trainer studio'),
        actions: const [PartnerNotificationBell(), SizedBox(width: 6)],
        bottom: TabBar(
          controller: _tabs,
          labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          labelColor: AppColors.text,
          unselectedLabelColor: AppColors.text3,
          indicatorColor: AppColors.primary,
          indicatorSize: TabBarIndicatorSize.label,
          dividerColor: AppColors.line,
          tabs: const [Tab(text: 'Overview'), Tab(text: 'Bookings'), Tab(text: 'Profile')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _OverviewTab(
            profile: _profile,
            bookings: _bookings,
            onReload: _reloadAll,
            onEditProfile: () => _tabs.animateTo(2),
            onOpenBookings: () => _tabs.animateTo(1),
          ),
          _BookingsTab(future: _bookings, onReload: _reloadBookings),
          _ProfileTab(profile: _profile, onReload: _reloadAll, onSaved: _profileSaved),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers shared by the trainer tabs
// ---------------------------------------------------------------------------

const _modeInfo = <String, (String, IconData, Color, Color)>{
  'online': ('Online', Icons.videocam_rounded, AppColors.blue, AppColors.blueSoft),
  'home': ('At home', Icons.home_rounded, AppColors.purple, AppColors.purpleSoft),
  'gym': ('At gym', Icons.fitness_center_rounded, AppColors.primary, AppColors.primarySoft),
};

(String, IconData, Color, Color) _mode(String m) => _modeInfo[m] ?? (m, Icons.event_rounded, AppColors.text2, AppColors.surfaceAlt);

/// Parses "06:30 AM" / "18:00" into minutes since midnight for sorting.
int _slotMinutes(String slot) {
  final m = RegExp(r'(\d{1,2}):(\d{2})\s*([AaPp][Mm])?').firstMatch(slot);
  if (m == null) return 0;
  var h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  final ap = m.group(3)?.toUpperCase();
  if (ap == 'PM' && h < 12) h += 12;
  if (ap == 'AM' && h == 12) h = 0;
  return h * 60 + min;
}

DateTime? _sessionDay(TrainerBookingItem b) {
  final d = DateTime.tryParse(b.sessionDate);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

/// Upcoming = not cancelled / completed, and today or later.
bool _isUpcoming(TrainerBookingItem b) {
  final d = _sessionDay(b);
  return b.status == 'confirmed' && d != null && !d.isBefore(DateUtils.dateOnly(DateTime.now()));
}

class _RefreshableFill extends StatelessWidget {
  const _RefreshableFill({required this.onRefresh, required this.child});
  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(constraints: BoxConstraints(minHeight: c.maxHeight), child: child),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.profile,
    required this.bookings,
    required this.onReload,
    required this.onEditProfile,
    required this.onOpenBookings,
  });

  final Future<TrainerProfileDetails?> profile;
  final Future<List<TrainerBookingItem>> bookings;
  final Future<void> Function() onReload;
  final VoidCallback onEditProfile;
  final VoidCallback onOpenBookings;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TrainerProfileDetails?>(
      future: profile,
      builder: (context, pSnap) => FutureBuilder<List<TrainerBookingItem>>(
        future: bookings,
        builder: (context, bSnap) {
          if (pSnap.connectionState != ConnectionState.done || bSnap.connectionState != ConnectionState.done) {
            return const _OverviewSkeleton();
          }
          final error = pSnap.error ?? bSnap.error;
          if (error != null) return _RefreshableFill(onRefresh: onReload, child: ErrorView(error: error, onRetry: onReload));
          final p = pSnap.data;
          if (p == null) {
            return _RefreshableFill(onRefresh: onReload, child: _Onboarding(onStart: onEditProfile));
          }
          return RefreshIndicator(
            onRefresh: onReload,
            child: _OverviewBody(
              details: p,
              bookings: bSnap.data!,
              onEditProfile: onEditProfile,
              onOpenBookings: onOpenBookings,
            ),
          );
        },
      ),
    );
  }
}

class _Onboarding extends StatelessWidget {
  const _Onboarding({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        PhotoBanner(
          image: AppImages.strength,
          eyebrow: 'FitPro on FITKEY',
          title: 'Get booked by members near you',
          subtitle: 'Online, at their home or at a partner gym — you set the rate.',
          cta: 'Create trainer profile',
          height: 200,
          onTap: onStart,
        ),
        const SizedBox(height: 18),
        for (final s in const [
          (Icons.category_rounded, 'Pick your categories', 'Choose up to 12 trainer types so members find you in the right category.'),
          (Icons.payments_rounded, 'Set your rate & modes', 'Hourly rate, home-visit buffer and the modes you train in.'),
          (Icons.event_available_rounded, 'Get bookings', 'Members book a date and slot; sessions appear in Bookings.'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AppCard(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                IconBubble(s.$1, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.$2, style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(s.$3, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                  ]),
                ),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        AppButton(label: 'Create trainer profile', icon: Icons.arrow_forward_rounded, onPressed: onStart),
      ]),
    );
  }
}

class _OverviewBody extends StatelessWidget {
  const _OverviewBody({required this.details, required this.bookings, required this.onEditProfile, required this.onOpenBookings});
  final TrainerProfileDetails details;
  final List<TrainerBookingItem> bookings;
  final VoidCallback onEditProfile;
  final VoidCallback onOpenBookings;

  @override
  Widget build(BuildContext context) {
    final p = details.profile;
    final now = DateTime.now();
    final valid = bookings.where((b) => b.status != 'cancelled').toList();
    final thisMonth = valid.where((b) {
      final d = _sessionDay(b);
      return d != null && d.year == now.year && d.month == now.month;
    }).toList();
    final upcoming = bookings.where(_isUpcoming).toList()
      ..sort((a, b) {
        final c = a.sessionDate.compareTo(b.sessionDate);
        return c != 0 ? c : _slotMinutes(a.slotTime).compareTo(_slotMinutes(b.slotTime));
      });
    final upcomingValue = upcoming.fold<int>(0, (s, b) => s + b.amountPaise);
    final lifetime = valid.fold<int>(0, (s, b) => s + b.amountPaise);
    final byMode = <String, int>{};
    for (final b in valid) {
      byMode[b.mode] = (byMode[b.mode] ?? 0) + 1;
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        // Profile header
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              PersonAvatar(name: p.name, photoUrl: p.photoUrl, size: 64),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                    ),
                    if (p.verificationStatus == 'verified') ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.verified_rounded, color: AppColors.blue, size: 19),
                    ],
                  ]),
                  const SizedBox(height: 3),
                  Text('${formatPaise(p.hourlyRatePaise)}/hr · ${p.trainingModes.map((m) => _mode(m).$1).join(' · ')}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                ]),
              ),
              IconButton(tooltip: 'Edit profile', onPressed: onEditProfile, icon: const Icon(Icons.edit_rounded, color: AppColors.text2)),
            ]),
            if (details.trainerTypeLabels.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final l in details.trainerTypeLabels) Tag(l, color: AppColors.ink, bg: AppColors.surfaceAlt, dense: true),
              ]),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        _VerificationBanner(status: p.verificationStatus),
        const SizedBox(height: 12),
        _RatingCard(details: details),
        const SectionTitle('Earnings', subtitle: 'Booking value of sessions (cancelled excluded)', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
        Row(children: [
          Expanded(
            child: MetricTile(
              label: 'This month · ${thisMonth.length} sessions',
              value: formatPaise(thisMonth.fold(0, (s, b) => s + b.amountPaise)),
              icon: Icons.calendar_month_rounded,
              color: AppColors.green,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: MetricTile(
              label: 'Upcoming · ${upcoming.length} sessions',
              value: formatPaise(upcomingValue),
              icon: Icons.event_available_rounded,
              color: AppColors.blue,
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: MetricTile(label: 'Lifetime booking value', value: formatPaise(lifetime), icon: Icons.savings_rounded, color: AppColors.purple),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: MetricTile(label: 'Total sessions', value: '${valid.length}', icon: Icons.fitness_center_rounded, color: AppColors.primary),
          ),
        ]),
        if (byMode.isNotEmpty) ...[
          const SizedBox(height: 10),
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Sessions by mode', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 8,
                  child: Row(children: [
                    for (final e in byMode.entries) Expanded(flex: e.value, child: Container(color: _mode(e.key).$3)),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 14, runSpacing: 6, children: [
                for (final e in byMode.entries)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(_mode(e.key).$2, size: 15, color: _mode(e.key).$3),
                    const SizedBox(width: 4),
                    Text('${_mode(e.key).$1} · ${e.value}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ]),
              ]),
            ]),
          ),
        ],
        SectionTitle('Next up', action: bookings.isEmpty ? null : 'All bookings', onAction: onOpenBookings,
            padding: const EdgeInsets.fromLTRB(0, 24, 0, 12)),
        if (upcoming.isEmpty)
          AppCard(
            child: Row(children: [
              const IconBubble(Icons.event_busy_rounded, color: AppColors.text2, bg: AppColors.surfaceAlt, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  bookings.isEmpty
                      ? 'No bookings yet. Members find you under your trainer categories in the FITKEY app.'
                      : 'No upcoming sessions right now.',
                  style: const TextStyle(color: AppColors.text2, fontSize: 13),
                ),
              ),
            ]),
          )
        else
          for (final b in upcoming.take(3))
            Padding(padding: const EdgeInsets.only(bottom: 10), child: _BookingCard(booking: b)),
        const SizedBox(height: 14),
        const _FitFeedCard(),
      ],
    );
  }
}

class _VerificationBanner extends StatelessWidget {
  const _VerificationBanner({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final look = switch (status) {
      'verified' => (
          c: AppColors.green,
          soft: AppColors.greenSoft,
          icon: Icons.verified_user_rounded,
          title: 'Verified trainer',
          body: 'Your profile is live and members can book you.'
        ),
      'rejected' => (
          c: AppColors.red,
          soft: AppColors.redSoft,
          icon: Icons.gpp_bad_rounded,
          title: 'Verification rejected',
          body: 'Your profile is hidden from members. Update your certifications and contact FITKEY partner support for a re-check.'
        ),
      _ => (
          c: AppColors.amber,
          soft: AppColors.amberSoft,
          icon: Icons.hourglass_top_rounded,
          title: 'Verification pending',
          body: 'We are checking your profile. It goes live for bookings once verified.'
        ),
    };
    return AppCard(
      color: look.soft,
      shadow: false,
      padding: const EdgeInsets.all(14),
      child: Row(children: [
        IconBubble(look.icon, color: look.c, bg: Colors.white, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(look.title, style: TextStyle(fontWeight: FontWeight.w800, color: look.c)),
            const SizedBox(height: 2),
            Text(look.body, style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35)),
          ]),
        ),
      ]),
    );
  }
}

class _RatingCard extends StatelessWidget {
  const _RatingCard({required this.details});
  final TrainerProfileDetails details;

  @override
  Widget build(BuildContext context) {
    final d = details;
    return AppCard(
      onTap: () => push(context, const PartnerRatingsScreen(trainer: true)),
      padding: const EdgeInsets.all(14),
      child: Row(children: [
        Container(
          width: 58,
          height: 50,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: d.isNew ? AppColors.surfaceAlt : AppColors.green,
            borderRadius: BorderRadius.circular(12),
          ),
          child: d.isNew
              ? const Text('New', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.text2))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(d.ratingAvg!.toStringAsFixed(1),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
                  const SizedBox(width: 2),
                  const Icon(Icons.star_rounded, color: Colors.white, size: 16),
                ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.isNew ? 'Ratings show after 5 reviews' : '${d.ratingCount} member ratings',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(
              d.isNew
                  ? '${d.ratingCount} of 5 so far — members rate you after a session.'
                  : 'See what members say and reply to reviews.',
              style: const TextStyle(color: AppColors.text2, fontSize: 12.5),
            ),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: AppColors.text3),
      ]),
    );
  }
}

class _FitFeedCard extends StatelessWidget {
  const _FitFeedCard();

  @override
  Widget build(BuildContext context) {
    final phone = context.select<PartnerSession, String?>((s) => s.user?.phone);
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(gradient: AppColors.mansiGradient, borderRadius: BorderRadius.circular(14)),
          child: const Icon(Icons.dynamic_feed_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Flexible(child: Text('Verified Trainer on FitFeed', style: TextStyle(fontWeight: FontWeight.w800))),
              SizedBox(width: 6),
              Icon(Icons.verified_rounded, color: AppColors.blue, size: 16),
            ]),
            const SizedBox(height: 4),
            Text(
              'Your Verified Trainer badge appears on FitFeed when you post from the FITKEY member app with this same '
              'phone number${phone == null || phone.isEmpty ? '' : ' ($phone)'}. Share tips and workouts to get discovered.',
              style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.4),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _OverviewSkeleton extends StatelessWidget {
  const _OverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: const [
          SkeletonBox(height: 120, radius: 20),
          SizedBox(height: 12),
          SkeletonBox(height: 70, radius: 20),
          SizedBox(height: 12),
          SkeletonBox(height: 78, radius: 20),
          SizedBox(height: 28),
          Row(children: [
            Expanded(child: SkeletonBox(height: 104, radius: 20)),
            SizedBox(width: 10),
            Expanded(child: SkeletonBox(height: 104, radius: 20)),
          ]),
        ],
      ),
    );
  }
}
