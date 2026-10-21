import 'package:intl/intl.dart';

final _rupees = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

String formatPaise(int paise) => _rupees.format(paise / 100);
String formatInr(int paise) => formatPaise(paise);

String formatDate(DateTime d) => DateFormat('d MMM yyyy').format(d);
String formatShortDate(DateTime d) => DateFormat('d MMM').format(d);
String formatDayDate(DateTime d) => DateFormat('EEE, d MMM').format(d);
String formatDateTime(DateTime d) => DateFormat('d MMM, h:mm a').format(d);
String formatClock(DateTime d) => DateFormat('h:mm a').format(d);

/// "YYYY-MM-DD" for API payloads.
String apiDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

/// "18:30:00" → "6:30 PM"
String formatTimeOfDay(String? hhmmss) {
  if (hhmmss == null || hhmmss.length < 5) return '--';
  final h = int.parse(hhmmss.substring(0, 2));
  final m = hhmmss.substring(3, 5);
  final suffix = h >= 12 ? 'PM' : 'AM';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:$m $suffix';
}

String formatDuration(int? seconds) {
  if (seconds == null) return '';
  final m = seconds ~/ 60;
  return m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '$m min';
}

String formatNumber(num n) => n % 1 == 0 ? n.toInt().toString() : n.toStringAsFixed(1);

String initials(String? name) {
  final parts = (name ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return parts.take(2).map((p) => p[0].toUpperCase()).join();
}
