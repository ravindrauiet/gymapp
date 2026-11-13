import 'dart:async';

import 'package:razorpay_flutter/razorpay_flutter.dart';

import '../data/models.dart';
import 'payments.dart';

/// Razorpay Checkout on Android / iOS (razorpay_flutter). Completes with the success data or throws
/// [PaymentCancelled] / [PaymentFailed].
Future<CheckoutSuccess> openCheckout(Json options) {
  final done = Completer<CheckoutSuccess>();
  final rzp = Razorpay();
  rzp.on(Razorpay.EVENT_PAYMENT_SUCCESS, (PaymentSuccessResponse r) {
    if (done.isCompleted) return;
    if (r.paymentId == null || r.signature == null) {
      done.completeError(PaymentFailed('Payment could not be confirmed. If money was deducted it will be refunded.'));
      return;
    }
    done.complete((orderId: r.orderId ?? options['order_id'] as String, paymentId: r.paymentId!, signature: r.signature!));
  });
  rzp.on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse r) {
    if (done.isCompleted) return;
    done.completeError(r.code == Razorpay.PAYMENT_CANCELLED
        ? PaymentCancelled()
        : PaymentFailed(_message(r.message) ?? 'Payment failed. Please try again.'));
  });
  // External wallets (PhonePe / Paytm app hand-off) come back through success / error; nothing to do here.
  rzp.on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse _) {});
  rzp.open({
    ...options,
    'retry': {'enabled': true, 'max_count': 3},
    'send_sms_hash': true,
  });
  return done.future.whenComplete(rzp.clear);
}

/// Razorpay sends the error as JSON text on Android ({"error":{"description":"…"}}); pull the description out.
String? _message(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final m = RegExp(r'"description"\s*:\s*"([^"]+)"').firstMatch(raw);
  return m?.group(1) ?? (raw.startsWith('{') ? null : raw);
}
