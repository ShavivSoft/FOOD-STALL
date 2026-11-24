// Supabase Edge Function: sends the "order ready" push to the customer's phone.
// Called by the admin dashboard when the token manager taps READY.
// Needs secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY (optional VAPID_SUBJECT).
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

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
    const url = Deno.env.get('SUPABASE_URL')!;
    // 1. caller must be a token manager
    const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    });
    const { data: isAdmin } = await asUser.rpc('is_admin');
    if (!isAdmin) return json({ error: 'forbidden' }, 403);

    const { order_id, site_url } = await req.json();
    const db = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: o, error } = await db.from('orders').select('id, token, key').eq('id', order_id).single();
    if (error || !o) return json({ error: 'order not found' }, 404);
    const { data: subs } = await db.from('push_subs').select('id, endpoint, keys').eq('order_id', order_id);

    webpush.setVapidDetails(
      Deno.env.get('VAPID_SUBJECT') ?? 'mailto:admin@example.com',
      Deno.env.get('VAPID_PUBLIC_KEY')!,
      Deno.env.get('VAPID_PRIVATE_KEY')!,
    );
    const payload = JSON.stringify({
      title: `Your order is ready! Token #${o.token}`,
      body: 'Please collect your food at the counter.',
      url: `${site_url}?t=${o.key}`,
      tag: `order-${o.id}`,
    });

    let sent = 0;
    for (const s of subs ?? []) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: s.keys }, payload, { TTL: 3600, urgency: 'high' });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await db.from('push_subs').delete().eq('id', s.id); // phone unsubscribed
        console.error('push failed', code ?? e);
      }
    }
    return json({ sent });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
