-- =====================================================================
-- 57 · iFood — preparação para a homologação (parte 2). Tudo aditivo; pode rodar de novo sem erro.
--  C-08  Pedido: bandeira do cartão (e se é pago no app ou na entrega), quem paga o cupom (iFood ou loja)
--        e o horário de retirada agendada aparecem nas observações (tela e comanda).
--  C-06  Cancelar pedido do iFood: os motivos OFICIAIS do iFood são buscados antes e a equipe escolhe um.
--  C-07  Códigos: validar o código do entregador do iFood (coleta) e o código de entrega pedido pelo iFood.
--  C-02  Lista de lojas do app (GET /merchants): confere se o merchantId configurado pertence ao app.
--  D-01  Estado de cada módulo do iFood (OK / 401 / 403 / 429 / erro), último sucesso e último erro.
--  C-13  Aviso no celular quando um módulo passa a ser recusado (401/403) — no máximo 1 a cada 6 h por módulo.
-- =====================================================================

-- ---------- colunas novas ----------
alter table public.ifood_pedidos add column if not exists motivos_cancel jsonb;
alter table public.ifood_pedidos add column if not exists motivos_em timestamptz;
alter table public.ifood_pedidos add column if not exists motivo_escolhido jsonb;
alter table public.ifood_pedidos add column if not exists codigo_coleta_ok boolean;
alter table public.ifood_pedidos add column if not exists codigo_entrega_ok boolean;
alter table public.ifood_pedidos add column if not exists codigo_erro text;
alter table public.ifood_pedidos add column if not exists codigo_em timestamptz;
alter table public.ifood_loja add column if not exists lojas jsonb;
alter table public.ifood_loja add column if not exists merchant_valido boolean;
alter table public.ifood_loja add column if not exists lojas_em timestamptz;

-- ações novas na fila
alter table public.ifood_acoes drop constraint if exists ifood_acoes_acao_check;
alter table public.ifood_acoes add constraint ifood_acoes_acao_check check (acao = any (array['confirmar','iniciar_preparo','pronto','despachar','cancelar',
  'negociacao_aceitar','negociacao_recusar','negociacao_alternativa','loja_fechar','loja_abrir','loja_pausar','loja_retomar','loja_horario_enviar','loja_horario_ler',
  'catalogo_importar','catalogo_preco','catalogo_pausar','catalogo_retomar','catalogo_modelo_enviar','catalogo_lote_preco','catalogo_lote_status','catalogo_opcao_preco',
  'catalogo_opcao_status','avaliacao_responder','motivos','codigo_coleta','codigo_entrega']));

-- ---------- estado por módulo (D-01) ----------
create table if not exists public.ifood_modulos (
  modulo text primary key,
  ultimo_ok timestamptz,
  ultimo_erro_em timestamptz,
  ultimo_status int,
  ultima_msg text,
  avisado_em timestamptz,
  atualizado_em timestamptz not null default now()
);
alter table public.ifood_modulos enable row level security;
revoke all on table public.ifood_modulos from public, anon, authenticated;
grant all on table public.ifood_modulos to service_role;

-- recebe um resumo da rodada: {"order":{"ok":true}, "review":{"ok":false,"status":403,"msg":"..."}}
create or replace function public.ifood_modulos_registrar(p jsonb) returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare k text; v jsonb; v_ant int; v_av timestamptz; v_st int;
begin
  for k, v in select * from jsonb_each(coalesce(p, '{}'::jsonb)) loop
    k := left(lower(k), 30);
    if coalesce((v->>'ok')::boolean, false) then
      insert into ifood_modulos (modulo, ultimo_ok, ultimo_status, atualizado_em) values (k, now(), 200, now())
        on conflict (modulo) do update set ultimo_ok = now(), ultimo_status = 200, atualizado_em = now();
    else
      v_st := nullif(v->>'status', '')::int;
      select ultimo_status, avisado_em into v_ant, v_av from ifood_modulos where modulo = k;
      insert into ifood_modulos (modulo, ultimo_erro_em, ultimo_status, ultima_msg, atualizado_em) values (k, now(), v_st, left(v->>'msg', 300), now())
        on conflict (modulo) do update set ultimo_erro_em = now(), ultimo_status = excluded.ultimo_status, ultima_msg = excluded.ultima_msg, atualizado_em = now();
      if v_st in (401, 403) and (v_av is null or v_av < now() - interval '6 hours') and v_ant is distinct from v_st then
        update ifood_modulos set avisado_em = now() where modulo = k;
        perform _integ_log('ifood', 'erro', 'Módulo ' || k || ' do iFood recusado (' || v_st || '): ' || left(coalesce(v->>'msg', ''), 150));
        begin perform _push_admins('iFood: módulo ' || k || ' recusado (' || v_st || ')',
          case when v_st = 401 then 'O iFood não aceitou as credenciais. Confira Client ID e Client Secret.' else 'O iFood não liberou este módulo para o app. Veja Integrações → iFood → Estado dos módulos.' end, 'ifood-modulo-' || k);
        exception when others then null; end;
      end if;
    end if;
  end loop;
end $function$;
revoke all on function public.ifood_modulos_registrar(jsonb) from public, anon, authenticated;
grant execute on function public.ifood_modulos_registrar(jsonb) to service_role;

create or replace function public.api_ifood_modulos(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  return jsonb_build_object('ok', true,
    'modulos', coalesce((select jsonb_agg(jsonb_build_object('modulo', modulo, 'ultimoOk', ultimo_ok, 'ultimoErroEm', ultimo_erro_em, 'status', ultimo_status, 'msg', ultima_msg) order by modulo) from ifood_modulos), '[]'::jsonb),
    'loja', (select jsonb_build_object('merchantValido', merchant_valido, 'lojas', coalesce(lojas, '[]'::jsonb), 'lojasEm', lojas_em, 'situacao', situacao, 'disponivel', disponivel, 'motivo', motivo, 'verificadoEm', verificado_em) from ifood_loja where id));
end $function$;
revoke all on function public.api_ifood_modulos(jsonb) from public, anon;
grant execute on function public.api_ifood_modulos(jsonb) to authenticated, service_role;

-- ---------- lojas do app (C-02) ----------
create or replace function public.ifood_lojas_gravar(p_lista jsonb, p_merchant text) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare v_ok boolean; v_ant boolean;
begin
  v_ok := exists (select 1 from jsonb_array_elements(coalesce(p_lista, '[]'::jsonb)) x where x->>'id' = p_merchant or x->>'merchantId' = p_merchant);
  select merchant_valido into v_ant from ifood_loja where id;
  update ifood_loja set lojas = (select coalesce(jsonb_agg(jsonb_build_object('id', coalesce(x->>'id', x->>'merchantId'), 'nome', coalesce(x->>'name', x->>'corporateName', ''))), '[]'::jsonb)
                                   from jsonb_array_elements(coalesce(p_lista, '[]'::jsonb)) x),
                        merchant_valido = v_ok, lojas_em = now(), atualizado_em = now() where id;
  if not v_ok and v_ant is distinct from false then
    perform _integ_log('ifood', 'erro', 'O merchantId configurado não está entre as lojas deste app no iFood.');
    begin perform _push_admins('iFood: loja configurada não pertence ao app', 'Confira o Merchant ID em Integrações → iFood.', 'ifood-merchant'); exception when others then null; end;
  end if;
  return jsonb_build_object('ok', true, 'valido', v_ok);
end $function$;
revoke all on function public.ifood_lojas_gravar(jsonb, text) from public, anon, authenticated;
grant execute on function public.ifood_lojas_gravar(jsonb, text) to service_role;

-- ---------- motivos oficiais de cancelamento (C-06) ----------
create or replace function public.ifood_motivos_gravar(p_pedido text, p_lista jsonb) returns void
 language sql security definer set search_path to 'public' as $function$
  update ifood_pedidos set motivos_cancel = (select coalesce(jsonb_agg(jsonb_build_object('codigo', coalesce(x->>'cancelCodeId', x->>'code', x->>'id'), 'descricao', coalesce(x->>'description', x->>'reason', ''))), '[]'::jsonb)
                                               from jsonb_array_elements(case when jsonb_typeof(p_lista) = 'array' then p_lista else '[]'::jsonb end) x),
         motivos_em = now(), atualizado_em = now() where pedido_ifood = p_pedido
$function$;
revoke all on function public.ifood_motivos_gravar(text, jsonb) from public, anon, authenticated;
grant execute on function public.ifood_motivos_gravar(text, jsonb) to service_role;

-- a tela pede os motivos: devolve o que tem e, se estiverem velhos (> 3 min), pede de novo ao iFood (na próxima rodada, até 30 s)
create or replace function public.api_ifood_motivos(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare r ifood_pedidos%rowtype; v_aguarda boolean := false; v_erro text;
begin
  if not tem_nivel('Admin', 'Operador', 'Garçom', 'Cozinha') then return _negado(); end if;
  select * into r from ifood_pedidos where venda_id = nullif(p->>'vendaId', '')::uuid;
  if not found then return jsonb_build_object('ok', true, 'ifood', false); end if;
  if r.simulado then return jsonb_build_object('ok', true, 'ifood', true, 'simulado', true, 'motivos', '[]'::jsonb); end if;
  if r.motivos_em is null or r.motivos_em < now() - interval '3 minutes' then
    if not exists (select 1 from ifood_acoes where pedido_ifood = r.pedido_ifood and acao = 'motivos' and estado = 'pendente') then
      perform _ifood_enfileirar(r.pedido_ifood, 'motivos', '{}'::jsonb);
    end if;
    v_aguarda := true;
  end if;
  select erro into v_erro from ifood_acoes where pedido_ifood = r.pedido_ifood and acao = 'motivos' and estado = 'erro' and criado_em > now() - interval '5 minutes' order by id desc limit 1;
  return jsonb_build_object('ok', true, 'ifood', true, 'motivos', coalesce(r.motivos_cancel, '[]'::jsonb), 'em', r.motivos_em, 'aguardando', v_aguarda,
    'erro', v_erro, 'escolhido', r.motivo_escolhido);
end $function$;
revoke all on function public.api_ifood_motivos(jsonb) from public, anon;
grant execute on function public.api_ifood_motivos(jsonb) to authenticated, service_role;

create or replace function public.api_ifood_motivo_escolher(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare r ifood_pedidos%rowtype; v_cod text := left(btrim(coalesce(p->>'codigo', '')), 40);
begin
  if not tem_nivel('Admin', 'Operador', 'Garçom', 'Cozinha') then return _negado(); end if;
  select * into r from ifood_pedidos where venda_id = nullif(p->>'vendaId', '')::uuid for update;
  if not found then return _falha('Pedido do iFood não encontrado.'); end if;
  if v_cod = '' or not exists (select 1 from jsonb_array_elements(coalesce(r.motivos_cancel, '[]'::jsonb)) x where x->>'codigo' = v_cod) then
    return _falha('Escolha um dos motivos do iFood.');
  end if;
  -- a descrição vem da lista guardada (a que o iFood mandou), não do navegador
  update ifood_pedidos set motivo_escolhido = jsonb_build_object('codigo', v_cod,
           'descricao', (select left(x->>'descricao', 200) from jsonb_array_elements(r.motivos_cancel) x where x->>'codigo' = v_cod limit 1), 'em', now()),
         atualizado_em = now() where pedido_ifood = r.pedido_ifood;
  return jsonb_build_object('ok', true);
end $function$;
revoke all on function public.api_ifood_motivo_escolher(jsonb) from public, anon;
grant execute on function public.api_ifood_motivo_escolher(jsonb) to authenticated, service_role;

-- o cancelamento leva o código escolhido para o iFood
do $$
declare d text;
begin
  select pg_get_functiondef('public._ifood_trg_status()'::regprocedure) into d;
  if position('motivo_escolhido' in d) = 0 then
    if (length(d) - length(replace(d, 'jsonb_build_object(''motivo'', new.motivo_cancelamento)', ''))) / length('jsonb_build_object(''motivo'', new.motivo_cancelamento)') <> 1 then
      raise exception '57: ponto de troca não encontrado em _ifood_trg_status';
    end if;
    d := replace(d, 'jsonb_build_object(''motivo'', new.motivo_cancelamento)',
      'jsonb_build_object(''motivo'', coalesce(nullif(r.motivo_escolhido->>''descricao'', ''''), new.motivo_cancelamento), ''codigo'', r.motivo_escolhido->>''codigo'')');
    execute d;
  end if;
end $$;

-- ---------- códigos de coleta e de entrega (C-07) ----------
-- coleta: entrega PELO iFood; o entregador do iFood chega à loja e diz o código (validatePickupCode)
-- entrega: entrega pela LOJA; o iFood pede o código ao entregar (evento de "código de entrega") e o entregador digita (verifyDeliveryCode)
create or replace function public.api_ifood_codigos_pendentes(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if not tem_nivel('Admin', 'Operador', 'Garçom', 'Cozinha', 'Entregador') then return _negado(); end if;
  return jsonb_build_object('ok', true, 'lista', coalesce((
    select jsonb_agg(jsonb_build_object('vendaId', v.id, 'numero', v.numero_pedido, 'ifood', i.numero_ifood, 'tipo', x.tipo, 'cliente', v.cliente_nome,
             'erro', case when i.codigo_em > now() - interval '10 minutes' then i.codigo_erro end,
             'enviando', exists (select 1 from ifood_acoes a where a.pedido_ifood = i.pedido_ifood and a.acao = 'codigo_' || x.tipo and a.estado = 'pendente')) order by v.data_hora)
      from ifood_pedidos i join vendas v on v.id = i.venda_id
      cross join lateral (select case
          when upper(coalesce(i.bruto->'delivery'->>'deliveredBy', '')) = 'IFOOD' and v.status_pedido::text in ('Em preparo', 'Pronta') and i.codigo_coleta_ok is not true
               and exists (select 1 from ifood_eventos e where e.pedido_ifood = i.pedido_ifood and e.recebido_em > now() - interval '6 hours'
                            and (upper(e.codigo) in ('ADR', 'GTO', 'AAO') or e.codigo_completo ilike any (array['%ASSIGN_DRIVER%', '%GOING_TO_ORIGIN%', '%ARRIVED_AT_ORIGIN%', '%PICKUP_CODE%'])))
            then 'coleta'
          when upper(coalesce(i.bruto->'delivery'->>'deliveredBy', '')) <> 'IFOOD' and v.status_pedido::text = 'Saiu para entrega' and i.codigo_entrega_ok is not true
               and exists (select 1 from ifood_eventos e where e.pedido_ifood = i.pedido_ifood and e.recebido_em > now() - interval '6 hours'
                            and (e.codigo_completo ilike '%DROP_CODE%' or e.codigo_completo ilike '%DELIVERY_CODE%' or upper(e.codigo) = 'DDCR'))
            then 'entrega' end as tipo) x
     where not i.simulado and v.status = 'Confirmada' and x.tipo is not null), '[]'::jsonb));
end $function$;
revoke all on function public.api_ifood_codigos_pendentes(jsonb) from public, anon;
grant execute on function public.api_ifood_codigos_pendentes(jsonb) to authenticated, service_role;

create or replace function public.api_ifood_codigo(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare r ifood_pedidos%rowtype; v_tipo text := lower(coalesce(p->>'tipo', '')); v_cod text := regexp_replace(coalesce(p->>'codigo', ''), '\s', '', 'g');
begin
  if not tem_nivel('Admin', 'Operador', 'Garçom', 'Cozinha', 'Entregador') then return _negado(); end if;
  if v_tipo not in ('coleta', 'entrega') then return _falha('Tipo de código inválido.'); end if;
  if v_cod !~ '^[0-9A-Za-z]{3,12}$' then return _falha('Digite o código que o iFood mostrou (só letras e números).'); end if;
  select * into r from ifood_pedidos where venda_id = nullif(p->>'vendaId', '')::uuid;
  if not found then return _falha('Pedido do iFood não encontrado.'); end if;
  if r.simulado then return _falha('Pedido de simulação: não há código no iFood.'); end if;
  delete from ifood_acoes where pedido_ifood = r.pedido_ifood and acao = 'codigo_' || v_tipo and estado = 'pendente';
  perform _ifood_enfileirar(r.pedido_ifood, 'codigo_' || v_tipo, jsonb_build_object('codigo', v_cod));
  update ifood_pedidos set codigo_erro = null, codigo_em = now() where pedido_ifood = r.pedido_ifood;
  perform _auditar('Código do iFood enviado', 'iFood #' || r.numero_ifood || ' · código de ' || v_tipo, null);
  return jsonb_build_object('ok', true, 'message', 'Código enviado ao iFood. A resposta chega em até 30 segundos.');
end $function$;
revoke all on function public.api_ifood_codigo(jsonb) from public, anon;
grant execute on function public.api_ifood_codigo(jsonb) to authenticated, service_role;

create or replace function public.ifood_codigo_resultado(p_pedido text, p_tipo text, p_ok boolean, p_erro text default null) returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if p_tipo = 'coleta' then update ifood_pedidos set codigo_coleta_ok = case when p_ok then true else codigo_coleta_ok end, codigo_erro = case when p_ok then null else left(p_erro, 200) end, codigo_em = now() where pedido_ifood = p_pedido;
  else update ifood_pedidos set codigo_entrega_ok = case when p_ok then true else codigo_entrega_ok end, codigo_erro = case when p_ok then null else left(p_erro, 200) end, codigo_em = now() where pedido_ifood = p_pedido; end if;
  perform _integ_log('ifood', case when p_ok then 'info' else 'aviso' end, 'Código de ' || p_tipo || ' do pedido ' || right(p_pedido, 6) || case when p_ok then ' aceito pelo iFood' else ' recusado: ' || left(coalesce(p_erro, ''), 120) end);
end $function$;
revoke all on function public.ifood_codigo_resultado(text, text, boolean, text) from public, anon, authenticated;
grant execute on function public.ifood_codigo_resultado(text, text, boolean, text) to service_role;

-- ---------- C-08: bandeira, quem paga o cupom e retirada agendada ----------
create or replace function public._ifood_extras_obs(p_order jsonb) returns text
 language plpgsql stable set search_path to 'public' as $function$
declare m jsonb; b jsonb; s jsonb; v_txt text := ''; v_tipo text; v_ifood numeric := 0; v_loja numeric := 0; v_outros numeric := 0; v_n numeric; v_ret text; v_t timestamptz;
begin
  -- cartão: tipo (crédito/débito/vale), bandeira e se foi pago no app ou será na entrega
  for m in select * from jsonb_array_elements(coalesce(p_order->'payments'->'methods', '[]'::jsonb)) loop
    v_tipo := upper(coalesce(m->>'method', ''));
    if v_tipo in ('CREDIT', 'DEBIT', 'MEAL_VOUCHER', 'FOOD_VOUCHER') or m ? 'card' then
      v_txt := v_txt || ' · Cartão ' || case v_tipo when 'CREDIT' then 'CRÉDITO' when 'DEBIT' then 'DÉBITO' when 'MEAL_VOUCHER' then 'VALE-REFEIÇÃO' when 'FOOD_VOUCHER' then 'VALE-ALIMENTAÇÃO' else v_tipo end
        || coalesce(' ' || upper(nullif(m->'card'->>'brand', '')), '')
        || case when upper(coalesce(m->>'type', '')) = 'OFFLINE' then ' (cobrar na entrega: levar maquininha)' else ' (pago no app)' end;
    end if;
  end loop;
  -- cupom/desconto: quem paga
  for b in select * from jsonb_array_elements(coalesce(p_order->'benefits', '[]'::jsonb)) loop
    for s in select * from jsonb_array_elements(coalesce(b->'sponsorshipValues', '[]'::jsonb)) loop
      v_n := coalesce(nullif(s->>'value', '')::numeric, 0);
      if upper(coalesce(s->>'name', '')) = 'IFOOD' then v_ifood := v_ifood + v_n;
      elsif upper(coalesce(s->>'name', '')) = 'MERCHANT' then v_loja := v_loja + v_n;
      else v_outros := v_outros + v_n; end if;
    end loop;
  end loop;
  if v_ifood + v_loja + v_outros > 0 then
    v_txt := v_txt || ' · Cupom: ' || concat_ws(' + ',
      case when v_ifood > 0 then 'R$ ' || replace(to_char(v_ifood, 'FM9999990.00'), '.', ',') || ' pago pelo iFood' end,
      case when v_loja > 0 then 'R$ ' || replace(to_char(v_loja, 'FM9999990.00'), '.', ',') || ' pago pela loja' end,
      case when v_outros > 0 then 'R$ ' || replace(to_char(v_outros, 'FM9999990.00'), '.', ',') || ' pago por parceiro' end);
  end if;
  -- retirada: horário combinado
  if upper(coalesce(p_order->>'orderType', '')) = 'TAKEOUT' then
    v_ret := coalesce(p_order->'takeout'->>'takeoutDateTime', '');
    begin v_t := nullif(v_ret, '')::timestamptz; exception when others then v_t := null; end;
    if v_t is not null then v_txt := v_txt || ' · RETIRADA ' || case when upper(coalesce(p_order->'takeout'->>'mode', '')) = 'SCHEDULED' then 'AGENDADA' else '' end || ' às ' || to_char(v_t at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'); end if;
  end if;
  return v_txt;
exception when others then return '';
end $function$;

do $$
declare d text; a text := 'if p_simulado then v_obs := v_obs || '' · TESTE (simulação)''; end if;';
begin
  select pg_get_functiondef('public.ifood_criar_pedido(jsonb,boolean)'::regprocedure) into d;
  if position('_ifood_extras_obs' in d) = 0 then
    if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception '57: ponto de troca não encontrado em ifood_criar_pedido'; end if;
    d := replace(d, a, 'v_obs := v_obs || public._ifood_extras_obs(p_order);   -- 57 (C-08)' || chr(10) || '  ' || a);
    execute d;
  end if;
end $$;

-- tarefas periódicas do ifood-sync: + "lojas" (1x por dia). Antes, qualquer tarefa diferente de "financeiro" mexia no relógio das avaliações.
alter table public.ifood_estado add column if not exists lojas_em timestamptz;
create or replace function public.ifood_precisa(p_tarefa text, p_minutos integer) returns boolean
 language plpgsql security definer set search_path to 'public' as $function$
declare v timestamptz;
begin
  if p_tarefa not in ('financeiro', 'avaliacoes', 'lojas') then return false; end if;
  select case p_tarefa when 'financeiro' then financeiro_em when 'avaliacoes' then avaliacoes_em when 'lojas' then lojas_em end into v from ifood_estado where id;
  if v is not null and v > now() - make_interval(mins => p_minutos) then return false; end if;
  if p_tarefa = 'financeiro' then update ifood_estado set financeiro_em = now() where id;
  elsif p_tarefa = 'avaliacoes' then update ifood_estado set avaliacoes_em = now() where id;
  else update ifood_estado set lojas_em = now() where id; end if;
  return true;
end $function$;
revoke all on function public.ifood_precisa(text, integer) from public, anon, authenticated;
grant execute on function public.ifood_precisa(text, integer) to service_role;
