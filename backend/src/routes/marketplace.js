import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate, conflict } from '../utils/http.js';

export const marketplaceRouter = Router();

// ============================================================================
// Consumer App Endpoints (FITKEY)
// ============================================================================

marketplaceRouter.get('/products', async (req, res) => {
  const { category, q, limit = 20, page = 1 } = req.query;
  const conditions = ['is_active = true'];
  const params = [];

  if (category && category !== 'all') {
    params.push(category);
    conditions.push(`category = $${params.length}`);
  }
  if (q && q.trim()) {
    params.push(`%${q.trim()}%`);
    conditions.push(`(title ILIKE $${params.length} OR brand ILIKE $${params.length} OR description ILIKE $${params.length})`);
  }

  const offset = (Math.max(1, +page) - 1) * +limit;
  params.push(+limit, offset);

  const products = await query(
    `SELECT * FROM marketplace_products
     WHERE ${conditions.join(' AND ')}
     ORDER BY created_at DESC
     LIMIT $${params.length - 1} OFFSET $${params.length}`,
    params,
  );

  res.json({ products });
});

marketplaceRouter.get('/products/:id', async (req, res) => {
  const product = await queryOne(
    `SELECT p.*, v.business_name AS vendor_name
     FROM marketplace_products p
     LEFT JOIN marketplace_vendors v ON v.id = p.vendor_id
     WHERE p.id = $1`,
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
});

marketplaceRouter.post('/orders', requireAuth('user'), async (req, res) => {
  const body = validate(checkoutSchema, req.body);

  const order = await withTransaction(async (client) => {
    // 1. Fetch products and calculate total
    let totalPaise = 0;
    const itemsData = [];

    for (const item of body.items) {
      const pRes = await client.query(
        `SELECT id, vendor_id, title, price_paise, stock_quantity FROM marketplace_products WHERE id = $1 AND is_active = true FOR UPDATE`,
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
         user_id, status, total_amount_paise, payment_method, payment_status, shipping_address, tracking_number
       ) VALUES ($1, 'placed', $2, $3, $4, $5, $6)
       RETURNING *`,
      [req.user.id, totalPaise, body.paymentMethod, paymentStatus, JSON.stringify(body.shippingAddress), trackingNum],
    );
    const order = orderRes.rows[0];

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
                  'quantity', i.quantity
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
                  'quantity', i.quantity
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
       partner_id, business_name, gstin, bank_name, bank_account_no, ifsc_code, verification_status
     ) VALUES ($1, $2, $3, $4, $5, $6, 'verified')
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
    `SELECT * FROM marketplace_products WHERE vendor_id = $1 ORDER BY created_at DESC`,
    [vendor.id],
  );
  res.json({ products });
});

const productSchema = z.object({
  title: z.string().min(3),
  brand: z.string().min(2),
  category: z.enum(['supplements', 'apparel', 'wearables', 'gear']),
  description: z.string().min(10),
  pricePaise: z.number().int().min(0),
  originalPricePaise: z.number().int().min(0),
  stockQuantity: z.number().int().min(0),
  images: z.array(z.string()).default([]),
  specs: z.record(z.string()).default({}),
});

partnerVendorRouter.post('/products', async (req, res) => {
  let vendor = await queryOne(`SELECT id FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  if (!vendor) {
    vendor = await queryOne(
      `INSERT INTO marketplace_vendors (partner_id, business_name)
       VALUES ($1, $2) RETURNING id`,
      [req.user.id, req.user.name || 'Partner Vendor'],
    );
  }

  const p = validate(productSchema, req.body);
  const product = await queryOne(
    `INSERT INTO marketplace_products (
       vendor_id, title, brand, category, description, price_paise, original_price_paise,
       stock_quantity, images, specs
     ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
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

  const updated = await queryOne(
    `UPDATE marketplace_products SET
       title = COALESCE($1, title),
       brand = COALESCE($2, brand),
       category = COALESCE($3, category),
       description = COALESCE($4, description),
       price_paise = COALESCE($5, price_paise),
       original_price_paise = COALESCE($6, original_price_paise),
       stock_quantity = COALESCE($7, stock_quantity),
       specs = COALESCE($8, specs)
     WHERE id = $9
     RETURNING *`,
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
    ],
  );
  res.json({ product: updated });
});

// 3. Order Fulfillment & Dispatch
partnerVendorRouter.get('/orders', async (req, res) => {
  const vendor = await queryOne(`SELECT id FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  if (!vendor) return res.json({ orders: [] });

  const orders = await query(
    `SELECT DISTINCT o.id, o.status, o.total_amount_paise, o.payment_method, o.payment_status,
            o.shipping_address, o.tracking_number, o.created_at, o.dispatched_at,
            (SELECT json_agg(json_build_object('title', i.title, 'pricePaise', i.price_paise, 'quantity', i.quantity))
             FROM marketplace_order_items i WHERE i.order_id = o.id AND i.vendor_id = $1) AS vendor_items
     FROM marketplace_orders o
     JOIN marketplace_order_items oi ON oi.order_id = o.id
     WHERE oi.vendor_id = $1
     ORDER BY o.created_at DESC`,
    [vendor.id],
  );
  res.json({ orders });
});

partnerVendorRouter.patch('/orders/:id/status', async (req, res) => {
  const schema = z.object({
    status: z.enum(['processing', 'dispatched', 'delivered']),
    trackingNumber: z.string().optional(),
  });
  const data = validate(schema, req.body);

  const updated = await queryOne(
    `UPDATE marketplace_orders SET
       status = $1,
       tracking_number = COALESCE($2, tracking_number),
       dispatched_at = CASE WHEN $1 = 'dispatched' AND dispatched_at IS NULL THEN now() ELSE dispatched_at END,
       delivered_at = CASE WHEN $1 = 'delivered' AND delivered_at IS NULL THEN now() ELSE delivered_at END
     WHERE id = $3
     RETURNING *`,
    [data.status, data.trackingNumber ?? null, req.params.id],
  );
  if (!updated) throw notFound('Order not found');
  res.json({ order: updated });
});

// 4. Commission & Earnings Reports
partnerVendorRouter.get('/commissions', async (req, res) => {
  const vendor = await queryOne(`SELECT id, commission_rate FROM marketplace_vendors WHERE partner_id = $1`, [req.user.id]);
  if (!vendor) return res.json({ totalRevenuePaise: 0, commissionPaise: 0, netPayoutPaise: 0, ordersCount: 0 });

  const stats = await queryOne(
    `SELECT COUNT(DISTINCT o.id) AS orders_count,
            COALESCE(SUM(oi.price_paise * oi.quantity), 0) AS gross_paise
     FROM marketplace_orders o
     JOIN marketplace_order_items oi ON oi.order_id = o.id
     WHERE oi.vendor_id = $1 AND o.status != 'cancelled'`,
    [vendor.id],
  );

  const grossPaise = +stats.gross_paise;
  const commissionRate = +(vendor.commission_rate || 10.0);
  const commissionPaise = Math.round(grossPaise * (commissionRate / 100));
  const netPayoutPaise = grossPaise - commissionPaise;

  res.json({
    grossRevenuePaise: grossPaise,
    commissionRatePercent: commissionRate,
    commissionPaise,
    netPayoutPaise,
    ordersCount: +stats.orders_count,
  });
});
