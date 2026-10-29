import 'dart:async';
import 'dart:math' as math;

import 'package:fitkey_core/fitkey_core.dart' show formatClock;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/models.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';

/// P6 — front-desk screen. Shows a rotating QR (members scan it in the FITKEY app) and a 6-digit OTP fallback.
/// Codes expire after 5 minutes and refresh automatically; the live feed shows members as they check in.
class CheckinCodeScreen extends StatefulWidget {
  const CheckinCodeScreen({super.key, required this.venueId, required this.venueName});

  final String venueId;
  final String venueName;

  @override
  State<CheckinCodeScreen> createState() => _CheckinCodeScreenState();
}

class _CheckinCodeScreenState extends State<CheckinCodeScreen> {
  CheckinCode? _code;
  Object? _error;
  List<AttendanceEntry> _today = const [];
  bool _feedLoaded = false;
  Timer? _tick;
  Timer? _feed;
  Duration _left = Duration.zero;
  Duration _total = const Duration(minutes: 5);
  bool _refreshing = false;
  DateTime? _lastFailure;

  /// Ids that arrived while this screen was open — highlighted as "just checked in".
  final _fresh = <String>{};

  static const _refreshBefore = Duration(seconds: 20);
  static const _retryAfterFailure = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    // The front-desk screen stays on all day; don't let the display sleep.
    WakelockPlus.enable().catchError((_) {});
    _refresh();
    _loadFeed();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _feed = Timer.periodic(const Duration(seconds: 8), (_) => _loadFeed());
  }

  void _onTick() {
    final code = _code;
    if (code == null || !mounted) return;
    final left = code.expiresAt.difference(DateTime.now());
    setState(() => _left = left.isNegative ? Duration.zero : left);
    // Back off after a failed refresh so a flaky network isn't hammered every second.
    final cooling = _lastFailure != null && DateTime.now().difference(_lastFailure!) < _retryAfterFailure;
    if (left <= _refreshBefore && !_refreshing && !cooling) _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    if (mounted) setState(() {});
    try {
      final code = await context.read<PartnerSession>().api.checkinCode(widget.venueId);
      if (!mounted) return;
      final left = code.expiresAt.difference(DateTime.now());
      setState(() {
        _code = code;
        _error = null;
        _lastFailure = null;
        _left = left.isNegative ? Duration.zero : left;
        // Use the server's TTL (normally 5 min) for the ring, tolerating small clock skew.
        _total = left.inSeconds > 30 ? left : const Duration(minutes: 5);
      });
    } catch (e) {
      _lastFailure = DateTime.now();
      if (mounted) setState(() => _error = e);
    } finally {
      _refreshing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadFeed() async {
    try {
      final list = await context.read<PartnerSession>().api.attendance(widget.venueId);
      if (!mounted) return;
      final known = _today.map((c) => c.id).toSet();
      final arrivals = _feedLoaded ? list.where((c) => !known.contains(c.id)).toList() : const <AttendanceEntry>[];
      setState(() {
        _today = list;
        _feedLoaded = true;
        _fresh.addAll(arrivals.map((c) => c.id));
      });
      if (arrivals.isNotEmpty) {
        final who = arrivals.first.memberName ?? 'A member';
        toast(context, arrivals.length == 1 ? '$who just checked in' : '$who + ${arrivals.length - 1} more just checked in',
            icon: Icons.how_to_reg_rounded);
      }
    } catch (_) {
      // Feed is best-effort; the QR keeps working.
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable().catchError((_) {});
    _tick?.cancel();
    _feed?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.venueName, maxLines: 1, overflow: TextOverflow.ellipsis),
          const Text('Front-desk check-in',
              style: TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600)),
        ]),
        actions: [
          IconButton(
            tooltip: 'New code now',
            onPressed: _refreshing ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: code == null
          ? (_error != null
              ? ErrorView(error: _error!, onRetry: _refresh)
              : Shimmer(
                  child: ListView(padding: const EdgeInsets.all(16), children: const [
                    SkeletonBox(height: 420, radius: 28),
                    SizedBox(height: 16),
                    SkeletonBox(height: 120, radius: 20),
                  ]),
                ))
          : RefreshIndicator(
              onRefresh: () async {
                await Future.wait([_refresh(), _loadFeed()]);
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _QrPass(
                    code: code,
                    left: _left,
                    total: _total,
                    refreshing: _refreshing,
                    offline: _error != null,
                  ),
                  const SizedBox(height: 14),
                  _OtpCard(otp: code.otp),
                  const SizedBox(height: 4),
                  _feedHeader(),
                  if (!_feedLoaded)
                    const SkeletonList(count: 2, itemHeight: 44, padding: EdgeInsets.zero)
                  else if (_today.isEmpty)
                    const AppCard(
                      border: true,
                      shadow: false,
                      child: Row(children: [
                        IconBubble(Icons.hourglass_empty_rounded, color: AppColors.text2, size: 40),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text('No check-ins yet today. New arrivals appear here automatically.',
                              style: TextStyle(color: AppColors.text2, height: 1.4)),
                        ),
                      ]),
                    )
                  else
                    for (final c in _today.take(15)) _FeedRow(entry: c, fresh: _fresh.contains(c.id)),
                  if (_today.length > 15)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('+ ${_today.length - 15} more earlier today',
                          textAlign: TextAlign.center, style: const TextStyle(color: AppColors.text3, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _feedHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(0, 24, 0, 12),
        child: Row(children: [
          const _LiveDot(),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Live check-ins', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          ),
          Tag('${_today.length} today', color: AppColors.green),
        ]),
      );
}

/// Dark "pass" card: high-contrast QR on white with the refresh countdown ring.
class _QrPass extends StatelessWidget {
  const _QrPass({required this.code, required this.left, required this.total, required this.refreshing, required this.offline});

  final CheckinCode code;
  final Duration left;
  final Duration total;
  final bool refreshing;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final mm = left.inMinutes.toString();
    final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    final fraction = total.inSeconds == 0 ? 0.0 : (left.inSeconds / total.inSeconds).clamp(0.0, 1.0);
    final urgent = left.inSeconds <= 30;

    return LayoutBuilder(builder: (context, c) {
      final qrSize = math.min(c.maxWidth - 72, 300.0);
      return Container(
        decoration: BoxDecoration(gradient: AppColors.passGradient, borderRadius: BorderRadius.circular(28), boxShadow: AppShadows.card),
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
        child: Column(children: [
          const Text('SCAN TO CHECK IN',
              style: TextStyle(color: AppColors.lime, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 2)),
          const SizedBox(height: 4),
          const Text('FITKEY app → Check in → point the camera here',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: QrImageView(
                key: ValueKey(code.qr),
                data: code.qr,
                size: qrSize,
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            SizedBox(
              width: 54,
              height: 54,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: refreshing ? null : fraction,
                    strokeWidth: 5,
                    strokeCap: StrokeCap.round,
                    color: urgent ? AppColors.amber : AppColors.lime,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                Text('$mm:$ss', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
              ]),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  offline
                      ? 'Reconnecting…'
                      : refreshing
                          ? 'Getting a fresh code…'
                          : 'New code in $mm:$ss',
                  style: TextStyle(
                      color: offline ? AppColors.amber : Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  offline ? 'Check the internet connection at the desk.' : 'Refreshes automatically — keep this screen open.',
                  style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.35),
                ),
              ]),
            ),
          ]),
        ]),
      );
    });
  }
}

class _OtpCard extends StatelessWidget {
  const _OtpCard({required this.otp});
  final String otp;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      child: Column(children: [
        const Row(children: [
          IconBubble(Icons.pin_rounded, size: 34),
          SizedBox(width: 10),
          Expanded(
            child: Text('Camera not working? Share this code',
                style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.text2)),
          ),
        ]),
        const SizedBox(height: 14),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Row(
            key: ValueKey(otp),
            children: [
              for (var i = 0; i < otp.length; i++) ...[
                if (i == 3) const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    height: 62,
                    margin: EdgeInsets.only(right: i == otp.length - 1 || i == 2 ? 0 : 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.line),
                    ),
                    child: Text(otp[i],
                        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: AppColors.ink, height: 1)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ]),
    );
  }
}

class _FeedRow extends StatelessWidget {
  const _FeedRow({required this.entry, required this.fresh});
  final AttendanceEntry entry;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final c = entry;
    final sub = ['•••• ${c.phoneLast4 ?? '----'}', if (c.planName != null) c.planName!].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: fresh ? AppColors.greenSoft : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: fresh ? AppColors.green.withValues(alpha: 0.4) : AppColors.line),
        ),
        child: Row(children: [
          PersonAvatar(name: c.memberName, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.memberName ?? 'FITKEY member',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (fresh) const Tag('JUST NOW', color: AppColors.green, dense: true),
            if (fresh) const SizedBox(height: 4),
            Text(formatClock(c.checkedInAt), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
            Text(c.method.toUpperCase(), style: const TextStyle(fontSize: 10.5, color: AppColors.text3, fontWeight: FontWeight.w700)),
          ]),
        ]),
      ),
    );
  }
}

/// Pulsing green "live" dot.
class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(alignment: Alignment.center, children: [
          Container(
            width: 8 + 10 * _c.value,
            height: 8 + 10 * _c.value,
            decoration: BoxDecoration(color: AppColors.green.withValues(alpha: 0.35 * (1 - _c.value)), shape: BoxShape.circle),
          ),
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.green, shape: BoxShape.circle)),
        ]),
      ),
    );
  }
}
