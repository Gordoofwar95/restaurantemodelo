import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { CORS, json, svcClient, autorizar, cfg, URL_ } from "./auth.ts";
const SHEETS_MAIN = await cfg("SHEETS_MAIN_URL");
const CHAVE_SERVIDOR = await cfg("PRINCIPAL_CHAVE_SERVIDOR");
const PUBLISHABLE = await cfg("SB_PUBLISHABLE_KEY");

// Fotos da batida do ponto (18/10/2026), pelo mesmo caminho das notas de compra:
// Edge Function -> planilha principal (Apps Script, dono do Drive) -> Drive principal e Drive da contingência. Arquivos PRIVADOS.
//   enviar  (qualquer perfil logado): só o próprio funcionário, logo depois de bater o ponto (o banco confere em api_ponto_foto_pode)
//   ver     (Admin): devolve a foto de uma batida
//   limpar  (rotina diária do banco): apaga nos dois Drives as fotos com mais de 45 dias e limpa o caminho no registro
// foto_ent / foto_sai guardam "drive:<id>", "cont:<id>" ou "drive:<id>|cont:<id>".
const DIAS_GUARDA = 45;
const TODOS = ["Admin", "Operador", "Garçom", "Cozinha", "Entregador"];
async function planilha(corpo: Record<string, unknown>) {
  const r = await fetch(SHEETS_MAIN, { method: "POST", headers: { "Content-Type": "text/plain" },
    body: JSON.stringify({ chave: CHAVE_SERVIDOR, ...corpo }) });
  return await r.json();
}
const desatualizada = (m: string) => /Ação desconhecida/i.test(m || "")
  ? "A planilha principal ainda não tem a função de fotos do ponto: cole o código novo do Apps Script (das duas planilhas) e publique uma nova versão." : m;
const partesDe = (path: string) => Object.fromEntries(String(path || "").split("|").map((x) => x.split(":")).filter((x) => x.length === 2));

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const b = await req.json();
    if (b.acao === "limpar") {
      const a = await autorizar(req, null);
      if (!a.ok) return json({ ok: false, message: a.message }, a.status);
      const corte = new Date(Date.now() - DIAS_GUARDA * 86400000).toISOString();
      const svc = svcClient();
      const { data: regs, error } = await svc.from("ponto_registros").select("id,foto_ent,foto_sai")
        .or("foto_ent.not.is.null,foto_sai.not.is.null").lt("entrada", corte).limit(150);
      if (error) return json({ ok: false, message: error.message }, 500);
      let apagados = 0, falhas = 0;
      for (const r of regs || []) {
        const ids: string[] = [], idsReserva: string[] = [];
        for (const path of [r.foto_ent, r.foto_sai]) { const p = partesDe(path as string); if (p.drive) ids.push(p.drive); if (p.cont) idsReserva.push(p.cont); }
        try {
          const j = ids.length || idsReserva.length ? await planilha({ action: "sbExcluirPonto", ids, idsReserva }) : { ok: true };
          if (!j?.ok) { falhas++; continue; }
          await svc.from("ponto_registros").update({ foto_ent: null, foto_sai: null }).eq("id", r.id);
          apagados++;
        } catch { falhas++; }
      }
      return json({ ok: true, apagados, falhas, restantes: (regs || []).length >= 150 });
    }

    if (b.acao === "enviar") {
      const a = await autorizar(req, TODOS);
      if (!a.ok) return json({ ok: false, message: a.message }, a.status);
      if (a.servico) return json({ ok: false, message: "Só o funcionário envia a foto." }, 403);
      const lado = b.lado === "saida" ? "saida" : "entrada";
      const dados = String(b.base64Data || "");
      if (!dados || dados.length > 2.1 * 1024 * 1024) return json({ ok: false, message: "Foto ausente ou maior que 1,5 MB." }, 400);
      const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const usr = createClient(URL_, PUBLISHABLE, { global: { headers: { Authorization: "Bearer " + token } } });
      const ped = { registroId: String(b.registroId || ""), lado };
      const { data: pode } = await usr.rpc("api_ponto_foto_pode", { p: ped });
      if (!pode?.ok) return json({ ok: false, message: pode?.message || "Não foi possível salvar a foto." }, 403);
      const j = await planilha({ action: "sbGuardarPonto", base64Data: dados, nomeBase: "ponto-" + ped.registroId.slice(0, 8) + "-" + lado, destino: "ambos" });
      if (!j?.ok) return json({ ok: false, message: desatualizada(j?.message) || "Falha ao salvar a foto." }, 502);
      const path = [j.id ? "drive:" + j.id : "", j.idReserva ? "cont:" + j.idReserva : ""].filter(Boolean).join("|");
      const { data: an } = await usr.rpc("api_ponto_foto_anexar", { p: { ...ped, path } });
      if (!an?.ok) {
        try { await planilha({ action: "sbExcluirPonto", ids: j.id ? [j.id] : [], idsReserva: j.idReserva ? [j.idReserva] : [] }); } catch { /* ok */ }
        return json({ ok: false, message: an?.message || "Não foi possível anexar a foto." }, 400);
      }
      return json({ ok: true, aviso: j.avisoReserva ? "Salva só no Drive principal (a contingência não respondeu)." : "" });
    }

    if (b.acao === "ver") {
      const a = await autorizar(req, ["Admin"]);
      if (!a.ok) return json({ ok: false, message: a.message }, a.status);
      const { data: r } = await svcClient().from("ponto_registros").select("foto_ent,foto_sai").eq("id", b.registroId).single();
      const path = String((b.lado === "saida" ? r?.foto_sai : r?.foto_ent) || "");
      if (!path) return json({ ok: false, message: "Esta batida não tem foto (ou já passou de " + DIAS_GUARDA + " dias e foi apagada)." }, 404);
      const partes = partesDe(path);
      let ultimo = "";
      for (const [onde, chave] of [["principal", "drive"], ["contingencia", "cont"]]) {
        if (!partes[chave]) continue;
        const j = await planilha({ action: "sbLerPonto", id: partes[chave], onde });
        if (j?.ok && j.base64) return json({ ok: true, tipo: j.tipo, base64: j.base64, de: onde });
        ultimo = desatualizada(j?.message) || ultimo;
      }
      return json({ ok: false, message: ultimo || "Não consegui abrir a foto (arquivo apagado)." }, 404);
    }
    return json({ ok: false, message: "Ação inválida." }, 400);
  } catch (e) { return json({ ok: false, message: (e as Error).message }, 500); }
});
