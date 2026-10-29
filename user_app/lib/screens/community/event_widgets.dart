import 'package:fitkey_core/fitkey_core.dart' show formatShortDate, formatDayDate, formatPaise;
import 'package:flutter/material.dart';

import '../../data/events_api.dart';
import '../../data/models.dart';
import '../../ui/ui.dart';

// ---------------------------------------------------------------------------
// Styling shared by the events list, event detail and Home's contest cards.
// ---------------------------------------------------------------------------

typedef EventLook = ({List<Color> colors, IconData icon, String metricLabel, String image});

EventLook _look(String metric) => switch (metric) {
      'running_km' => (
          colors: const [Color(0xFF14B8A6), Color(0xFF0E9F6E)],
          icon: Icons.directions_run_rounded,
          metricLabel: 'Running',
          image: AppImages.running,
        ),
      'streak' => (
          colors: const [Color(0xFFFF7A45), Color(0xFFFF4B2B)],
          icon: Icons.local_fire_department_rounded,
          metricLabel: 'Streak',
          image: AppImages.gymFloor,
        ),
      'attendance' => (
          colors: const [Color(0xFF3D7BFF), Color(0xFF2B59D9)],
          icon: Icons.place_rounded,
          metricLabel: 'On-ground',
          image: AppImages.groupClass,
        ),
      'arena_reps' => (
          colors: const [Color(0xFFFF4F9A), Color(0xFF7C5CFF)],
          icon: Icons.auto_awesome_rounded,
          metricLabel: 'AI-verified',
          image: AppImages.homeWorkout,
        ),
      _ => (
          colors: const [Color(0xFF7C5CFF), Color(0xFF4F46E5)],
          icon: Icons.login_rounded,
          metricLabel: 'Check-ins',
          image: AppImages.gym,
        ),
    };

/// Gradient + icon for a contest, keyed on what it measures so list and detail match.
({List<Color> colors, IconData icon, String metricLabel}) contestStyle(Contest c) {
  final l = _look(c.metric);
  return (colors: l.colors, icon: l.icon, metricLabel: l.metricLabel);
}

EventLook eventStyle(FitEvent e) => _look(e.metric);

/// "4d left", "Starts 2 Nov" or "Ended" depending on where today falls in the contest window.
String contestTimeLabel(Contest c) {
  final today = DateUtils.dateOnly(DateTime.now());
  if (today.isBefore(DateUtils.dateOnly(c.startsOn))) return 'Starts ${formatShortDate(c.startsOn)}';
  if (today.isAfter(DateUtils.dateOnly(c.endsOn))) return 'Ended';
  final d = c.daysLeft;
  return d <= 1 ? 'Last day' : '${d}d left';
}

bool contestFinished(Contest c) => DateUtils.dateOnly(DateTime.now()).isAfter(DateUtils.dateOnly(c.endsOn));

String eventTimeLabel(FitEvent e) {
  if (e.format == 'onground' && e.eventDate != null) {
    final today = DateUtils.dateOnly(DateTime.now());
    final d = DateUtils.dateOnly(e.eventDate!);
    if (d == today) return 'Today';
    if (d.isBefore(today)) return 'Ended';
    return formatDayDate(d);
  }
  if (e.finished) return 'Ended';
  if (e.upcoming) return 'Starts ${formatShortDate(e.startsOn)}';
  final d = e.daysLeft;
  return d <= 1 ? 'Last day' : '${d}d left';
}

({String label, Color color, IconData icon}) eventKindStyle(FitEvent e) => switch (e.kind) {
      'org' => (
          label: e.isBattle ? 'ORG BATTLE' : (e.orgKind == 'college' ? 'COLLEGE' : 'ORG EVENT'),
          color: AppColors.purple,
          icon: e.orgKind == 'college' ? Icons.school_rounded : Icons.business_rounded,
        ),
      'partner' => (label: 'PARTNER', color: AppColors.blue, icon: Icons.storefront_rounded),
      _ => (
          label: e.isBattle ? 'ORG BATTLE' : 'FITKEY',
          color: AppColors.primary,
          icon: e.isBattle ? Icons.sports_kabaddi_rounded : Icons.bolt_rounded,
        ),
    };

String eventFormatLabel(FitEvent e) => switch (e.format) {
      'onground' => 'On-ground',
      'ai' => 'AI-verified',
      _ => 'Virtual',
    };

/// Who hosts / who may join, e.g. "Zomato members", "Iron Paradise members only", "Open to all".
String eventAudience(FitEvent e) {
  if (e.isBattle) return e.battleOrgs.map((o) => o.name).join(' vs ');
  if (e.kind == 'org') return '${e.orgName ?? 'Org'} only';
  if (e.kind == 'partner') {
    final v = e.venue?.name ?? 'Venue';
    return e.membersOnly ? '$v members' : 'Hosted by $v';
  }
  return e.city != null ? 'Open in ${e.city}' : 'Open to all';
}

String eventFeeLabel(FitEvent e) => e.registrationFeePaise > 0 ? formatPaise(e.registrationFeePaise) : 'Free';

// ---------------------------------------------------------------------------
// Event card
// ---------------------------------------------------------------------------

class EventCard extends StatelessWidget {
  const EventCard({super.key, required this.event, required this.onTap});
  final FitEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final look = eventStyle(e);
    final kind = eventKindStyle(e);
    final cover = e.coverUrl ?? e.venue?.photo;
    return AppCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      radius: 22,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 138,
          child: Stack(fit: StackFit.expand, children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
              child: NetImage(cover, fallback: look.image),
            ),
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
              child: const PhotoScrim(strength: 0.7, from: Alignment.topCenter),
            ),
            Positioned(
              left: 12,
              top: 12,
              right: 12,
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                Tag(kind.label, icon: kind.icon, color: kind.color, bg: Colors.white, dense: true),
                Tag(eventTimeLabel(e),
                    icon: e.status == 'live' ? Icons.bolt_rounded : Icons.schedule_rounded,
                    color: Colors.white,
                    bg: e.status == 'live' ? AppColors.green : const Color(0x66000000),
                    dense: true),
              ]),
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 12,
              child: Row(children: [
                Icon(look.icon, color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Text('${eventFormatLabel(e)} · ${look.metricLabel}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5)),
                const Spacer(),
                if (e.sponsor != null)
                  Flexible(
                    child: Text('by ${e.sponsor}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
              ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, height: 1.25, letterSpacing: -0.3)),
            const SizedBox(height: 6),
            Row(children: [
              Icon(e.requiresOrg ? Icons.verified_user_rounded : Icons.public_rounded,
                  size: 14, color: e.isMyOrg ? AppColors.green : AppColors.text3),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  e.format == 'onground' && e.venue != null
                      ? '${e.venue!.name}${e.venue!.area != null ? ', ${e.venue!.area}' : ''}'
                      : eventAudience(e),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
            if (e.reward != null && e.reward!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.card_giftcard_rounded, size: 14, color: AppColors.amber),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(e.reward!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFFB86E00))),
                ),
              ]),
            ],
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.groups_rounded, size: 17, color: AppColors.text3),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '${e.participantCount} joined · ${eventFeeLabel(e)}',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w700),
                ),
              ),
              _JoinPill(event: e, color: look.colors.last),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _JoinPill extends StatelessWidget {
  const _JoinPill({required this.event, required this.color});
  final FitEvent event;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final (label, bg, fg, icon) = e.joined
        ? (e.attended ? 'Attended' : 'Joined', AppColors.greenSoft, AppColors.green, Icons.check_circle_rounded)
        : e.finished
            ? ('Results', AppColors.surfaceAlt, AppColors.text, Icons.leaderboard_rounded)
            : e.requiresOrg && !e.isMyOrg
                ? ('Verify & join', AppColors.purpleSoft, AppColors.purple, Icons.verified_user_rounded)
                : ('Join', color, Colors.white, Icons.bolt_rounded);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(11)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: fg),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 12.5)),
      ]),
    );
  }
}

/// Verified org badge chip, reused on the events list, event detail and trophy screen.
class OrgBadgeChip extends StatelessWidget {
  const OrgBadgeChip({super.key, required this.name, this.college = false, this.pending = false});
  final String name;
  final bool college;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final c = pending ? AppColors.amber : AppColors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: pending ? AppColors.amberSoft : AppColors.greenSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(pending ? Icons.hourglass_top_rounded : (college ? Icons.school_rounded : Icons.verified_rounded), size: 15, color: c),
        const SizedBox(width: 5),
        Text(pending ? '$name · in review' : name,
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: pending ? const Color(0xFFB86E00) : AppColors.green)),
      ]),
    );
  }
}

class EventCardsSkeleton extends StatelessWidget {
  const EventCardsSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: [
          SkeletonBox(height: 250, radius: 22),
          SizedBox(height: 14),
          SkeletonBox(height: 250, radius: 22),
        ]),
      ),
    );
  }
}
