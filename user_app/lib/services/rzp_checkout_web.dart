import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../data/models.dart';
import 'payments.dart';

/// Razorpay Checkout on the web build: loads checkout.js once and opens the standard Razorpay modal.
Future<CheckoutSuccess> openCheckout(Json options) async {
  await _loadScript();
  final done = Completer<CheckoutSuccess>();

  final opts = options.jsify() as JSObject;
  opts['handler'] = ((JSObject r) {
    if (done.isCompleted) return;
    final orderId = (r['razorpay_order_id'] as JSString?)?.toDart ?? options['order_id'] as String;
    final paymentId = (r['razorpay_payment_id'] as JSString?)?.toDart;
    final signature = (r['razorpay_signature'] as JSString?)?.toDart;
    if (paymentId == null || signature == null) {
      done.completeError(PaymentFailed('Payment could not be confirmed. If money was deducted it will be refunded.'));
    } else {
      done.complete((orderId: orderId, paymentId: paymentId, signature: signature));
    }
  }).toJS;
  final modal = JSObject();
  modal['ondismiss'] = (() {
    if (!done.isCompleted) done.completeError(PaymentCancelled());
  }).toJS;
  opts['modal'] = modal;
  final retry = JSObject()
    ..['enabled'] = true.toJS
    ..['max_count'] = 3.toJS;
  opts['retry'] = retry;

  final ctor = globalContext['Razorpay'] as JSFunction;
  final rzp = ctor.callAsConstructor<JSObject>(opts);
  rzp.callMethod('on'.toJS, 'payment.failed'.toJS, ((JSObject resp) {
    // Checkout lets the member retry; we only give up when they close the modal (ondismiss).
  }).toJS);
  rzp.callMethod('open'.toJS);
  return done.future;
}

Future<void> _loadScript() async {
  if (globalContext.has('Razorpay')) return;
  final loaded = Completer<void>();
  final document = globalContext['document'] as JSObject;
  final script = document.callMethod<JSObject>('createElement'.toJS, 'script'.toJS);
  script['src'] = 'https://checkout.razorpay.com/v1/checkout.js'.toJS;
  script['onload'] = (() => loaded.complete()).toJS;
  script['onerror'] = (() {
    if (!loaded.isCompleted) loaded.completeError(PaymentFailed('Could not load Razorpay. Check your connection.'));
  }).toJS;
  (document['head'] as JSObject).callMethod('appendChild'.toJS, script);
  await loaded.future.timeout(const Duration(seconds: 20));
}
