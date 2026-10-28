-- =====================================================================
-- 15 · ARQUIVAMENTO SEM PERDA (18/10/2026)
-- Conferência do que acontece quando vendas e caixas saem do Supabase para a planilha (abas Arquivo_*). Ajustes:
--  1) Pedido com CONVERSA de chat (qualquer estado), OCORRÊNCIA (qualquer estado) ou NOTA FISCAL não é mais arquivado:
--     a conversa e a ocorrência são apagadas/desligadas junto com a venda e não vão para a planilha. Esses pedidos ficam no sistema.
--  2) Caixa com BRINDE ou LIBERAÇÃO registrada não é mais arquivado (o banco recusava a remoção e o arquivamento de caixas parava
--     toda noite no mesmo caixa). Fica no sistema.
--  3) Pagamento online (Mercado Pago) guarda o NÚMERO do pedido antes do vínculo com a venda ser desfeito.
--  4) "Simular" passa a seguir exatamente as mesmas regras.
-- Aditivo: 1 coluna nova, 3 funções recriadas, 1 função renomeada + função de passagem. Nada é apagado.
-- =====================================================================

alter table public.pagamentos_online add column if not exists venda_numero int;

create or replace function public.api_arquivar_lote_vendas(p_dias integer, p_limite integer default 200, p_min_dias integer default 30)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_corte timestamptz := now() - (greatest(p_dias, greatest(p_min_dias,1))||' days')::interval; v_ids uuid[];
begin
  select array_agg(id) into v_ids from (
    select v.id from vendas v
    where v.data_hora < v_corte
      and (v.status = 'Cancelada' or (v.status_pagamento = 'Pago' and coalesce(v.status_pedido::text,'Entregue') in ('Entregue','Retirada','Servida')))
      and not exists (select 1 from ajustes_pos_venda a where a.venda_id = v.id)
      and not exists (select 1 from entregas_fechadas e where e.venda_id = v.id)
      and not exists (select 1 from reembolsos r where r.venda_id = v.id)
      and not (v.status <> 'Cancelada' and v.tipo::text = 'Entrega' and v.entregador_id is not null and v.fechamento_entrega_id is null)
      and not exists (select 1 from ocorrencias o where o.venda_id = v.id)
      and not exists (select 1 from chat_conversas c where c.venda_id = v.id)
      and not exists (select 1 from nfce_notas n where n.venda_id = v.id)
    order by v.data_hora limit p_limite) x;
  return jsonb_build_object('ok',true,
    'ids', coalesce(to_jsonb(v_ids),'[]'::jsonb),
    'vendas', (select coalesce(jsonb_agg(to_jsonb(v)),'[]'::jsonb) from vendas v where v.id = any(coalesce(v_ids,'{}'))),
    'itens', (select coalesce(jsonb_agg(to_jsonb(i)),'[]'::jsonb) from itens_venda i where i.venda_id = any(coalesce(v_ids,'{}'))),
    'pagamentos', (select coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) from pagamentos_venda p where p.venda_id = any(coalesce(v_ids,'{}'))));
end $$;

create or replace function public.api_arquivar_lote_caixa(p_dias integer, p_limite integer default 100, p_min_dias integer default 30)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_corte timestamptz := now() - (greatest(p_dias, greatest(p_min_dias,1))||' days')::interval; v_ids uuid[];
begin
  select array_agg(id) into v_ids from (
    select c.id from caixa_sessoes c
    where c.status = 'Fechado' and c.fechamento < v_corte
      and not exists (select 1 from vendas v where v.caixa_id = c.id)
      and not exists (select 1 from brindes b where b.caixa_id = c.id)
      and not exists (select 1 from caixa_liberacoes l where l.caixa_id = c.id)
    order by c.fechamento limit p_limite) x;
  return jsonb_build_object('ok',true,
    'ids', coalesce(to_jsonb(v_ids),'[]'::jsonb),
    'caixas', (select coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) from caixa_sessoes c where c.id = any(coalesce(v_ids,'{}'))),
    'sangrias', (select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from sangrias s where s.caixa_id = any(coalesce(v_ids,'{}'))));
end $$;

create or replace function public.api_simular_arquivamento(p_dias integer default 90)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_corte timestamptz := now() - (greatest(coalesce(p_dias, 90), 30) || ' days')::interval; r jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select jsonb_build_object('ok', true, 'dias', greatest(coalesce(p_dias, 90), 30),
    'vendasAntigas', count(*),
    'vendasArquivaveis', count(*) filter (where ok),
    'vendasBloqueadas', count(*) filter (where not ok),
    'bloqReembolso', count(*) filter (where tem_reemb),
    'maisAntiga', min(data_hora) filter (where ok), 'maisNova', max(data_hora) filter (where ok)) into r
  from (
    select v.data_hora,
      exists (select 1 from reembolsos x where x.venda_id = v.id) tem_reemb,
      ((v.status = 'Cancelada' or (v.status_pagamento = 'Pago' and coalesce(v.status_pedido::text,'Entregue') in ('Entregue','Retirada','Servida')))
        and not exists (select 1 from ajustes_pos_venda a where a.venda_id = v.id)
        and not exists (select 1 from entregas_fechadas e where e.venda_id = v.id)
        and not exists (select 1 from reembolsos x where x.venda_id = v.id)
        and not (v.status <> 'Cancelada' and v.tipo::text = 'Entrega' and v.entregador_id is not null and v.fechamento_entrega_id is null)
        and not exists (select 1 from ocorrencias o where o.venda_id = v.id)
        and not exists (select 1 from chat_conversas c where c.venda_id = v.id)
        and not exists (select 1 from nfce_notas n where n.venda_id = v.id)) ok
      from vendas v where v.data_hora < v_corte) t;
  return r || jsonb_build_object(
    'caixasArquivaveis', (select count(*) from caixa_sessoes c where c.status = 'Fechado' and c.fechamento < v_corte and not exists (select 1 from vendas v where v.caixa_id = c.id)
                            and not exists (select 1 from brindes b where b.caixa_id = c.id) and not exists (select 1 from caixa_liberacoes l where l.caixa_id = c.id)),
    'resumoGuardado', (select count(*) from vendas_resumo_arquivo),
    'historicoArquivadas', (select count(*) from arquivo_historico where tabela = 'vendas'),
    'filaAnonimizacao', (select count(*) from anonimizar_arquivo_fila where feito_em is null));
end $$;

-- função de passagem: guarda o número do pedido nos pagamentos online e depois chama a rotina original (renomeada)
do $$ begin   -- só renomeia na primeira vez (rodar de novo não dá erro)
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'api_arquivar_confirmar_vendas' and p.prosrc not like '%_arquivar_confirmar_vendas_base%') then
    alter function public.api_arquivar_confirmar_vendas(uuid[]) rename to _arquivar_confirmar_vendas_base;
  end if;
end $$;
create or replace function public.api_arquivar_confirmar_vendas(p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
begin
  update pagamentos_online po set venda_numero = v.numero_pedido from vendas v where v.id = po.venda_id and po.venda_id = any(p_ids) and po.venda_numero is null;
  return _arquivar_confirmar_vendas_base(p_ids);
end $$;
revoke all on function public.api_arquivar_confirmar_vendas(uuid[]) from public, anon, authenticated;
grant execute on function public.api_arquivar_confirmar_vendas(uuid[]) to service_role;
revoke all on function public._arquivar_confirmar_vendas_base(uuid[]) from public, anon, authenticated;
grant execute on function public._arquivar_confirmar_vendas_base(uuid[]) to service_role;
