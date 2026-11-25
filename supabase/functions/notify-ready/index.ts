// Supabase Edge Function "notify-ready" — sends the "order ready" push to the customer's phone,
// even when they have closed the page. Called by the admin dashboard.
//   { action: "init" }                    → makes sure the push key pair exists, returns the public key
//   { order_id, site_url }                → sends the ready notification for that order
// No secrets to configure: the key pair is created on first use and kept in the push_keys table.
// Deploy with "Verify JWT" OFF — this function checks the admin login itself.
import { createClient } from 'npm:@supabase/supabase-js@2';

// ---------- Web Push (RFC 8291 + VAPID), WebCrypto only ----------
type Bytes = Uint8Array<ArrayBuffer>;
const te = new TextEncoder();
const b64u = (buf: ArrayBuffer | Bytes): string => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64u = (s: string): Bytes => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - s.length % 4) % 4)), (c) => c.charCodeAt(0));
const concat = (...a: Bytes[]): Bytes => { const out = new Uint8Array(a.reduce((n, x) => n + x.length, 0)); let o = 0; for (const x of a) { out.set(x, o); o += x.length; } return out; };

async function hkdf(salt: Bytes, ikm: Bytes, info: Bytes, len: number): Promise<Bytes> {
  const k = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, k, len * 8));
}

async function generateVapidKeys(): Promise<{ publicKey: string; privateKey: string }> {
  const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const jwk = await crypto.subtle.exportKey('jwk', kp.privateKey);
  return { publicKey: b64u(concat(new Uint8Array([4]), unb64u(jwk.x!), unb64u(jwk.y!))), privateKey: jwk.d! };
}

async function vapidAuth(endpoint: string, publicKey: string, privateKey: string, subject: string): Promise<string> {
  const pub = unb64u(publicKey);
  const key = await crypto.subtle.importKey('jwk',
    { kty: 'EC', crv: 'P-256', x: b64u(pub.slice(1, 33)), y: b64u(pub.slice(33, 65)), d: privateKey, ext: true },
    { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const head = b64u(te.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const body = b64u(te.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: subject })));
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, te.encode(head + '.' + body)); // raw r||s = JWS ES256
  return `vapid t=${head}.${body}.${b64u(sig)}, k=${publicKey}`;
}

type Sub = { endpoint: string; keys: { p256dh: string; auth: string } };
async function encryptPayload(subscription: Sub, text: string): Promise<Bytes> {
  const uaPub = unb64u(subscription.keys.p256dh), auth = unb64u(subscription.keys.auth);
  const as = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const asPub = new Uint8Array(await crypto.subtle.exportKey('raw', as.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPub, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const secret = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, as.privateKey, 256));
  const ikm = await hkdf(auth, secret, concat(te.encode('WebPush: info\0'), uaPub, asPub), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, te.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, te.encode('Content-Encoding: nonce\0'), 12);
  const aes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aes, concat(te.encode(text), new Uint8Array([2]))));
  const rs = new Uint8Array([0, 0, 16, 0]); // record size 4096
  return concat(salt, rs, new Uint8Array([asPub.length]), asPub, ct);
}

// Returns the HTTP status from the push service (201 = delivered to the queue; 404/410 = subscription gone).
async function sendPush(
  subscription: Sub, text: string,
  { publicKey, privateKey, subject, ttl = 3600, urgency = 'high' }: { publicKey: string; privateKey: string; subject: string; ttl?: number; urgency?: string },
): Promise<number> {
  const res = await fetch(subscription.endpoint, {
    method: 'POST',
    headers: {
      Authorization: await vapidAuth(subscription.endpoint, publicKey, privateKey, subject),
      'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream',
      TTL: String(ttl), Urgency: urgency,
    },
    body: await encryptPayload(subscription, text),
  });
  return res.status;
}

// ---------- handler ----------
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    // server key: legacy service_role, or the new sb_secret_ key on newer projects
    let serverKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!serverKey) {
      try { serverKey = Object.values(JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}'))[0] as string ?? ''; } catch { /* ignore */ }
    }
    if (!serverKey) return json({ error: 'no server key available to the function' }, 500);
    const db = createClient(Deno.env.get('SUPABASE_URL')!, serverKey, {
      auth: { persistSession: false },
    });

    // 1. caller must be a logged-in token manager
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: u } = await db.auth.getUser(jwt);
    const email = u?.user?.email?.toLowerCase();
    if (!email) return json({ error: 'login required' }, 401);
    const { data: adm } = await db.from('admins').select('email').eq('email', email).maybeSingle();
    if (!adm) return json({ error: 'forbidden' }, 403);

    // 2. push key pair (created once, then reused)
    let { data: keys } = await db.from('push_keys').select('public_key, private_key').eq('id', 1).maybeSingle();
    if (!keys) {
      const k = await generateVapidKeys();
      await db.from('push_keys').upsert({ id: 1, public_key: k.publicKey, private_key: k.privateKey }, { onConflict: 'id', ignoreDuplicates: true });
      ({ data: keys } = await db.from('push_keys').select('public_key, private_key').eq('id', 1).single());
    }
    await db.from('settings').update({ vapid_public: keys!.public_key }).eq('id', 1); // customers read it from here

    const body = await req.json().catch(() => ({}));
    if (body.action === 'init') return json({ publicKey: keys!.public_key });

    // 3. send to every phone subscribed to this order
    const { data: o } = await db.from('orders').select('id, token, key').eq('id', body.order_id).maybeSingle();
    if (!o) return json({ error: 'order not found' }, 404);
    const { data: subs } = await db.from('push_subs').select('id, endpoint, keys').eq('order_id', o.id);
    const payload = JSON.stringify({
      title: `🍔 Your order is ready! Token #${o.token}`,
      body: 'Please collect your food at the counter.',
      url: `${body.site_url}?t=${o.key}`,
      tag: `order-${o.id}`,
    });
    let sent = 0;
    const failed: number[] = [];
    for (const s of subs ?? []) {
      try {
        const status = await sendPush({ endpoint: s.endpoint, keys: s.keys }, payload, {
          publicKey: keys!.public_key, privateKey: keys!.private_key, subject: `mailto:${email}`,
        });
        if (status >= 200 && status < 300) sent++;
        else {
          failed.push(status);
          if (status === 404 || status === 410) await db.from('push_subs').delete().eq('id', s.id); // phone unsubscribed
        }
      } catch (e) {
        failed.push(0);
        console.error('push error', e);
      }
    }
    return json({ sent, failed });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
