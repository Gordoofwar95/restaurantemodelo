import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { CORS, json, svcClient, autorizar, cfg } from "./auth.ts";
const SHEETS_MAIN = await cfg("SHEETS_MAIN_URL");
const CHAVE_SERVIDOR = await cfg("PRINCIPAL_CHAVE_SERVIDOR");

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const a = await autorizar(req, ["Admin"]);
  if (!a.ok) return json({ ok: false, message: a.message }, a.status);
  try {
    const svc = svcClient();
    const { data: conf } = await svc.from("configuracoes_fotos").select("replicar_antigas").eq("id", true).single();
    if (conf?.replicar_antigas === "nenhuma") return json({ ok: true, message: "Replicação desligada." });
    const lim = 15;   // poucas por vez: cada cópia leva alguns segundos; repita o botão até zerar
    const itens: any[] = [];
    for (const tipo of ["produtos", "combos"] as const) {
      const { data } = await svc.from(tipo).select("id,nome,foto_id_principal")
        .not("foto_id_principal", "is", null).is("foto_id_contingencia", null).limit(lim);
      (data || []).forEach((x) => itens.push({ tipo, ...x }));
    }
    if (!itens.length) return json({ ok: true, message: "Nada a replicar.", replicadas: 0 });

    const j = await (await fetch(SHEETS_MAIN, { method: "POST", headers: { "Content-Type": "text/plain" },
      body: JSON.stringify({ action: "replicarFotos", chave: CHAVE_SERVIDOR, itens: itens.slice(0, lim) }) })).json();
    for (const r of j?.resultados || [])
      await svc.from(r.tipo === "combos" ? "combos" : "produtos").update({ foto_id_contingencia: r.foto_id_contingencia }).eq("id", r.id);
    return json({ ok: j?.ok ?? false, message: j?.message, replicadas: (j?.resultados || []).length, faltam: Math.max(0, itens.length - (j?.resultados || []).length) });
  } catch (e) { return json({ ok: false, message: (e as Error).message }, 500); }
});
