// "Documents & bank" listing step (Partner BRD §6.2 / contract §C): documents per entity, owner KYC (last 4 Aadhaar
// digits only) and the payout bank account (penny-drop verified). Shared by the venue editor, the other partner
// types' wizard and the assisted-listing handover.

import 'dart:async';

import 'package:dio/dio.dart' show DioMediaType, FormData, MultipartFile;
import 'package:file_picker/file_picker.dart' show FilePicker, FileType;
import 'package:fitkey_core/fitkey_core.dart' show ApiException, resolveMediaUrl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/brd_api.dart';
import '../../data/partner_api.dart';
import '../../state/partner_session.dart';
import '../../ui/ui.dart';

// ---------------------------------------------------------------------------------------------------------------
// Validators (pure — unit tested in test/listing_validators_test.dart)
// ---------------------------------------------------------------------------------------------------------------

abstract final class ListingValidators {
  /// Indian IFSC: 4 letters (bank), a literal 0, then 6 letters/digits (branch). E.g. HDFC0001234.
  static final ifscPattern = RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$');

  static String? ifsc(String? v) {
    final s = (v ?? '').trim().toUpperCase();
    if (s.isEmpty) return 'Enter the IFSC code';
    if (s.length != 11) return 'IFSC has 11 characters, e.g. HDFC0001234';
    if (!ifscPattern.hasMatch(s)) return 'Invalid IFSC — 4 letters, then 0, then 6 letters/digits';
    return null;
  }

  /// Bank account numbers in India are 9–18 digits.
  static String? accountNumber(String? v) {
    final s = (v ?? '').replaceAll(' ', '');
    if (s.isEmpty) return 'Enter the account number';
    if (!RegExp(r'^\d+$').hasMatch(s)) return 'Digits only';
    if (s.length < 9 || s.length > 18) return 'Account numbers have 9–18 digits';
    return null;
  }

  static String? confirmAccountNumber(String? account, String? confirm) {
    final c = (confirm ?? '').replaceAll(' ', '');
    if (c.isEmpty) return 'Re-enter the account number';
    if (c != (account ?? '').replaceAll(' ', '')) return 'Account numbers don\'t match';
    return null;
  }

  /// Only the LAST 4 digits of Aadhaar are ever collected. A 12-digit number is refused outright.
  static String? aadhaarLast4(String? v) {
    final s = (v ?? '').replaceAll(RegExp(r'[\s-]'), '');
    if (s.isEmpty) return 'Enter the last 4 digits';
    if (s.length > 4) return 'Enter only the last 4 digits — never your full Aadhaar number';
    if (!RegExp(r'^\d{4}$').hasMatch(s)) return 'Enter exactly 4 digits';
    return null;
  }

  static String? nameOnId(String? v) {
    final s = (v ?? '').trim();
    if (s.length < 2) return 'Enter the name as printed on your ID';
    return null;
  }

  static String? holderName(String? v) {
    final s = (v ?? '').trim();
    if (s.length < 2) return 'Enter the account holder\'s name';
    return null;
  }

  /// Masked display: XXXX-XXXX-1234.
  static String maskAadhaar(String last4) => 'XXXX-XXXX-$last4';
}

/// Upper-cases as you type (IFSC).
class UpperCaseFormatter extends TextInputFormatter {
  const UpperCaseFormatter();
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

// ---------------------------------------------------------------------------------------------------------------
// Upload helper (photos + PDFs)
// ---------------------------------------------------------------------------------------------------------------

DioMediaType _mediaFor(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.pdf')) return DioMediaType('application', 'pdf');
  if (n.endsWith('.png')) return DioMediaType('image', 'png');
  if (n.endsWith('.webp')) return DioMediaType('image', 'webp');
  return DioMediaType('image', 'jpeg');
}

/// Uploads document bytes (photo or PDF) to `POST /uploads` and returns the server URL.
Future<String> uploadDocumentBytes(PartnerApi api, List<int> bytes, String filename) async {
  final r = await api.client.post(
    '/uploads',
    FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: filename, contentType: _mediaFor(filename))}),
  );
  return r['url'] as String;
}

bool _isPdf(String url) => url.toLowerCase().split('?').first.endsWith('.pdf');

const _docHints = {
  'licence': ('Licence / registration no.', Icons.storefront_rounded),
  'gst': ('GSTIN (15 characters)', Icons.receipt_long_rounded),
  'fssai': ('FSSAI licence no. (14 digits)', Icons.restaurant_rounded),
  'drug_licence': ('Drug licence no.', Icons.local_pharmacy_rounded),
  'clinic_registration': ('Registration no.', Icons.local_hospital_rounded),
  'doctor_registration': ('Medical council reg. no.', Icons.medical_information_rounded),
  'certificate': ('Certificate no. (optional)', Icons.workspace_premium_rounded),
  'achievement': ('Title / year (optional)', Icons.emoji_events_rounded),
  'trademark': ('Trademark application no.', Icons.verified_rounded),
  'other': ('Reference no. (optional)', Icons.description_rounded),
};

/// Doc types where several files make sense (one per doctor / certificate).
const _multiDocTypes = {'certificate', 'achievement', 'doctor_registration', 'other'};

// ---------------------------------------------------------------------------------------------------------------
// The step
// ---------------------------------------------------------------------------------------------------------------

class DocumentsBankStep extends StatefulWidget {
  const DocumentsBankStep({
    super.key,
    required this.entityType,
    required this.entityId,
    required this.requiredDocTypes,
    this.optionalDocTypes = const [],
    this.onReadyChanged,
  });

  final String entityType;
  final String entityId;
  final List<String> requiredDocTypes;
  final List<String> optionalDocTypes;

  /// true once every required document + KYC + bank account exist (pending or verified).
  final ValueChanged<bool>? onReadyChanged;

  @override
  State<DocumentsBankStep> createState() => _DocumentsBankStepState();
}

class _DocumentsBankStepState extends State<DocumentsBankStep> {
  List<PartnerDocument> _docs = const [];
  bool _docsLoaded = false;
  Object? _docsError;
  bool _kycOk = false;
  bool _bankOk = false;
  bool? _lastReady;

  @override
  void initState() {
    super.initState();
    _loadDocs();
  }

  @override
  void didUpdateWidget(DocumentsBankStep old) {
    super.didUpdateWidget(old);
    if (old.entityId != widget.entityId || old.entityType != widget.entityType) {
      _loadDocs();
    } else {
      _emitReady();
    }
  }

  Future<void> _loadDocs() async {
    try {
      final d = await context.read<PartnerSession>().api.documents(widget.entityType, widget.entityId);
      if (!mounted) return;
      setState(() {
        _docs = d;
        _docsLoaded = true;
        _docsError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _docsError = e);
    }
    _emitReady();
  }

  bool _hasDoc(String type) => _docs.any((d) => d.docType == type && d.status != 'rejected');

  void _emitReady() {
    final ready = _docsLoaded && widget.requiredDocTypes.every(_hasDoc) && _kycOk && _bankOk;
    if (ready == _lastReady) return;
    _lastReady = ready;
    final cb = widget.onReadyChanged;
    if (cb != null) WidgetsBinding.instance.addPostFrameCallback((_) => cb(ready));
  }

  @override
  Widget build(BuildContext context) {
    final types = [
      for (final t in widget.requiredDocTypes) (t, true),
      for (final t in widget.optionalDocTypes)
        if (!widget.requiredDocTypes.contains(t)) (t, false),
    ];
    final requiredDone = widget.requiredDocTypes.where(_hasDoc).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _StepIntro(
        done: requiredDone,
        total: widget.requiredDocTypes.length,
        kycOk: _kycOk,
        bankOk: _bankOk,
      ),
      const SizedBox(height: 18),
      _GroupLabel('Documents', trailing: '$requiredDone/${widget.requiredDocTypes.length} added'),
      const SizedBox(height: 8),
      if (_docsError != null && !_docsLoaded)
        AppCard(
          shadow: false,
          border: true,
          child: Row(children: [
            const Icon(Icons.wifi_off_rounded, color: AppColors.text3),
            const SizedBox(width: 10),
            Expanded(child: Text(friendlyError(_docsError!), style: const TextStyle(color: AppColors.text2))),
            TextButton(onPressed: _loadDocs, child: const Text('Retry')),
          ]),
        )
      else if (!_docsLoaded)
        const Column(children: [SkeletonBox(height: 84, radius: 18), SizedBox(height: 10), SkeletonBox(height: 84, radius: 18)])
      else
        for (final (t, req) in types)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _DocTypeCard(
              docType: t,
              required: req,
              docs: _docs.where((d) => d.docType == t).toList(),
              entityType: widget.entityType,
              entityId: widget.entityId,
              onChanged: _loadDocs,
            ),
          ),
      const SizedBox(height: 10),
      const _GroupLabel('Owner KYC'),
      const SizedBox(height: 8),
      OwnerKycCard(onChanged: (ok) {
        _kycOk = ok;
        if (mounted) setState(() {});
        _emitReady();
      }),
      const SizedBox(height: 18),
      const _GroupLabel('Payout bank account'),
      const SizedBox(height: 8),
      BankAccountCard(onChanged: (ok) {
        _bankOk = ok;
        if (mounted) setState(() {});
        _emitReady();
      }),
    ]);
  }
}

class _StepIntro extends StatelessWidget {
  const _StepIntro({required this.done, required this.total, required this.kycOk, required this.bankOk});
  final int done;
  final int total;
  final bool kycOk;
  final bool bankOk;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, bool ok) => Tag(
          label,
          icon: ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
          color: ok ? AppColors.green : AppColors.text3,
          bg: ok ? AppColors.greenSoft : AppColors.surfaceAlt,
        );
    return AppCard(
      color: AppColors.blueSoft,
      shadow: false,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.shield_rounded, color: AppColors.blue, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text('Verify your business', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
        ]),
        const SizedBox(height: 6),
        const Text(
          'Optional — add these now or later. Verified documents earn a trust badge, and a verified bank account is needed before your first payout. Never shown to members.',
          style: TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.4),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          chip('Documents $done/$total', total == 0 || done >= total),
          chip('KYC', kycOk),
          chip('Bank', bankOk),
        ]),
      ]),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.title, {this.trailing});
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: Text(title.toUpperCase(),
              style: const TextStyle(fontSize: 12, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: AppColors.text3)),
        ),
        if (trailing != null)
          Text(trailing!, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.text3)),
      ]);
}

// ---------------------------------------------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------------------------------------------

class _DocStatusPill extends StatelessWidget {
  const _DocStatusPill(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status) {
      'verified' => ('VERIFIED', AppColors.green, Icons.verified_rounded),
      'rejected' => ('REJECTED', AppColors.red, Icons.error_rounded),
      'failed' => ('FAILED', AppColors.red, Icons.error_rounded),
      _ => ('PENDING', AppColors.amber, Icons.schedule_rounded),
    };
    return Tag(label, color: color, icon: icon, dense: true);
  }
}

class _DocTypeCard extends StatelessWidget {
  const _DocTypeCard({
    required this.docType,
    required this.required,
    required this.docs,
    required this.entityType,
    required this.entityId,
    required this.onChanged,
  });

  final String docType;
  final bool required;
  final List<PartnerDocument> docs;
  final String entityType;
  final String entityId;
  final Future<void> Function() onChanged;

  String get _label => PartnerDocument.labels[docType] ?? docType;

  Future<void> _add(BuildContext context, {PartnerDocument? replacing}) async {
    final saved = await showAppSheet<bool>(
      context,
      builder: (_) => _DocUploadSheet(
        docType: docType,
        label: _label,
        entityType: entityType,
        entityId: entityId,
        replacing: replacing,
      ),
    );
    if (saved == true) await onChanged();
  }

  Future<void> _delete(BuildContext context, PartnerDocument d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${d.label.toLowerCase()}?'),
        content: const Text('You can upload a new file any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await context.read<PartnerSession>().api.deleteDocument(d.id);
      await onChanged();
    } catch (e) {
      if (context.mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = _docHints[docType]?.$2 ?? Icons.description_rounded;
    final has = docs.any((d) => d.status != 'rejected');
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          IconBubble(icon, color: has ? AppColors.green : AppColors.blue, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
              const SizedBox(height: 2),
              Text(
                required ? 'Recommended' : 'Optional',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: required && !has ? AppColors.primary : AppColors.text3,
                ),
              ),
            ]),
          ),
          if (docs.isEmpty)
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
              onPressed: () => _add(context),
              icon: const Icon(Icons.upload_rounded, size: 18),
              label: const Text('Upload'),
            )
          else if (_multiDocTypes.contains(docType))
            TextButton.icon(
              onPressed: () => _add(context),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add'),
            ),
        ]),
        for (final d in docs) ...[
          const SizedBox(height: 10),
          _DocRow(
            doc: d,
            onReplace: () => _add(context, replacing: d),
            onDelete: () => _delete(context, d),
          ),
        ],
      ]),
    );
  }
}

class _DocRow extends StatelessWidget {
  const _DocRow({required this.doc, required this.onReplace, required this.onDelete});
  final PartnerDocument doc;
  final VoidCallback onReplace;
  final VoidCallback onDelete;

  Future<void> _open(BuildContext context) async {
    final url = resolveMediaUrl(doc.fileUrl);
    if (url == null) return;
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!ok && context.mounted) toast(context, 'Could not open the file', error: true);
  }

  @override
  Widget build(BuildContext context) {
    final pdf = _isPdf(doc.fileUrl);
    final fmt = DateFormat('d MMM yyyy');
    final expired = doc.expiresOn != null && doc.expiresOn!.isBefore(DateTime.now());
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: doc.status == 'rejected' ? AppColors.redSoft : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Tap(
            onTap: () => _open(context),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 48,
                height: 48,
                child: pdf
                    ? Container(
                        color: AppColors.redSoft,
                        child: const Icon(Icons.picture_as_pdf_rounded, color: AppColors.red),
                      )
                    : NetImage(doc.fileUrl, fallback: AppImages.gym, width: 48, height: 48),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(
                    (doc.docNumber ?? '').isEmpty ? (pdf ? 'PDF document' : 'Photo') : doc.docNumber!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                  ),
                ),
                const SizedBox(width: 6),
                _DocStatusPill(doc.status),
              ]),
              if (doc.expiresOn != null)
                Text(
                  expired ? 'Expired ${fmt.format(doc.expiresOn!)}' : 'Valid till ${fmt.format(doc.expiresOn!)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: expired ? AppColors.red : AppColors.text3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ]),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: AppColors.text2),
            onSelected: (v) => switch (v) {
              'view' => _open(context),
              'replace' => onReplace(),
              _ => onDelete(),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'view', child: Text('View file')),
              const PopupMenuItem(value: 'replace', child: Text('Replace')),
              if (doc.status != 'verified')
                const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: AppColors.red))),
            ],
          ),
        ]),
        if (doc.status == 'rejected' || (doc.reviewNote ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded,
                size: 16, color: doc.status == 'rejected' ? AppColors.red : AppColors.text3),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                (doc.reviewNote ?? '').isEmpty ? 'Rejected — please upload a clearer copy.' : doc.reviewNote!,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  color: doc.status == 'rejected' ? AppColors.red : AppColors.text2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ]),
          if (doc.status == 'rejected')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onReplace,
                icon: const Icon(Icons.upload_rounded, size: 18),
                label: const Text('Upload a new copy'),
              ),
            ),
        ],
      ]),
    );
  }
}

class _PickedFile {
  _PickedFile(this.name, this.bytes);
  final String name;
  final List<int> bytes;
  bool get isPdf => name.toLowerCase().endsWith('.pdf');
}

class _DocUploadSheet extends StatefulWidget {
  const _DocUploadSheet({
    required this.docType,
    required this.label,
    required this.entityType,
    required this.entityId,
    this.replacing,
  });

  final String docType;
  final String label;
  final String entityType;
  final String entityId;
  final PartnerDocument? replacing;

  @override
  State<_DocUploadSheet> createState() => _DocUploadSheetState();
}

class _DocUploadSheetState extends State<_DocUploadSheet> {
  late final _number = TextEditingController(text: widget.replacing?.docNumber ?? '');
  late DateTime? _expires = widget.replacing?.expiresOn;
  _PickedFile? _file;
  bool _busy = false;
  String? _error;

  static const _maxBytes = 8 * 1024 * 1024;

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final f = await ImagePicker().pickImage(source: source, maxWidth: 2000, imageQuality: 85);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final name = f.name.isEmpty ? 'document.jpg' : f.name;
      _setFile(_PickedFile(name, bytes));
    } catch (_) {
      if (mounted) toast(context, 'Could not open the camera / photos', error: true);
    }
  }

  Future<void> _pickPdf() async {
    try {
      final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png']);
      if (f == null) return;
      _setFile(_PickedFile(f.name, await f.readAsBytes()));
    } catch (_) {
      if (mounted) toast(context, 'Could not open your files', error: true);
    }
  }

  void _setFile(_PickedFile f) {
    if (!mounted) return;
    if (f.bytes.length > _maxBytes) {
      setState(() => _error = 'File is larger than 8 MB — please choose a smaller one.');
      return;
    }
    setState(() {
      _file = f;
      _error = null;
    });
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _expires ?? DateTime(now.year + 1, now.month, now.day),
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: DateTime(now.year + 30),
      helpText: 'Valid till',
    );
    if (d != null) setState(() => _expires = d);
  }

  Future<void> _save() async {
    if (_file == null) {
      setState(() => _error = 'Choose a photo or PDF first');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<PartnerSession>().api;
    try {
      final url = await uploadDocumentBytes(api, _file!.bytes, _file!.name);
      await api.addDocument(
        entityType: widget.entityType,
        entityId: widget.entityId,
        docType: widget.docType,
        fileUrl: url,
        docNumber: _number.text.trim().isEmpty ? null : _number.text.trim(),
        expiresOn: _expires,
      );
      if (widget.replacing != null) {
        // The new copy is saved — removing the old one is best effort.
        await api.deleteDocument(widget.replacing!.id).catchError((_) {});
      }
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = _docHints[widget.docType]?.$1 ?? 'Document no.';
    final f = _file;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        const SizedBox(height: 14),
        Text(widget.replacing == null ? 'Upload ${widget.label.toLowerCase()}' : 'Replace ${widget.label.toLowerCase()}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
        const SizedBox(height: 4),
        const Text('A clear photo of the full document, or a PDF (max 8 MB).',
            style: TextStyle(color: AppColors.text2, fontSize: 13)),
        const SizedBox(height: 16),
        if (f == null)
          Row(children: [
            Expanded(child: _SourceTile(icon: Icons.photo_camera_rounded, label: 'Camera', onTap: () => _pickPhoto(ImageSource.camera))),
            const SizedBox(width: 10),
            Expanded(child: _SourceTile(icon: Icons.photo_library_rounded, label: 'Photos', onTap: () => _pickPhoto(ImageSource.gallery))),
            const SizedBox(width: 10),
            Expanded(child: _SourceTile(icon: Icons.picture_as_pdf_rounded, label: 'PDF / file', onTap: _pickPdf)),
          ])
        else
          AppCard(
            shadow: false,
            border: true,
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              IconBubble(f.isPdf ? Icons.picture_as_pdf_rounded : Icons.image_rounded,
                  color: f.isPdf ? AppColors.red : AppColors.blue, size: 40),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${(f.bytes.length / 1024).ceil()} KB',
                      style: const TextStyle(color: AppColors.text3, fontSize: 12)),
                ]),
              ),
              TextButton(onPressed: _busy ? null : () => setState(() => _file = null), child: const Text('Change')),
            ]),
          ),
        const SizedBox(height: 14),
        TextField(
          controller: _number,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: hint, prefixIcon: const Icon(Icons.tag_rounded)),
        ),
        const SizedBox(height: 10),
        Tap(
          onTap: _pickExpiry,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Valid till (if it expires)',
              prefixIcon: const Icon(Icons.event_rounded),
              suffixIcon: _expires == null
                  ? null
                  : IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => _expires = null)),
            ),
            child: Text(
              _expires == null ? 'No expiry' : DateFormat('d MMM yyyy').format(_expires!),
              style: TextStyle(color: _expires == null ? AppColors.text3 : AppColors.text),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 18),
        AppButton(label: 'Save document', icon: Icons.cloud_upload_rounded, busy: _busy, onPressed: _save),
      ]),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AppCard(
        onTap: onTap,
        shadow: false,
        border: true,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Column(children: [
          Icon(icon, color: AppColors.primary, size: 26),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
        ]),
      );
}

// ---------------------------------------------------------------------------------------------------------------
// Owner KYC (BRD §6.2) — only the last 4 Aadhaar digits ever leave the phone.
// ---------------------------------------------------------------------------------------------------------------

class OwnerKycCard extends StatefulWidget {
  const OwnerKycCard({super.key, this.onChanged});

  /// true when a KYC record exists (pending or verified).
  final ValueChanged<bool>? onChanged;

  @override
  State<OwnerKycCard> createState() => _OwnerKycCardState();
}

class _OwnerKycCardState extends State<OwnerKycCard> {
  final _form = GlobalKey<FormState>();
  final _last4 = TextEditingController();
  final _name = TextEditingController();
  String _method = 'digilocker';
  PartnerKyc? _kyc;
  bool _loading = true;
  bool _editing = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _last4.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final k = await context.read<PartnerSession>().api.kyc();
      if (!mounted) return;
      setState(() {
        _kyc = k;
        _loading = false;
        _error = null;
      });
      widget.onChanged?.call(k != null && k.status != 'rejected' && k.status != 'failed');
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final k = await context.read<PartnerSession>().api.submitKyc(
            method: _method,
            aadhaarLast4: _last4.text.trim(),
            nameOnId: _name.text.trim(),
          );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _kyc = k;
        _editing = false;
        _last4.clear();
      });
      widget.onChanged?.call(k.status != 'rejected' && k.status != 'failed');
      toast(context, k.status == 'verified' ? 'KYC verified' : 'KYC submitted', icon: Icons.verified_user_rounded);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SkeletonBox(height: 120, radius: 20);
    final k = _kyc;
    if (k != null && !_editing) return _summary(k);
    return AppCard(
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [
            IconBubble(Icons.badge_rounded, color: AppColors.purple, size: 40),
            SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Verify the owner', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                Text('Aadhaar-based KYC · takes a minute', style: TextStyle(color: AppColors.text3, fontSize: 12.5)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'digilocker', label: Text('DigiLocker'), icon: Icon(Icons.cloud_done_rounded)),
              ButtonSegment(value: 'offline_ekyc', label: Text('Offline e-KYC'), icon: Icon(Icons.qr_code_2_rounded)),
            ],
            selected: {_method},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _method = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            _method == 'digilocker'
                ? 'Confirm your Aadhaar through DigiLocker — no card photo needed.'
                : 'Use the Aadhaar offline e-KYC (paperless XML / QR) — no card photo needed.',
            style: const TextStyle(color: AppColors.text2, fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            validator: ListingValidators.nameOnId,
            decoration: const InputDecoration(labelText: 'Name as on Aadhaar', prefixIcon: Icon(Icons.person_rounded)),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _last4,
            keyboardType: TextInputType.number,
            maxLength: 4,
            obscureText: false,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
            validator: ListingValidators.aadhaarLast4,
            decoration: const InputDecoration(
              labelText: 'Last 4 digits of Aadhaar',
              prefixText: 'XXXX-XXXX-',
              prefixIcon: Icon(Icons.pin_rounded),
              counterText: '',
            ),
          ),
          const SizedBox(height: 10),
          const _PrivacyNote(
            'We store only XXXX-XXXX-1234 — never your full Aadhaar number or card image.',
            icon: Icons.lock_rounded,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 14),
          AppButton(
            label: _method == 'digilocker' ? 'Verify with DigiLocker' : 'Verify with Aadhaar offline e-KYC',
            icon: Icons.verified_user_rounded,
            busy: _busy,
            onPressed: _submit,
          ),
          if (_editing)
            TextButton(onPressed: _busy ? null : () => setState(() => _editing = false), child: const Text('Cancel')),
        ]),
      ),
    );
  }

  Widget _summary(PartnerKyc k) {
    final ok = k.status == 'verified';
    final bad = k.status == 'rejected' || k.status == 'failed';
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          IconBubble(ok ? Icons.verified_user_rounded : Icons.badge_rounded,
              color: ok ? AppColors.green : (bad ? AppColors.red : AppColors.amber), size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k.nameOnId ?? 'Owner', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              Text('Aadhaar ${k.aadhaarMasked} · ${k.method == 'digilocker' ? 'DigiLocker' : 'Offline e-KYC'}',
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ]),
          ),
          _DocStatusPill(k.status),
        ]),
        const SizedBox(height: 10),
        const _PrivacyNote('We store only the masked number — never your full Aadhaar number or card image.',
            icon: Icons.lock_rounded),
        if (!ok)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() {
                _editing = true;
                _name.text = k.nameOnId ?? '';
                _method = k.method == 'offline_ekyc' ? 'offline_ekyc' : 'digilocker';
              }),
              child: Text(bad ? 'Verify again' : 'Edit details'),
            ),
          ),
      ]),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote(this.text, {required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: AppColors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 12.5, height: 1.35, color: AppColors.text, fontWeight: FontWeight.w600)),
          ),
        ]),
      );
}

// ---------------------------------------------------------------------------------------------------------------
// Bank account (penny-drop verified)
// ---------------------------------------------------------------------------------------------------------------

class BankAccountCard extends StatefulWidget {
  const BankAccountCard({super.key, this.onChanged, this.startEditing = false});

  /// true when an account exists (pending or verified), or when it is hidden from a FitKey employee (the owner
  /// confirms it at handover; the server's checklist is the source of truth).
  final ValueChanged<bool>? onChanged;

  /// Open the form straight away (e.g. "Change account" at handover).
  final bool startEditing;

  @override
  State<BankAccountCard> createState() => _BankAccountCardState();
}

class _BankAccountCardState extends State<BankAccountCard> {
  final _form = GlobalKey<FormState>();
  final _holder = TextEditingController();
  final _account = TextEditingController();
  final _confirm = TextEditingController();
  final _ifsc = TextEditingController();
  PartnerBank? _bank;
  bool _loading = true;
  bool _hidden = false;
  late bool _editing = widget.startEditing;
  bool _busy = false;
  bool _showNumber = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_holder, _account, _confirm, _ifsc]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final b = await context.read<PartnerSession>().api.bank();
      if (!mounted) return;
      setState(() {
        _bank = b;
        _loading = false;
        _error = null;
      });
      widget.onChanged?.call(b != null && b.status != 'failed');
    } on ApiException catch (e) {
      if (!mounted) return;
      // FitKey employees acting for a partner can't see bank details (contract §D).
      if (e.statusCode == 403) {
        setState(() {
          _hidden = true;
          _loading = false;
        });
        widget.onChanged?.call(true);
      } else {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final b = await context.read<PartnerSession>().api.saveBank(
            holderName: _holder.text.trim(),
            accountNumber: _account.text.replaceAll(' ', ''),
            ifsc: _ifsc.text.trim().toUpperCase(),
          );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _bank = b;
        _editing = false;
        _account.clear();
        _confirm.clear();
      });
      widget.onChanged?.call(b.status != 'failed');
      toast(
        context,
        b.status == 'verified' ? 'Bank account verified' : 'Bank account saved — verification in progress',
        icon: Icons.account_balance_rounded,
      );
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startEdit() => setState(() {
        _editing = true;
        _holder.text = _bank?.holderName ?? '';
        _ifsc.text = _bank?.ifsc ?? '';
      });

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SkeletonBox(height: 120, radius: 20);
    if (_hidden) {
      return const AppCard(
        shadow: false,
        border: true,
        child: Row(children: [
          IconBubble(Icons.lock_rounded, color: AppColors.text2, size: 40),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Bank details are private to the partner. They confirm their payout account when they accept the listing.',
              style: TextStyle(color: AppColors.text2, fontSize: 13, height: 1.4),
            ),
          ),
        ]),
      );
    }
    final b = _bank;
    if (b != null && !_editing) return _summary(b);
    return AppCard(
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [
            IconBubble(Icons.account_balance_rounded, color: AppColors.teal, size: 40),
            SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Where should we pay you?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                Text('We verify with a ₹1 penny-drop', style: TextStyle(color: AppColors.text3, fontSize: 12.5)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          TextFormField(
            controller: _holder,
            textCapitalization: TextCapitalization.words,
            validator: ListingValidators.holderName,
            decoration: const InputDecoration(labelText: 'Account holder name', prefixIcon: Icon(Icons.person_rounded)),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _account,
            keyboardType: TextInputType.number,
            obscureText: !_showNumber,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(18)],
            validator: ListingValidators.accountNumber,
            decoration: InputDecoration(
              labelText: 'Account number',
              prefixIcon: const Icon(Icons.numbers_rounded),
              suffixIcon: IconButton(
                icon: Icon(_showNumber ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                onPressed: () => setState(() => _showNumber = !_showNumber),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _confirm,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(18)],
            validator: (v) => ListingValidators.confirmAccountNumber(_account.text, v),
            decoration: const InputDecoration(labelText: 'Confirm account number', prefixIcon: Icon(Icons.done_all_rounded)),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _ifsc,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
              const UpperCaseFormatter(),
              LengthLimitingTextInputFormatter(11),
            ],
            validator: ListingValidators.ifsc,
            decoration: const InputDecoration(
              labelText: 'IFSC code',
              hintText: 'HDFC0001234',
              prefixIcon: Icon(Icons.account_tree_rounded),
            ),
          ),
          const SizedBox(height: 10),
          const _PrivacyNote('Payouts go only to a verified account. We show only the last 4 digits after saving.',
              icon: Icons.shield_rounded),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 14),
          AppButton(label: 'Verify & save account', icon: Icons.account_balance_rounded, busy: _busy, onPressed: _save),
          if (_editing && b != null)
            TextButton(onPressed: _busy ? null : () => setState(() => _editing = false), child: const Text('Cancel')),
        ]),
      ),
    );
  }

  Widget _summary(PartnerBank b) {
    final ok = b.status == 'verified';
    final failed = b.status == 'failed';
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          IconBubble(Icons.account_balance_rounded,
              color: ok ? AppColors.green : (failed ? AppColors.red : AppColors.amber), size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b.bankName ?? b.holderName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              Text('A/c •••• ${b.last4} · ${b.ifsc}',
                  style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ]),
          ),
          _DocStatusPill(b.status),
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(ok ? Icons.verified_rounded : (failed ? Icons.error_rounded : Icons.hourglass_top_rounded),
                size: 16, color: ok ? AppColors.green : (failed ? AppColors.red : AppColors.amber)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ok
                    ? 'Penny-drop verified · name at bank: ${b.verifiedName ?? b.holderName}'
                    : failed
                        ? 'Penny-drop failed — check the account number and IFSC.'
                        : 'Penny-drop verification in progress.',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.35),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        const Text('Payouts go only to a verified account.',
            style: TextStyle(color: AppColors.text3, fontSize: 12, fontWeight: FontWeight.w600)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _startEdit,
            icon: const Icon(Icons.edit_rounded, size: 16),
            label: Text(failed ? 'Fix account details' : 'Change account'),
          ),
        ),
      ]),
    );
  }
}
