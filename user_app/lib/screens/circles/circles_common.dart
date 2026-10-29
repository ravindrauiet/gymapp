import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams;
import 'package:url_launcher/url_launcher.dart';

import '../../data/circles_api.dart';
import '../../ui/ui.dart';

// ---------------------------------------------------------------------------
// Elder-friendly preferences: large text + Hindi, persisted on the device.
// ---------------------------------------------------------------------------

class CirclesPrefs extends ChangeNotifier {
  CirclesPrefs._();
  static final instance = CirclesPrefs._();

  static const _storage = FlutterSecureStorage();
  static const _largeKey = 'circles_large_text';
  static const _hindiKey = 'circles_hindi';

  bool large = false;
  bool hindi = false;
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      large = await _storage.read(key: _largeKey) == '1';
      hindi = await _storage.read(key: _hindiKey) == '1';
      notifyListeners();
    } catch (_) {
      // Storage unavailable (e.g. private web window) — keep defaults.
    }
  }

  void setLarge(bool v) {
    large = v;
    notifyListeners();
    _storage.write(key: _largeKey, value: v ? '1' : '0').catchError((_) {});
  }

  void setHindi(bool v) {
    hindi = v;
    notifyListeners();
    _storage.write(key: _hindiKey, value: v ? '1' : '0').catchError((_) {});
  }

  /// Translates [key]; `{name}` placeholders are filled from [args].
  String t(String key, [Map<String, Object?> args = const {}]) {
    var s = (hindi ? _hi[key] : null) ?? _en[key] ?? key;
    args.forEach((k, v) => s = s.replaceAll('{$k}', '${v ?? ''}'));
    return s;
  }
}

class _CirclesScope extends InheritedNotifier<CirclesPrefs> {
  _CirclesScope({required super.child}) : super(notifier: CirclesPrefs.instance);
}

/// Prefs for Circles widgets; registers a dependency so text updates when the language changes.
CirclesPrefs circlesOf(BuildContext context) {
  context.dependOnInheritedWidgetOfExactType<_CirclesScope>();
  return CirclesPrefs.instance;
}

/// Wrap every Circles screen in this: applies the large-text toggle and rebuilds on language change.
class CirclesShell extends StatefulWidget {
  const CirclesShell({super.key, required this.child});
  final Widget child;

  @override
  State<CirclesShell> createState() => _CirclesShellState();
}

class _CirclesShellState extends State<CirclesShell> {
  @override
  void initState() {
    super.initState();
    CirclesPrefs.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    return _CirclesScope(
      child: Builder(builder: (context) {
        final prefs = circlesOf(context);
        final mq = MediaQuery.of(context);
        final base = mq.textScaler.scale(1);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(prefs.large ? (base * 1.3).clamp(1.25, 2.0) : base)),
          child: widget.child,
        );
      }),
    );
  }
}

/// "Aa" large text + EN/हिं toggles, used in Circles app bars and headers.
class CirclesA11yToggles extends StatelessWidget {
  const CirclesA11yToggles({super.key});

  @override
  Widget build(BuildContext context) {
    final p = circlesOf(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _Toggle(
        label: 'Aa',
        tooltip: p.t('largeText'),
        active: p.large,
        onTap: () => p.setLarge(!p.large),
      ),
      const SizedBox(width: 6),
      _Toggle(
        label: p.hindi ? 'EN' : 'हिं',
        tooltip: p.t('language'),
        active: p.hindi,
        onTap: () => p.setHindi(!p.hindi),
      ),
    ]);
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.tooltip, required this.active, required this.onTap});
  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Tap(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: active ? AppColors.primarySoft : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: active ? AppColors.primary : AppColors.line),
          ),
          child: Text(label,
              textScaler: TextScaler.noScaling,
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: active ? AppColors.primary : AppColors.text)),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Visuals & formatting
// ---------------------------------------------------------------------------

const circleActivities = ['yoga', 'walk', 'laughter', 'running', 'dance', 'meditation', 'exercise', 'cycling', 'other'];

({IconData icon, Color color, String image}) circleVisual(String activity) => switch (activity) {
      'yoga' => (icon: Icons.self_improvement_rounded, color: AppColors.purple, image: AppImages.yoga),
      'walk' => (icon: Icons.directions_walk_rounded, color: AppColors.green, image: AppImages.running),
      'laughter' => (icon: Icons.sentiment_very_satisfied_rounded, color: AppColors.amber, image: AppImages.groupClass),
      'running' => (icon: Icons.directions_run_rounded, color: AppColors.primary, image: AppImages.running),
      'dance' => (icon: Icons.music_note_rounded, color: AppColors.pink, image: AppImages.dance),
      'meditation' => (icon: Icons.spa_rounded, color: AppColors.teal, image: AppImages.yoga),
      'exercise' => (icon: Icons.fitness_center_rounded, color: AppColors.blue, image: AppImages.homeWorkout),
      'cycling' => (icon: Icons.directions_bike_rounded, color: AppColors.teal, image: AppImages.sports),
      _ => (icon: Icons.groups_rounded, color: AppColors.blue, image: AppImages.groupClass),
    };

String activityLabel(CirclesPrefs p, String activity) => p.t('act_$activity');

/// '06:00' → '6:00 AM'
String clock12(String? hhmm) {
  if (hhmm == null || hhmm.length < 4) return '';
  final parts = hhmm.split(':');
  final h = int.tryParse(parts[0]) ?? 0;
  final m = parts.length > 1 ? parts[1].padLeft(2, '0') : '00';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:$m ${h < 12 ? 'AM' : 'PM'}';
}

String dayShort(CirclesPrefs p, int isoDay) => p.t('day$isoDay');

/// Localised schedule line, e.g. "6:00 AM – 7:00 AM · daily".
String scheduleLine(CirclesPrefs p, CircleSummary c) {
  final days = [...c.days]..sort();
  final d = days.length == 7
      ? p.t('daily')
      : days.join(',') == '1,2,3,4,5'
          ? p.t('weekdays')
          : days.join(',') == '6,7'
              ? p.t('weekends')
              : days.map((x) => dayShort(p, x)).join(', ');
  return '${clock12(c.startTime)} – ${clock12(c.endTime)} · $d';
}

/// 'YYYY-MM-DD' → "Sat, 1 Nov" (or Today / Tomorrow).
String friendlyDate(CirclesPrefs p, String ymd) {
  final d = DateTime.tryParse(ymd);
  if (d == null) return ymd;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return p.t('today');
  if (diff == 1) return p.t('tomorrow');
  if (diff == -1) return p.t('yesterday');
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${dayShort(p, d.weekday)}, ${d.day} ${months[d.month - 1]}';
}

// ---------------------------------------------------------------------------
// Location & sharing
// ---------------------------------------------------------------------------

/// Current position, or null on web / when location is off or permission is denied.
Future<Position?> currentPosition({bool request = true}) async {
  if (kIsWeb) return null;
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied && request) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
    );
  } catch (_) {
    return null;
  }
}

String inviteText(CirclesPrefs p, CircleSummary c) => p.t('inviteMsg', {
      'name': c.name,
      'place': c.where,
      'time': scheduleLine(p, c),
      'code': c.inviteCode ?? '',
    });

Future<void> shareInvite(BuildContext context, CircleSummary c, {bool whatsapp = false}) async {
  final p = CirclesPrefs.instance;
  final text = inviteText(p, c);
  try {
    if (whatsapp) {
      final ok = await launchUrl(Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
          mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) toast(context, p.t('whatsappMissing'), error: true);
    } else {
      await SharePlus.instance.share(ShareParams(text: text, subject: c.name));
    }
  } catch (_) {
    if (context.mounted) toast(context, p.t('shareFailed'), error: true);
  }
}

// ---------------------------------------------------------------------------
// String table (EN / HI)
// ---------------------------------------------------------------------------

const _en = <String, String>{
  'circles': 'Circles',
  'largeText': 'Large text',
  'language': 'हिंदी / English',
  'heroEyebrow': 'Circles',
  'heroTitle': 'Fitness with your neighbours',
  'heroSub': 'Morning yoga, walks and laughter clubs in your park or society.',
  'create': 'Start a circle',
  'joinCode': 'Join with code',
  'scanQr': 'Scan circle QR',
  'family': 'Family',
  'myCircles': 'My circles',
  'nearMe': 'Circles near me',
  'nearMeSubLoc': 'Sorted by distance from you',
  'nearMeSubCity': 'In {city} · turn on location for distance',
  'nearMeSubAll': 'Add your city in Profile to see circles near you',
  'noNearby': 'No circles here yet',
  'noNearbyMsg': 'Be the first — start one in your park or society and invite your neighbours on WhatsApp.',
  'noMine': 'You have not joined a circle yet',
  'noMatch': 'No circles match "{q}"',
  'members': '{n} members',
  'kmAway': '{km} km away',
  'join': 'Join',
  'joined': 'Joined',
  'joinCircle': 'Join this circle',
  'leader': 'Leader',
  'ledBy': 'Led by {name}',
  'streak': 'Streak',
  'streakN': '{n} in a row',
  'thisMonth': 'This month',
  'ofSessions': '{a} of {b}',
  'markAttendance': "I'm here — mark attendance",
  'attended': 'Present today ✓',
  'attendedMsg': 'Marked present at {name}! Streak: {n}',
  'joinedAndAttended': 'Welcome to {name}! You are marked present.',
  'noSessionToday': 'No session today',
  'sessionOpensAt': 'Attendance opens at {time}',
  'sessionOver': "Today's session is over",
  'sessionOpen': 'Session on now · until {time}',
  'nextSession': 'Next session',
  'today': 'Today',
  'tomorrow': 'Tomorrow',
  'yesterday': 'Yesterday',
  'daily': 'daily',
  'weekdays': 'Mon–Fri',
  'weekends': 'weekends',
  'day1': 'Mon',
  'day2': 'Tue',
  'day3': 'Wed',
  'day4': 'Thu',
  'day5': 'Fri',
  'day6': 'Sat',
  'day7': 'Sun',
  'locating': 'Checking your location…',
  'noLocation': "Couldn't get your location. Scan the QR poster at the spot instead.",
  'webScan': 'Scanning works in the FITKEY mobile app. Ask your leader to mark you, or join with the invite code.',
  'webLocation': 'One-tap attendance uses your location and works in the mobile app.',
  'invite': 'Invite',
  'inviteWhatsapp': 'Invite on WhatsApp',
  'shareInvite': 'Share invite',
  'inviteCode': 'Invite code',
  'inviteMsg':
      'Join my FITKEY Circle "{name}" 🌿\n📍 {place}\n🕕 {time}\n\nOpen the FITKEY app → Community → Circles → Join with code and enter: {code}',
  'whatsappMissing': 'WhatsApp is not available on this device',
  'shareFailed': 'Could not open sharing',
  'copied': 'Copied',
  'chat': 'Circle chat',
  'chatSub': 'Text and voice notes',
  'membersTitle': 'Members',
  'membersSub': 'Streaks and today\'s attendance',
  'markMembers': 'Mark attendance',
  'markMembersSub': 'One tap for members without a phone',
  'qrPoster': 'QR poster',
  'qrPosterSub': 'Print it and stick it at the spot',
  'specialDays': 'Special days',
  'addSpecial': 'Add special day',
  'noSpecials': 'No special days planned',
  'rsvp': "I'll come",
  'going': 'Going ✓',
  'goingN': '{n} going',
  'healthCamp': 'Book health checks',
  'kind_special': 'Special session',
  'kind_festival': 'Festival',
  'kind_yoga_day': 'Yoga Day',
  'kind_health_camp': 'Health camp',
  'mostRegular': 'Most regular member',
  'mostRegularLast': 'Last month: {name} ({n} sessions)',
  'sessionsN': '{n} sessions',
  'noRegular': 'Mark attendance to see who comes most often',
  'cityRank': 'Circle vs Circle',
  'cityRankSub': '#{rank} of {total} in {city} · {rate}% attendance',
  'circleOfMonth': 'Circle of the month',
  'leaderboard': 'Circle vs Circle',
  'leaderboardSub': 'Average attendance this month',
  'seeAll': 'See all',
  'noBoard': 'No attendance in {city} yet this month',
  'rateLabel': '{rate}% attendance',
  'bookTrainer': 'Book a certified trainer',
  'bookTrainerSub': 'Get your circle a qualified yoga or fitness coach.',
  'leave': 'Leave circle',
  'leaveConfirm': 'Leave {name}? Your attendance history stays.',
  'close': 'Close circle',
  'closeConfirm': 'Close {name}? Members will no longer see it.',
  'edit': 'Edit circle',
  'cancel': 'Cancel',
  'confirm': 'Yes',
  'save': 'Save',
  'nameLabel': 'Circle name',
  'nameHint': 'e.g. Sector 12 Morning Yoga',
  'activity': 'Activity',
  'placeLabel': 'Park or society',
  'placeHint': 'e.g. Sector 12 Central Park',
  'areaLabel': 'Area / locality',
  'cityLabel': 'City',
  'descLabel': 'About (optional)',
  'descHint': 'What to bring, who it is for…',
  'pinLabel': 'Map pin',
  'pinSet': 'Pinned at your current location',
  'pinNone': 'Stand at the spot and tap to pin it — members can then tap "I\'m here".',
  'pinUse': 'Use my location',
  'pinClear': 'Remove pin',
  'pinWeb': 'Map pins are set from the mobile app.',
  'days': 'Days',
  'everyday': 'Every day',
  'startTime': 'Starts',
  'endTime': 'Ends',
  'createBtn': 'Create circle',
  'created': 'Circle created! Invite your neighbours.',
  'needDay': 'Pick at least one day',
  'needFields': 'Fill in the name, place and city',
  'enterCode': 'Enter the invite code',
  'codeHint': 'e.g. 9KEA7K',
  'joinBtn': 'Join circle',
  'scanTitle': 'Scan the circle QR',
  'scanSub': 'Point at the poster at your park or society',
  'notCircleQr': "That's not a FITKEY Circle QR",
  'offline': 'Without phone',
  'offlineMembers': 'Members without a phone',
  'addOffline': 'Add member without phone',
  'offlineName': 'Name',
  'offlinePhone': 'Phone (optional)',
  'add': 'Add',
  'remove': 'Remove',
  'present': 'Present',
  'absent': 'Tap to mark',
  'noSessionMark': 'Attendance can be marked on session days only',
  'specialTitle': 'Title',
  'specialTitleHint': 'e.g. Diwali walk',
  'specialType': 'Type',
  'specialDate': 'Date',
  'specialTime': 'Time (optional)',
  'specialNote': 'Note (optional)',
  'specialCreated': 'Special day added — members have been notified',
  'pickDate': 'Pick a date',
  'posterTitle': 'Scan to mark attendance',
  'posterFoot': 'Open FITKEY → Community → Circles → Scan circle QR',
  'sharePoster': 'Share / print poster',
  'newPoster': 'Replace poster',
  'newPosterConfirm': 'Old printed posters will stop working. Continue?',
  'familyTitle': 'Family link',
  'familySub': 'Children can follow a parent\'s circle streaks and get updates.',
  'myCode': 'My family code',
  'myCodeSub': 'Share this with your children so they can follow your streaks.',
  'shareCode': 'Share code',
  'newCode': 'New code',
  'followParent': 'Follow a parent',
  'followParentSub': 'Enter the family code your parent shared',
  'follow': 'Follow',
  'following': 'Following',
  'followers': 'Following you',
  'noFollowing': 'You are not following anyone yet',
  'noFollowingMsg': 'Ask your mother or father for their family code.',
  'notInCircle': 'Not in any circle yet',
  'missedN': 'Missed {n} in a row',
  'lastSeen': 'Last attended {date}',
  'unlink': 'Remove',
  'familyCodeMsg':
      'Follow my FITKEY Circle streaks! Open FITKEY → Community → Circles → Family and enter my code: {code}',
  'linked': 'Linked! You will get updates.',
  'typeMessage': 'Type a message…',
  'holdToRecord': 'Tap the mic to record a voice note',
  'recording': 'Recording… tap stop to send',
  'voiceNote': 'Voice note',
  'micDenied': 'Allow microphone access to send voice notes',
  'voiceWeb': 'Voice notes can be recorded in the mobile app',
  'noMessages': 'Say namaste to your circle',
  'noMessagesMsg': 'Share timings, reminders or a voice note.',
  'act_yoga': 'Yoga',
  'act_walk': 'Morning walk',
  'act_laughter': 'Laughter club',
  'act_running': 'Running',
  'act_dance': 'Dance / Zumba',
  'act_meditation': 'Meditation',
  'act_exercise': 'Exercise',
  'act_cycling': 'Cycling',
  'act_other': 'Other',
};

const _hi = <String, String>{
  'circles': 'सर्कल',
  'largeText': 'बड़े अक्षर',
  'heroEyebrow': 'सर्कल',
  'heroTitle': 'पड़ोसियों के साथ फिटनेस',
  'heroSub': 'आपके पार्क या सोसाइटी में सुबह का योग, सैर और लाफ्टर क्लब।',
  'create': 'नया सर्कल शुरू करें',
  'joinCode': 'कोड से जुड़ें',
  'scanQr': 'सर्कल QR स्कैन करें',
  'family': 'परिवार',
  'myCircles': 'मेरे सर्कल',
  'nearMe': 'मेरे पास के सर्कल',
  'nearMeSubLoc': 'आपसे दूरी के अनुसार',
  'nearMeSubCity': '{city} में · दूरी देखने के लिए लोकेशन चालू करें',
  'nearMeSubAll': 'पास के सर्कल देखने के लिए प्रोफ़ाइल में शहर जोड़ें',
  'noNearby': 'यहाँ अभी कोई सर्कल नहीं है',
  'noNearbyMsg': 'पहल करें — अपने पार्क या सोसाइटी में सर्कल शुरू करें और WhatsApp पर पड़ोसियों को बुलाएँ।',
  'noMine': 'आप अभी किसी सर्कल में नहीं हैं',
  'noMatch': '"{q}" से कोई सर्कल नहीं मिला',
  'members': '{n} सदस्य',
  'kmAway': '{km} किमी दूर',
  'join': 'जुड़ें',
  'joined': 'जुड़ गए',
  'joinCircle': 'इस सर्कल से जुड़ें',
  'leader': 'लीडर',
  'ledBy': 'लीडर: {name}',
  'streak': 'लगातार',
  'streakN': 'लगातार {n}',
  'thisMonth': 'इस महीने',
  'ofSessions': '{b} में से {a}',
  'markAttendance': 'मैं आ गया — हाज़िरी लगाएँ',
  'attended': 'आज हाज़िर ✓',
  'attendedMsg': '{name} में हाज़िरी लग गई! लगातार: {n}',
  'joinedAndAttended': '{name} में स्वागत है! आपकी हाज़िरी लग गई।',
  'noSessionToday': 'आज कोई सत्र नहीं',
  'sessionOpensAt': 'हाज़िरी {time} से',
  'sessionOver': 'आज का सत्र खत्म हो गया',
  'sessionOpen': 'सत्र चल रहा है · {time} तक',
  'nextSession': 'अगला सत्र',
  'today': 'आज',
  'tomorrow': 'कल',
  'yesterday': 'कल (बीता)',
  'daily': 'रोज़',
  'weekdays': 'सोम–शुक्र',
  'weekends': 'शनि–रवि',
  'day1': 'सोम',
  'day2': 'मंगल',
  'day3': 'बुध',
  'day4': 'गुरु',
  'day5': 'शुक्र',
  'day6': 'शनि',
  'day7': 'रवि',
  'locating': 'आपकी लोकेशन देख रहे हैं…',
  'noLocation': 'लोकेशन नहीं मिली। वहाँ लगा QR पोस्टर स्कैन करें।',
  'webScan': 'स्कैन FITKEY मोबाइल ऐप में होता है। लीडर से हाज़िरी लगवाएँ या कोड से जुड़ें।',
  'webLocation': 'एक-टैप हाज़िरी लोकेशन से होती है, यह मोबाइल ऐप में चलती है।',
  'invite': 'बुलाएँ',
  'inviteWhatsapp': 'WhatsApp पर बुलाएँ',
  'shareInvite': 'न्योता भेजें',
  'inviteCode': 'न्योता कोड',
  'inviteMsg':
      'मेरे FITKEY सर्कल "{name}" से जुड़ें 🌿\n📍 {place}\n🕕 {time}\n\nFITKEY ऐप खोलें → Community → Circles → कोड से जुड़ें, और यह कोड डालें: {code}',
  'whatsappMissing': 'इस फ़ोन पर WhatsApp नहीं है',
  'shareFailed': 'शेयर नहीं हो सका',
  'copied': 'कॉपी हो गया',
  'chat': 'सर्कल चैट',
  'chatSub': 'संदेश और वॉइस नोट',
  'membersTitle': 'सदस्य',
  'membersSub': 'लगातार हाज़िरी और आज की हाज़िरी',
  'markMembers': 'हाज़िरी लगाएँ',
  'markMembersSub': 'बिना फ़ोन वाले सदस्यों के लिए एक टैप',
  'qrPoster': 'QR पोस्टर',
  'qrPosterSub': 'प्रिंट करके जगह पर लगाएँ',
  'specialDays': 'खास दिन',
  'addSpecial': 'खास दिन जोड़ें',
  'noSpecials': 'कोई खास दिन तय नहीं',
  'rsvp': 'मैं आऊँगा',
  'going': 'आ रहे हैं ✓',
  'goingN': '{n} आ रहे हैं',
  'healthCamp': 'हेल्थ चेकअप बुक करें',
  'kind_special': 'खास सत्र',
  'kind_festival': 'त्योहार',
  'kind_yoga_day': 'योग दिवस',
  'kind_health_camp': 'हेल्थ कैंप',
  'mostRegular': 'सबसे नियमित सदस्य',
  'mostRegularLast': 'पिछला महीना: {name} ({n} सत्र)',
  'sessionsN': '{n} सत्र',
  'noRegular': 'हाज़िरी लगने पर यहाँ दिखेगा कौन सबसे ज़्यादा आता है',
  'cityRank': 'सर्कल बनाम सर्कल',
  'cityRankSub': '{city} में {total} में से #{rank} · {rate}% हाज़िरी',
  'circleOfMonth': 'महीने का सर्कल',
  'leaderboard': 'सर्कल बनाम सर्कल',
  'leaderboardSub': 'इस महीने की औसत हाज़िरी',
  'seeAll': 'सब देखें',
  'noBoard': 'इस महीने {city} में अभी कोई हाज़िरी नहीं',
  'rateLabel': '{rate}% हाज़िरी',
  'bookTrainer': 'सर्टिफाइड ट्रेनर बुक करें',
  'bookTrainerSub': 'अपने सर्कल के लिए योग या फिटनेस कोच पाएँ।',
  'leave': 'सर्कल छोड़ें',
  'leaveConfirm': '{name} छोड़ना है? आपकी हाज़िरी का रिकॉर्ड रहेगा।',
  'close': 'सर्कल बंद करें',
  'closeConfirm': '{name} बंद करना है? सदस्यों को यह नहीं दिखेगा।',
  'edit': 'सर्कल बदलें',
  'cancel': 'रद्द करें',
  'confirm': 'हाँ',
  'save': 'सेव करें',
  'nameLabel': 'सर्कल का नाम',
  'nameHint': 'जैसे सेक्टर 12 सुबह का योग',
  'activity': 'गतिविधि',
  'placeLabel': 'पार्क या सोसाइटी',
  'placeHint': 'जैसे सेक्टर 12 सेंट्रल पार्क',
  'areaLabel': 'इलाका',
  'cityLabel': 'शहर',
  'descLabel': 'जानकारी (वैकल्पिक)',
  'descHint': 'क्या लाना है, किसके लिए है…',
  'pinLabel': 'नक्शे पर जगह',
  'pinSet': 'आपकी अभी की लोकेशन पर पिन किया',
  'pinNone': 'उस जगह खड़े होकर टैप करें — फिर सदस्य "मैं आ गया" दबा सकेंगे।',
  'pinUse': 'मेरी लोकेशन लें',
  'pinClear': 'पिन हटाएँ',
  'pinWeb': 'नक्शे का पिन मोबाइल ऐप से लगता है।',
  'days': 'दिन',
  'everyday': 'रोज़',
  'startTime': 'शुरू',
  'endTime': 'खत्म',
  'createBtn': 'सर्कल बनाएँ',
  'created': 'सर्कल बन गया! पड़ोसियों को बुलाएँ।',
  'needDay': 'कम से कम एक दिन चुनें',
  'needFields': 'नाम, जगह और शहर भरें',
  'enterCode': 'न्योता कोड डालें',
  'codeHint': 'जैसे 9KEA7K',
  'joinBtn': 'सर्कल से जुड़ें',
  'scanTitle': 'सर्कल QR स्कैन करें',
  'scanSub': 'पार्क या सोसाइटी में लगे पोस्टर की ओर कैमरा करें',
  'notCircleQr': 'यह FITKEY सर्कल QR नहीं है',
  'offline': 'बिना फ़ोन',
  'offlineMembers': 'बिना फ़ोन वाले सदस्य',
  'addOffline': 'बिना फ़ोन वाला सदस्य जोड़ें',
  'offlineName': 'नाम',
  'offlinePhone': 'फ़ोन (वैकल्पिक)',
  'add': 'जोड़ें',
  'remove': 'हटाएँ',
  'present': 'हाज़िर',
  'absent': 'हाज़िरी लगाएँ',
  'noSessionMark': 'हाज़िरी सिर्फ़ सत्र वाले दिन लगती है',
  'specialTitle': 'नाम',
  'specialTitleHint': 'जैसे दिवाली सैर',
  'specialType': 'प्रकार',
  'specialDate': 'तारीख',
  'specialTime': 'समय (वैकल्पिक)',
  'specialNote': 'नोट (वैकल्पिक)',
  'specialCreated': 'खास दिन जुड़ गया — सदस्यों को बता दिया गया',
  'pickDate': 'तारीख चुनें',
  'posterTitle': 'हाज़िरी के लिए स्कैन करें',
  'posterFoot': 'FITKEY खोलें → Community → Circles → सर्कल QR स्कैन करें',
  'sharePoster': 'पोस्टर शेयर / प्रिंट करें',
  'newPoster': 'नया पोस्टर बनाएँ',
  'newPosterConfirm': 'पुराने छपे पोस्टर काम नहीं करेंगे। आगे बढ़ें?',
  'familyTitle': 'परिवार से जोड़ें',
  'familySub': 'बच्चे माता-पिता की सर्कल हाज़िरी देख सकते हैं और अपडेट पा सकते हैं।',
  'myCode': 'मेरा परिवार कोड',
  'myCodeSub': 'यह कोड बच्चों को भेजें ताकि वे आपकी हाज़िरी देख सकें।',
  'shareCode': 'कोड भेजें',
  'newCode': 'नया कोड',
  'followParent': 'माता-पिता को फ़ॉलो करें',
  'followParentSub': 'माता-पिता का भेजा परिवार कोड डालें',
  'follow': 'फ़ॉलो करें',
  'following': 'जिन्हें आप फ़ॉलो करते हैं',
  'followers': 'जो आपको फ़ॉलो करते हैं',
  'noFollowing': 'आप अभी किसी को फ़ॉलो नहीं करते',
  'noFollowingMsg': 'अपनी माँ या पिताजी से उनका परिवार कोड माँगें।',
  'notInCircle': 'अभी किसी सर्कल में नहीं',
  'missedN': 'लगातार {n} छूटे',
  'lastSeen': 'आख़िरी हाज़िरी {date}',
  'unlink': 'हटाएँ',
  'familyCodeMsg': 'मेरी FITKEY सर्कल हाज़िरी फ़ॉलो करें! FITKEY खोलें → Community → Circles → परिवार, और मेरा कोड डालें: {code}',
  'linked': 'जुड़ गए! आपको अपडेट मिलेंगे।',
  'typeMessage': 'संदेश लिखें…',
  'holdToRecord': 'वॉइस नोट के लिए माइक दबाएँ',
  'recording': 'रिकॉर्ड हो रहा है… भेजने के लिए रोकें',
  'voiceNote': 'वॉइस नोट',
  'micDenied': 'वॉइस नोट के लिए माइक की अनुमति दें',
  'voiceWeb': 'वॉइस नोट मोबाइल ऐप में रिकॉर्ड होते हैं',
  'noMessages': 'अपने सर्कल को नमस्ते कहें',
  'noMessagesMsg': 'समय, याद दिलाने वाली बातें या वॉइस नोट भेजें।',
  'act_yoga': 'योग',
  'act_walk': 'सुबह की सैर',
  'act_laughter': 'लाफ्टर क्लब',
  'act_running': 'दौड़',
  'act_dance': 'डांस / ज़ुम्बा',
  'act_meditation': 'ध्यान',
  'act_exercise': 'व्यायाम',
  'act_cycling': 'साइकिलिंग',
  'act_other': 'अन्य',
};
