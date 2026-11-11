import 'package:flutter/services.dart';

// Business-email handling (Partner BRD §2 bug: valid addresses like name@gmail.com were rejected).
//
// Root cause: Android keyboards (Samsung / Gboard with autocorrect + "smart punctuation") and autofill insert
// characters the old check `^[^@\s]+@[^@\s]+\.[^@\s]+$` choked on: a space after the "." ("name@gmail. com"),
// a non-breaking or zero-width space (not removed by String.trim) or a trailing space mid-edit; autocorrect also
// capitalised the first letter. The field now strips every kind of whitespace / invisible character as you type,
// lower-cases on save, disables autocorrect / suggestions / capitalisation, and validates with a sane pattern.

/// All Unicode whitespace plus zero-width / BOM / word-joiner / soft-hyphen characters.
final _invisible = RegExp(r'[\s ­ ᠎ -‏ -  ⁠　﻿]');

/// local@domain.tld — letters, digits and . _ % + - ' in the local part; dotted domain labels; 2+ letter TLD.
final _emailPattern = RegExp(r"^[a-z0-9._%+'-]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$");

/// Removes invisible characters and lower-cases: what we validate and send to the server.
String normalizeEmail(String raw) => raw.replaceAll(_invisible, '').toLowerCase();

bool isValidEmail(String raw) {
  final e = normalizeEmail(raw);
  if (e.length > 254 || e.contains('..')) return false;
  final local = e.split('@').first;
  if (local.startsWith('.') || local.endsWith('.')) return false;
  return _emailPattern.hasMatch(e);
}

/// Form validator. [required] = false accepts an empty field.
String? emailValidator(String? v, {bool required = true}) {
  final e = normalizeEmail(v ?? '');
  if (e.isEmpty) return required ? 'Enter your email' : null;
  return isValidEmail(e) ? null : 'Enter a valid email, like name@gmail.com';
}

/// Strips spaces / invisible characters while typing (keeps the cursor in place).
class NoWhitespaceFormatter extends TextInputFormatter {
  const NoWhitespaceFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (!_invisible.hasMatch(newValue.text)) return newValue;
    final before = newValue.selection.baseOffset.clamp(0, newValue.text.length);
    final head = newValue.text.substring(0, before).replaceAll(_invisible, '');
    final text = newValue.text.replaceAll(_invisible, '');
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: head.length));
  }
}
