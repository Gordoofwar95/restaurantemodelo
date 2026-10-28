-- 62 · iFood FINANCEIRO completo (módulo Financial do iFood, exigido na homologação). Versão 1.15 (25/10/2026).
-- Feito pela documentação oficial do iFood (PDFs do portal do desenvolvedor, 25/10/2026):
--   API Sales (vendas), API Financial Events (lançamentos), API Settlement (repasses/títulos), API Anticipation (antecipações D+1/D+7)
--   e API Reconciliation On-Demand (arquivo mensal de conciliação em CSV).
-- Como funciona: o ifood-sync (que já roda a cada 30 s) busca os dados aos poucos, por uma FILA de tarefas (no máximo algumas
-- chamadas por rodada: bem abaixo do limite de 1000/min do iFood), com paginação, limites de período (vendas: 7 dias por vez;
-- lançamentos: 7 dias por vez, máx. 33), renovação do token, espera em 429 e o cabeçalho de homologação quando ligado.
-- Tudo fica guardado aqui (só leitura no app) e a tela Administrador → Dinheiro → "iFood: vendas e repasses" mostra.
-- Pode rodar de novo sem erro. Desfazer: drop das tabelas ifood_fin_* e das funções *ifood_fin*.

create or replace function pg_temp.tb_trocar1(d text, a text, b text) returns text language plpgsql as $f$
declare n int := (length(d) - length(replace(d, a, ''))) / greatest(length(a), 1);
begin
  if n <> 1 then raise exception '62: trecho esperado apareceu % vez(es): %', n, left(a, 90); end if;
  return replace(d, a, b);
end $f$;

-- ---------------------------------------------------------------- tabelas
create table if not exists public.ifood_fin_tarefas (
  id bigserial primary key,
  api text not null check (api in ('vendas', 'eventos', 'repasses', 'antecipacoes', 'conciliacao_pedir', 'conciliacao_status')),
  ini date, fim date, competencia text,
  pagina int not null default 0,
  estado text not null default 'pendente' check (estado in ('pendente', 'ok', 'sem_dados', 'erro')),
  tentativas int not null default 0,
  proxima timestamptz not null default now(),
  status_http int, erro text,
  origem text not null default 'auto' check (origem in ('auto', 'manual')),
  lote uuid,
  dados jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  feito_em timestamptz);
create index if not exists ix_ifood_fin_tarefas_pend on public.ifood_fin_tarefas (proxima) where estado = 'pendente';
create index if not exists ix_ifood_fin_tarefas_lote on public.ifood_fin_tarefas (lote);

create table if not exists public.ifood_fin_vendas (
  id text primary key,                         -- sales.id = id do pedido no iFood
  short_id text, criado_em timestamptz, dia date, status text, tipo text, categoria text, canal text,
  bruto_itens numeric not null default 0, taxa_entrega numeric not null default 0, taxa_servico numeric not null default 0,
  beneficios jsonb, entrega jsonb, pagamentos jsonb, lancamentos jsonb,
  saldo numeric,                               -- billingSummary.saleBalance: líquido desta venda
  saldo_confere boolean,                       -- saleBalance = soma dos billingEntries (± R$ 0,01)
  comissao numeric not null default 0, taxas numeric not null default 0, subsidios numeric not null default 0,
  venda_id uuid,
  atualizado_em timestamptz not null default now());
create index if not exists ix_ifood_fin_vendas_dia on public.ifood_fin_vendas (dia);

create table if not exists public.ifood_fin_eventos (
  chave text primary key,
  nome text, descricao text, produto text, gatilho text, data_hora timestamptz, dia date, competencia text,
  periodo_ini date, periodo_fim date, ref_tipo text, ref_id text, ref_data timestamptz,
  impacto boolean not null default false, valor numeric not null default 0, base numeric, percentual numeric,
  parcela text, parcela_data date, repasse_esperado date, metodo text, bandeira text, responsavel text,
  atualizado_em timestamptz not null default now());
create index if not exists ix_ifood_fin_eventos_dia on public.ifood_fin_eventos (dia);
create index if not exists ix_ifood_fin_eventos_periodo on public.ifood_fin_eventos (periodo_ini);
create index if not exists ix_ifood_fin_eventos_ref on public.ifood_fin_eventos (ref_id);

create table if not exists public.ifood_fin_liquidacoes (
  id text primary key,                         -- closingItems.id (título)
  periodo_ini date, periodo_fim date, tipo text, produto text, valor numeric not null default 0, status text,
  transacao text, banco jsonb, banco_ok boolean, data_pagamento date, origem jsonb,
  atualizado_em timestamptz not null default now());
create index if not exists ix_ifood_fin_liq_periodo on public.ifood_fin_liquidacoes (periodo_ini);

create table if not exists public.ifood_fin_antecipacoes (
  chave text primary key,
  periodo_ini date, periodo_fim date, tipo text, valor_original numeric, taxa_pct numeric, taxa_valor numeric,
  valor_antecipado numeric, status text, banco jsonb, data_original date, data_antecipada date,
  atualizado_em timestamptz not null default now());

create table if not exists public.ifood_fin_consultas (       -- cada busca no iFood (para a tela mostrar "atualizado há..." e o último erro)
  api text primary key, em timestamptz, ok_em timestamptz, ok boolean, status_http int, mensagem text, saldo numeric, qtd int, ini date, fim date);

create table if not exists public.ifood_fin_conciliacao (
  competencia text primary key check (competencia ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  request_id text, estado text not null default 'solicitado' check (estado in ('solicitado', 'processando', 'pronto', 'erro')),
  pedido_em timestamptz not null default now(), pedido_por text, concluido_em timestamptz, erro text,
  arquivo_gz bytea, bytes int, linhas int, resumo jsonb);

create table if not exists public.ifood_fin_alertas (chave text primary key, em timestamptz not null default now());

alter table public.ifood_estado add column if not exists fin_rotas jsonb not null default '{}'::jsonb;

do $do$
declare t text;
begin
  foreach t in array array['ifood_fin_tarefas', 'ifood_fin_vendas', 'ifood_fin_eventos', 'ifood_fin_liquidacoes', 'ifood_fin_antecipacoes',
                           'ifood_fin_consultas', 'ifood_fin_conciliacao', 'ifood_fin_alertas'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    execute format('grant all on table public.%I to service_role', t);
  end loop;
end $do$;
grant usage, select on sequence public.ifood_fin_tarefas_id_seq to service_role;

-- ---------------------------------------------------------------- ajudas
create or replace function public._ifood_fin_d(t text) returns date language plpgsql immutable as $f$
begin
  if t is null or btrim(t) = '' then return null; end if;
  return left(btrim(t), 10)::date;
exception when others then return null; end $f$;
create or replace function public._ifood_fin_ts(t text) returns timestamptz language plpgsql stable as $f$
begin
  if t is null or btrim(t) = '' then return null; end if;
  return btrim(t)::timestamptz;
exception when others then return null; end $f$;
create or replace function public._ifood_fin_bool(j jsonb) returns boolean language sql immutable as $f$
  select case when j is null then false when jsonb_typeof(j) = 'boolean' then (j #>> '{}')::boolean
              else upper(coalesce(j #>> '{}', '')) in ('TRUE', 'SIM', 'S', 'YES', '1') end $f$;
create or replace function public._ifood_fin_hoje() returns date language sql stable as $f$ select (now() at time zone 'America/Sao_Paulo')::date $f$;
create or replace function public._ifood_fin_segunda(d date) returns date language sql immutable as $f$ select d - (extract(isodow from d)::int - 1) $f$;

-- Dados do banco: guarda só o necessário para conferir e mostrar (conta mascarada) e valida o formato (banco 3 dígitos, agência 1-5,
-- conta 1-20, dígito 1), como pede a documentação.
create or replace function public._ifood_fin_banco(a jsonb) returns jsonb language plpgsql immutable as $f$
declare n text := a->>'bankNumber'; ag text := a->>'branchCode'; c text := a->>'accountNumber'; dg text := a->>'accountDigit'; prob text[] := '{}';
begin
  if a is null or jsonb_typeof(a) <> 'object' or a = '{}'::jsonb then return null; end if;
  if coalesce(n, '') !~ '^\d{3}$' then prob := prob || 'banco'; end if;
  if coalesce(ag, '') !~ '^\d{1,5}$' then prob := prob || 'agência'; end if;
  if coalesce(c, '') !~ '^\d{1,20}$' then prob := prob || 'conta'; end if;
  if coalesce(dg, '') !~ '^[0-9Xx]$' then prob := prob || 'dígito'; end if;
  return jsonb_build_object('nome', a->>'bankName', 'numero', n, 'agencia', ag,
    'conta', case when c is null then null else '•••' || right(c, 4) || coalesce('-' || dg, '') end,
    'documento', case when a->>'documentNumber' is null then null else '•••' || right(a->>'documentNumber', 4) end,
    'ok', cardinality(prob) = 0, 'problemas', to_jsonb(prob));
end $f$;

-- ---------------------------------------------------------------- fila de tarefas
create or replace function public._ifood_fin_enfileirar(p_api text, p_ini date, p_fim date, p_comp text, p_origem text, p_lote uuid)
 returns void language plpgsql security definer set search_path to 'public' as $f$
begin
  if exists (select 1 from ifood_fin_tarefas where estado = 'pendente' and api = p_api and ini is not distinct from p_ini
               and fim is not distinct from p_fim and competencia is not distinct from p_comp) then
    if p_lote is not null then update ifood_fin_tarefas set lote = coalesce(lote, p_lote), origem = p_origem
      where estado = 'pendente' and api = p_api and ini is not distinct from p_ini and fim is not distinct from p_fim and competencia is not distinct from p_comp; end if;
    return;
  end if;
  insert into ifood_fin_tarefas (api, ini, fim, competencia, origem, lote, pagina)
  values (p_api, p_ini, p_fim, p_comp, p_origem, p_lote, case when p_api = 'vendas' then 0 else 1 end);
end $f$;

-- Divide um período em pedaços de até 7 dias (o iFood recomenda semanas; lançamentos aceitam no máximo 33 dias).
create or replace function public._ifood_fin_enfileirar_periodo(p_ini date, p_fim date, p_origem text, p_lote uuid)
 returns int language plpgsql security definer set search_path to 'public' as $f$
declare d date := p_ini; n int := 0;
begin
  while d <= p_fim loop
    perform _ifood_fin_enfileirar('vendas', d, least(d + 6, p_fim), null, p_origem, p_lote);
    perform _ifood_fin_enfileirar('eventos', d, least(d + 6, p_fim), null, p_origem, p_lote);
    n := n + 2; d := d + 7;
  end loop;
  perform _ifood_fin_enfileirar('repasses', p_ini, p_fim, null, p_origem, p_lote);
  perform _ifood_fin_enfileirar('antecipacoes', p_ini, p_fim, null, p_origem, p_lote);
  return n + 2;
end $f$;

-- Automático (a cada 6 h, pelo ifood-sync): últimas 2 semanas de apuração completas + a semana atual; repasses e antecipações de 5 semanas.
-- Também apaga o que tem mais de 13 meses (o arquivo mensal oficial fica no iFood) e tarefas antigas.
create or replace function public.ifood_fin_agendar_auto() returns int
 language plpgsql security definer set search_path to 'public' as $f$
declare h date := _ifood_fin_hoje(); s date := _ifood_fin_segunda(_ifood_fin_hoje()); n int;
begin
  n := _ifood_fin_enfileirar_periodo(s - 14, h, 'auto', null);
  perform _ifood_fin_enfileirar('repasses', s - 35, h, null, 'auto', null);
  perform _ifood_fin_enfileirar('antecipacoes', s - 35, h, null, 'auto', null);
  delete from ifood_fin_eventos where dia < h - interval '13 months';
  delete from ifood_fin_vendas where dia < h - interval '13 months';
  delete from ifood_fin_liquidacoes where periodo_fim < h - interval '13 months';
  delete from ifood_fin_antecipacoes where periodo_fim < h - interval '13 months';
  delete from ifood_fin_conciliacao where competencia < to_char(h - interval '13 months', 'YYYY-MM');
  delete from ifood_fin_tarefas where estado <> 'pendente' and criado_em < now() - interval '7 days';
  delete from ifood_fin_alertas where em < now() - interval '120 days';
  return n;
end $f$;

create or replace function public.ifood_fin_proximas(p_limite int default 6) returns jsonb
 language sql security definer set search_path to 'public' as $f$
  select jsonb_build_object('rotas', (select fin_rotas from ifood_estado where id), 'tarefas', coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'api', t.api, 'ini', t.ini, 'fim', t.fim, 'competencia', t.competencia, 'pagina', t.pagina,
           'tentativas', t.tentativas, 'dados', t.dados, 'requestId', nullif(c.request_id, ''), 'pedidoEm', c.pedido_em) order by t.proxima, t.id), '[]'::jsonb))
  from (select * from ifood_fin_tarefas where estado = 'pendente' and proxima <= now()
        order by (origem = 'manual') desc, proxima, id limit greatest(1, least(coalesce(p_limite, 6), 20))) t
  left join ifood_fin_conciliacao c on c.competencia = t.competencia
$f$;
-- (até a 1.15 de testes devolvia só a lista; agora devolve {rotas, tarefas})

-- Resultado de uma tarefa. p_estado: ok | sem_dados | erro | pendente (= tenta de novo daqui a p_espera_seg) | pagina (= próxima página já)
create or replace function public.ifood_fin_tarefa_fim(p_id bigint, p_estado text, p_status int default null, p_erro text default null,
   p_espera_seg int default 0, p_dados jsonb default null) returns void
 language plpgsql security definer set search_path to 'public' as $f$
begin
  if p_estado = 'pagina' then
    update ifood_fin_tarefas set pagina = pagina + 1, proxima = now(), status_http = p_status, erro = null, dados = dados || coalesce(p_dados, '{}') where id = p_id;
  elsif p_estado = 'pendente' then
    update ifood_fin_tarefas set tentativas = tentativas + 1, proxima = now() + make_interval(secs => greatest(10, coalesce(p_espera_seg, 60))),
      status_http = p_status, erro = left(p_erro, 400), dados = dados || coalesce(p_dados, '{}') where id = p_id;
  else
    update ifood_fin_tarefas set estado = case when p_estado in ('ok', 'sem_dados', 'erro') then p_estado else 'erro' end, feito_em = now(),
      status_http = p_status, erro = left(p_erro, 400), dados = dados || coalesce(p_dados, '{}') where id = p_id;
  end if;
end $f$;

create or replace function public.ifood_fin_consulta(p_api text, p_ok boolean, p_status int default null, p_msg text default null,
   p_saldo numeric default null, p_qtd int default null, p_ini date default null, p_fim date default null) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare v_ant boolean;
begin
  select ok into v_ant from ifood_fin_consultas where api = p_api;
  insert into ifood_fin_consultas (api, em, ok_em, ok, status_http, mensagem, saldo, qtd, ini, fim)
  values (p_api, now(), case when p_ok then now() end, p_ok, p_status, left(p_msg, 400), p_saldo, p_qtd, p_ini, p_fim)
  on conflict (api) do update set em = now(), ok_em = case when p_ok then now() else ifood_fin_consultas.ok_em end, ok = p_ok,
     status_http = p_status, mensagem = left(p_msg, 400), saldo = coalesce(p_saldo, ifood_fin_consultas.saldo),
     qtd = coalesce(p_qtd, ifood_fin_consultas.qtd), ini = coalesce(p_ini, ifood_fin_consultas.ini), fim = coalesce(p_fim, ifood_fin_consultas.fim);
  if not p_ok and v_ant is distinct from false then      -- registra só quando muda de "ok" para "erro" (sem encher o log a cada 6 h)
    perform _integ_log('ifood', 'aviso', 'Financeiro do iFood (' || p_api || ') não carregou: ' || coalesce(p_status::text, '') || ' ' || left(coalesce(p_msg, ''), 200));
  end if;
end $f$;

create or replace function public.ifood_fin_rota(p_api text, p_rota text) returns void
 language sql security definer set search_path to 'public' as $f$
  update ifood_estado set fin_rotas = fin_rotas || jsonb_build_object(p_api, p_rota) where id
$f$;

-- ---------------------------------------------------------------- gravação (vem do ifood-sync)
create or replace function public.ifood_fin_vendas_gravar(p_lista jsonb) returns int
 language plpgsql security definer set search_path to 'public' as $f$
declare s jsonb; n int := 0; v_soma numeric; v_saldo numeric; v_com numeric; v_tax numeric; v_sub numeric; v_venda uuid; v_usar boolean;
begin
  v_usar := coalesce((select (config->>'comissaoFinanceiro')::boolean from integracoes_config where provedor = 'ifood'), false);
  for s in select value from jsonb_array_elements(coalesce(p_lista, '[]'::jsonb)) loop
    if nullif(s->>'id', '') is null then continue; end if;
    select coalesce(sum(_ifood_n(e->'value')), 0),
           coalesce(sum(abs(_ifood_n(e->'value'))) filter (where _ifood_n(e->'value') < 0 and upper(e->>'name') like '%COMMISSION%'), 0),
           coalesce(sum(abs(_ifood_n(e->'value'))) filter (where _ifood_n(e->'value') < 0 and upper(e->>'name') not like '%COMMISSION%'), 0),
           coalesce(sum(_ifood_n(e->'value')) filter (where upper(e->>'name') like '%SUBSID%'), 0)
      into v_soma, v_com, v_tax, v_sub
      from jsonb_array_elements(case when jsonb_typeof(s->'billingSummary'->'billingEntries') = 'array' then s->'billingSummary'->'billingEntries' else '[]'::jsonb end) e;
    v_saldo := case when s->'billingSummary' ? 'saleBalance' then _ifood_n(s->'billingSummary'->'saleBalance') end;
    select venda_id into v_venda from ifood_pedidos where pedido_ifood = s->>'id';
    insert into ifood_fin_vendas (id, short_id, criado_em, dia, status, tipo, categoria, canal, bruto_itens, taxa_entrega, taxa_servico,
       beneficios, entrega, pagamentos, lancamentos, saldo, saldo_confere, comissao, taxas, subsidios, venda_id, atualizado_em)
    values (s->>'id', s->>'shortId', _ifood_fin_ts(s->>'createdAt'), (_ifood_fin_ts(s->>'createdAt') at time zone 'America/Sao_Paulo')::date,
       s->>'currentStatus', s->>'type', s->>'category', s->>'salesChannel',
       _ifood_n(s->'saleGrossValue'->'bag'), _ifood_n(s->'saleGrossValue'->'deliveryFee'), _ifood_n(s->'saleGrossValue'->'serviceFee'),
       s->'benefits', jsonb_strip_nulls(jsonb_build_object('tipo', s->'delivery'->>'type', 'logistica', s->'delivery'->'deliveryParameters'->>'logisticProvider',
           'bruto', s->'delivery'->'prices'->'grossValue', 'desconto', s->'delivery'->'prices'->'discount', 'liquido', s->'delivery'->'prices'->'netValue')),
       (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('metodo', m->>'method', 'tipo', m->>'type', 'valor', m->'value', 'bandeira', m->'card'->>'brand',
           'carteira', m->'wallet'->>'name', 'responsavel', m->>'liability', 'parcelas', m->'installment'->'maxInstallments', 'troco', m->'cash'->'changeFor', 'reembolso', m->>'refundType')))
          from jsonb_array_elements(case when jsonb_typeof(s->'payments'->'methods') = 'array' then s->'payments'->'methods' else '[]'::jsonb end) m),
       s->'billingSummary'->'billingEntries', v_saldo,
       case when v_saldo is null then null else abs(v_saldo - v_soma) <= 0.011 end,
       v_com, v_tax, v_sub, v_venda, now())
    on conflict (id) do update set short_id = excluded.short_id, criado_em = excluded.criado_em, dia = excluded.dia, status = excluded.status,
       tipo = excluded.tipo, categoria = excluded.categoria, canal = excluded.canal, bruto_itens = excluded.bruto_itens, taxa_entrega = excluded.taxa_entrega,
       taxa_servico = excluded.taxa_servico, beneficios = excluded.beneficios, entrega = excluded.entrega, pagamentos = excluded.pagamentos,
       lancamentos = excluded.lancamentos, saldo = excluded.saldo, saldo_confere = excluded.saldo_confere, comissao = excluded.comissao,
       taxas = excluded.taxas, subsidios = excluded.subsidios, venda_id = coalesce(excluded.venda_id, ifood_fin_vendas.venda_id), atualizado_em = now();
    -- opção (desligada de fábrica): usar a comissão + taxas REAIS do iFood nas taxas da venda do sistema (relatórios e DRE)
    if v_usar and v_venda is not null and (v_com + v_tax) > 0 then
      update ifood_pedidos set comissao = v_com + v_tax where pedido_ifood = s->>'id';
      perform _ifood_aplicar_comissao(v_venda, v_com + v_tax);
    end if;
    n := n + 1;
  end loop;
  return n;
end $f$;

create or replace function public.ifood_fin_eventos_gravar(p_ini date, p_fim date, p_primeira boolean, p_lista jsonb) returns int
 language plpgsql security definer set search_path to 'public' as $f$
declare n int;
begin
  if p_primeira then delete from ifood_fin_eventos where dia between p_ini and p_fim; end if;   -- a busca refaz o período inteiro
  insert into ifood_fin_eventos (chave, nome, descricao, produto, gatilho, data_hora, dia, competencia, periodo_ini, periodo_fim, ref_tipo, ref_id, ref_data,
     impacto, valor, base, percentual, parcela, parcela_data, repasse_esperado, metodo, bandeira, responsavel, atualizado_em)
  select md5(x.e::text || '#' || x.ord), x.e->>'name', x.e->>'description', x.e->>'product', x.e->>'trigger', _ifood_fin_ts(x.e->>'dateTime'),
     coalesce((_ifood_fin_ts(x.e->>'dateTime') at time zone 'America/Sao_Paulo')::date, _ifood_fin_d(x.e->'period'->>'beginDate')),
     x.e->>'competence', _ifood_fin_d(x.e->'period'->>'beginDate'), _ifood_fin_d(x.e->'period'->>'endDate'),
     x.e->'reference'->>'type', x.e->'reference'->>'id', _ifood_fin_ts(x.e->'reference'->>'date'),
     _ifood_fin_bool(x.e->'hasTransferImpact'), _ifood_n(x.e->'amount'),
     case when x.e->'billing' ? 'baseValue' then _ifood_n(x.e->'billing'->'baseValue') end,
     case when x.e->'billing' ? 'feePercentage' then _ifood_n(x.e->'billing'->'feePercentage') end,
     x.e->'billing'->'installments'->>'reference', _ifood_fin_d(x.e->'billing'->'installments'->>'referenceDate'),
     _ifood_fin_d(x.e->'settlement'->>'expectedDate'), x.e->'payment'->>'method', x.e->'payment'->>'brand', x.e->'payment'->>'liability', now()
  from (select e, row_number() over (partition by e::text order by o) ord
          from jsonb_array_elements(coalesce(p_lista, '[]'::jsonb)) with ordinality a(e, o) where jsonb_typeof(e) = 'object') x
  on conflict (chave) do update set atualizado_em = now(), impacto = excluded.impacto, valor = excluded.valor, repasse_esperado = excluded.repasse_esperado;
  get diagnostics n = row_count;
  return n;
end $f$;

-- Repasses (títulos). BOLETO = a loja deve ao iFood: entra NEGATIVO na conferência.
create or replace function public.ifood_fin_liquidacoes_gravar(p_resp jsonb) returns int
 language plpgsql security definer set search_path to 'public' as $f$
declare p jsonb; c jsonb; n int := 0; v_id text;
begin
  for p in select value from jsonb_array_elements(case when jsonb_typeof(p_resp->'settlements') = 'array' then p_resp->'settlements' else '[]'::jsonb end) loop
    for c in select value from jsonb_array_elements(case when jsonb_typeof(p->'closingItems') = 'array' then p->'closingItems' else '[]'::jsonb end) loop
      v_id := coalesce(nullif(c->>'id', ''), md5(p::text || c::text));
      insert into ifood_fin_liquidacoes (id, periodo_ini, periodo_fim, tipo, produto, valor, status, transacao, banco, banco_ok, data_pagamento, origem, atualizado_em)
      values (v_id, _ifood_fin_d(p->>'startDateCalculation'), _ifood_fin_d(p->>'endDateCalculation'), c->>'type', c->>'product', _ifood_n(c->'amount'),
              c->>'status', c->>'transactionId', _ifood_fin_banco(c->'accountDetails'), (_ifood_fin_banco(c->'accountDetails')->>'ok')::boolean,
              _ifood_fin_d(c->>'paymentDate'), nullif(c->'originDetails', 'null'::jsonb), now())
      on conflict (id) do update set periodo_ini = excluded.periodo_ini, periodo_fim = excluded.periodo_fim, tipo = excluded.tipo, produto = excluded.produto,
         valor = excluded.valor, status = excluded.status, transacao = excluded.transacao, banco = excluded.banco, banco_ok = excluded.banco_ok,
         data_pagamento = excluded.data_pagamento, origem = excluded.origem, atualizado_em = now();
      if upper(coalesce(c->>'status', '')) = 'FAILED' and not exists (select 1 from ifood_fin_alertas where chave = 'liq-' || v_id) then
        insert into ifood_fin_alertas (chave) values ('liq-' || v_id);
        begin perform _push_admins('iFood: repasse com FALHA', 'O título ' || v_id || ' (' || coalesce(c->>'type', '') || ', R$ ' || _ifood_n(c->'amount') || ') falhou. Veja Dinheiro → iFood: vendas e repasses.', 'ifood-fin');
        exception when others then null; end;
      end if;
      n := n + 1;
    end loop;
  end loop;
  -- compatibilidade: o quadro antigo "A receber / recebido do iFood" continua alimentado pelos repasses pagos
  begin
    perform ifood_repasses_gravar((select coalesce(jsonb_agg(jsonb_build_object('id', id, 'paymentDate', data_pagamento, 'periodStart', periodo_ini, 'periodEnd', periodo_fim, 'amount', valor, 'orders', '[]'::jsonb)), '[]'::jsonb)
                                   from ifood_fin_liquidacoes where upper(coalesce(tipo, '')) = 'REPASSE' and upper(coalesce(status, '')) = 'SUCCEED'));
  exception when others then null; end;
  return n;
end $f$;

create or replace function public.ifood_fin_antecipacoes_gravar(p_resp jsonb) returns int
 language plpgsql security definer set search_path to 'public' as $f$
declare p jsonb; c jsonb; n int := 0; v_k text;
begin
  for p in select value from jsonb_array_elements(case when jsonb_typeof(p_resp->'settlements') = 'array' then p_resp->'settlements' else '[]'::jsonb end) loop
    for c in select value from jsonb_array_elements(case when jsonb_typeof(p->'closingItems') = 'array' then p->'closingItems' else '[]'::jsonb end) loop
      v_k := coalesce(nullif(c->>'id', ''), md5(coalesce(p->>'startDateCalculation', '') || (c - 'accountDetails' - 'status')::text));
      insert into ifood_fin_antecipacoes (chave, periodo_ini, periodo_fim, tipo, valor_original, taxa_pct, taxa_valor, valor_antecipado, status, banco, data_original, data_antecipada, atualizado_em)
      values (v_k, _ifood_fin_d(p->>'startDateCalculation'), _ifood_fin_d(p->>'endDateCalculation'), c->>'type', _ifood_n(c->'originalPaymentAmount'),
              _ifood_n(c->'feePercentage'), _ifood_n(c->'feeAmount'), _ifood_n(c->'anticipatedPaymentAmount'), c->>'status',
              _ifood_fin_banco(c->'accountDetails'), _ifood_fin_d(c->>'originalPaymentDate'), _ifood_fin_d(c->>'anticipatedPaymentDate'), now())
      on conflict (chave) do update set status = excluded.status, banco = excluded.banco, valor_antecipado = excluded.valor_antecipado,
         taxa_valor = excluded.taxa_valor, taxa_pct = excluded.taxa_pct, data_antecipada = excluded.data_antecipada, atualizado_em = now();
      if upper(coalesce(c->>'status', '')) = 'FAILED' and not exists (select 1 from ifood_fin_alertas where chave = 'ant-' || v_k) then
        insert into ifood_fin_alertas (chave) values ('ant-' || v_k);
        begin perform _push_admins('iFood: antecipação com FALHA', 'Uma antecipação de R$ ' || _ifood_n(c->'originalPaymentAmount') || ' falhou. Veja Dinheiro → iFood: vendas e repasses.', 'ifood-fin');
        exception when others then null; end;
      end if;
      n := n + 1;
    end loop;
  end loop;
  return n;
end $f$;

create or replace function public.ifood_fin_conciliacao_estado(p_competencia text, p_estado text, p_request_id text default null, p_erro text default null) returns void
 language plpgsql security definer set search_path to 'public' as $f$
begin
  update ifood_fin_conciliacao set estado = p_estado, request_id = coalesce(p_request_id, request_id), erro = left(p_erro, 400),
     concluido_em = case when p_estado = 'erro' then now() else concluido_em end
   where competencia = p_competencia;
end $f$;

create or replace function public.ifood_fin_conciliacao_pronta(p_competencia text, p_b64 text, p_linhas int, p_resumo jsonb) returns void
 language plpgsql security definer set search_path to 'public' as $f$
begin
  update ifood_fin_conciliacao set estado = 'pronto', concluido_em = now(), erro = null, arquivo_gz = decode(p_b64, 'base64'),
     bytes = length(decode(p_b64, 'base64')), linhas = p_linhas, resumo = p_resumo
   where competencia = p_competencia;
end $f$;

do $do$
declare f text;
begin
  foreach f in array array['_ifood_fin_enfileirar(text,date,date,text,text,uuid)', '_ifood_fin_enfileirar_periodo(date,date,text,uuid)',
     'ifood_fin_agendar_auto()', 'ifood_fin_proximas(integer)', 'ifood_fin_tarefa_fim(bigint,text,integer,text,integer,jsonb)',
     'ifood_fin_consulta(text,boolean,integer,text,numeric,integer,date,date)', 'ifood_fin_rota(text,text)', 'ifood_fin_vendas_gravar(jsonb)',
     'ifood_fin_eventos_gravar(date,date,boolean,jsonb)', 'ifood_fin_liquidacoes_gravar(jsonb)', 'ifood_fin_antecipacoes_gravar(jsonb)',
     'ifood_fin_conciliacao_estado(text,text,text,text)', 'ifood_fin_conciliacao_pronta(text,text,integer,jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
    execute 'grant execute on function public.' || f || ' to service_role';
  end loop;
end $do$;

-- ---------------------------------------------------------------- conferência semanal (Vendas × Lançamentos × Repasse)
-- Regra do iFood: repasse da semana (seg–dom) = soma dos lançamentos COM impacto no repasse (tolerância 0,01%).
create or replace function public._ifood_fin_semanas(p_qtd int default 8) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare s date := _ifood_fin_segunda(_ifood_fin_hoje()); i int; d date; v jsonb := '[]'::jsonb;
  v_vendas numeric; v_nv int; v_ev numeric; v_ne int; v_sem numeric; v_liq numeric; v_nl int; v_tol numeric; v_situ text; v_dif numeric;
begin
  for i in 0..greatest(1, least(p_qtd, 26)) - 1 loop
    d := s - 7 * i;
    select sum(saldo), count(*) into v_vendas, v_nv from ifood_fin_vendas where dia between d and d + 6;
    select sum(valor) filter (where impacto), count(*), sum(valor) filter (where not impacto) into v_ev, v_ne, v_sem
      from ifood_fin_eventos where coalesce(periodo_ini, _ifood_fin_segunda(dia)) = d;
    select sum(case when upper(coalesce(tipo, '')) = 'BOLETO' then -abs(valor) else valor end), count(*) into v_liq, v_nl
      from ifood_fin_liquidacoes where periodo_ini = d;
    v_dif := null; v_situ := 'sem_dados';
    if v_ne > 0 and v_nl > 0 then
      v_dif := round(coalesce(v_ev, 0) - coalesce(v_liq, 0), 2);
      v_tol := greatest(0.01, abs(coalesce(v_liq, 0)) * 0.0001);
      v_situ := case when abs(v_dif) <= v_tol then 'confere' else 'diferenca' end;
    end if;
    -- semana ainda aberta (ou apurada hoje, segunda): o iFood só fecha a apuração na segunda-feira seguinte (dados completos à tarde)
    if d + 7 >= _ifood_fin_hoje() and v_situ <> 'confere' then v_situ := 'aberta';
    elsif v_situ = 'sem_dados' and v_ne > 0 then v_situ := 'sem_repasse'; end if;
    v := v || jsonb_build_object('ini', d, 'fim', d + 6, 'vendas', v_vendas, 'qtdVendas', v_nv, 'lancamentos', v_ev, 'semImpacto', v_sem, 'qtdLancamentos', v_ne,
                                 'repasse', v_liq, 'qtdTitulos', v_nl, 'diferenca', v_dif, 'situacao', v_situ,
                                 'vendasDif', case when v_nv > 0 and v_ne > 0 then round(coalesce(v_vendas, 0) - coalesce(v_ev, 0), 2) end);
  end loop;
  return v;
end $f$;

create or replace function public.ifood_fin_alertar_semanas() returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare w jsonb;
begin
  for w in select value from jsonb_array_elements(_ifood_fin_semanas(6)) loop
    if w->>'situacao' = 'diferenca' and abs((w->>'diferenca')::numeric) > greatest(1, abs(coalesce((w->>'repasse')::numeric, 0)) * 0.01)
       and not exists (select 1 from ifood_fin_alertas where chave = 'sem-' || (w->>'ini')) then
      insert into ifood_fin_alertas (chave) values ('sem-' || (w->>'ini'));
      perform _integ_log('ifood', 'aviso', 'Financeiro do iFood: semana ' || (w->>'ini') || ' com diferença de R$ ' || (w->>'diferenca') || ' entre lançamentos e repasse.');
      begin perform _push_admins('iFood: repasse não confere', 'Semana de ' || to_char((w->>'ini')::date, 'DD/MM') || ': diferença de R$ ' || replace((w->>'diferenca'), '.', ',') || ' entre os lançamentos e o repasse. Veja Dinheiro → iFood: vendas e repasses.', 'ifood-fin');
      exception when others then null; end;
    end if;
  end loop;
end $f$;
revoke all on function public.ifood_fin_alertar_semanas() from public, anon, authenticated;
grant execute on function public.ifood_fin_alertar_semanas() to service_role;
revoke all on function public._ifood_fin_semanas(int) from public, anon, authenticated;

-- ---------------------------------------------------------------- tela (Admin)
create or replace function public.api_ifood_fin_dados(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare v_aba text := coalesce(p->>'aba', 'painel'); v_ini date := coalesce(_ifood_fin_d(p->>'ini'), _ifood_fin_hoje() - 30);
  v_fim date := coalesce(_ifood_fin_d(p->>'fim'), _ifood_fin_hoje()); v_busca text := lower(btrim(coalesce(p->>'busca', '')));
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_fim < v_ini then return _falha('A data final precisa ser depois da inicial.'); end if;
  if v_aba = 'painel' then
    return jsonb_build_object('ok', true,
      'ligado', _integracao_ligada('ifood'),
      'homologacao', coalesce((select (config->>'modoHomologacao')::boolean from integracoes_config where provedor = 'ifood'), false),
      'comissaoFinanceiro', coalesce((select (config->>'comissaoFinanceiro')::boolean from integracoes_config where provedor = 'ifood'), false),
      'modulo', (select jsonb_build_object('status', ultimo_status, 'ultimoOk', ultimo_ok, 'ultimoErroEm', ultimo_erro_em, 'msg', ultima_msg) from ifood_modulos where modulo = 'financial'),
      'consultas', coalesce((select jsonb_object_agg(api, jsonb_build_object('em', em, 'okEm', ok_em, 'ok', ok, 'status', status_http, 'msg', mensagem, 'saldo', saldo, 'qtd', qtd, 'ini', ini, 'fim', fim)) from ifood_fin_consultas), '{}'::jsonb),
      'pendentes', (select count(*) from ifood_fin_tarefas where estado = 'pendente'),
      'semanas', _ifood_fin_semanas(coalesce((p->>'semanas')::int, 8)),
      'totais', (select jsonb_build_object('vendas', count(*), 'semSaldoConferido', count(*) filter (where saldo_confere = false)) from ifood_fin_vendas where dia between v_ini and v_fim));
  elsif v_aba = 'vendas' then
    return jsonb_build_object('ok', true, 'ini', v_ini, 'fim', v_fim,
      'itens', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'numero', v.short_id, 'em', v.criado_em, 'status', v.status, 'canal', v.canal,
           'bruto', v.bruto_itens + v.taxa_entrega + v.taxa_servico, 'itens', v.bruto_itens, 'entrega', v.taxa_entrega, 'servico', v.taxa_servico,
           'comissao', v.comissao, 'taxas', v.taxas, 'subsidios', v.subsidios, 'liquido', v.saldo, 'confere', v.saldo_confere,
           'pagamentos', v.pagamentos, 'lancamentos', v.lancamentos, 'beneficios', v.beneficios, 'entregaInfo', v.entrega,
           'vendaId', v.venda_id, 'pedidoLocal', (select numero_pedido from vendas where id = v.venda_id)) order by v.criado_em desc)
         from (select * from ifood_fin_vendas where dia between v_ini and v_fim
                 and (v_busca = '' or lower(coalesce(short_id, '')) like '%' || v_busca || '%' or lower(id) like v_busca || '%')
               order by criado_em desc limit 400) v), '[]'::jsonb),
      'soma', (select jsonb_build_object('qtd', count(*), 'bruto', sum(bruto_itens + taxa_entrega + taxa_servico), 'comissao', sum(comissao), 'taxas', sum(taxas),
           'subsidios', sum(subsidios), 'liquido', sum(saldo)) from ifood_fin_vendas where dia between v_ini and v_fim));
  elsif v_aba = 'eventos' then
    return jsonb_build_object('ok', true, 'ini', v_ini, 'fim', v_fim,
      'itens', coalesce((select jsonb_agg(jsonb_build_object('nome', nome, 'descricao', descricao, 'gatilho', gatilho, 'produto', produto, 'em', data_hora, 'dia', dia,
           'competencia', competencia, 'periodoIni', periodo_ini, 'periodoFim', periodo_fim, 'refTipo', ref_tipo, 'refId', ref_id, 'impacto', impacto, 'valor', valor,
           'base', base, 'percentual', percentual, 'parcela', parcela, 'repasseEsperado', repasse_esperado, 'metodo', metodo, 'bandeira', bandeira,
           'responsavel', responsavel, 'pedido', (select short_id from ifood_fin_vendas fv where fv.id = e.ref_id)) order by data_hora desc nulls last)
         from (select * from ifood_fin_eventos where dia between v_ini and v_fim
                 and (coalesce(p->>'impacto', '') = '' or impacto = (p->>'impacto')::boolean)
                 and (v_busca = '' or lower(coalesce(nome, '') || ' ' || coalesce(descricao, '') || ' ' || coalesce(ref_id, '')) like '%' || v_busca || '%')
               order by data_hora desc nulls last limit 600) e), '[]'::jsonb),
      'soma', (select jsonb_build_object('qtd', count(*), 'comImpacto', sum(valor) filter (where impacto), 'semImpacto', sum(valor) filter (where not impacto),
           'creditos', sum(valor) filter (where impacto and valor > 0), 'debitos', sum(valor) filter (where impacto and valor < 0))
         from ifood_fin_eventos where dia between v_ini and v_fim));
  elsif v_aba = 'repasses' then
    return jsonb_build_object('ok', true, 'ini', v_ini, 'fim', v_fim,
      'saldoUltimaConsulta', (select saldo from ifood_fin_consultas where api = 'repasses'),
      'itens', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'periodoIni', periodo_ini, 'periodoFim', periodo_fim, 'tipo', tipo, 'produto', produto, 'valor', valor,
           'status', status, 'transacao', transacao, 'banco', banco, 'bancoOk', banco_ok, 'pagamento', data_pagamento, 'origem', origem) order by periodo_ini desc, data_pagamento desc nulls last)
         from ifood_fin_liquidacoes where coalesce(data_pagamento, periodo_fim) between v_ini and v_fim + 60 and coalesce(periodo_ini, v_ini) <= v_fim), '[]'::jsonb));
  elsif v_aba = 'antecipacoes' then
    return jsonb_build_object('ok', true, 'ini', v_ini, 'fim', v_fim,
      'itens', coalesce((select jsonb_agg(jsonb_build_object('tipo', tipo, 'periodoIni', periodo_ini, 'periodoFim', periodo_fim, 'original', valor_original, 'taxaPct', taxa_pct,
           'taxa', taxa_valor, 'antecipado', valor_antecipado, 'status', status, 'banco', banco, 'dataOriginal', data_original, 'dataAntecipada', data_antecipada,
           'diasAntes', data_original - data_antecipada) order by data_antecipada desc nulls last)
         from ifood_fin_antecipacoes where coalesce(data_antecipada, periodo_fim) between v_ini and v_fim + 60), '[]'::jsonb),
      'semPlano', (select status_http = 404 from ifood_fin_consultas where api = 'antecipacoes'));
  elsif v_aba = 'conciliacao' then
    return jsonb_build_object('ok', true,
      'itens', coalesce((select jsonb_agg(jsonb_build_object('competencia', competencia, 'estado', estado, 'pedidoEm', pedido_em, 'pedidoPor', pedido_por, 'concluidoEm', concluido_em,
           'erro', erro, 'bytes', bytes, 'linhas', linhas, 'resumo', resumo, 'temArquivo', arquivo_gz is not null,
           'eventosComImpacto', (select sum(valor) from ifood_fin_eventos e where e.impacto and coalesce(e.competencia, to_char(e.dia, 'YYYY-MM')) = c.competencia),
           'podePedirEm', case when estado in ('solicitado', 'processando') or pedido_em > now() - interval '6 hours' then pedido_em + interval '6 hours' end)
         order by competencia desc) from ifood_fin_conciliacao c), '[]'::jsonb),
      'meses', (select jsonb_agg(to_char(m, 'YYYY-MM') order by m desc) from generate_series(date_trunc('month', _ifood_fin_hoje()) - interval '12 months',
                 date_trunc('month', _ifood_fin_hoje()) - interval '1 month', interval '1 month') m));
  end if;
  return _falha('Aba desconhecida.');
end $f$;
revoke all on function public.api_ifood_fin_dados(jsonb) from public, anon;
grant execute on function public.api_ifood_fin_dados(jsonb) to authenticated, service_role;

create or replace function public.api_ifood_fin_acao(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare v_acao text := coalesce(p->>'acao', ''); v_ini date; v_fim date; v_lote uuid; n int; v_comp text; c record; v_eu text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select login into v_eu from usuarios where id = auth.uid();
  if v_acao = 'atualizar' then
    if not _integracao_ligada('ifood') then return _falha('A integração do iFood está desligada. Ligue em Integrações e contas → iFood.'); end if;
    v_ini := _ifood_fin_d(p->>'ini'); v_fim := least(coalesce(_ifood_fin_d(p->>'fim'), _ifood_fin_hoje()), _ifood_fin_hoje());
    if v_ini is null then return _falha('Escolha a data inicial.'); end if;
    if v_fim < v_ini then return _falha('A data final precisa ser depois da inicial.'); end if;
    if v_fim - v_ini > 92 then return _falha('Escolha no máximo 3 meses por vez (o iFood aceita até 90 dias nas vendas).'); end if;
    if (select count(*) from ifood_fin_tarefas where estado = 'pendente' and origem = 'manual') > 80 then return _falha('Já há muitas buscas na fila. Espere terminar.'); end if;
    v_lote := gen_random_uuid();
    n := _ifood_fin_enfileirar_periodo(v_ini, v_fim, 'manual', v_lote);
    return jsonb_build_object('ok', true, 'lote', v_lote, 'tarefas', n,
      'message', 'Buscando no iFood (' || n || ' consultas, de ' || to_char(v_ini, 'DD/MM') || ' a ' || to_char(v_fim, 'DD/MM') || '). Leva de 1 a ' || greatest(2, ceil(n / 10.0)::int) || ' minuto(s).');
  elsif v_acao = 'lote' then
    v_lote := nullif(p->>'lote', '')::uuid;
    return jsonb_build_object('ok', true,
      'total', (select count(*) from ifood_fin_tarefas where lote = v_lote),
      'feitas', (select count(*) from ifood_fin_tarefas where lote = v_lote and estado <> 'pendente'),
      'erros', coalesce((select jsonb_agg(jsonb_build_object('api', api, 'ini', ini, 'fim', fim, 'status', status_http, 'erro', erro)) from ifood_fin_tarefas where lote = v_lote and estado = 'erro'), '[]'::jsonb),
      'esperando', (select min(proxima) from ifood_fin_tarefas where lote = v_lote and estado = 'pendente'));
  elsif v_acao = 'conciliacao' then
    if not _integracao_ligada('ifood') then return _falha('A integração do iFood está desligada.'); end if;
    v_comp := p->>'competencia';
    if coalesce(v_comp, '') !~ '^\d{4}-(0[1-9]|1[0-2])$' then return _falha('Mês inválido (use AAAA-MM).'); end if;
    if to_date(v_comp || '-01', 'YYYY-MM-DD') >= date_trunc('month', _ifood_fin_hoje())::date then return _falha('O arquivo só existe para meses que já terminaram.'); end if;
    if to_date(v_comp || '-01', 'YYYY-MM-DD') < (date_trunc('month', _ifood_fin_hoje()) - interval '24 months')::date then return _falha('O iFood só gera arquivo dos últimos 24 meses.'); end if;
    select * into c from ifood_fin_conciliacao where competencia = v_comp;
    if found and c.estado in ('solicitado', 'processando') and c.pedido_em > now() - interval '35 minutes' then
      return jsonb_build_object('ok', true, 'message', 'Este mês já está sendo gerado pelo iFood. Aguarde.');
    end if;
    if found and c.pedido_em > now() - interval '6 hours' and c.estado = 'pronto' then
      return _falha('O iFood só gera de novo o mesmo mês 6 horas depois (pedido às ' || to_char(c.pedido_em at time zone 'America/Sao_Paulo', 'HH24:MI') || '). O arquivo atual continua disponível.');
    end if;
    insert into ifood_fin_conciliacao (competencia, estado, pedido_em, pedido_por, request_id, erro)
    values (v_comp, 'solicitado', now(), v_eu, null, null)
    on conflict (competencia) do update set estado = 'solicitado', pedido_em = now(), pedido_por = v_eu, erro = null,
       request_id = case when ifood_fin_conciliacao.pedido_em > now() - interval '6 hours' then nullif(ifood_fin_conciliacao.request_id, '') end;
    perform _ifood_fin_enfileirar(case when (select nullif(request_id, '') from ifood_fin_conciliacao where competencia = v_comp) is not null then 'conciliacao_status' else 'conciliacao_pedir' end,
                                  null, null, v_comp, 'manual', null);
    perform _auditar('iFood: arquivo de conciliação pedido', v_comp);
    return jsonb_build_object('ok', true, 'message', 'Pedido ao iFood. O arquivo de ' || v_comp || ' fica pronto em alguns minutos (até 30).');
  elsif v_acao = 'arquivo' then
    select * into c from ifood_fin_conciliacao where competencia = p->>'competencia';
    if not found or c.arquivo_gz is null then return _falha('Arquivo ainda não disponível.'); end if;
    perform _auditar('iFood: arquivo de conciliação baixado', c.competencia);
    return jsonb_build_object('ok', true, 'competencia', c.competencia, 'gz', encode(c.arquivo_gz, 'base64'), 'linhas', c.linhas);
  end if;
  return _falha('Ação desconhecida.');
end $f$;
revoke all on function public.api_ifood_fin_acao(jsonb) from public, anon;
grant execute on function public.api_ifood_fin_acao(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------- opção nova do iFood: comissão real nas vendas
do $do$
declare d text;
begin
  d := pg_get_functiondef('public.api_integracoes_config(jsonb)'::regprocedure);
  if position('''comissaoFinanceiro''' in d) > 0 then return; end if;
  d := pg_temp.tb_trocar1(d, '''acompanharEntrega'', ''modoHomologacao'')', '''acompanharEntrega'', ''modoHomologacao'', ''comissaoFinanceiro'')');
  execute d;
end $do$;
