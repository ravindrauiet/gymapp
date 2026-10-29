import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams;

import '../../data/circles_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'circle_detail_screen.dart';
import 'circle_forms.dart';
import 'circles_common.dart';

/// Family link: share my code with my children; follow a parent's circle streaks.
/// Opening this screen also runs the (lazy) "missed 2 sessions in a row" check for the people I follow.
class CircleFamilyScreen extends StatefulWidget {
  const CircleFamilyScreen({super.key});

  @override
  State<CircleFamilyScreen> createState() => _CircleFamilyScreenState();
}

class _CircleFamilyScreenState extends State<CircleFamilyScreen> {
  late Future<FamilyOverview> _future = context.read<Session>().api.circleFamily();

  Future<void> _reload() async {
    final f = context.read<Session>().api.circleFamily();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // Shown by AsyncBody's error state.
    }
  }

  Future<void> _follow() async {
    final r = await showFamilyCodeSheet(context);
    if (r == 'ok' && mounted) {
      toast(context, CirclesPrefs.instance.t('linked'), icon: Icons.family_restroom_rounded);
      _reload();
    }
  }

  Future<void> _rotate() async {
    try {
      await context.read<Session>().api.rotateFamilyCode();
      if (mounted) _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _unlink(FamilyPerson person) async {
    final p = CirclesPrefs.instance;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${p.t('unlink')} ${person.name ?? ''}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(p.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(p.t('unlink'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<Session>().api.unlinkFamily(person.userId);
      if (mounted) _reload();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CirclesShell(child: Builder(builder: (context) {
      final p = circlesOf(context);
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(title: Text(p.t('familyTitle')), actions: const [CirclesA11yToggles(), SizedBox(width: 12)]),
        bottomNavigationBar: BottomActionBar(
          child: AppButton(label: p.t('followParent'), icon: Icons.family_restroom_rounded, onPressed: _follow),
        ),
        body: AsyncBody<FamilyOverview>(
          future: _future,
          onRetry: _reload,
          builder: (context, f) => RefreshIndicator(
            onRefresh: _reload,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
              Text(p.t('familySub'), style: const TextStyle(color: AppColors.text2, height: 1.4)),
              const SizedBox(height: 14),
              _codeCard(p, f.code),
              SectionTitle(p.t('following'), padding: const EdgeInsets.fromLTRB(0, 22, 0, 10)),
              if (f.following.isEmpty)
                AppCard(
                  child: Row(children: [
                    const IconBubble(Icons.family_restroom_rounded, color: AppColors.teal),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.t('noFollowing'), style: const TextStyle(fontWeight: FontWeight.w800)),
                        Text(p.t('noFollowingMsg'), style: const TextStyle(color: AppColors.text2, fontSize: 13)),
                      ]),
                    ),
                  ]),
                ),
              for (final person in f.following) _personCard(p, person),
              if (f.followers.isNotEmpty) ...[
                SectionTitle(p.t('followers'), padding: const EdgeInsets.fromLTRB(0, 22, 0, 10)),
                AppCard(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(children: [
                    for (final c in f.followers)
                      ListTile(
                        leading: PersonAvatar(name: c.name ?? 'F', photoUrl: c.avatarUrl, size: 40),
                        title: Text(c.name ?? 'Family member', style: const TextStyle(fontWeight: FontWeight.w700)),
                        trailing: TextButton(onPressed: () => _unlink(c), child: Text(p.t('unlink'))),
                      ),
                  ]),
                ),
              ],
            ]),
          ),
        ),
      );
    }));
  }

  Widget _codeCard(CirclesPrefs p, String code) => AppCard(
        gradient: AppColors.primaryGradient,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.t('myCode'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: SelectableText(code,
                  style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 3)),
            ),
            IconButton(
              tooltip: p.t('copied'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (mounted) toast(context, p.t('copied'));
              },
              icon: const Icon(Icons.copy_rounded, color: Colors.white),
            ),
          ]),
          Text(p.t('myCodeSub'), style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppColors.primary),
                onPressed: () async {
                  try {
                    await SharePlus.instance.share(ShareParams(text: p.t('familyCodeMsg', {'code': code})));
                  } catch (_) {
                    if (mounted) toast(context, p.t('shareFailed'), error: true);
                  }
                },
                icon: const Icon(Icons.share_rounded),
                label: Text(p.t('shareCode')),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _rotate,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: Text(p.t('newCode')),
            ),
          ]),
        ]),
      );

  Widget _personCard(CirclesPrefs p, FamilyPerson person) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              PersonAvatar(name: person.name ?? 'F', photoUrl: person.avatarUrl, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Text(person.name ?? 'Family member', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              ),
              TextButton(onPressed: () => _unlink(person), child: Text(p.t('unlink'))),
            ]),
            if (person.circles.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(p.t('notInCircle'), style: const TextStyle(color: AppColors.text2)),
              ),
            for (final c in person.circles) ...[
              const Divider(height: 22),
              Tap(
                onTap: () => push(context, CircleDetailScreen(circleId: c.circleId)),
                child: Row(children: [
                  IconBubble(circleVisual(c.activity).icon, color: circleVisual(c.activity).color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text(c.schedule, style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
                      const SizedBox(height: 4),
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        if (c.attendedToday) Tag(p.t('attended'), color: AppColors.green, dense: true),
                        if (c.missedInRow >= 2)
                          Tag(p.t('missedN', {'n': c.missedInRow}), color: AppColors.red, dense: true)
                        else if (c.lastAttended != null && !c.attendedToday)
                          Tag(p.t('lastSeen', {'date': friendlyDate(p, c.lastAttended!)}), color: AppColors.text2, dense: true),
                        Tag('${p.t('thisMonth')} ${p.t('ofSessions', {'a': c.monthCount, 'b': c.monthSessions})}',
                            color: AppColors.blue, dense: true),
                      ]),
                    ]),
                  ),
                  Column(children: [
                    Text('${c.streak}',
                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: AppColors.primary)),
                    Text(p.t('streak'), style: const TextStyle(fontSize: 11, color: AppColors.text2)),
                  ]),
                ]),
              ),
            ],
          ]),
        ),
      );
}
