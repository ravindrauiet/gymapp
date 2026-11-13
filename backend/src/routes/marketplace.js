import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { commissionPct } from '../utils/commission.js';
import { badRequest, forbidden, notFound, validate, conflict } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { earningsSummary, FSSAI_CATEGORIES, PRODUCT_CATEGORIES, todayIst } from '../utils/partner_types.js';
import { redeemCoins, redeemable } from '../utils/wallet.js';
import { paymentRequired } from '../utils/payments.js';
import { config } from '../config.js';

export const marketplaceRouter = Router();

/**
 * Partner BRD §7 — what members may see / buy (p = marketplace_products, v = LEFT JOIN marketplace_vendors):
 *  - vendors whose listing is not live are hidden (NULL listing_status = legacy vendor, shown);
 *  - supplements / healthy food need the vendor's verified FSSAI licence (fssai_verified_at). FitKey's own
 *    products (no vendor) are not affected.
 */
const FSSAI_LIST = FSSAI_CATEGORIES.map((c) => `'${c}'`).join(', ');
const MEMBER_VISIBLE_PRODUCT = `(p.vendor_id IS NULL OR (
    (v.listing_status IS NULL OR v.listing_status = 'live')
    AND (p.category NOT IN (${FSSAI_LIST}) OR v.fssai_verified_at IS NOT NULL)))`;

// ============================================================================
// Consumer App Endpoints (FITKEY)
// ============================================================================

marketplaceRouter.get('/products', async (req, res) => {
  const { category, q } = req.query;
  const limit = Math.min(100, Math.max(1, parseInt(req.query.limit, 10) || 20));
  const page = Math.max(1, parseInt(req.query.page, 10) || 1);
  const conditions = ['p.is_active = true', MEMBER_VISIBLE_PRODUCT];
  const params = [];

  if (category && category !== 'all') {
    params.push(String(category));
    conditions.push(`p.category = $${params.length}`);
  }
  if (q && String(q).trim()) {
    params.push(`%${String(q).trim()}%`);
    conditions.push(`(p.title ILIKE $${params.length} OR p.brand ILIKE $${params.length} OR p.description ILIKE $${params.length})`);
  }

  const offset = (page - 1) * limit;
  params.push(limit, offset);

  const products = await query(
    `SELECT p.* FROM marketplace_products p
     LEFT JOIN marketplace_vendors v ON v.id = p.vendor_id
     WHERE ${conditions.join(' AND ')}
     ORDER BY p.created_at DESC
     LIMIT $${params.length - 1} OFFSET $${params.length}`,
    params,
  );

  res.json({ products });
});

marketplaceRouter.get('/products/:id', async (req, res) => {
  const product = await queryOne(
    `SELECT p.*, COALESCE(v.brand_name, v.business_name) AS vendor_name, v.dispatch_days
     FROM marketplace_products p
     LEFT JOIN marketplace_vendors v ON v.id = p.vendor_id
     WHERE p.id = $1 AND ${MEMBER_VISIBLE_PRODUCT}`,
    [req.params.id],
  );
  if (!product) throw notFound('Product not found');
  res.json({ product });
});

// Member Order Endpoints
const orderItemSchema = z.object({
  productId: z.string().uuid(),
  quantity: z.number().int().min(1).max(20),
});

const checkoutSchema = z.object({
  items: z.array(orderItemSchema).min(1),
  shippingAddress: z.object({
    fullName: z.string().min(2),
    phone: z.string().min(10),
    addressLine: z.string().min(5),
    city: z.string().min(2),
    pincode: z.string().min(4),
  }),
  paymentMethod: z.enum(['upi', 'card', 'netbanking', 'cod']),
  // Wallet v2: pay part of the order with coins — ProveIt coins first, then referral coins, max 50% of the order
  // (wallet_settings.store_max_coin_pct). `coins` caps how many (default: as many as allowed).
  useCoins: z.boolean().default(false),
  coins: z.number().int().min(0).optional(),
});

/** Creates a store order (stock, coins, items, vendor + low-stock alerts). Online orders: only after payment. */
async function placeOrder(userId, body, { paymentRef = null } = {}) {

  let used = { coins: 0 };
  const order = await withTransaction(async (client) => {
    // 1. Fetch products and calculate total
    let totalPaise = 0;
    const itemsData = [];

    for (const item of body.items) {
      const pRes = await client.query(
        `SELECT p.id, p.vendor_id, p.title, p.price_paise, p.stock_quantity
           FROM marketplace_products p LEFT JOIN marketplace_vendors v ON v.id = p.vendor_id
          WHERE p.id = $1 AND p.is_active = true AND ${MEMBER_VISIBLE_PRODUCT} FOR UPDATE OF p`,
        [item.productId],
      );
      const prod = pRes.rows[0];
      if (!prod) throw notFound(`Product not found: ${item.productId}`);
      if (prod.stock_quantity < item.quantity) {
        throw conflict(`Insufficient stock for "${prod.title}". Only ${prod.stock_quantity} left.`);
      }

      const itemTotal = prod.price_paise * item.quantity;
      totalPaise += itemTotal;
      itemsData.push({
        productId: prod.id,
        vendorId: prod.vendor_id,
        title: prod.title,
        pricePaise: prod.price_paise,
        quantity: item.quantity,
      });

      // Deduct stock
      await client.query(
        `UPDATE marketplace_products SET stock_quantity = stock_quantity - $1 WHERE id = $2`,
        [item.quantity, prod.id],
      );
    }

    const paymentStatus = body.paymentMethod === 'cod' ? 'cod_pending' : 'paid';
    const trackingNum = `TRK${Date.now().toString().slice(-8)}${Math.floor(100 + Math.random() * 900)}`;

    // 2. Insert order
    const orderRes = await client.query(
      `INSERT INTO marketplace_orders (
         user_id, status, total_amount_paise, payment_method, payment_status, shipping_address, tracking_number, payment_ref
       ) VALUES ($1, 'placed', $2, $3, $4, $5, $6, $7)
       RETURNING *`,
      [userId, totalPaise, body.paymentMethod, paymentStatus, JSON.stringify(body.shippingAddress), trackingNum, paymentRef],
    );
    let order = orderRes.rows[0];

    // 2b. Coins (FitKey coins bought with money are for visits only and are never used here).
    if (body.useCoins && (body.coins ?? 1) > 0) {
      used = await redeemCoins(client, userId, {
        context: 'store', amountPaise: totalPaise, requested: body.coins ?? null, ref: `order:${order.id}`, orderId: order.id,
      });
      order = (await client.query(
        `UPDATE marketplace_orders SET coins_redeemed = $2, proveit_coins_redeemed = $3, referral_coins_redeemed = $4,
           payable_paise = total_amount_paise - $2 * 100 WHERE id = $1 RETURNING *`,
        [order.id, used.coins, used.proveit, used.referral],
      )).rows[0];
    } else {
      order = (await client.query(`UPDATE marketplace_orders SET payable_paise = total_amount_paise WHERE id = $1 RETURNING *`, [order.id])).rows[0];
    }

    // 3. Insert items
    for (const it of itemsData) {
      await client.query(
        `INSERT INTO marketplace_order_items (order_id, product_id, vendor_id, title, price_paise, quantity)
         VALUES ($1, $2, $3, $4, $5, $6)`,
        [order.id, it.productId, it.vendorId, it.title, it.pricePaise, it.quantity],
      );
    }

    return order;
  });

  // Tell each vendor whose products are in this order (partner app).
  const vendors = await query(
    `SELECT v.partner_id, SUM(i.quantity)::int AS items, SUM(i.price_paise * i.quantity)::int AS amount_paise
     FROM marketplace_order_items i JOIN marketplace_vendors v ON v.id = i.vendor_id
     WHERE i.order_id = $1 GROUP BY v.partner_id`,
    [order.id],
  );
  for (const v of vendors) {
    await notify(v.partnerId, {
      type: 'vendor_order',
      title: `New order · ${v.items} item${v.items === 1 ? '' : 's'}`,
      body: `₹${(v.amountPaise / 100).toLocaleString('en-IN')} · ${body.paymentMethod === 'cod' ? 'Cash on delivery' : 'Paid'} — pack and dispatch it from your vendor portal.`,
      data: { orderId: order.id },
    });
  }

  // Low-stock alerts (BRD §10.4): SKUs in this order that dropped to / below their threshold.
  const low = await query(
    `SELECT DISTINCT p.id, p.title, p.stock_quantity, v.partner_id
       FROM marketplace_order_items i
       JOIN marketplace_products p ON p.id = i.product_id
       JOIN marketplace_vendors v ON v.id = p.vendor_id
      WHERE i.order_id = $1 AND p.stock_quantity <= p.low_stock_threshold`,
    [order.id],
  );
  for (const p of low) {
    await notify(p.partnerId, {
      type: 'vendor_low_stock',
      title: p.stockQuantity === 0 ? `Out of stock: ${p.title}` : `Low stock: ${p.title} (${p.stockQuantity} left)`,
      body: 'Restock it from the Sell tab so members can keep ordering.',
      data: { productId: p.id },
    });
  }

  return { order, _overpaidPaise: Math.max(0, ((body.coins ?? 0) - used.coins) * 100) };
}

/** Prices a cart exactly like placeOrder does (visible products, stock, coin cap) without writing anything. */
async function quoteOrder(userId, body) {
  let totalPaise = 0;
  for (const item of body.items) {
    const prod = await queryOne(
      `SELECT p.title, p.price_paise, p.stock_quantity
         FROM marketplace_products p LEFT JOIN marketplace_vendors v ON v.id = p.vendor_id
        WHERE p.id = $1 AND p.is_active = true AND ${MEMBER_VISIBLE_PRODUCT}`,
      [item.productId],
    );
    if (!prod) throw notFound(`Product not found: ${item.productId}`);
    if (prod.stockQuantity < item.quantity) throw conflict(`Insufficient stock for "${prod.title}". Only ${prod.stockQuantity} left.`);
    totalPaise += prod.pricePaise * item.quantity;
  }
  let coins = 0;
  if (body.useCoins && (body.coins ?? 1) > 0) {
    const r = await redeemable(userId, 'store', totalPaise);
    coins = body.coins == null ? r.coins : Math.min(body.coins, r.coins);
  }
  return { totalPaise, coins };
}

/** Payments (routes/payments.js): online store orders (UPI / card / netbanking). COD never goes through here. */
export const storeOrderPurchase = {
  async quote(userId, payload) {
    const body = validate(checkoutSchema, payload);
    if (body.paymentMethod === 'cod') throw badRequest('Cash on delivery orders are placed directly');
    const q = await quoteOrder(userId, body);
    const n = body.items.reduce((s, i) => s + i.quantity, 0);
    return {
      amountPaise: q.totalPaise - q.coins * 100,
      description: `FITKEY Store · ${n} item${n === 1 ? '' : 's'}`,
      payload: { ...body, coins: q.coins, useCoins: q.coins > 0 },
    };
  },
  async fulfill(userId, payload, { paymentRef }) {
    const body = validate(checkoutSchema, payload);
    return placeOrder(userId, body, { paymentRef });
  },
};

/**
 * POST /marketplace/orders — cash on delivery always; online methods only in mock mode (with Razorpay the app pays
 * first via /payments, purpose store_order, and the order is created when the payment is confirmed).
 */
marketplaceRouter.post('/orders', requireAuth('user'), async (req, res) => {
  const body = validate(checkoutSchema, req.body);
  if (body.paymentMethod !== 'cod' && config.paymentsMode !== 'mock') throw paymentRequired('store_order');
  const { order } = await placeOrder(req.user.id, body, { paymentRef: body.paymentMethod === 'cod' ? null : `MOCK-${Date.now()}` });
  res.status(201).json({ order });
});

marketplaceRouter.get('/orders/me', requireAuth('user'), async (req, res) => {
  const orders = await query(
    `SELECT o.*,
            COALESCE(
              json_agg(
                json_build_object(
                  'id', i.id,
                  'productId', i.product_id,
                  'title', i.title,
                  'pricePaise', i.price_paise,
                  'quantity', i.quantity,
                  'returnStatus', i.return_status
                )
              ) FILTER (WHERE i.id IS NOT NULL), '[]'
            ) AS items
     FROM marketplace_orders o
     LEFT JOIN marketplace_order_items i ON i.order_id = o.id
     WHERE o.user_id = $1
     GROUP BY o.id
     ORDER BY o.created_at DESC`,
    [req.user.id],
  );
  res.json({ orders });
});

marketplaceRouter.get('/orders/:id', requireAuth('user'), async (req, res) => {
  const order = await queryOne(
    `SELECT o.*,
            COALESCE(
              json_agg(
                json_build_object(
                  'id', i.id,
                  'productId', i.product_id,
                  'title', i.title,
                  'pricePaise', i.price_paise,
                  'quantity', i.quantity,
                  'returnStatus', i.return_status
                )
              ) FILTER (WHERE i.id IS NOT NULL), '[]'
            ) AS items
     FROM marketplace_orders o
     LEFT JOIN marketplace_order_items i ON i.order_id = o.id
     WHERE o.id = $1 AND o.user_id = $2
     GROUP BY o.id`,
    [req.params.id, req.user.id],
  );
  if (!order) throw notFound('Order not found');

  // Tracking timeline
  const timeline = [
    { status: 'placed', label: 'Order Placed', time: order.created_at, completed: true },
    { status: 'processing', label: 'Processing & Packed', time: order.created_at, completed: ['processing', 'dispatched', 'out_for_delivery', 'delivered'].includes(order.status) },
    { status: 'dispatched', label: 'Dispatched from Hub', time: order.dispatched_at, completed: ['dispatched', 'out_for_delivery', 'delivered'].includes(order.status) },
    { status: 'out_for_delivery', label: 'Out for Delivery', time: null, completed: ['out_for_delivery', 'delivered'].includes(order.status) },
    { status: 'delivered', label: 'Delivered', time: order.delivered_at, completed: order.status === 'delivered' },
  ];

  res.json({ order, timeline });
});

/** POST /marketplace/orders/:id/items/:itemId/return { reason } — member asks to return a delivered item. */
marketplaceRouter.post('/orders/:id/items/:itemId/return', requireAuth('user'), async (req, res) => {
  const { reason } = validate(z.object({ reason: z.string().trim().min(3).max(300) }), req.body);
  const item = await queryOne(
    `SELECT i.id, i.title, i.return_status, o.status, o.delivered_at, v.partner_id
       FROM marketplace_order_items i
       JOIN marketplace_orders o ON o.id = i.order_id
       LEFT JOIN marketplace_vendors v ON v.id = i.vendor_id
      WHERE i.id = $1 AND i.order_id = $2 AND o.user_id = $3`,
    [req.params.itemId, req.params.id, req.user.id],
  );
  if (!item) throw notFound('Order item not found');
  if (item.status !== 'delivered') throw conflict('You can return an item once it is delivered');
  if (item.returnStatus) throw conflict(`A return is already ${item.returnStatus}`);
  const updated = await queryOne(
    `UPDATE marketplace_order_items SET return_status = 'requested', return_reason = $2, return_requested_at = now(), return_updated_at = now()
      WHERE id = $1 RETURNING *`,
    [item.id, reason],
  );
  if (item.partnerId) {
    await notify(item.partnerId, {
      type: 'vendor_return_requested',
      title: `Return requested: ${item.title}`,
      body: reason,
      data: { orderId: req.params.id, itemId: item.id },
    });
  }
  res.status(201).json({ item: updated });
});

// ============================================================================
// Partner App Scope (FITKEY Partner Vendor Portal)
// ============================================================================

export const partnerVendorRouter = Router();
partnerVendorRouter.use(requireAuth('partner'));

// 1. Merchant Onboarding & Profile
partnerVendorRouter.get('/profile', async (req, res) => {
  const vendor = await queryOne(
    `SELECT * FROM marketplace_vendors WHERE partner_id = $1`,
    [req.user.id],
  );
  res.json({ vendor: vendor || null });
});

partnerVendorRouter.post('/profile', async (req, res) => {
  const schema = z.object({
    businessName: z.string().min(2),
    gstin: z.string().optional(),
    bankName: z.string().min(2),
    bankAccountNo: z.string().min(5),
    ifscCode: z.string().min(4),
  });
  const data = validate(schema, req.body);

  const vendor = await queryOne(
    `INSERT INTO marketplace_vendors (
       partner_id, business_name, gstin, bank_name, bank_account_no, ifsc_code, verification_status, listing_status
     ) VALUES ($1, $2, $3, $4, $5, $6, 'verified', 'draft')
     ON CONFLICT (partner_id) DO UPDATE SET
       business_name = EXCLUDED.business_name,
       gstin = EXCLUDED.gstin,
       bank_name = EXCLUDED.bank_name,
       bank_account_no = EXCLUDED.bank_account_no,
       ifsc_code = EXCLUDED.ifsc_code
     RETURNING *`,
    [req.user.id, data.businessName, data.gstin ?? null, data.bankName, data.bankAccountNo, data.ifscCode],
  );
  res.status(201).json({ vendor });
});

// 2. SKU & Inventory Management
partnerVendorRouter.get('/products', async (req, res) => {
  const vendor = await queryOne(`SELECT id FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  if (!vendor) return res.json({ products: [] });

  const products = await query(
    `SELECT p.*, (p.stock_quantity <= p.low_stock_threshold) AS low_stock,
            CASE WHEN NOT p.is_active THEN 'unlisted'
                 WHEN v.listing_status IS NOT NULL AND v.listing_status <> 'live' THEN 'store_not_live'
                 WHEN p.category IN (${FSSAI_LIST}) AND v.fssai_verified_at IS NULL THEN 'fssai_pending'
                 WHEN p.stock_quantity = 0 THEN 'out_of_stock'
            END AS hidden_reason
       FROM marketplace_products p JOIN marketplace_vendors v ON v.id = p.vendor_id
      WHERE p.vendor_id = $1 ORDER BY p.created_at DESC`,
    [vendor.id],
  );
  res.json({ products });
});

/** GET /partner/vendor/low-stock → { products } SKUs at / below their low-stock threshold (active ones). */
partnerVendorRouter.get('/low-stock', async (req, res) => {
  const vendor = await queryOne(`SELECT id FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  if (!vendor) return res.json({ products: [] });
  const products = await query(
    `SELECT id, title, sku, category, stock_quantity, low_stock_threshold, price_paise, images
       FROM marketplace_products WHERE vendor_id = $1 AND is_active AND stock_quantity <= low_stock_threshold
      ORDER BY stock_quantity, title`,
    [vendor.id],
  );
  res.json({ products });
});

const productSchema = z.object({
  title: z.string().min(3),
  brand: z.string().min(2),
  category: z.enum(PRODUCT_CATEGORIES),
  description: z.string().min(10),
  pricePaise: z.number().int().min(0), // selling price
  originalPricePaise: z.number().int().min(0), // MRP
  stockQuantity: z.number().int().min(0),
  lowStockThreshold: z.number().int().min(0).max(10000).optional(),
  sku: z.string().trim().max(60).optional(),
  images: z.array(z.string()).default([]),
  specs: z.record(z.string()).default({}),
  isActive: z.boolean().optional(), // PUT only: list / unlist the SKU in the member store
});

partnerVendorRouter.post('/products', async (req, res) => {
  let vendor = await queryOne(`SELECT id FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  if (!vendor) {
    // New sellers start as a draft listing (Partner BRD §7) — members see their products once it is live.
    vendor = await queryOne(
      `INSERT INTO marketplace_vendors (partner_id, business_name, listing_status, listed_by)
       VALUES ($1, $2, 'draft', $3) RETURNING id`,
      [req.user.id, req.user.name || 'Partner Vendor', req.staffId ?? null],
    );
  }

  const p = validate(productSchema, req.body);
  if (p.pricePaise > p.originalPricePaise) throw badRequest('pricePaise: selling price cannot be more than the MRP');
  const product = await queryOne(
    `INSERT INTO marketplace_products (
       vendor_id, title, brand, category, description, price_paise, original_price_paise,
       stock_quantity, images, specs, low_stock_threshold, sku
     ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, COALESCE($11::int, 5), $12)
     RETURNING *`,
    [
      vendor.id,
      p.title,
      p.brand,
      p.category,
      p.description,
      p.pricePaise,
      p.originalPricePaise,
      p.stockQuantity,
      p.images,
      JSON.stringify(p.specs),
      p.lowStockThreshold ?? null,
      p.sku ?? null,
    ],
  );
  res.status(201).json({ product });
});

partnerVendorRouter.put('/products/:id', async (req, res) => {
  const vendor = await queryOne(`SELECT id FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  if (!vendor) throw notFound('Vendor not found');

  const p = validate(productSchema.partial(), req.body);
  const existing = await queryOne(
    `SELECT * FROM marketplace_products WHERE id = $1 AND vendor_id = $2`,
    [req.params.id, vendor.id],
  );
  if (!existing) throw notFound('Product not found');
  if ((p.pricePaise ?? existing.pricePaise) > (p.originalPricePaise ?? existing.originalPricePaise)) {
    throw badRequest('pricePaise: selling price cannot be more than the MRP');
  }

  const updated = await queryOne(
    `UPDATE marketplace_products SET
       title = COALESCE($1, title),
       brand = COALESCE($2, brand),
       category = COALESCE($3, category),
       description = COALESCE($4, description),
       price_paise = COALESCE($5, price_paise),
       original_price_paise = COALESCE($6, original_price_paise),
       stock_quantity = COALESCE($7, stock_quantity),
       specs = COALESCE($8, specs),
       images = COALESCE($10, images),
       is_active = COALESCE($11, is_active),
       low_stock_threshold = COALESCE($12::int, low_stock_threshold),
       sku = COALESCE($13::text, sku)
     WHERE id = $9
     RETURNING *, (stock_quantity <= low_stock_threshold) AS low_stock`,
    [
      p.title ?? null,
      p.brand ?? null,
      p.category ?? null,
      p.description ?? null,
      p.pricePaise ?? null,
      p.originalPricePaise ?? null,
      p.stockQuantity ?? null,
      p.specs ? JSON.stringify(p.specs) : null,
      req.params.id,
      // .partial() keeps defaults, so only send images when the client actually included them.
      'images' in req.body ? p.images : null,
      p.isActive ?? null,
      p.lowStockThreshold ?? null,
      p.sku ?? null,
    ],
  );
  res.json({ product: updated });
});

// 3. Order Fulfillment & Dispatch
partnerVendorRouter.get('/orders', async (req, res) => {
  const vendor = await queryOne(`SELECT id FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  if (!vendor) return res.json({ orders: [] });

  const orders = await query(
    // EXISTS rather than JOIN + DISTINCT: DISTINCT cannot compare the json columns (Postgres 42883).
    `SELECT o.id, o.status, o.total_amount_paise, o.payment_method, o.payment_status,
            o.shipping_address, o.tracking_number, o.created_at, o.dispatched_at,
            (SELECT json_agg(json_build_object('id', i.id, 'productId', i.product_id, 'title', i.title, 'pricePaise', i.price_paise, 'quantity', i.quantity, 'returnStatus', i.return_status))
             FROM marketplace_order_items i WHERE i.order_id = o.id AND i.vendor_id = $1) AS vendor_items
     FROM marketplace_orders o
     WHERE EXISTS (SELECT 1 FROM marketplace_order_items oi WHERE oi.order_id = o.id AND oi.vendor_id = $1)
     ORDER BY o.created_at DESC`,
    [vendor.id],
  );
  res.json({ orders });
});

partnerVendorRouter.patch('/orders/:id/status', async (req, res) => {
  const schema = z.object({
    status: z.enum(['processing', 'dispatched', 'out_for_delivery', 'delivered']),
    trackingNumber: z.string().optional(),
  });
  const data = validate(schema, req.body);

  // Ownership: a vendor may only update orders that contain at least one of its items.
  const owned = await queryOne(
    `SELECT 1 FROM marketplace_order_items oi JOIN marketplace_vendors v ON v.id = oi.vendor_id
     WHERE oi.order_id = $1 AND v.partner_id = $2 LIMIT 1`,
    [req.params.id, req.user.id],
  );
  if (!owned) throw notFound('Order not found');

  const updated = await queryOne(
    // $1::text everywhere: without the casts Postgres deduces varchar vs text for $1 and rejects the query (42P08).
    `UPDATE marketplace_orders SET
       status = $1::text,
       tracking_number = COALESCE($2::text, tracking_number),
       dispatched_at = CASE WHEN $1::text = 'dispatched' AND dispatched_at IS NULL THEN now() ELSE dispatched_at END,
       delivered_at = CASE WHEN $1::text = 'delivered' AND delivered_at IS NULL THEN now() ELSE delivered_at END
     WHERE id = $3
     RETURNING *`,
    [data.status, data.trackingNumber ?? null, req.params.id],
  );
  if (!updated) throw notFound('Order not found');
  const label = { processing: 'is being packed', dispatched: 'has been shipped', out_for_delivery: 'is out for delivery', delivered: 'has been delivered' }[data.status];
  await notify(updated.userId, {
    type: 'store_order_status',
    title: `Your FITKEY Store order ${label}`,
    body: data.trackingNumber ? `Tracking number: ${data.trackingNumber}` : null,
    data: { orderId: updated.id },
  });
  res.json({ order: updated });
});

// 3b. Returns (BRD §10.4)
/** GET /partner/vendor/returns?status= → { returns:[{ itemId, orderId, title, quantity, pricePaise, returnStatus, … }] } */
partnerVendorRouter.get('/returns', async (req, res) => {
  const { status } = validate(z.object({ status: z.enum(['requested', 'approved', 'rejected', 'received', 'refunded']).optional() }), req.query);
  const vendor = await queryOne(`SELECT id FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  if (!vendor) return res.json({ returns: [] });
  const returns = await query(
    `SELECT i.id AS item_id, i.order_id, i.product_id, i.title, i.quantity, i.price_paise, i.return_status, i.return_reason,
            i.return_note, i.return_requested_at, i.return_updated_at, o.delivered_at, o.shipping_address, u.name AS member_name
       FROM marketplace_order_items i
       JOIN marketplace_orders o ON o.id = i.order_id
       JOIN users u ON u.id = o.user_id
      WHERE i.vendor_id = $1 AND i.return_status IS NOT NULL AND ($2::text IS NULL OR i.return_status = $2::text)
      ORDER BY i.return_requested_at DESC`,
    [vendor.id, status ?? null],
  );
  res.json({ returns });
});

const RETURN_TRANSITIONS = { requested: ['approved', 'rejected'], approved: ['received', 'rejected'], received: ['refunded'], rejected: [], refunded: [] };

/** POST /partner/vendor/returns/:itemId { status: approved|rejected|received|refunded, note? } — received restocks the SKU. */
partnerVendorRouter.post('/returns/:itemId', async (req, res) => {
  const d = validate(z.object({ status: z.enum(['approved', 'rejected', 'received', 'refunded']), note: z.string().trim().max(300).optional() }), req.body);
  const item = await queryOne(
    `SELECT i.*, o.user_id FROM marketplace_order_items i
       JOIN marketplace_orders o ON o.id = i.order_id
       JOIN marketplace_vendors v ON v.id = i.vendor_id
      WHERE i.id = $1 AND v.partner_id = $2`,
    [req.params.itemId, req.user.id],
  );
  if (!item || !item.returnStatus) throw notFound('Return not found');
  if (!(RETURN_TRANSITIONS[item.returnStatus] ?? []).includes(d.status)) {
    throw conflict(`Cannot change a ${item.returnStatus} return to ${d.status}`);
  }
  const updated = await withTransaction(async (client) => {
    const r = await client.query(
      `UPDATE marketplace_order_items SET return_status = $2::text, return_note = COALESCE($3::text, return_note), return_updated_at = now()
        WHERE id = $1 RETURNING *`,
      [item.id, d.status, d.note ?? null],
    );
    if (d.status === 'received' && item.productId) {
      await client.query(`UPDATE marketplace_products SET stock_quantity = stock_quantity + $2 WHERE id = $1`, [item.productId, item.quantity]);
    }
    return r.rows[0];
  });
  const label = { approved: 'approved — pickup will be arranged', rejected: 'not approved', received: 'received by the seller', refunded: 'refunded' }[d.status];
  await notify(item.userId, {
    type: 'store_return_status',
    title: `Return ${label}: ${item.title}`,
    body: d.note ?? null,
    data: { orderId: item.orderId, itemId: item.id },
  });
  res.json({ item: updated });
});

// 4. Commission & Earnings Reports
// Commission follows the founding-partner plan (utils/commission.js: 0% year 1, 2.5% year 2, 5% after), counted
// from the partner's go-live, applied per order date. Returned (received / refunded) lines are excluded.
const VENDOR_SALES = `SELECT to_char((o.created_at AT TIME ZONE 'Asia/Kolkata')::date, 'YYYY-MM-DD') AS date,
       (oi.price_paise * oi.quantity) AS gross_paise, o.payment_method AS source, o.id AS order_id
     FROM marketplace_orders o
     JOIN marketplace_order_items oi ON oi.order_id = o.id
     WHERE oi.vendor_id = $1 AND o.status != 'cancelled'
       AND (oi.return_status IS NULL OR oi.return_status NOT IN ('received', 'refunded'))`;

const goLiveOf = async (userId) =>
  (await queryOne(`SELECT partner_go_live_at FROM users WHERE id = $1`, [userId]))?.partnerGoLiveAt ?? null;

partnerVendorRouter.get('/commissions', async (req, res) => {
  if (req.staffId) throw forbidden('FitKey staff cannot view partner earnings');
  const goLiveAt = await goLiveOf(req.user.id);
  const vendor = await queryOne(`SELECT id FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  if (!vendor) {
    return res.json({ grossRevenuePaise: 0, commissionRatePercent: commissionPct(goLiveAt), commissionPaise: 0, netPayoutPaise: 0, ordersCount: 0 });
  }
  const rows = await query(VENDOR_SALES, [vendor.id]);
  const s = earningsSummary(rows, goLiveAt);
  res.json({
    grossRevenuePaise: s.totals.grossPaise,
    commissionRatePercent: s.commissionPct,
    commissionPaise: s.totals.commissionPaise,
    netPayoutPaise: s.totals.netPaise,
    ordersCount: new Set(rows.map((r) => r.orderId)).size,
  });
});

/** GET /partner/vendor/earnings?from=&to= → { from, to, totals, bySource, byDay, commissionPct } */
partnerVendorRouter.get('/earnings', async (req, res) => {
  if (req.staffId) throw forbidden('FitKey staff cannot view partner earnings');
  const f = validate(z.object({ from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(), to: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional() }), req.query);
  const to = f.to ?? todayIst();
  const from = f.from ?? new Date(Date.parse(`${to}T00:00:00Z`) - 29 * 86_400_000).toISOString().slice(0, 10);
  const vendor = await queryOne(`SELECT id FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  const rows = vendor
    ? await query(
        `SELECT * FROM (${VENDOR_SALES}) s WHERE s.date BETWEEN $2 AND $3`,
        [vendor.id, from, to],
      )
    : [];
  res.json({ from, to, ...earningsSummary(rows, await goLiveOf(req.user.id)) });
});
