-- 35 · iFood: recursos opcionais (19/10/2026). TODOS nascem DESLIGADOS (Administrador › Sistema › Integrações e contas › iFood › Ajustes).
--  • conferirRepasse   : compara cada repasse do iFood com o que o sistema esperava receber dos mesmos pedidos (só mostra a diferença).
--  • avaliacaoAlerta   : avisa (push) também a avaliação nota 3 (sem isso, só nota 1 e 2).
--  • avaliacaoSugestao : botão "Sugerir resposta" nas avaliações (só tela; o dono revisa antes de enviar).
--  • acompanharEntrega : guarda a posição do entregador do iFood enquanto o pedido está pronto ou a caminho e mostra no pedido.
alter table public.ifood_pedidos add column if not exists rastreio jsonb;
alter table public.ifood_pedidos add column if not exists rastreio_em timestamptz;

-- 1) as novas chaves passam a ser aceitas em "Ajustes salvos"
do $$
declare d text;
begin
  d := pg_get_functiondef('public.api_integracoes_config(jsonb)'::regprocedure);
  if d like '%''acompanharEntrega''%' then return; end if;
  d := replace(d, '''pausarSemEstoque'', ''enviarPrecos'')', '''pausarSemEstoque'', ''enviarPrecos'', ''conferirRepasse'', ''avaliacaoAlerta'', ''avaliacaoSugestao'', ''acompanharEntrega'')');
  if d not like '%''acompanharEntrega''%' then raise exception 'trecho não encontrado em api_integracoes_config'; end if;
  execute d;
end $$;

-- 2) avaliação nota 3 também avisa, se o ajuste estiver ligado
do $$
declare d text;
begin
  d := pg_get_functiondef('public.ifood_avaliacoes_gravar(jsonb)'::regprocedure);
  if d like '%avaliacaoAlerta%' then return; end if;
  d := replace(d, 'if v_nota <= 2 then perform _push_enviar', 'if v_nota <= 2 or (v_nota = 3 and coalesce((select (config->>''avaliacaoAlerta'')::boolean from integracoes_config where provedor = ''ifood''), false)) then perform _push_enviar');
  if d not like '%avaliacaoAlerta%' then raise exception 'trecho não encontrado em ifood_avaliacoes_gravar'; end if;
  execute d;
end $$;

-- 3) conferência de repasses (só leitura)
create or replace function public.api_ifood_conferencia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_on boolean := coalesce((select (config->>'conferirRepasse')::boolean from integracoes_config where provedor = 'ifood'), false);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if not v_on then return jsonb_build_object('ok', true, 'ligado', false); end if;
  return jsonb_build_object('ok', true, 'ligado', true,
    'repasses', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'pagoEm', r.pago_em, 'recebido', r.valor, 'esperado', q.esperado, 'pedidos', q.n, 'diferenca', round(r.valor - q.esperado, 2)) order by r.pago_em desc nulls last)
       from (select * from ifood_repasses order by coalesce(pago_em, (criado_em at time zone 'America/Sao_Paulo')::date) desc limit 15) r
       cross join lateral (select count(distinct i.pedido_ifood) n,
              coalesce(sum((select coalesce(sum(pv.valor - coalesce(pv.taxa_aplicada, 0)), 0) from pagamentos_venda pv where pv.venda_id = i.venda_id and pv.forma_pagamento = 'iFood (pago no app)')), 0) esperado
            from ifood_pedidos i where i.repasse_id = r.id and not i.simulado) q), '[]'::jsonb),
    'atrasados', coalesce((select jsonb_agg(jsonb_build_object('numero', i.numero_ifood, 'venda', v.numero_pedido, 'desde', v.data_hora) order by v.data_hora)
       from ifood_pedidos i join vendas v on v.id = i.venda_id
       where not i.simulado and v.status = 'Confirmada' and i.repassado_em is null and i.estado <> 'cancelado' and v.data_hora < now() - interval '10 days'
         and exists (select 1 from pagamentos_venda pv where pv.venda_id = v.id and pv.forma_pagamento = 'iFood (pago no app)')), '[]'::jsonb));
end $$;

-- 4) acompanhamento da entrega do iFood
create or replace function public.ifood_rastreio_pendentes() returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not coalesce((select (config->>'acompanharEntrega')::boolean from integracoes_config where provedor = 'ifood'), false) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(i.pedido_ifood) from (
    select i.pedido_ifood from ifood_pedidos i join vendas v on v.id = i.venda_id
     where not i.simulado and v.status = 'Confirmada' and v.tipo::text = 'Entrega' and v.status_pedido::text in ('Pronta', 'Saiu para entrega')
       and coalesce(v.observacoes_entrega, '') ilike '%ENTREGA PELO iFOOD%' order by v.data_hora limit 10) i), '[]'::jsonb);
end $$;
create or replace function public.ifood_rastreio_gravar(p_pedido text, p_dados jsonb) returns void language sql security definer set search_path to 'public' as $$
  update ifood_pedidos set rastreio = p_dados, rastreio_em = now() where pedido_ifood = p_pedido;
$$;
revoke all on function public.ifood_rastreio_pendentes() from public, anon, authenticated;
revoke all on function public.ifood_rastreio_gravar(text, jsonb) from public, anon, authenticated;
grant execute on function public.ifood_rastreio_pendentes() to service_role;
grant execute on function public.ifood_rastreio_gravar(text, jsonb) to service_role;

create or replace function public.api_ifood_rastreios(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  if not coalesce((select (config->>'acompanharEntrega')::boolean from integracoes_config where provedor = 'ifood'), false) then return jsonb_build_object('ok', true, 'ligado', false); end if;
  return jsonb_build_object('ok', true, 'ligado', true, 'mapa', coalesce((select jsonb_object_agg(i.venda_id::text, jsonb_build_object('dados', i.rastreio, 'em', i.rastreio_em))
     from ifood_pedidos i join vendas v on v.id = i.venda_id
    where i.rastreio is not null and i.rastreio_em > now() - interval '30 minutes' and v.status_pedido::text in ('Pronta', 'Saiu para entrega')), '{}'::jsonb));
end $$;

do $$
declare f text;
begin
  foreach f in array array['api_ifood_conferencia(jsonb)', 'api_ifood_rastreios(jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
end $$;

-- 5) agendamento do acompanhamento: só chama a função ifood-rastreio se a integração estiver ligada E houver pedido para acompanhar
select cron.schedule('ifood-rastreio-minuto', '* * * * *', $c$select case when public._integracao_ligada('ifood') and jsonb_array_length(public.ifood_rastreio_pendentes()) > 0 then public.chamar_edge('ifood-rastreio', '{}'::jsonb) end$c$);
