-- 64 · iFood · Order: ajustes da homologação (Fase 1 do plano de 25/10/2026). Pode rodar de novo sem erro.
-- B3: o iFood só aceita "despachar" DEPOIS de "pronto para retirada". Se a equipe marcar "Saiu para entrega" sem ter marcado
--     "Pronta" antes, o sistema manda o "pronto" primeiro (a fila respeita a ordem de criação).
create or replace function public._ifood_trg_status() returns trigger
 language plpgsql security definer set search_path to 'public' as $function$
declare r ifood_pedidos%rowtype;
begin
  if new.canal is distinct from 'iFood' then return null; end if;
  if not public._integracao_ligada('ifood') then return null; end if;
  select * into r from ifood_pedidos where venda_id = new.id;
  if not found or r.simulado or r.estado in ('cancelado', 'concluido') then return null; end if;
  if new.status = 'Cancelada' and old.status is distinct from 'Cancelada' then
    perform public._ifood_enfileirar(r.pedido_ifood, 'cancelar', jsonb_build_object('motivo', coalesce(nullif(r.motivo_escolhido->>'descricao', ''), new.motivo_cancelamento), 'codigo', r.motivo_escolhido->>'codigo'));
  elsif new.status_pedido is distinct from old.status_pedido and new.status = 'Confirmada' then
    if new.status_pedido::text = 'Em preparo' then
      if r.estado = 'novo' then perform public._ifood_enfileirar(r.pedido_ifood, 'confirmar'); end if;
      perform public._ifood_enfileirar(r.pedido_ifood, 'iniciar_preparo');
    elsif new.status_pedido::text = 'Pronta' then
      perform public._ifood_enfileirar(r.pedido_ifood, 'pronto');
    elsif new.status_pedido::text = 'Saiu para entrega' and upper(coalesce(r.bruto->'delivery'->>'deliveredBy', '')) <> 'IFOOD' then
      if r.estado not in ('pronto', 'despachado')
         and not exists (select 1 from ifood_acoes a where a.pedido_ifood = r.pedido_ifood and a.acao = 'pronto' and a.estado in ('pendente', 'ok')) then
        perform public._ifood_enfileirar(r.pedido_ifood, 'pronto');
      end if;
      perform public._ifood_enfileirar(r.pedido_ifood, 'despachar');
    end if;
  end if;
  return null;
end $function$;


-- ===== B12 · Negociação do cliente (aceitar / recusar / contraproposta) conforme a documentação OFICIAL "Plataforma de negociação" =====
-- Guarda tudo que o iFood manda (ação, tipo, prazo e o que acontece se ninguém responder, fotos do cliente, motivos aceitos, itens, contrapropostas)
-- e o resultado final (HANDSHAKE_SETTLEMENT). A resposta exige o motivo oficial quando o iFood pede.
alter table public.ifood_negociacoes add column if not exists acao text;
alter table public.ifood_negociacoes add column if not exists grupo text;
alter table public.ifood_negociacoes add column if not exists mensagem text;
alter table public.ifood_negociacoes add column if not exists se_nao_responder text;
alter table public.ifood_negociacoes add column if not exists evidencias jsonb not null default '[]'::jsonb;
alter table public.ifood_negociacoes add column if not exists motivos_aceite jsonb not null default '[]'::jsonb;
alter table public.ifood_negociacoes add column if not exists itens jsonb not null default '[]'::jsonb;
alter table public.ifood_negociacoes add column if not exists resposta jsonb;
alter table public.ifood_negociacoes add column if not exists resultado text;
alter table public.ifood_negociacoes add column if not exists resultado_motivo text;
alter table public.ifood_negociacoes add column if not exists resultado_alternativa jsonb;
alter table public.ifood_negociacoes add column if not exists erro text;

create or replace function public.ifood_negociacao_registrar(p_evento jsonb, p_pedido text) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare m jsonb := coalesce(p_evento->'metadata', '{}'::jsonb); v_id text := coalesce(nullif(m->>'disputeId', ''), nullif(m->>'handshakeId', ''), nullif(p_evento->>'id', ''));
        v_exp timestamptz; v_num text; v_tipo text := coalesce(m->>'handshakeType', m->>'type'); v_acao text := m->>'action'; p_imagens jsonb := coalesce(p_evento->'_imagens', '[]'::jsonb);
begin
  begin v_exp := nullif(coalesce(m->>'expiresAt', m->>'expirationDate'), '')::timestamptz; exception when others then v_exp := null; end;
  insert into ifood_negociacoes (id, pedido_ifood, tipo, acao, grupo, mensagem, se_nao_responder, motivo, expira_em, alternativas, evidencias, motivos_aceite, itens, bruto)
  values (v_id, p_pedido, v_tipo, v_acao, m->>'handshakeGroup', left(coalesce(m->>'message', ''), 500), m->>'timeoutAction',
          left(coalesce(m->>'message', m->>'reason', m->>'handshakeGroup', ''), 300), coalesce(v_exp, now() + interval '5 minutes'),
          case when jsonb_typeof(m->'alternatives') = 'array' then m->'alternatives' else '[]'::jsonb end,
          case when jsonb_typeof(p_imagens) = 'array' then p_imagens else '[]'::jsonb end,
          case when jsonb_typeof(m->'acceptCancellationReasons') = 'array' then m->'acceptCancellationReasons' else '[]'::jsonb end,
          case when jsonb_typeof(m->'items') = 'array' then m->'items' when jsonb_typeof(m->'item') = 'array' then m->'item' else '[]'::jsonb end,
          p_evento)
  on conflict (id) do nothing;
  if found then
    select numero_ifood into v_num from ifood_pedidos where pedido_ifood = p_pedido;
    perform _push_enviar('pedido', '⚠️ iFood: cliente pediu ' || case upper(coalesce(v_tipo, '')) when 'DELAY' then 'cancelar por atraso' when 'PREPARATION_TIME' then 'cancelar durante o preparo'
        when 'AFTER_DELIVERY_PARTIALLY' then 'reembolso parcial' else 'cancelamento/reembolso' end || ' #' || coalesce(v_num, ''),
      'Responda no painel (Integrações → iFood) antes do prazo. Se ninguém responder: ' || case upper(coalesce(m->>'timeoutAction', '')) when 'ACCEPT_CANCELLATION' then 'o iFood CANCELA o pedido.' when 'REJECT_CANCELLATION' then 'o iFood recusa o pedido do cliente.' else 'o iFood decide.' end,
      'ifood-neg-' || v_id);
    perform _integ_log('ifood', 'aviso', 'Negociação de cancelamento no pedido #' || coalesce(v_num, p_pedido));
    perform _auditar('Negociação do iFood recebida', 'Pedido iFood #' || coalesce(v_num, p_pedido) || ' · ' || coalesce(v_tipo, '') || ' · ' || coalesce(v_acao, ''));
  end if;
  return jsonb_build_object('ok', true);
end $function$;
revoke all on function public.ifood_negociacao_registrar(jsonb, text) from public, anon, authenticated;
grant execute on function public.ifood_negociacao_registrar(jsonb, text) to service_role;

-- resultado final (HANDSHAKE_SETTLEMENT): ACCEPTED / REJECTED / EXPIRED / ALTERNATIVE_REPLIED
create or replace function public.ifood_negociacao_fim(p_evento jsonb, p_pedido text) returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare m jsonb := coalesce(p_evento->'metadata', '{}'::jsonb); v_id text := coalesce(nullif(m->>'disputeId', ''), nullif(m->>'handshakeId', ''));
        v_st text := upper(coalesce(m->>'status', '')); v_n text; v_num text;
begin
  if v_id is null then select id into v_id from ifood_negociacoes where pedido_ifood = p_pedido order by criado_em desc limit 1; end if;
  update ifood_negociacoes set
      estado = case when v_st = 'EXPIRED' and estado = 'aberta' then 'expirada'
                    when estado = 'aberta' then case v_st when 'ACCEPTED' then 'aceita' when 'REJECTED' then 'recusada' when 'ALTERNATIVE_REPLIED' then 'alternativa' else 'encerrada' end
                    else estado end,
      resultado = nullif(v_st, ''), resultado_motivo = left(nullif(m->>'reason', ''), 300),
      resultado_alternativa = case when jsonb_typeof(m->'selectedDisputeAlternative') = 'object' then m->'selectedDisputeAlternative' else resultado_alternativa end,
      respondido_em = coalesce(respondido_em, now())
   where id = v_id;
  select numero_ifood into v_num from ifood_pedidos where pedido_ifood = p_pedido;
  perform _integ_log('ifood', case when v_st = 'EXPIRED' then 'aviso' else 'info' end,
    'Negociação do pedido #' || coalesce(v_num, p_pedido) || ' encerrada: ' || case v_st when 'ACCEPTED' then 'aceita' when 'REJECTED' then 'recusada' when 'EXPIRED' then 'prazo acabou (o iFood aplicou a ação automática)'
       when 'ALTERNATIVE_REPLIED' then 'contraproposta enviada' else coalesce(nullif(v_st, ''), '?') end);
end $function$;
revoke all on function public.ifood_negociacao_fim(jsonb, text) from public, anon, authenticated;
grant execute on function public.ifood_negociacao_fim(jsonb, text) to service_role;

-- a Edge Function avisa quando o iFood recusou a resposta (a pessoa precisa ver o motivo)
create or replace function public.ifood_negociacao_erro(p_id text, p_erro text) returns void
 language plpgsql security definer set search_path to 'public' as $f$
begin
  update ifood_negociacoes set erro = left(p_erro, 300),
         estado = case when estado in ('aceita', 'recusada', 'alternativa') and resultado is null then 'aberta' else estado end
   where id = p_id;
  perform _integ_log('ifood', 'erro', 'iFood recusou a resposta da negociação: ' || left(p_erro, 200));
end $f$;
revoke all on function public.ifood_negociacao_erro(text, text) from public, anon, authenticated;
grant execute on function public.ifood_negociacao_erro(text, text) to service_role;

create or replace function public.api_ifood_negociacao_responder(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare n ifood_negociacoes%rowtype; v_acao text := p->>'acao'; v_login text; v_mot text := upper(nullif(btrim(coalesce(p->>'motivo', '')), '')); v_alt jsonb; v_tipo text;
        v_max numeric; v_valor numeric; v_min int; v_dados jsonb;
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  select * into n from ifood_negociacoes where id = p->>'id' for update;
  if not found then return _falha('Negociação não encontrada.'); end if;
  if n.estado <> 'aberta' then return _falha('Esta negociação já foi respondida ou encerrada.'); end if;
  if n.expira_em < now() then return _falha('O prazo para responder acabou; o iFood aplica a ação automática (' ||
       case upper(coalesce(n.se_nao_responder, '')) when 'ACCEPT_CANCELLATION' then 'cancelar o pedido' when 'REJECT_CANCELLATION' then 'recusar o pedido do cliente' else 'o iFood decide' end || ').'); end if;
  if v_acao not in ('aceitar', 'recusar', 'alternativa') then return _falha('Resposta inválida.'); end if;
  v_dados := jsonb_build_object('disputa', n.id, 'detalhe', left(coalesce(p->>'detalhe', ''), 250));
  if v_acao = 'aceitar' then
    if jsonb_array_length(n.motivos_aceite) > 0 or upper(coalesce(n.tipo, '')) = 'DELAY' then
      if v_mot is null then return _falha('Escolha o motivo para aceitar o cancelamento.'); end if;
      if jsonb_array_length(n.motivos_aceite) > 0 and not exists (select 1 from jsonb_array_elements_text(n.motivos_aceite) x where upper(x) = v_mot) then
        return _falha('Esse motivo não é aceito pelo iFood nesta negociação. Escolha um da lista.'); end if;
    end if;
    v_dados := v_dados || jsonb_build_object('motivo', v_mot);
  elsif v_acao = 'recusar' then
    if v_mot is null or v_mot not in ('HIGH_STORE_DEMAND', 'UNKNOWN_ISSUE', 'CUSTOMER_SATISFACTION', 'INVENTORY_CHECK', 'SYSTEM_ISSUE', 'WRONG_ORDER', 'PRODUCT_QUALITY', 'LATE_DELIVERY') then
      return _falha('Escolha o motivo da recusa.'); end if;
    v_dados := v_dados || jsonb_build_object('motivo', v_mot);
  else
    select a into v_alt from jsonb_array_elements(n.alternativas) a where a->>'id' = p->>'alternativaId' limit 1;
    if v_alt is null then return _falha('Escolha uma contraproposta da lista.'); end if;
    v_tipo := upper(coalesce(v_alt->>'type', ''));
    if v_tipo in ('REFUND', 'BENEFIT') then
      v_max := nullif(coalesce(v_alt->'metadata'->'maxAmount'->>'value', v_alt->'metadata'->>'maxAmount'), '')::numeric;   -- o iFood manda em centavos
      begin v_valor := replace(coalesce(p->>'valor', ''), ',', '.')::numeric; exception when others then v_valor := null; end;
      if v_valor is null or v_valor <= 0 then return _falha('Informe o valor do reembolso (R$).'); end if;
      if v_max is not null and round(v_valor * 100) > v_max then return _falha('O valor passa do máximo permitido: R$ ' || to_char(v_max / 100, 'FM999990D00') || '.'); end if;
      v_dados := v_dados || jsonb_build_object('tipo', v_tipo, 'valorCentavos', round(v_valor * 100));
    elsif v_tipo = 'ADDITIONAL_TIME' then
      begin v_min := (p->>'minutos')::int; exception when others then v_min := null; end;
      if v_min is null or v_min <= 0 then return _falha('Escolha quantos minutos a mais.'); end if;
      if jsonb_typeof(v_alt->'metadata'->'allowedsAdditionalTimeInMinutes') = 'array'
         and not exists (select 1 from jsonb_array_elements_text(v_alt->'metadata'->'allowedsAdditionalTimeInMinutes') x where x::int = v_min) then
        return _falha('O iFood só aceita estes minutos: ' || (select string_agg(x, ', ') from jsonb_array_elements_text(v_alt->'metadata'->'allowedsAdditionalTimeInMinutes') x) || '.'); end if;
      v_dados := v_dados || jsonb_build_object('tipo', v_tipo, 'minutos', v_min, 'motivo', coalesce(v_mot, 'HIGH_STORE_DEMAND'));
    else return _falha('Tipo de contraproposta não reconhecido: ' || coalesce(v_tipo, '?')); end if;
    v_dados := v_dados || jsonb_build_object('alternativaId', p->>'alternativaId');
  end if;
  select login into v_login from usuarios where id = auth.uid();
  update ifood_negociacoes set estado = case v_acao when 'aceitar' then 'aceita' when 'recusar' then 'recusada' else 'alternativa' end, respondido_em = now(), resposta_por = v_login, erro = null,
         resposta = jsonb_build_object('acao', v_acao) || v_dados where id = n.id;
  perform public._ifood_enfileirar(n.pedido_ifood, 'negociacao_' || v_acao, v_dados);
  perform _auditar('Negociação do iFood respondida', 'Pedido ' || n.pedido_ifood || ' · ' || v_acao || coalesce(' · ' || v_mot, '') || ' por ' || coalesce(v_login, ''));
  return jsonb_build_object('ok', true, 'message', 'Resposta enviada ao iFood. O resultado aparece aqui quando o iFood confirmar.') || api_ifood_negociacoes('{}');
end $function$;

create or replace function public.api_ifood_negociacoes(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  return jsonb_build_object('ok', true, 'itens', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'pedido', i.numero_ifood, 'tipo', n.tipo, 'acao', n.acao, 'motivo', n.motivo, 'mensagem', n.mensagem,
      'expiraEm', n.expira_em, 'segundos', greatest(0, round(extract(epoch from (n.expira_em - now())))), 'estado', n.estado, 'alternativas', n.alternativas,
      'seNaoResponder', n.se_nao_responder, 'fotos', n.evidencias, 'motivosAceite', n.motivos_aceite, 'itens', n.itens,
      'resultado', n.resultado, 'resultadoMotivo', n.resultado_motivo, 'resultadoAlternativa', n.resultado_alternativa, 'erro', n.erro, 'respostaPor', n.resposta_por, 'em', n.criado_em) order by n.criado_em desc)
    from (select * from ifood_negociacoes order by criado_em desc limit 15) n left join ifood_pedidos i on i.pedido_ifood = n.pedido_ifood), '[]'::jsonb));
end $function$;
