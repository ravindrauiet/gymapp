import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show ApiException;

import '../data/fitkey_api.dart';
import '../data/models.dart';
import 'rzp_checkout_mobile.dart' if (dart.library.js_interop) 'rzp_checkout_web.dart' as checkout;

/// The member closed Razorpay Checkout without paying.
class PaymentCancelled extends ApiException {
  PaymentCancelled() : super('Payment cancelled', code: 'PAYMENT_CANCELLED');
}

/// Razorpay reported a failed payment (card declined, UPI timeout…).
class PaymentFailed extends ApiException {
  PaymentFailed(super.message) : super(code: 'PAYMENT_FAILED');
}

/// Success data from Razorpay Checkout.
typedef CheckoutSuccess = ({String orderId, String paymentId, String signature});

/// Everything a member buys with money goes through here.
///
/// The server decides how to pay (`GET /payments/config`):
/// * **mock** (demo): calls the old instant endpoint ([mock]).
/// * **razorpay**: `POST /payments/orders {purpose, payload}` → Razorpay Checkout (UPI, cards, netbanking, wallets) →
///   `POST /payments/verify` → the purchase result (same JSON the instant endpoint returns).
///
/// Prices are never sent from the app — the server computes them from [payload].
class Payments {
  Payments._();

  static String? _mode;
  static DateTime? _modeAt;

  /// 'razorpay' or 'mock' (cached for 10 minutes).
  static Future<String> mode(FitkeyApi api) async {
    if (_mode != null && _modeAt != null && DateTime.now().difference(_modeAt!) < const Duration(minutes: 10)) {
      return _mode!;
    }
    try {
      final r = await api.client.get('/payments/config');
      _mode = r['mode'] as String? ?? 'mock';
    } on ApiException catch (e) {
      // Older servers have no /payments yet → demo mode.
      if (e.statusCode == 404) {
        _mode = 'mock';
      } else {
        rethrow;
      }
    }
    _modeAt = DateTime.now();
    return _mode!;
  }

  static Future<Json> run(
    FitkeyApi api, {
    required String purpose,
    required Json payload,
    required Future<Json> Function() mock,
  }) async {
    if (await mode(api) != 'razorpay') {
      try {
        return await mock();
      } on ApiException catch (e) {
        // Server switched to real payments since we cached the mode.
        if (e.statusCode == 426) {
          _mode = 'razorpay';
          return run(api, purpose: purpose, payload: payload, mock: mock);
        }
        rethrow;
      }
    }

    final order = await api.client.post('/payments/orders', {'purpose': purpose, 'payload': payload});
    if (order['paid'] == true) return Json.from(order['result'] as Map);

    final paymentOrderId = order['paymentOrderId'] as String;
    final success = await checkout.openCheckout(Json.from(order['checkout'] as Map));
    return _verify(api, paymentOrderId, success);
  }

  static Future<Json> _verify(FitkeyApi api, String paymentOrderId, CheckoutSuccess s) async {
    try {
      final r = await api.client.post('/payments/verify', {
        'razorpayOrderId': s.orderId,
        'razorpayPaymentId': s.paymentId,
        'razorpaySignature': s.signature,
      });
      return Json.from(r['result'] as Map);
    } on ApiException catch (e) {
      // Network blip / server busy right after paying: the webhook or the server sweep finishes it — poll the status.
      if (e.statusCode == null || e.statusCode! >= 500 || e.code == 'PAYMENT_PENDING') {
        return _poll(api, paymentOrderId);
      }
      rethrow;
    }
  }

  static Future<Json> _poll(FitkeyApi api, String paymentOrderId) async {
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        final p = (await api.client.get('/payments/orders/$paymentOrderId'))['payment'] as Map;
        switch (p['status']) {
          case 'fulfilled':
            return Json.from(p['result'] as Map);
          case 'refunded':
          case 'failed':
            throw ApiException('${p['error'] ?? 'Payment could not be completed'}. Your money will be refunded.',
                code: 'PAYMENT_REFUNDED');
        }
      } on ApiException catch (e) {
        if (e.code == 'PAYMENT_REFUNDED') rethrow;
      }
    }
    throw ApiException(
      'Payment received — we are confirming it. Your purchase will appear in a few minutes.',
      code: 'PAYMENT_PENDING',
    );
  }
}
