-- =====================================================================
-- 10 · Ajustes da auditoria (18/10/2026, noite). Pode rodar de novo sem erro.
-- Já estão aplicados no banco em uso; este arquivo serve para refazer o banco do zero.
-- Rode DEPOIS do 09. Contém: (a) fuso de Brasília no resumo do Mercado Pago e no painel de IA,
-- (b) conferência do valor pago no Mercado Pago, (c) fechar funções internas para visitantes.
-- =====================================================================

-- (a) F5-4: mês do resumo do Mercado Pago e "últimos 7 dias" da IA usam o horário de Brasília (antes cortavam às 21h)
CREATE OR REPLACE FUNCTION public.api_mp_resumo_operacional(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_ini timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
        v_fim timestamptz := (date_trunc('month', now() at time zone 'America/Sao_Paulo') + interval '1 month') at time zone 'America/Sao_Paulo';
        v_total numeric(12,2); v_taxas numeric(12,2); v_qtd integer;
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  select coalesce(sum(greatest(x.valor - x.valor_reembolsado, 0)),0), count(*)::int into v_total, v_qtd
    from pagamentos_online x where x.status in ('aprovado','reembolso_parcial','reembolsado') and x.aprovado_em >= v_ini and x.aprovado_em < v_fim;
  select coalesce(sum(pv.taxa_aplicada),0) into v_taxas
    from pagamentos_online x join pagamentos_venda pv on pv.venda_id = x.venda_id
    where x.status in ('aprovado','reembolso_parcial','reembolsado') and x.aprovado_em >= v_ini and x.aprovado_em < v_fim;
  return jsonb_build_object('ok', true, 'periodo', to_char(v_ini at time zone 'America/Sao_Paulo','MM/YYYY'),
    'quantidade', v_qtd, 'total', round(v_total,2), 'taxas', round(v_taxas,2),
    'itens', (select coalesce(jsonb_agg(jsonb_build_object('metodo', q.metodo, 'quantidade', q.quantidade, 'total', q.total, 'taxas', q.taxas) order by q.metodo), '[]'::jsonb)
      from (select x.metodo, count(*)::int as quantidade, round(coalesce(sum(greatest(x.valor - x.valor_reembolsado, 0)),0),2) as total,
                   round(coalesce(sum(pv.taxa_aplicada),0),2) as taxas
              from pagamentos_online x left join (select venda_id, sum(taxa_aplicada) as taxa_aplicada from pagamentos_venda group by venda_id) pv on pv.venda_id = x.venda_id
             where x.status in ('aprovado','reembolso_parcial','reembolsado') and x.aprovado_em >= v_ini and x.aprovado_em < v_fim
             group by x.metodo) q));
end $function$;

CREATE OR REPLACE FUNCTION public.ia_painel_uso()
 RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path TO 'public'
AS $function$
begin
  if not tem_nivel('Admin') then return jsonb_build_object('ok', false, 'message', 'Sem permissão.'); end if;
  return jsonb_build_object('ok', true,
    'hoje', coalesce((select jsonb_agg(jsonb_build_object('provedor', provedor, 'chamadas', c, 'erros', e)) from
        (select provedor, sum(chamadas) c, sum(erros) e from ai_uso where dia = (now() at time zone 'America/Sao_Paulo')::date group by 1) x), '[]'::jsonb),
    'ultimos_7_dias', coalesce((select sum(chamadas) from ai_uso where dia >= (now() at time zone 'America/Sao_Paulo')::date - 7), 0),
    'erros_24h', (select count(*) from ai_log where status = 'erro' and criado_em >= now() - interval '24 hours'),
    'cache_24h', (select count(*) from ai_log where status = 'cache' and criado_em >= now() - interval '24 hours'));
end $function$;

-- (b) F51-1: se o Mercado Pago informar ("valorPago") um valor MENOR que o cobrado, o pedido vai para "a decidir" em vez de virar venda sozinho.
-- (Hoje as Edge Functions ainda não enviam "valorPago"; quando enviarem, a regra passa a valer sem outra mudança no banco.)
DO $$
declare d text;
begin
  select pg_get_functiondef('public.mp_aplicar_status(jsonb)'::regprocedure) into d;
  if position('v_vp' in d) = 0 then
    d := replace(d, 'v_antes numeric;', 'v_antes numeric; v_vp numeric;');
    d := replace(d, 'if g.status not in (''reembolso_parcial'', ''reembolsado'') then v_res := _mp_confirmar_pagamento(g.id); end if;',
      'if g.status not in (''reembolso_parcial'', ''reembolsado'') then
      v_vp := _num(p->>''valorPago'', 0);
      if v_vp > 0 and v_vp < g.valor - 0.009 and g.venda_id is null and g.decisao is null and not g.decisao_pendente then
        update pagamentos_online set status = ''aprovado'', aprovado_em = coalesce(aprovado_em, now()), erro = '''', atualizado_em = now() where id = g.id;
        perform _mp_marcar_decidir(g.id, ''Valor pago (R$ '' || _dinheiro(v_vp) || '') menor que o cobrado (R$ '' || _dinheiro(g.valor) || '')'');
        v_res := jsonb_build_object(''ok'', true, ''decidir'', true, ''motivo'', ''valor_diferente'');
      else
        v_res := _mp_confirmar_pagamento(g.id);
      end if;
    end if;');
    execute d;
  end if;
end $$;

-- (c) F2-3: funções internas (alertas, entrada de compra, alíquota) deixam de ser chamáveis por visitantes e por logados pela API.
-- Quem as usa é o servidor (agendamentos, Edge Functions e outras funções do banco).
DO $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p where p.pronamespace='public'::regnamespace
     and p.proname in ('_alertas_cfg','_alertas_email','_alertas_pedidos_parados','_alertas_push','_alertas_sistema_avisar','_compra_receber2','_imposto_pct')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
    execute format('grant execute on function %s to service_role', r.f);
  end loop;
end $$;
