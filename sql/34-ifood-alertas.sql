-- 34 · Alertas de pedido parado: entrega feita pelo próprio iFood não alerta "sem sair para entrega" (19/10/2026)
-- Quando o iFood entrega, a loja só deixa o pedido pronto; quem sai com ele é o entregador do iFood. Os demais alertas continuam valendo.
create or replace function public._alertas_pedidos_parados()
returns table (venda_id uuid, numero int, regra text, rotulo text, desde timestamptz, minutos int, niveis text[], tipo text)
language plpgsql stable security definer set search_path to 'public' as $$
declare v_cfg jsonb := _alertas_cfg()->'regras'; s caixa_sessoes%rowtype;
begin
  select * into s from caixa_sessoes where status = 'Aberto' order by abertura desc limit 1;
  if s.id is null then return; end if;
  return query
  with base as (
    select v.id, v.numero_pedido, v.tipo::text tp, v.status_pedido::text sp, v.status_pagamento::text pg,
           v.data_hora, v.inicio_preparo_em, v.pronta_em, v.saiu_em, v.concluida_em,
           coalesce(v.observacoes_entrega, '') ilike '%AGENDADO%' agendado,
           (v.canal = 'iFood' and coalesce(v.observacoes_entrega, '') ilike '%ENTREGA PELO iFOOD%') ent_ifood
      from vendas v
     where v.status = 'Confirmada'
       and (v.caixa_id = s.id or (v.caixa_id is null and v.data_hora >= s.abertura))
       and coalesce(v.status_pedido::text, '') <> 'Suspenso'
       and not exists (select 1 from ocorrencias o where o.venda_id = v.id and o.status::text in ('Aberta', 'Em andamento'))
  ), r as (
    select id, numero_pedido, 'recebido' rg, 'Novo pedido sem aceite' rot, data_hora d, array['Cozinha','Operador'] nv, tp from base where sp = 'Recebido' and not agendado
    union all select id, numero_pedido, 'preparo', 'Em preparo há muito tempo', coalesce(inicio_preparo_em, data_hora), array['Cozinha','Operador'], tp from base where sp = 'Em preparo' and not agendado
    union all select id, numero_pedido, 'pronta_retirada', 'Pronta (retirada) sem marcar "Retirada"', coalesce(pronta_em, data_hora), array['Operador','Admin'], tp from base where sp = 'Pronta' and tp = 'Retirada'
    union all select id, numero_pedido, 'pronta_entrega', 'Pronta (entrega) sem sair para entrega', coalesce(pronta_em, data_hora), array['Operador','Admin'], tp from base where sp = 'Pronta' and tp = 'Entrega' and not ent_ifood
    union all select id, numero_pedido, 'pronta_mesa', 'Pronta (mesa) sem marcar "Servida"', coalesce(pronta_em, data_hora), array['Operador','Garçom'], tp from base where sp = 'Pronta' and tp = 'Mesa'
    union all select id, numero_pedido, 'saiu', 'Saiu para entrega e não foi concluído', coalesce(saiu_em, data_hora), array['Operador','Admin'], tp from base where sp = 'Saiu para entrega' and not ent_ifood
    union all select id, numero_pedido, 'a_receber', 'Pagamento "a receber" com o pedido pronto', coalesce(concluida_em, pronta_em, data_hora), array['Operador','Admin'], tp
      from base where pg = 'A Receber' and tp <> 'Mesa' and sp in ('Pronta', 'Retirada', 'Servida', 'Entregue')
  )
  select r.id, r.numero_pedido, r.rg, r.rot, r.d, floor(extract(epoch from (now() - r.d)) / 60)::int, r.nv, r.tp
    from r
   where coalesce((v_cfg->r.rg->>'ligado')::boolean, true)
     and now() - r.d >= make_interval(mins => greatest(1, coalesce((v_cfg->r.rg->>'min')::int, 10)));
end $$;
