-- 68 · iFood Shipping (v1.19) — "entregador do iFood" (Sob Demanda). LIGA/DESLIGA na tela iFood › Entregador do iFood.
-- Pelos PDFs oficiais do módulo Shipping. Pode rodar de novo sem erro.
-- Modo A: pedido que VEIO do iFood com entrega própria → pede um entregador do iFood (cotação, chamar, cancelar a chamada).
-- Modo B: pedido FORA do iFood (cardápio próprio, balcão, WhatsApp) → cria o pedido de entrega Sob Demanda (cotação pelo endereço,
--         link de rastreio para o cliente, código de 4 dígitos, nível de confiança, troca de endereço, cancelamento com motivos do iFood).
-- Pré-requisito no iFood: contratar o serviço Sob Demanda no Portal do Parceiro › Serviços. Chamar e cancelar pedem a SENHA do Admin.

create table if not exists public.ifood_ship_config (
  id boolean primary key default true check (id),
  ligado boolean not null default false,
  cidade text not null default '',
  uf text not null default '',
  preparo_seg int not null default 900 check (preparo_seg between 60 and 3600),
  atualizado_em timestamptz not null default now()
);
insert into public.ifood_ship_config (id) values (true) on conflict do nothing;
alter table public.ifood_ship_config enable row level security;
revoke all on public.ifood_ship_config from anon, authenticated;

create table if not exists public.ifood_ship (
  id uuid primary key default gen_random_uuid(),
  modo text not null check (modo in ('A', 'B')),
  venda_id uuid not null,
  pedido_ifood text,                 -- modo A: id do pedido no iFood
  ship_id text,                      -- id do pedido no Shipping (A = o próprio pedido do iFood; B = o que o iFood devolve ao criar)
  endereco jsonb not null default '{}'::jsonb,
  quote_id text, quote jsonb, valor numeric(10,2), expira_em timestamptz,
  estado text not null default 'cotando' check (estado in ('cotando','cotada','erro_cotacao','solicitando','alocada','em_rota','entregue','falhou','cancelando','cancelada')),
  erro text, tracking_url text, codigo text, safe_score text, safe_regras jsonb, motivos jsonb, endereco_pendente jsonb, eventos jsonb not null default '[]'::jsonb,
  custo_lancado boolean not null default false,
  criado_por text, criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now()
);
create index if not exists ifood_ship_venda_idx on public.ifood_ship (venda_id);
create index if not exists ifood_ship_shipid_idx on public.ifood_ship (ship_id);
alter table public.ifood_ship enable row level security;
revoke all on public.ifood_ship from anon, authenticated;

alter table public.ifood_acoes drop constraint if exists ifood_acoes_acao_check;
alter table public.ifood_acoes add constraint ifood_acoes_acao_check check (acao = any (array['confirmar','iniciar_preparo','pronto','despachar','cancelar','negociacao_aceitar','negociacao_recusar','negociacao_alternativa','loja_fechar','loja_abrir','loja_pausar','loja_retomar','loja_horario_enviar','loja_horario_ler','catalogo_importar','catalogo_preco','catalogo_pausar','catalogo_retomar','catalogo_modelo_enviar','catalogo_lote_preco','catalogo_lote_status','catalogo_opcao_preco','catalogo_opcao_status','catalogo_diagnostico','avaliacao_responder','motivos','codigo_coleta','codigo_entrega','ship_cotar','ship_chamar','ship_cancelar','ship_motivos','ship_endereco','ship_safe']));

-- erros do iFood em português (G3)
create or replace function public._ifood_ship_erro_txt(p_codigo text) returns text language sql immutable as $f$
  select case coalesce(p_codigo, '')
    when 'DeliveryDistanceTooHigh' then 'O endereço fica a mais de ~10 km da loja: o iFood não entrega.'
    when 'ServiceAreaMismatch' then 'O endereço está fora da área de cobertura do entregador do iFood.'
    when 'OffOpeningHours' then 'Fora do horário de funcionamento da loja no iFood.'
    when 'HighDemand' then 'Muita demanda no iFood agora: não há entregador livre. Tente de novo em alguns minutos.'
    when 'MerchantEasyDeliveryDisabled' then 'O serviço Sob Demanda não está contratado para esta loja. Contrate no Portal do Parceiro › Serviços.'
    when 'MerchantStatusAvailability' then 'A conta da loja tem pendência no iFood. Veja no Portal do Parceiro.'
    when 'InvalidPaymentMethods' then 'Esta forma de pagamento não é aceita para entrega pelo iFood.'
    when 'SaturatedOfflinePayment' then 'Pagamento na entrega indisponível no iFood agora. Use um pedido já pago ou tente mais tarde.'
    when 'NRELimitExceeded' then 'Limite de entregadores do iFood atingido. Tente de novo mais tarde.'
    when 'UnavailableFleet' then 'Frota indisponível agora. Tente de novo em alguns minutos.'
    when 'OriginNotFound' then 'O iFood não encontrou a loja (confira o código da loja nas integrações).'
    when 'BadRequestMerchant' then 'A loja está indisponível no iFood (fechada ou pausada).'
    when 'BadRequestCustomer' then 'Os dados do cliente foram recusados (telefone ou nome inválido).'
    when 'BadRequest' then 'Dados inválidos na solicitação (confira endereço, CEP e coordenadas).'
    else null end
$f$;

-- ---------- configuração (liga/desliga) ----------
create or replace function public.api_ifood_ship_config(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare c ifood_ship_config%rowtype; v_aut text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if coalesce(p->>'salvar', '') = 'true' then
    if coalesce(p->>'senhaAdminConfirmacao', '') = '' then return _falha('Informe a sua senha de administrador para confirmar.'); end if;
    v_aut := _exige_admin(p->>'senhaAdminConfirmacao');
    if v_aut is null then return _falha('Senha de administrador incorreta.'); end if;
    if length(btrim(coalesce(p->>'uf', ''))) not in (0, 2) then return _falha('A UF precisa ter 2 letras (ex.: SP).'); end if;
    update ifood_ship_config set ligado = coalesce((p->>'ligado')::boolean, ligado), cidade = left(btrim(coalesce(p->>'cidade', cidade)), 80),
      uf = upper(btrim(coalesce(p->>'uf', uf))), preparo_seg = coalesce(nullif(p->>'preparoMin', '')::int * 60, preparo_seg), atualizado_em = now() where id;
    perform _auditar('Entregador do iFood: configuração', case when coalesce((p->>'ligado')::boolean, false) then 'ligado' else 'salvo' end);
  end if;
  select * into c from ifood_ship_config where id;
  return jsonb_build_object('ok', true, 'ligado', c.ligado, 'cidade', c.cidade, 'uf', c.uf, 'preparoMin', c.preparo_seg / 60);
end $f$;

-- ---------- lista (entregas pedidas + pedidos que podem chamar entregador) ----------
create or replace function public.api_ifood_ship_lista(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare c ifood_ship_config%rowtype;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select * into c from ifood_ship_config where id;
  return jsonb_build_object('ok', true, 'config', jsonb_build_object('ligado', c.ligado, 'cidade', c.cidade, 'uf', c.uf, 'preparoMin', c.preparo_seg / 60),
    'gasto7d', (select coalesce(sum(valor), 0) from ifood_ship where estado in ('alocada','em_rota','entregue','cancelando') and criado_em > now() - interval '7 days'),
    'entregas', coalesce((select jsonb_agg(x order by (x->>'em') desc) from (
      select jsonb_build_object('id', s.id, 'modo', s.modo, 'pedido', v.numero_pedido, 'cliente', v.cliente_nome, 'estado', s.estado, 'erro', s.erro, 'valor', s.valor,
        'expiraEm', s.expira_em, 'tempoMin', (s.quote->'deliveryTime'->>'min'), 'tempoMax', (s.quote->'deliveryTime'->>'max'), 'distancia', s.quote->>'distance', 'rastreio', s.tracking_url, 'codigo', s.codigo,
        'confianca', s.safe_score, 'regras', s.safe_regras, 'motivos', s.motivos, 'enderecoPendente', s.endereco_pendente, 'eventos', s.eventos, 'em', s.criado_em,
        'pagamentos', s.quote->'paymentMethods') as x
      from ifood_ship s join vendas v on v.id = s.venda_id where s.criado_em > now() - interval '7 days' order by s.criado_em desc limit 40) q), '[]'::jsonb),
    'candidatas', coalesce((select jsonb_agg(jsonb_build_object('vendaId', v.id, 'pedido', v.numero_pedido, 'cliente', v.cliente_nome, 'telefone', v.telefone_cliente, 'endereco', v.endereco,
        'complemento', v.complemento, 'referencia', v.referencia, 'total', v.valor_total, 'forma', v.forma_pagamento, 'pagamento', v.status_pagamento::text, 'situacao', v.status_pedido::text,
        'modo', case when i.pedido_ifood is not null then 'A' else 'B' end, 'lat', d.lat, 'lng', d.lng) order by v.data_hora desc)
      from vendas v left join ifood_pedidos i on i.venda_id = v.id left join pedido_destinos d on d.venda_id = v.id
      where v.tipo::text = 'Entrega' and v.status::text = 'Confirmada' and v.status_pedido::text in ('Recebido', 'Em preparo', 'Pronta') and v.data_hora > now() - interval '1 day'
        and (i.pedido_ifood is null or (not i.simulado and coalesce(v.observacoes_entrega, '') not ilike '%ENTREGA PELO iFOOD%'))
        and not exists (select 1 from ifood_ship s where s.venda_id = v.id and s.estado not in ('cancelada', 'falhou', 'erro_cotacao'))), '[]'::jsonb));
end $f$;

-- ---------- cotar (grátis) ----------
create or replace function public.api_ifood_ship_cotar(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare c ifood_ship_config%rowtype; v vendas%rowtype; i ifood_pedidos%rowtype; e jsonb := coalesce(p->'endereco', '{}'::jsonb); v_modo text; v_id uuid; v_login text; v_lat float; v_lng float;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select * into c from ifood_ship_config where id;
  if not c.ligado then return _falha('O entregador do iFood está desligado. Ligue em iFood › Entregador do iFood.'); end if;
  if not _integracao_ligada('ifood') then return _falha('O iFood está desligado.'); end if;
  select * into v from vendas where id = nullif(p->>'vendaId', '')::uuid;
  if not found then return _falha('Pedido não encontrado.'); end if;
  if v.tipo::text <> 'Entrega' or v.status::text <> 'Confirmada' then return _falha('Só pedido de ENTREGA confirmado pode chamar entregador.'); end if;
  if exists (select 1 from ifood_ship s where s.venda_id = v.id and s.estado not in ('cancelada', 'falhou', 'erro_cotacao')) then return _falha('Este pedido já tem uma entrega do iFood em andamento.'); end if;
  select * into i from ifood_pedidos where venda_id = v.id;
  if found then
    if i.simulado then return _falha('Pedido de teste do iFood: não chama entregador de verdade.'); end if;
    if coalesce(v.observacoes_entrega, '') ilike '%ENTREGA PELO iFOOD%' then return _falha('Este pedido já será entregue pelo próprio iFood.'); end if;
    v_modo := 'A';
  else
    v_modo := 'B';
    v_lat := nullif(e->>'lat', '')::float; v_lng := nullif(e->>'lng', '')::float;
    if v_lat is null or v_lng is null or abs(v_lat) > 90 or abs(v_lng) > 180 then return _falha('Informe as coordenadas do endereço (latitude e longitude). Dica: no Google Maps, toque e segure no endereço e copie os números.'); end if;
    if length(regexp_replace(coalesce(e->>'cep', ''), '\D', '', 'g')) <> 8 then return _falha('Informe o CEP com 8 números.'); end if;
    if coalesce(btrim(e->>'rua'), '') = '' or coalesce(btrim(e->>'numero'), '') = '' or coalesce(btrim(e->>'bairro'), '') = '' or coalesce(btrim(e->>'cidade'), '') = '' or length(btrim(coalesce(e->>'uf', ''))) <> 2 then
      return _falha('Preencha rua, número, bairro, cidade e UF (2 letras).');
    end if;
  end if;
  select login into v_login from usuarios where id = auth.uid();
  insert into ifood_ship (modo, venda_id, pedido_ifood, ship_id, endereco, estado, criado_por)
    values (v_modo, v.id, i.pedido_ifood, case when v_modo = 'A' then i.pedido_ifood end, e, 'cotando', v_login) returning id into v_id;
  perform _ifood_enfileirar('LOJA', 'ship_cotar', jsonb_build_object('chave', v_id::text, 'ship', v_id));
  return jsonb_build_object('ok', true, 'id', v_id, 'message', 'Pedindo a cotação ao iFood. Toque em Atualizar em alguns segundos.');
end $f$;

-- ---------- chamar (gasta dinheiro: pede a senha do Admin) ----------
create or replace function public.api_ifood_ship_chamar(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare s ifood_ship%rowtype; c ifood_ship_config%rowtype; v_aut text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select * into c from ifood_ship_config where id;
  if not c.ligado then return _falha('O entregador do iFood está desligado.'); end if;
  if coalesce(p->>'senhaAdminConfirmacao', '') = '' then return _falha('Informe a sua senha de administrador para confirmar.'); end if;
  v_aut := _exige_admin(p->>'senhaAdminConfirmacao');
  if v_aut is null then return _falha('Senha de administrador incorreta.'); end if;
  select * into s from ifood_ship where id = nullif(p->>'id', '')::uuid for update;
  if not found then return _falha('Entrega não encontrada.'); end if;
  if s.estado <> 'cotada' then return _falha('Peça uma cotação primeiro (estado atual: ' || s.estado || ').'); end if;
  if s.expira_em is not null and s.expira_em < now() then return _falha('A cotação venceu. Peça uma nova.'); end if;
  update ifood_ship set estado = 'solicitando', erro = null, atualizado_em = now() where id = s.id;
  perform _ifood_enfileirar('LOJA', 'ship_chamar', jsonb_build_object('chave', s.id::text || '-chamar', 'ship', s.id));
  perform _auditar('Entregador do iFood chamado', 'Pedido ' || (select numero_pedido from vendas where id = s.venda_id) || ' · R$ ' || coalesce(s.valor, 0));
  return jsonb_build_object('ok', true, 'message', 'Chamando o entregador. O iFood avisa quando alguém aceitar.');
end $f$;

-- ---------- motivos de cancelamento (modo B; nunca fixos no código) ----------
create or replace function public.api_ifood_ship_motivos(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare s ifood_ship%rowtype;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select * into s from ifood_ship where id = nullif(p->>'id', '')::uuid;
  if not found then return _falha('Entrega não encontrada.'); end if;
  update ifood_ship set motivos = null where id = s.id;
  perform _ifood_enfileirar('LOJA', 'ship_motivos', jsonb_build_object('chave', gen_random_uuid()::text, 'ship', s.id));
  return jsonb_build_object('ok', true, 'message', 'Buscando no iFood os motivos permitidos.');
end $f$;

create or replace function public.api_ifood_ship_cancelar(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare s ifood_ship%rowtype; v_aut text; v_ok boolean;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if coalesce(p->>'senhaAdminConfirmacao', '') = '' then return _falha('Informe a sua senha de administrador para confirmar.'); end if;
  v_aut := _exige_admin(p->>'senhaAdminConfirmacao');
  if v_aut is null then return _falha('Senha de administrador incorreta.'); end if;
  select * into s from ifood_ship where id = nullif(p->>'id', '')::uuid for update;
  if not found then return _falha('Entrega não encontrada.'); end if;
  if s.estado not in ('solicitando', 'alocada', 'em_rota', 'cotada') then return _falha('Esta entrega não pode ser cancelada agora (estado: ' || s.estado || ').'); end if;
  if s.estado = 'cotada' then
    update ifood_ship set estado = 'cancelada', atualizado_em = now() where id = s.id;
    return jsonb_build_object('ok', true, 'message', 'Cotação descartada.');
  end if;
  if s.modo = 'B' then
    select exists (select 1 from jsonb_array_elements(coalesce(s.motivos, '[]'::jsonb)) m where m->>'cancelCodeId' = p->>'codigo') into v_ok;
    if not v_ok then return _falha('Escolha um dos motivos de cancelamento trazidos do iFood.'); end if;
  end if;
  update ifood_ship set estado = 'cancelando', atualizado_em = now() where id = s.id;
  perform _ifood_enfileirar('LOJA', 'ship_cancelar', jsonb_build_object('chave', s.id::text || '-cancelar', 'ship', s.id, 'codigo', p->>'codigo',
    'motivo', left(coalesce((select m->>'description' from jsonb_array_elements(coalesce(s.motivos, '[]'::jsonb)) m where m->>'cancelCodeId' = p->>'codigo'), 'Cancelado pela loja'), 200)));
  perform _auditar('Entregador do iFood cancelado', 'Entrega ' || s.id);
  return jsonb_build_object('ok', true, 'message', 'Cancelamento enviado ao iFood. O resultado chega em instantes.');
end $f$;

-- ---------- endereço (modo B): confirmar o original, aceitar ou negar a troca pedida pelo cliente ----------
create or replace function public.api_ifood_ship_endereco(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare s ifood_ship%rowtype; v_acao text := p->>'acao';
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  if v_acao not in ('confirmar', 'aceitar', 'negar') then return _falha('Ação inválida.'); end if;
  select * into s from ifood_ship where id = nullif(p->>'id', '')::uuid;
  if not found or s.modo <> 'B' then return _falha('Entrega não encontrada.'); end if;
  if v_acao <> 'confirmar' and s.endereco_pendente is null then return _falha('Não há pedido de troca de endereço esperando resposta.'); end if;
  perform _ifood_enfileirar('LOJA', 'ship_endereco', jsonb_build_object('chave', gen_random_uuid()::text, 'ship', s.id, 'acao', v_acao));
  return jsonb_build_object('ok', true, 'message', 'Enviando a resposta ao iFood.');
end $f$;

create or replace function public.api_ifood_ship_safe(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare s ifood_ship%rowtype;
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  select * into s from ifood_ship where id = nullif(p->>'id', '')::uuid;
  if not found or s.modo <> 'B' then return _falha('Entrega não encontrada.'); end if;
  perform _ifood_enfileirar('LOJA', 'ship_safe', jsonb_build_object('chave', gen_random_uuid()::text, 'ship', s.id));
  return jsonb_build_object('ok', true, 'message', 'Consultando o nível de confiança no iFood.');
end $f$;

revoke all on function public.api_ifood_ship_config(jsonb), public.api_ifood_ship_lista(jsonb), public.api_ifood_ship_cotar(jsonb), public.api_ifood_ship_chamar(jsonb),
  public.api_ifood_ship_motivos(jsonb), public.api_ifood_ship_cancelar(jsonb), public.api_ifood_ship_endereco(jsonb), public.api_ifood_ship_safe(jsonb) from public, anon;
grant execute on function public.api_ifood_ship_config(jsonb), public.api_ifood_ship_lista(jsonb), public.api_ifood_ship_cotar(jsonb), public.api_ifood_ship_chamar(jsonb),
  public.api_ifood_ship_motivos(jsonb), public.api_ifood_ship_cancelar(jsonb), public.api_ifood_ship_endereco(jsonb), public.api_ifood_ship_safe(jsonb) to authenticated, service_role;

-- ---------- só para a Edge Function (service_role) ----------
create or replace function public.ifood_ship_dados(p_id uuid) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare s ifood_ship%rowtype; c ifood_ship_config%rowtype;
begin
  select * into s from ifood_ship where id = p_id;
  if not found then return null; end if;
  select * into c from ifood_ship_config where id;
  return jsonb_build_object('id', s.id, 'modo', s.modo, 'shipId', s.ship_id, 'quoteId', s.quote_id, 'estado', s.estado, 'endereco', s.endereco, 'valor', s.valor,
    'ligado', c.ligado, 'preparoSeg', c.preparo_seg, 'pedidoIfood', s.pedido_ifood);
end $f$;

create or replace function public.ifood_ship_resultado(p_id uuid, p_estado text, p_patch jsonb default '{}'::jsonb, p_erro text default null) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare s ifood_ship%rowtype;
begin
  update ifood_ship set estado = coalesce(nullif(p_estado, ''), estado), erro = left(p_erro, 400),
    quote_id = coalesce(p_patch->>'quoteId', quote_id), quote = coalesce(p_patch->'quote', quote),
    valor = coalesce(nullif(p_patch->>'valor', '')::numeric, valor), expira_em = coalesce(nullif(p_patch->>'expiraEm', '')::timestamptz, expira_em),
    ship_id = coalesce(nullif(p_patch->>'shipId', ''), ship_id), tracking_url = coalesce(p_patch->>'trackingUrl', tracking_url),
    safe_score = coalesce(p_patch->>'safeScore', safe_score), safe_regras = coalesce(p_patch->'safeRegras', safe_regras), motivos = coalesce(p_patch->'motivos', motivos),
    endereco_pendente = case when p_patch ? 'limparEndereco' then null else endereco_pendente end,
    atualizado_em = now() where id = p_id returning * into s;
  if found and p_erro is not null and p_estado in ('erro_cotacao', 'falhou') then
    perform ifood_aviso_registrar(s.pedido_ifood, 'ship_erro', '🛵 Entregador do iFood: ' || case when p_estado = 'erro_cotacao' then 'sem cotação' else 'não foi possível chamar' end, left(p_erro, 400), jsonb_build_object('ship', p_id));
  end if;
end $f$;

-- eventos do Shipping (REQUEST_DRIVER_*, DELIVERY_*): atualiza a entrega e avisa a equipe. Devolve {achou:true} se o pedido é uma entrega nossa.
create or replace function public.ifood_ship_evento(p_codigo text, p_pedido text, p_meta jsonb default '{}'::jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare s ifood_ship%rowtype; v_cod text := upper(coalesce(p_codigo, '')); v_num int; v_est text; v_tit text; v_msg text; v_tipo text := 'ship';
begin
  select * into s from ifood_ship where ship_id = p_pedido and estado <> 'cotando' order by criado_em desc limit 1;
  if not found then return jsonb_build_object('achou', false); end if;
  -- no modo A (pedido do iFood) só os eventos próprios do entregador passam por aqui; o resto segue o tratamento normal do pedido
  if s.modo = 'A' and v_cod !~ '^(REQUEST_DRIVER_|DELIVERY_CANCELLATION_)' then return jsonb_build_object('achou', true, 'avisou', false); end if;
  select numero_pedido into v_num from vendas where id = s.venda_id;
  update ifood_ship set eventos = (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select x from jsonb_array_elements(eventos || jsonb_build_array(jsonb_build_object('codigo', v_cod, 'em', now(), 'meta', coalesce(p_meta, '{}'::jsonb)))) x order by 1 desc limit 30) q) where id = s.id;
  if v_cod in ('REQUEST_DRIVER_SUCCESS') then v_est := 'alocada'; v_tit := '🛵 Entregador do iFood a caminho da loja'; v_msg := 'Um entregador aceitou o pedido #' || v_num || '.';
  elsif v_cod = 'REQUEST_DRIVER_FAILED' then v_est := 'falhou'; v_tit := '🛵 Nenhum entregador aceitou o pedido #' || v_num; v_msg := 'O iFood não conseguiu alocar um entregador. Tente chamar de novo ou use outro meio de entrega.';
  elsif v_cod = 'DELIVERY_DROP_CODE_REQUESTED' then update ifood_ship set codigo = coalesce(p_meta->>'CODE', codigo) where id = s.id; v_tit := '🔑 Código de entrega do pedido #' || v_num; v_msg := 'O entregador vai pedir este código ao cliente: ' || coalesce(p_meta->>'CODE', '(sem código)') || '. Avise o cliente.';
  elsif v_cod = 'DELIVERY_IN_TRANSIT' then v_est := 'em_rota'; v_tit := '🛵 Pedido #' || v_num || ' saiu para entrega'; v_msg := 'O entregador do iFood está a caminho do cliente.';
  elsif v_cod in ('DELIVERY_CONCLUDED') or (v_cod = 'CONCLUDED' and s.modo = 'B') then v_est := 'entregue'; v_tit := '✅ Pedido #' || v_num || ' entregue pelo iFood'; v_msg := 'Confira e marque o pedido como entregue no sistema, se ainda não marcou.';
  elsif v_cod in ('DELIVERY_CANCELLED', 'DELIVERY_CANCELLATION_ACCEPTED') or (v_cod = 'CANCELLED' and s.modo = 'B') then v_est := 'cancelada'; v_tit := '🛵 Entrega do iFood cancelada (pedido #' || v_num || ')'; v_msg := 'A entrega pelo entregador do iFood foi cancelada.';
  elsif v_cod in ('DELIVERY_CANCELLATION_REQUESTED', 'CANCELLATION_REQUESTED') then v_est := 'cancelando'; v_tit := '🛵 Cancelamento da entrega pedido'; v_msg := 'Aguardando o iFood confirmar o cancelamento do pedido #' || v_num || '.';
  elsif v_cod in ('DELIVERY_CANCELLATION_REJECTED', 'CANCELLATION_REQUEST_FAILED') then v_est := 'alocada'; v_tit := '❌ O iFood recusou cancelar a entrega do pedido #' || v_num; v_msg := 'O entregador provavelmente já saiu. A entrega continua.';
  elsif v_cod = 'DELIVERY_ADDRESS_CHANGE_REQUESTED' then update ifood_ship set endereco_pendente = coalesce(p_meta, '{}'::jsonb) where id = s.id; v_tit := '📍 Cliente pediu para mudar o endereço (pedido #' || v_num || ')'; v_msg := 'Responda em até 15 minutos em iFood › Entregador do iFood (aceitar ou negar). Sem resposta o iFood nega sozinho.';
  elsif v_cod in ('DELIVERY_ADDRESS_CHANGE_ACCEPTED', 'DELIVERY_ADDRESS_CHANGE_DENIED', 'DELIVERY_ADDRESS_CHANGE_USER_CONFIRMED') then update ifood_ship set endereco_pendente = null where id = s.id; v_tit := '📍 Endereço do pedido #' || v_num || ': ' || case v_cod when 'DELIVERY_ADDRESS_CHANGE_ACCEPTED' then 'troca aceita' when 'DELIVERY_ADDRESS_CHANGE_DENIED' then 'troca negada' else 'confirmado pelo cliente' end;
    v_msg := case when p_meta->>'action' = 'region-mismatch' then 'O novo endereço é de outra região: o iFood negou sozinho.' else 'Veja o resultado em iFood › Entregador do iFood.' end;
  else return jsonb_build_object('achou', true, 'avisou', false); end if;
  if v_est is not null then update ifood_ship set estado = v_est, atualizado_em = now(), erro = case when v_est = 'falhou' then left(v_msg, 400) else null end where id = s.id; end if;
  -- custo da entrega vira despesa (uma vez só, quando a entrega é concluída)
  if v_est = 'entregue' and not s.custo_lancado and coalesce(s.valor, 0) > 0 then
    begin
      insert into despesas (descricao, valor, categoria, observacao, status, situacao, saiu_do_caixa, competencia, requisicao_id, origem_pagamento)
      values ('Entregador do iFood · pedido #' || v_num, s.valor, 'Entregadores', 'Descontado pelo iFood no repasse (Sob Demanda).', 'Paga', 'Paga', false, to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM'), 'ifood-ship-' || s.id, 'iFood');
      update ifood_ship set custo_lancado = true where id = s.id;
    exception when others then null; end;
  end if;
  perform ifood_aviso_registrar(s.pedido_ifood, v_tipo, v_tit, v_msg, jsonb_build_object('ship', s.id, 'codigo', v_cod));
  return jsonb_build_object('achou', true, 'avisou', true);
end $f$;

revoke all on function public.ifood_ship_dados(uuid), public.ifood_ship_resultado(uuid, text, jsonb, text), public.ifood_ship_evento(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.ifood_ship_dados(uuid), public.ifood_ship_resultado(uuid, text, jsonb, text), public.ifood_ship_evento(text, text, jsonb) to service_role;

-- corpo do pedido Sob Demanda (modo B), montado a partir da venda
create or replace function public.ifood_ship_payload_b(p_id uuid) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare s ifood_ship%rowtype; v vendas%rowtype; c ifood_ship_config%rowtype; e jsonb; v_tel text; v_tipo text := 'CUSTOMER'; v_area text; v_num text; v_pag jsonb; v_itens jsonb; v_marca text; v_met text; v_total numeric;
begin
  select * into s from ifood_ship where id = p_id;
  select * into v from vendas where id = s.venda_id;
  select * into c from ifood_ship_config where id;
  e := s.endereco;
  v_tel := regexp_replace(coalesce(v.telefone_cliente, ''), '\D', '', 'g');
  if v_tel like '55%' and length(v_tel) >= 12 then v_tel := substr(v_tel, 3); end if;
  if length(v_tel) in (10, 11) and left(v_tel, 1) <> '0' then v_area := left(v_tel, 2); v_num := substr(v_tel, 3);
  else v_tipo := 'STORE'; v_area := '00'; v_num := '000000000'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', it.id, 'name', left(coalesce(it.descricao, 'Item'), 50), 'quantity', it.quantidade, 'unitPrice', it.valor_unitario,
      'price', round(it.quantidade * it.valor_unitario, 2), 'optionsPrice', greatest(round(it.valor_total_item - it.quantidade * it.valor_unitario, 2), 0),
      'totalPrice', round(it.quantidade * it.valor_unitario, 2) + greatest(round(it.valor_total_item - it.quantidade * it.valor_unitario, 2), 0))), '[]'::jsonb)
    into v_itens from itens_venda it where it.venda_id = v.id;
  v_total := v.valor_total;
  if v.status_pagamento::text = 'Pago' then v_pag := null;          -- pago (online/antecipado): o corpo NÃO leva "payments"
  else
    v_met := case when v.forma_pagamento ilike '%dinheiro%' then 'CASH' when v.forma_pagamento ilike '%cr%dito%' then 'CREDIT' when v.forma_pagamento ilike '%d%bito%' then 'DEBIT' else null end;
    if v_met is null then return jsonb_build_object('erro', 'A forma de pagamento "' || coalesce(v.forma_pagamento, '?') || '" não pode ser cobrada na entrega pelo iFood. Receba antes (pago) ou use dinheiro/cartão.'); end if;
    select coalesce(m->>'brand', 'Visa') into v_marca from jsonb_array_elements(coalesce(s.quote->'paymentMethods', '[]'::jsonb)) m where upper(m->>'method') = v_met limit 1;
    v_pag := jsonb_build_object('methods', jsonb_build_array(case v_met when 'CASH' then jsonb_build_object('method', 'CASH', 'type', 'OFFLINE', 'value', v_total, 'cash', jsonb_build_object('changeFor', v_total))
      else jsonb_build_object('method', v_met, 'type', 'OFFLINE', 'value', v_total, 'card', jsonb_build_object('brand', coalesce(v_marca, 'Visa'))) end));
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'customer', jsonb_build_object('name', left(coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), 50), 'phone', jsonb_build_object('countryCode', '55', 'areaCode', v_area, 'number', v_num, 'type', v_tipo)),
    'delivery', jsonb_build_object('merchantFee', s.valor, 'preparationTime', c.preparo_seg, 'quoteId', s.quote_id,
      'deliveryAddress', jsonb_build_object('postalCode', regexp_replace(coalesce(e->>'cep', ''), '\D', '', 'g'), 'streetNumber', e->>'numero', 'streetName', e->>'rua', 'complement', nullif(e->>'complemento', ''),
        'reference', nullif(e->>'referencia', ''), 'neighborhood', e->>'bairro', 'city', e->>'cidade', 'state', upper(e->>'uf'), 'country', 'BR',
        'coordinates', jsonb_build_object('latitude', (e->>'lat')::float, 'longitude', (e->>'lng')::float))),
    'items', v_itens, 'payments', v_pag, 'telefoneTipo', v_tipo));
end $f$;
revoke all on function public.ifood_ship_payload_b(uuid) from public, anon, authenticated;
grant execute on function public.ifood_ship_payload_b(uuid) to service_role;
