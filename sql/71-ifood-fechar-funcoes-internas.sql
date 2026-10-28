-- 71 · Segurança (auditoria final 25/10/2026) — funções internas do iFood só para o servidor. Pode rodar de novo sem erro.
-- Estas funções são usadas só pela Edge Function ifood-sync (chave de serviço). Antes, qualquer pessoa logada podia chamá-las pela API.
revoke all on function public.ifood_horario_gravar(jsonb), public.ifood_cat_arvore(uuid), public.ifood_cat_resultado(uuid, text, text, jsonb), public.ifood_cat_patch(uuid, jsonb), public._ifood_lacuna_varrer(bigint) from public, anon, authenticated;
grant execute on function public.ifood_horario_gravar(jsonb), public.ifood_cat_arvore(uuid), public.ifood_cat_resultado(uuid, text, text, jsonb), public.ifood_cat_patch(uuid, jsonb), public._ifood_lacuna_varrer(bigint) to service_role;

-- Auditoria geral (mesmo dia): funções internas de margem (mostravam preço, CUSTO e margem a quem não estava logado) e de alertas (disparo livre).
-- Só o servidor e as rotinas automáticas (donas das funções) usam estas funções.
revoke all on function public._margem_baixa(), public._margem_min_cat(uuid), public._margem_minima(), public._margem_pior_por_categoria(), public.alertas_pedidos_cron(), public.alertas_sistema_cron() from public, anon, authenticated;
grant execute on function public._margem_baixa(), public._margem_min_cat(uuid), public._margem_minima(), public._margem_pior_por_categoria(), public.alertas_pedidos_cron(), public.alertas_sistema_cron() to service_role;

-- Auditoria geral: funções auxiliares sem "search_path" fixo (aviso do Supabase).
do $d$ declare r record; begin
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = 'public' and p.proname in ('_ifood_fin_banco','_ifood_fin_bool','_ifood_fin_d','_ifood_fin_hoje','_ifood_fin_segunda','_ifood_fin_ts','_ifood_inelegivel_txt','_ifood_ship_erro_txt','_ifood_validacao_txt','_pag_nome')
      and (p.proconfig is null or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
  loop execute 'alter function ' || r.f || ' set search_path = public, pg_temp'; end loop;
end $d$;
