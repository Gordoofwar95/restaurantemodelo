-- 65 · iFood: eventos e detalhes do pedido, revisados pela documentação OFICIAL dos módulos Order e Events (PDFs do portal, 25/10/2026).
-- Versão 1.16. Pode rodar de novo sem erro.
-- 1) AVISOS do iFood (tabela + painel): o iFood recusou o cancelamento (CARF), o cliente alterou o pedido (ORDER_PATCHED), mudou o endereço (DAR),
--    pediu código de devolução (DRCR), pedido voltando/voltou para a loja, "comece o preparo às HH:MM" (RPS), vaga de retirada (PICKUP_AREA_ASSIGNED).
--    Cada aviso também vai para o celular da equipe (push). Nada fica calado.
-- 2) Eventos processados na ORDEM em que o iFood os criou (createdAt), não na ordem em que chegaram.
-- 3) 5 falhas seguidas ao falar com o iFood = alerta no celular (uma vez) até voltar ao normal.
-- 4) Detalhes do pedido: pedido de teste do iFood, CPF/CNPJ, TURBO, código do entregador, vaga de retirada, taxas do iFood,
--    carteira digital; agendado: "comece o preparo às…"
--    e o prazo de 8 min para confirmar passa a contar do início do preparo.
-- 5) Rastreio do entregador (só entrega do iFood, depois de o entregador ser escalado, no máximo 1 vez a cada 30 s por pedido).

alter table public.ifood_estado add column if not exists falhas_seguidas integer not null default 0;
alter table public.ifood_estado add column if not exists falhas_avisado boolean not null default false;

create table if not exists public.ifood_avisos (
  id bigserial primary key,
  pedido_ifood text,
  numero text,
  tipo text not null,
  titulo text not null,
  mensagem text not null default '',
  dados jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  visto_em timestamptz,
  visto_por text
);
create index if not exists ifood_avisos_aberto_idx on public.ifood_avisos (criado_em desc) where visto_em is null;
alter table public.ifood_avisos enable row level security;
revoke all on table public.ifood_avisos from anon, authenticated;

create or replace function public.ifood_aviso_registrar(p_pedido text, p_tipo text, p_titulo text, p_msg text, p_dados jsonb default '{}'::jsonb) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare v_num text;
begin
  select numero_ifood into v_num from ifood_pedidos where pedido_ifood = p_pedido;
  insert into ifood_avisos (pedido_ifood, numero, tipo, titulo, mensagem, dados) values (p_pedido, v_num, p_tipo, left(p_titulo, 160), left(coalesce(p_msg, ''), 500), coalesce(p_dados, '{}'::jsonb));
  perform _integ_log('ifood', 'aviso', 'Pedido #' || coalesce(v_num, p_pedido, '?') || ': ' || left(p_titulo, 120));
  begin perform _push_enviar('pedido', left(p_titulo || case when v_num is not null then ' · #' || v_num else '' end, 120), left(coalesce(p_msg, 'Veja o painel do iFood'), 180), 'ifood-av-' || p_tipo || '-' || coalesce(p_pedido, '') || '-' || extract(epoch from now())::bigint);
  exception when others then null; end;
end $f$;
revoke all on function public.ifood_aviso_registrar(text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.ifood_aviso_registrar(text, text, text, text, jsonb) to service_role;

create or replace function public.api_ifood_avisos(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  return jsonb_build_object('ok', true,
    'abertos', (select count(*) from ifood_avisos where visto_em is null and criado_em > now() - interval '7 days'),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'pedido', a.numero, 'tipo', a.tipo, 'titulo', a.titulo, 'mensagem', a.mensagem, 'dados', a.dados,
        'em', a.criado_em, 'visto', a.visto_em is not null, 'vistoPor', a.visto_por) order by a.criado_em desc)
      from (select * from ifood_avisos where criado_em > now() - interval '7 days' order by (visto_em is null) desc, criado_em desc limit 40) a), '[]'::jsonb));
end $f$;
grant execute on function public.api_ifood_avisos(jsonb) to authenticated;

create or replace function public.api_ifood_aviso_visto(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare v_login text;
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  select login into v_login from usuarios where id = auth.uid();
  if coalesce(p->>'todos', '') = 'true' then update ifood_avisos set visto_em = now(), visto_por = v_login where visto_em is null;
  else update ifood_avisos set visto_em = now(), visto_por = v_login where id = nullif(p->>'id', '')::bigint and visto_em is null; end if;
  return jsonb_build_object('ok', true) || api_ifood_avisos('{}');
end $f$;
grant execute on function public.api_ifood_aviso_visto(jsonb) to authenticated;

-- eventos na ordem de criação no iFood (a API entrega fora de ordem)
create or replace function public.ifood_eventos_pendentes() returns jsonb
 language sql stable security definer set search_path to 'public' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'codigo', coalesce(codigo_completo, codigo), 'pedido', pedido_ifood, 'tentativas', tentativas, 'bruto', bruto) order by coalesce(criado_ifood, recebido_em), recebido_em), '[]'::jsonb)
  from (select * from ifood_eventos where processado_em is null and recebido_em > now() - interval '1 day' order by coalesce(criado_ifood, recebido_em), recebido_em limit 50) x
$f$;

-- 5 falhas seguidas ao consultar o iFood: avisa a equipe (uma vez); volta ao normal = zera
create or replace function public.ifood_marcar_consulta(p_ok boolean, p_erro text default null, p_token_ok boolean default null) returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare v_ant timestamptz; v_id bigint; v_f int; v_av boolean;
begin
  select ultima_consulta_ok into v_ant from ifood_estado where id;
  update ifood_estado set ultima_consulta = now(),
    ultima_consulta_ok = case when p_ok then now() else ultima_consulta_ok end,
    token_ok = coalesce(p_token_ok, token_ok),
    ultimo_erro = case when p_ok then null else left(p_erro, 300) end,
    ultimo_erro_em = case when p_ok then ultimo_erro_em else now() end,
    falhas_seguidas = case when p_ok then 0 else falhas_seguidas + 1 end,
    falhas_avisado = case when p_ok then false else falhas_avisado end,
    atualizado_em = now() where id
  returning falhas_seguidas, falhas_avisado into v_f, v_av;
  if not p_ok and p_erro is not null then perform public._integ_log('ifood', 'erro', p_erro); end if;
  if not p_ok and v_f >= 5 and not v_av then
    update ifood_estado set falhas_avisado = true where id;
    begin perform _alertas_push('iFood: sem conseguir falar com o iFood',
      '5 tentativas seguidas falharam: ' || left(coalesce(p_erro, 'sem detalhe'), 140) || '. Pedidos novos podem demorar a aparecer: confira no portal do iFood.', 'ifood-falhas', array['Admin', 'Operador']);
    exception when others then null; end;
  end if;
  -- lacuna só conta se a última consulta boa foi DEPOIS de o iFood ser ligado (ligar de novo após desligar não é queda)
  if p_ok and v_ant is not null and now() - v_ant > interval '3 minutes' and now() - v_ant < interval '3 days'
     and v_ant >= coalesce((select ligado_em from integracoes_config where provedor = 'ifood'), '-infinity'::timestamptz) then
    insert into ifood_lacunas(inicio, fim) values (v_ant, now()) returning id into v_id;
    perform _ifood_lacuna_varrer(v_id);
    begin
      perform _alertas_push('iFood: sistema ficou fora do ar',
        'De ' || to_char(v_ant at time zone 'America/Sao_Paulo', 'HH24:MI') || ' às ' || to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI') || ' o iFood não conseguiu entregar pedidos. Confira no portal do iFood.',
        'ifood-lacuna', array['Admin', 'Operador']);
    exception when others then null; end;
  end if;
end $function$;

-- endereço novo (cliente mudou a entrega): atualiza a venda e avisa para repassar ao entregador
create or replace function public.ifood_endereco_atualizar(p_order jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare r ifood_pedidos%rowtype; ad jsonb; v_end text;
begin
  select * into r from ifood_pedidos where pedido_ifood = p_order->>'id';
  if not found or r.venda_id is null then return jsonb_build_object('ok', true, 'ignorado', true); end if;
  ad := coalesce(p_order->'delivery'->'deliveryAddress', '{}'::jsonb);
  v_end := coalesce(nullif(ad->>'formattedAddress', ''), btrim(concat_ws(', ', ad->>'streetName', ad->>'streetNumber', ad->>'neighborhood', ad->>'city')));
  if coalesce(v_end, '') = '' then return jsonb_build_object('ok', true, 'ignorado', true); end if;
  update vendas set endereco = v_end, complemento = coalesce(ad->>'complement', ''), referencia = coalesce(ad->>'reference', '') where id = r.venda_id and tipo::text = 'Entrega';
  update ifood_pedidos set bruto = p_order, atualizado_em = now() where pedido_ifood = r.pedido_ifood;
  perform _auditar('Endereço do pedido do iFood mudou', 'iFood #' || coalesce(r.numero_ifood, '') || ' · ' || left(v_end, 150));
  return jsonb_build_object('ok', true, 'endereco', v_end);
end $f$;
revoke all on function public.ifood_endereco_atualizar(jsonb) from public, anon, authenticated;
grant execute on function public.ifood_endereco_atualizar(jsonb) to service_role;

-- detalhes extras do pedido que aparecem na observação (comanda): pagamento, cupom (quem paga), retirada, TURBO, código do entregador, CPF/CNPJ, taxas
create or replace function public._ifood_extras_obs(p_order jsonb) returns text
 language plpgsql stable set search_path to 'public' as $function$
declare m jsonb; b jsonb; s jsonb; f jsonb; v_txt text := ''; v_tipo text; v_ifood numeric := 0; v_loja numeric := 0; v_outros numeric := 0; v_n numeric; v_ret text; v_t timestamptz; v_doc text; v_nome text; v_taxas text := '';
begin
  if lower(coalesce(p_order->>'isTest', '')) = 'true' then v_txt := v_txt || ' · PEDIDO DE TESTE DO iFOOD'; end if;
  for m in select * from jsonb_array_elements(coalesce(p_order->'payments'->'methods', '[]'::jsonb)) loop
    v_tipo := upper(coalesce(m->>'method', ''));
    if v_tipo in ('CREDIT', 'DEBIT', 'MEAL_VOUCHER', 'FOOD_VOUCHER') or m ? 'card' then
      v_txt := v_txt || ' · Cartão ' || case v_tipo when 'CREDIT' then 'CRÉDITO' when 'DEBIT' then 'DÉBITO' when 'MEAL_VOUCHER' then 'VALE-REFEIÇÃO' when 'FOOD_VOUCHER' then 'VALE-ALIMENTAÇÃO' else v_tipo end
        || coalesce(' ' || upper(nullif(m->'card'->>'brand', '')), '')
        || case when upper(coalesce(m->>'type', '')) = 'OFFLINE' then ' (cobrar na entrega: levar maquininha)' else ' (pago no app)' end;
    elsif m ? 'wallet' or v_tipo in ('DIGITAL_WALLET', 'WALLET') then
      v_txt := v_txt || ' · Carteira digital' || coalesce(' ' || upper(nullif(m->'wallet'->>'name', '')), '') || ' (pago no app)';
    end if;
  end loop;
  for b in select * from jsonb_array_elements(coalesce(p_order->'benefits', '[]'::jsonb)) loop
    for s in select * from jsonb_array_elements(coalesce(b->'sponsorshipValues', '[]'::jsonb)) loop
      v_n := coalesce(nullif(s->>'value', '')::numeric, 0);
      if upper(coalesce(s->>'name', '')) = 'IFOOD' then v_ifood := v_ifood + v_n;
      elsif upper(coalesce(s->>'name', '')) = 'MERCHANT' then v_loja := v_loja + v_n;
      else v_outros := v_outros + v_n; end if;   -- EXTERNAL (indústria/parceiro) e CHAIN (rede): quem paga é outro, o iFood repassa
    end loop;
  end loop;
  if v_ifood + v_loja + v_outros > 0 then
    v_txt := v_txt || ' · Cupom: ' || concat_ws(' + ',
      case when v_ifood > 0 then 'R$ ' || replace(to_char(v_ifood, 'FM9999990.00'), '.', ',') || ' pago pelo iFood' end,
      case when v_loja > 0 then 'R$ ' || replace(to_char(v_loja, 'FM9999990.00'), '.', ',') || ' pago pela loja' end,
      case when v_outros > 0 then 'R$ ' || replace(to_char(v_outros, 'FM9999990.00'), '.', ',') || ' pago por parceiro/rede' end);
  end if;
  -- taxas do iFood (ex.: pedido pequeno): receita do iFood, não entra na nota fiscal
  for f in select * from jsonb_array_elements(case when jsonb_typeof(p_order->'additionalFees') = 'array' then p_order->'additionalFees' else '[]'::jsonb end) loop
    v_n := coalesce(nullif(f->>'value', '')::numeric, 0);
    if v_n > 0 then v_taxas := v_taxas || case when v_taxas = '' then '' else ' + ' end || coalesce(nullif(f->>'description', ''), nullif(f->>'type', ''), 'taxa') || ' R$ ' || replace(to_char(v_n, 'FM9999990.00'), '.', ','); end if;
  end loop;
  if v_taxas <> '' then v_txt := v_txt || ' · Taxa do iFood (paga pelo cliente ao iFood): ' || v_taxas; end if;
  -- CPF/CNPJ na nota (cliente pediu)
  v_doc := regexp_replace(coalesce(p_order->'customer'->>'documentNumber', ''), '[^0-9]', '', 'g');
  if length(v_doc) = 14 then v_txt := v_txt || ' · CNPJ na nota: ' || v_doc;
  elsif length(v_doc) = 11 then v_txt := v_txt || ' · CPF na nota: ' || v_doc; end if;
  -- entrega
  if upper(coalesce(p_order->'delivery'->>'mode', '')) = 'TURBO' then v_txt := v_txt || ' · ⚡ TURBO: preparar em até 7 minutos'; end if;
  if nullif(p_order->'delivery'->>'pickupCode', '') is not null then v_txt := v_txt || ' · Código do entregador: ' || (p_order->'delivery'->>'pickupCode'); end if;
  if upper(coalesce(p_order->>'orderType', '')) = 'TAKEOUT' then
    v_ret := coalesce(p_order->'takeout'->>'takeoutDateTime', '');
    begin v_t := nullif(v_ret, '')::timestamptz; exception when others then v_t := null; end;
    if v_t is not null then v_txt := v_txt || ' · RETIRADA ' || case when upper(coalesce(p_order->'takeout'->>'mode', '')) = 'SCHEDULED' then 'AGENDADA' else '' end || ' às ' || to_char(v_t at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'); end if;
    if upper(coalesce(p_order->'takeout'->>'mode', '')) = 'PICKUP_AREA' then v_txt := v_txt || ' · Retirada em vaga/área do cliente (a vaga chega em aviso)'; end if;
  end if;
  return v_txt;
exception when others then return '';
end $function$;

-- rastreio do entregador: só entrega do iFood, depois de o entregador ser escalado, no máximo 1 vez a cada 30 s por pedido (regra da documentação)
create or replace function public.ifood_rastreio_pendentes() returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if not coalesce((select (config->>'acompanharEntrega')::boolean from integracoes_config where provedor = 'ifood'), false) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(i.pedido_ifood) from (
    select i.pedido_ifood from ifood_pedidos i join vendas v on v.id = i.venda_id
     where not i.simulado and v.status = 'Confirmada' and v.tipo::text = 'Entrega' and v.status_pedido::text in ('Pronta', 'Saiu para entrega')
       and coalesce(v.observacoes_entrega, '') ilike '%ENTREGA PELO iFOOD%'
       and (i.rastreio_em is null or i.rastreio_em < now() - interval '30 seconds')
       and exists (select 1 from ifood_eventos e where e.pedido_ifood = i.pedido_ifood and (upper(e.codigo) = 'ADR' or upper(e.codigo_completo) = 'ASSIGN_DRIVER'))
     order by v.data_hora limit 3) i), '[]'::jsonb);
end $function$;

-- pedido agendado: "comece o preparo às HH:MM" na observação; o prazo de 8 min para confirmar conta a partir do início do preparo (doc oficial)
create or replace function public.ifood_criar_pedido(p_order jsonb, p_simulado boolean default false) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare
  v_id text := p_order->>'id'; v_disp text := coalesce(nullif(p_order->>'displayId', ''), right(coalesce(p_order->>'id', ''), 4));
  v_venda uuid := gen_random_uuid(); v_tipo venda_tipo; v_nome text; v_tel text; v_end text; v_comp text; v_ref text; v_obs text;
  v_val jsonb; v_total numeric; v_sem int; v_caixa uuid; v_numero int; v_troco numeric; v_agend text; v_forma text; v_pend numeric; v_cash numeric; v_stpag status_pagamento; ad jsonb; v_cpf text; v_okdata timestamptz;
  v_prep timestamptz; v_expira timestamptz := now() + interval '8 minutes';
begin
  if v_id is null then return jsonb_build_object('ok', false, 'message', 'Pedido sem id.'); end if;
  if exists (select 1 from ifood_pedidos where pedido_ifood = v_id) then return jsonb_build_object('ok', true, 'duplicado', true); end if;
  if jsonb_typeof(p_order->'items') is distinct from 'array' or jsonb_array_length(p_order->'items') = 0 then return jsonb_build_object('ok', false, 'message', 'Pedido sem itens.'); end if;
  v_tipo := case when upper(coalesce(p_order->>'orderType', '')) in ('TAKEOUT', 'PICKUP', 'INDOOR') then 'Retirada' else 'Entrega' end::venda_tipo;
  v_nome := left(btrim(coalesce(p_order->'customer'->>'name', 'Cliente iFood')), 80) || ' (iFood)';
  v_tel := left(regexp_replace(coalesce(p_order->'customer'->'phone'->>'number', ''), '[^0-9]', '', 'g'), 20);
  ad := coalesce(p_order->'delivery'->'deliveryAddress', '{}'::jsonb);
  v_end := coalesce(nullif(ad->>'formattedAddress', ''), btrim(concat_ws(', ', ad->>'streetName', ad->>'streetNumber', ad->>'neighborhood', ad->>'city')));
  v_comp := coalesce(ad->>'complement', ''); v_ref := coalesce(ad->>'reference', '');
  v_cpf := regexp_replace(coalesce(p_order->'customer'->>'documentNumber', ''), '[^0-9]', '', 'g');
  if not public._cpf_valido(v_cpf) then v_cpf := null; end if;
  v_val := public._ifood_valores(p_order);
  v_total := (v_val->>'total')::numeric;
  v_pend := public._ifood_n(p_order->'payments'->'pending');
  v_cash := case when (v_val->>'entregaIfood')::boolean then 0 else round(least(greatest(v_pend, 0), v_total), 2) end;
  v_stpag := case when v_cash > 0.009 then 'A Receber' else 'Pago' end;
  v_forma := case when v_cash > 0.009 and v_total - v_cash > 0.009 then 'iFood (pago no app) + iFood (pagar na entrega)' when v_cash > 0.009 then 'iFood (pagar na entrega)' else 'iFood (pago no app)' end;
  v_obs := 'iFood #' || v_disp;
  if v_tipo = 'Entrega' and (v_val->>'entregaIfood')::boolean then v_obs := v_obs || ' · ENTREGA PELO iFOOD'; end if;
  select (m->'cash'->>'changeFor') into v_troco from jsonb_array_elements(coalesce(p_order->'payments'->'methods', '[]'::jsonb)) m where m->'cash'->>'changeFor' is not null limit 1;
  if v_troco is not null and public._ifood_n(to_jsonb(v_troco)) > 0 and upper(coalesce(p_order->'delivery'->>'deliveredBy', '')) = 'MERCHANT' then v_obs := v_obs || ' · levar troco para R$ ' || replace(to_char(public._ifood_n(to_jsonb(v_troco)), 'FM9999990.00'), '.', ','); end if;
  if upper(coalesce(p_order->>'orderTiming', '')) = 'SCHEDULED' then
    v_agend := coalesce(p_order->'schedule'->>'deliveryDateTimeStart', p_order->'delivery'->>'deliveryDateTime', p_order->>'preparationStartDateTime', '');
    begin v_okdata := nullif(v_agend, '')::timestamptz; exception when others then v_okdata := null; end;
    v_obs := v_obs || ' · AGENDADO' || case when v_okdata is not null then ' para ' || to_char(v_okdata at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') else '' end;
    begin v_prep := nullif(p_order->>'preparationStartDateTime', '')::timestamptz; exception when others then v_prep := null; end;
    if v_prep is not null then
      v_obs := v_obs || ' · COMECE O PREPARO ÀS ' || to_char(v_prep at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
      if v_prep > now() then v_expira := v_prep + interval '8 minutes'; end if;
    end if;
  end if;
  if nullif(btrim(coalesce(p_order->'delivery'->>'observations', '')), '') is not null then v_obs := v_obs || ' · ' || btrim(p_order->'delivery'->>'observations'); end if;
  v_obs := v_obs || public._ifood_extras_obs(p_order);
  if p_simulado then v_obs := v_obs || ' · TESTE (simulação)'; end if;
  select id into v_caixa from caixa_sessoes where status = 'Aberto' limit 1;

  insert into vendas (id, cliente_nome, telefone_cliente, forma_pagamento, valor_total, custo_total, status, tipo, status_pedido, endereco, complemento, referencia, observacoes_entrega,
                      status_pagamento, cpf_nota, recebido_em, valor_original, valor_desconto, desconto_detalhe, origem, taxa_entrega, caixa_id, requisicao_id, canal)
  values (v_venda, v_nome, nullif(v_tel, ''), v_forma, v_total, 0, 'Confirmada', v_tipo, 'Recebido',
          case when v_tipo = 'Entrega' then coalesce(v_end, '') else '' end, case when v_tipo = 'Entrega' then v_comp else '' end, case when v_tipo = 'Entrega' then v_ref else '' end, v_obs,
          v_stpag, v_cpf, case when v_stpag = 'Pago' then now() end, (v_val->>'original')::numeric, (v_val->>'descontoLoja')::numeric,
          case when (v_val->>'descontoLoja')::numeric > 0 then 'Desconto/cupom iFood pago pela loja' else '' end, 'Balcão', (v_val->>'taxaEntrega')::numeric, v_caixa, 'ifood:' || v_id, 'iFood')
  returning numero_pedido into v_numero;
  if not p_simulado then
    begin perform public._ifood_cliente(v_venda, p_order);
    exception when others then perform _integ_log('ifood', 'aviso', 'Pedido #' || v_disp || ': cliente não cadastrado (' || left(sqlerrm, 150) || ')'); end;
  end if;

  v_sem := public._ifood_gravar_itens(v_venda, p_order, false);
  update vendas set custo_total = coalesce((select sum(custo_unitario * quantidade) from itens_venda where venda_id = v_venda), 0) where id = v_venda;

  perform public._ifood_gravar_pagamentos(v_venda, p_order, v_total, (v_val->>'entregaIfood')::boolean);

  insert into ifood_pedidos (pedido_ifood, venda_id, numero_ifood, estado, expira_em, itens_sem_ligacao, simulado, bruto)
  values (v_id, v_venda, v_disp, 'novo', v_expira, v_sem, p_simulado, p_order);
  update ifood_estado set ultimo_pedido_em = now(), atualizado_em = now() where id;
  perform _auditar('Pedido do iFood recebido', 'iFood #' || v_disp || ' → venda #' || v_numero || ' · R$ ' || replace(to_char(v_total, 'FM9999990.00'), '.', ',') || case when v_sem > 0 then ' · ' || v_sem || ' item(ns) sem ligação' else '' end || case when p_simulado then ' · SIMULAÇÃO' else '' end, null);
  perform _integ_log('ifood', case when v_sem > 0 then 'aviso' else 'info' end, 'Pedido #' || v_disp || ' recebido' || case when v_sem > 0 then ' (' || v_sem || ' item sem ligação)' else '' end);
  if upper(coalesce(p_order->'delivery'->>'mode', '')) = 'TURBO' then
    perform public.ifood_aviso_registrar(v_id, 'turbo', '⚡ Pedido TURBO: preparar em até 7 minutos', 'O iFood promete esse pedido rápido. Comece já.', '{}'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'vendaId', v_venda, 'numero', v_numero, 'semLigacao', v_sem);
end $function$;
