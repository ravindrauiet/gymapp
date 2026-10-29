// `dio` is a transitive dependency of fitkey_core; it is needed here to upload picked images as bytes so photo
// upload also works on Flutter web (`ApiClient.uploadImage` reads a file path, which web does not have).
import 'package:dio/dio.dart' show DioMediaType, FormData, MultipartFile;
import 'package:fitkey_core/fitkey_core.dart' show ApiClient;
import 'package:image_picker/image_picker.dart' show XFile;

import 'models.dart';
import 'partner_api.dart';

// ---------------------------------------------------------------------------
// View models for the vendor portal and trainer module (parsed from the raw API rows, which are camelCased).
// ---------------------------------------------------------------------------

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
double? _dbl(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
List<String> _strs(Object? v) => v is List ? v.map((e) => '$e').toList() : const [];
Json _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// A marketplace SKU as the seller sees it (includes visibility, which [VendorProduct] does not carry).
class VendorSku {
  VendorSku.fromJson(Json j)
      : product = VendorProduct.fromJson(j),
        isActive = j['isActive'] ?? j['is_active'] ?? true;

  final VendorProduct product;
  final bool isActive;

  String get id => product.id;
  int get discountPercent {
    final p = product;
    if (p.originalPricePaise <= p.pricePaise || p.originalPricePaise <= 0) return 0;
    return ((p.originalPricePaise - p.pricePaise) * 100 / p.originalPricePaise).round();
  }
}

typedef VendorOrderLine = ({String title, int pricePaise, int quantity});

/// An order containing at least one of this vendor's items.
class VendorOrderView {
  VendorOrderView.fromJson(Json j)
      : id = '${j['id']}',
        status = '${j['status'] ?? 'placed'}',
        totalAmountPaise = _int(j['totalAmountPaise'] ?? j['total_amount_paise']),
        paymentMethod = '${j['paymentMethod'] ?? j['payment_method'] ?? ''}',
        paymentStatus = '${j['paymentStatus'] ?? j['payment_status'] ?? ''}',
        trackingNumber = (j['trackingNumber'] ?? j['tracking_number']) as String?,
        createdAt = DateTime.tryParse('${j['createdAt'] ?? j['created_at']}')?.toLocal() ?? DateTime.now(),
        dispatchedAt = DateTime.tryParse('${j['dispatchedAt'] ?? j['dispatched_at'] ?? ''}')?.toLocal(),
        shippingAddress = _map(j['shippingAddress'] ?? j['shipping_address']),
        items = ((j['vendorItems'] ?? j['vendor_items']) as List? ?? const [])
            .map((i) => (
                  title: '${(i as Map)['title'] ?? 'Item'}',
                  pricePaise: _int(i['pricePaise'] ?? i['price_paise']),
                  quantity: _int(i['quantity']),
                ))
            .toList();

  final String id;
  final String status;

  /// Whole-order total (may include other sellers' items).
  final int totalAmountPaise;
  final String paymentMethod;
  final String paymentStatus;
  final String? trackingNumber;
  final DateTime createdAt;
  final DateTime? dispatchedAt;
  final Json shippingAddress;
  final List<VendorOrderLine> items;

  /// This seller's share of the order.
  int get vendorSubtotalPaise => items.fold(0, (s, i) => s + i.pricePaise * i.quantity);
  int get unitCount => items.fold(0, (s, i) => s + i.quantity);
  String get shortId => id.length > 8 ? id.substring(0, 8).toUpperCase() : id.toUpperCase();
}

class TrainerTypeOption {
  const TrainerTypeOption(this.key, this.label);
  final String key;
  final String label;
}

class TrainerTypeGroup {
  TrainerTypeGroup.fromJson(Json j)
      : key = '${j['key']}',
        label = '${j['label']}',
        types = (j['types'] as List? ?? const [])
            .map((t) => TrainerTypeOption('${(t as Map)['key']}', '${t['label']}'))
            .toList();

  final String key;
  final String label;
  final List<TrainerTypeOption> types;
}

/// The partner's trainer profile with the BRD §6 fields the shared model does not carry.
class TrainerProfileDetails {
  TrainerProfileDetails.fromJson(Json j)
      : profile = PartnerTrainerProfile.fromJson({...j, 'bio': j['bio'] ?? '', 'name': j['name'] ?? ''}),
        trainerTypes = _strs(j['trainerTypes'] ?? j['trainer_types']),
        trainerTypeLabels = _strs(j['trainerTypeLabels']),
        ratingAvg = _dbl(j['ratingAvg'] ?? j['rating_avg']),
        ratingCount = _int(j['ratingCount'] ?? j['rating_count']),
        workingStart = '${_map(j['workingHours'] ?? j['working_hours'])['start'] ?? '06:00'}',
        workingEnd = '${_map(j['workingHours'] ?? j['working_hours'])['end'] ?? '21:00'}';

  final PartnerTrainerProfile profile;
  final List<String> trainerTypes;
  final List<String> trainerTypeLabels;

  /// Real average from member ratings (null until someone rates).
  final double? ratingAvg;
  final int ratingCount;
  final String workingStart;
  final String workingEnd;

  /// Ratings are only shown once they are backed by at least 5 reviews.
  bool get isNew => ratingCount < 5 || ratingAvg == null;
}

extension VendorTrainerApi on PartnerApi {
  ApiClient get _c => client;

  /// Uploads a picked image as bytes (works on Android and web) and returns its server-relative URL.
  Future<String> uploadPicked(XFile file) async {
    final bytes = await file.readAsBytes();
    final name = file.name.toLowerCase();
    final type = name.endsWith('.png')
        ? DioMediaType('image', 'png')
        : name.endsWith('.webp')
            ? DioMediaType('image', 'webp')
            : DioMediaType('image', 'jpeg');
    final r = await _c.post(
      '/uploads',
      FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: file.name, contentType: type)}),
    );
    return r['url'] as String;
  }

  // ---- Vendor ---------------------------------------------------------------
  Future<List<VendorSku>> vendorSkus() async =>
      ((await _c.get('/partner/vendor/products'))['products'] as List).map((p) => VendorSku.fromJson(p)).toList();

  Future<VendorSku> saveVendorSku(String? id, Json fields) async {
    final r = id == null ? await _c.post('/partner/vendor/products', fields) : await _c.put('/partner/vendor/products/$id', fields);
    return VendorSku.fromJson(r['product']);
  }

  Future<List<VendorOrderView>> vendorOrderViews() async =>
      ((await _c.get('/partner/vendor/orders'))['orders'] as List).map((o) => VendorOrderView.fromJson(o)).toList();

  // ---- Trainer --------------------------------------------------------------
  Future<List<TrainerTypeGroup>> trainerTypeCatalogue() async =>
      ((await _c.get('/partner/trainer/types'))['groups'] as List).map((g) => TrainerTypeGroup.fromJson(g)).toList();

  Future<TrainerProfileDetails?> trainerProfileDetails() async {
    final t = (await _c.get('/partner/trainer/profile'))['trainer'];
    return t == null ? null : TrainerProfileDetails.fromJson(Map<String, dynamic>.from(t as Map));
  }

  Future<TrainerProfileDetails> saveTrainerProfileDetails(Json fields) async =>
      TrainerProfileDetails.fromJson(Map<String, dynamic>.from((await _c.post('/partner/trainer/profile', fields))['trainer'] as Map));
}
