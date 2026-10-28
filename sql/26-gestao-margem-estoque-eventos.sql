-- =====================================================================
-- 26 · MARGEM, HISTÓRICO DE PREÇOS, COMPRA SUGERIDA, CONTAS NA VÉSPERA E RENDIMENTO DE EVENTOS (18/10/2026)
--  1) preco_historico: todo preço/custo que muda em produto_precos fica registrado (quem, quando, antes e depois) + api_preco_historico.
--  2) api_margem_alerta / api_margem_config_salvar: produtos com margem abaixo do mínimo que o dono define, com preço sugerido; aviso semanal no celular.
--  3) api_estoque_sugestao: ingredientes no mínimo ou abaixo, com quantidade sugerida, fornecedor habitual e custo estimado.
--  4) Aviso de contas a pagar que vencem amanhã, hoje ou já venceram (dentro de alertas_sistema_cron).
--  5) Eventos: horas da equipe (manual ou pelo ponto) e rendimento por hora (api_evento_horas_salvar, api_evento_rendimento).
-- Aditivo. Pode rodar de novo sem erro. Rode DEPOIS do 25.
-- =====================================================================

-- 1) histórico de preços
create table if not exists public.preco_historico (
  id uuid primary key default gen_random_uuid(),
  produto_id uuid not null,
  forma_pagamento_id uuid,
  preco_antigo numeric(10,2),
  preco_novo numeric(10,2),
  custo_antigo numeric(10,2),
  custo_novo numeric(10,2),
  usuario_login text,
  quando timestamptz not null default now()
);
create index if not exists preco_historico_quando_idx on public.preco_historico (quando desc);
create index if not exists preco_historico_prod_idx on public.preco_historico (produto_id, quando desc);
alter table public.preco_historico enable row level security;

create or replace function public._preco_historico_gravar() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_login text;
begin
  if tg_op = 'UPDATE' and new.preco is not distinct from old.preco and new.custo is not distinct from old.custo then return new; end if;
  select u.login into v_login from usuarios u where u.id = auth.uid();
  insert into preco_historico (produto_id, forma_pagamento_id, preco_antigo, preco_novo, custo_antigo, custo_novo, usuario_login)
  values (new.produto_id, new.forma_pagamento_id, case when tg_op = 'UPDATE' then old.preco end, new.preco, case when tg_op = 'UPDATE' then old.custo end, new.custo, coalesce(v_login, 'sistema'));
  return new;
end $$;
create or replace trigger produto_precos_historico after insert or update on public.produto_precos for each row execute function public._preco_historico_gravar();

create or replace function public.api_preco_historico(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_busca text := nullif(btrim(coalesce(p->>'busca', '')), ''); v_lim int := least(greatest(coalesce(nullif(p->>'limite', '')::int, 100), 1), 500); v_l jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select coalesce(jsonb_agg(x order by (x->>'quando') desc), '[]'::jsonb) into v_l from (
    select jsonb_build_object('quando', h.quando, 'produto', pr.nome, 'forma', f.nome, 'precoAntigo', h.preco_antigo, 'precoNovo', h.preco_novo,
             'custoAntigo', h.custo_antigo, 'custoNovo', h.custo_novo, 'usuario', h.usuario_login,
             'percentual', case when coalesce(h.preco_antigo, 0) > 0 and h.preco_novo is not null then round((h.preco_novo - h.preco_antigo) / h.preco_antigo * 100, 1) end) x
      from preco_historico h join produtos pr on pr.id = h.produto_id left join formas_pagamento f on f.id = h.forma_pagamento_id
     where h.preco_antigo is not null and (v_busca is null or pr.nome ilike '%' || v_busca || '%')
     order by h.quando desc limit v_lim) s;
  return jsonb_build_object('ok', true, 'itens', v_l);
end $$;

-- 2) margem mínima
create or replace function public._margem_minima() returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select (valor #>> '{}')::numeric from sistema where chave = 'MARGEM_MINIMA'), 50)
$$;

create or replace function public._margem_baixa() returns table (produto_id uuid, nome text, forma text, preco numeric, custo numeric, margem numeric, sugerido numeric)
language sql stable security definer set search_path to 'public' as $$
  select distinct on (pr.id) pr.id, pr.nome, f.nome, pp.preco, pp.custo,
         round((pp.preco - pp.custo) / pp.preco * 100, 1),
         ceil(pp.custo / (1 - _margem_minima() / 100.0) * 10) / 10
    from produtos pr join produto_precos pp on pp.produto_id = pr.id left join formas_pagamento f on f.id = pp.forma_pagamento_id
   where pr.ativo and pp.preco > 0 and pp.custo > 0 and (pp.preco - pp.custo) / pp.preco * 100 < _margem_minima()
   order by pr.id, (pp.preco - pp.custo) / pp.preco
$$;

create or replace function public.api_margem_alerta(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_l jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select coalesce(jsonb_agg(jsonb_build_object('produtoId', m.produto_id, 'nome', m.nome, 'forma', m.forma, 'preco', m.preco, 'custo', m.custo, 'margem', m.margem, 'sugerido', m.sugerido) order by m.margem), '[]'::jsonb) into v_l from _margem_baixa() m;
  return jsonb_build_object('ok', true, 'margemMin', _margem_minima(), 'itens', v_l);
end $$;

create or replace function public.api_margem_config_salvar(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v numeric := _num(p->>'margemMin', -1);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v < 1 or v > 95 then return _falha('Informe uma margem mínima entre 1% e 95%.'); end if;
  insert into sistema (chave, valor, atualizado_em) values ('MARGEM_MINIMA', to_jsonb(v), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  perform _auditar('Margem mínima alterada', v || '%');
  return jsonb_build_object('ok', true, 'margemMin', v, 'message', 'Margem mínima de ' || replace(v::text, '.', ',') || '% salva.');
end $$;

-- 3) compra sugerida
create or replace function public.api_estoque_sugestao(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_l jsonb;
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'nome', q.ingrediente, 'unidade', q.un, 'atual', q.quantidade, 'minimo', q.quantidade_minima,
           'sugerido', q.sug, 'custoEstimado', round(q.sug * coalesce(q.custo_unitario, 0), 2),
           'fornecedorId', q.forn_id, 'fornecedor', q.forn, 'telefone', q.fone) order by coalesce(q.forn, 'zzz'), q.ingrediente), '[]'::jsonb) into v_l
  from (
    select e.id, e.ingrediente, e.unidade::text un, e.quantidade, e.quantidade_minima, e.custo_unitario,
           round(greatest(e.quantidade_minima * 2 - e.quantidade, e.quantidade_minima), 2) sug,
           ult.forn_id, ult.forn, ult.fone
      from estoque e
      left join lateral (select fo.id forn_id, fo.nome forn, fo.telefone fone from compra_itens ci join compras c on c.id = ci.compra_id join fornecedores fo on fo.id = c.fornecedor_id
                          where ci.ingrediente_id = e.id and c.status = 'Recebida' order by c.data desc, c.criado_em desc limit 1) ult on true
     where e.status = 'Ativo' and e.quantidade_minima > 0 and e.quantidade <= e.quantidade_minima) q;
  return jsonb_build_object('ok', true, 'itens', v_l);
end $$;

-- 5) eventos: horas da equipe e rendimento por hora
alter table public.eventos add column if not exists horas_equipe numeric(6,2);

create or replace function public.api_evento_horas_salvar(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_h numeric := case when coalesce(p->>'horas', '') = '' then null else _num(p->>'horas') end;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_h is not null and (v_h < 0 or v_h > 999) then return _falha('Horas inválidas.'); end if;
  update eventos set horas_equipe = v_h where id = v_id;
  if not found then return _falha('Evento não encontrado.'); end if;
  return jsonb_build_object('ok', true, 'message', case when v_h is null then 'Voltou a usar as horas do ponto.' else 'Horas da equipe salvas.' end);
end $$;

create or replace function public.api_evento_rendimento(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_l jsonb; v_fat numeric; v_h numeric;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select coalesce(jsonb_agg(x order by (x->>'data') desc), '[]'::jsonb) into v_l from (
    select jsonb_build_object('id', e.id, 'nome', e.nome, 'data', e.data, 'contratado', e.valor_contratado, 'resultado', e.resultado,
             'horas', h.horas, 'fonte', h.fonte,
             'resultadoHora', case when h.horas > 0 then round(e.resultado / h.horas, 2) end,
             'contratadoHora', case when h.horas > 0 then round(e.valor_contratado / h.horas, 2) end) x
      from eventos e
      cross join lateral (select coalesce(e.horas_equipe, nullif(pt.h, 0)) horas, case when e.horas_equipe is not null then 'manual' when coalesce(pt.h, 0) > 0 then 'ponto' end fonte
                            from (select sum(extract(epoch from (r.saida - r.entrada)) / 3600.0) h from ponto_registros r
                                   where not r.cancelado and r.saida is not null and (r.entrada at time zone 'America/Sao_Paulo')::date = e.data) pt) h
     where e.status in ('Confirmado', 'Em andamento', 'Concluído') and e.data <= v_hoje and e.data >= v_hoje - 365) s;
  -- referência: faturamento por hora trabalhada nos dias normais (sem evento) dos últimos 60 dias
  select coalesce(sum(r.h), 0) into v_h from (
    select sum(extract(epoch from (pr.saida - pr.entrada)) / 3600.0) h from ponto_registros pr
     where not pr.cancelado and pr.saida is not null and (pr.entrada at time zone 'America/Sao_Paulo')::date >= v_hoje - 60
       and not exists (select 1 from eventos e where e.data = (pr.entrada at time zone 'America/Sao_Paulo')::date and e.status <> 'Cancelado')) r;
  select coalesce(sum(v.valor_total), 0) into v_fat from vendas v
   where v.status = 'Confirmada' and (v.data_hora at time zone 'America/Sao_Paulo')::date >= v_hoje - 60
     and exists (select 1 from ponto_registros pr where not pr.cancelado and pr.saida is not null and (pr.entrada at time zone 'America/Sao_Paulo')::date = (v.data_hora at time zone 'America/Sao_Paulo')::date)
     and not exists (select 1 from eventos e where e.data = (v.data_hora at time zone 'America/Sao_Paulo')::date and e.status <> 'Cancelado');
  return jsonb_build_object('ok', true, 'eventos', v_l, 'horasNormais', round(v_h, 1), 'faturamentoHoraNormal', case when v_h > 0 then round(v_fat / v_h, 2) end);
end $$;

-- 2b + 4) avisos no celular: margem baixa (1x por semana) e contas a pagar (véspera, hoje, vencidas)
do $$
declare v text;
begin
  select pg_get_functiondef('public.alertas_sistema_cron()'::regprocedure) into v;
  if v not like '%sis:contas_amanha%' then
    v := replace(v, $q$select max(data_hora) into v_t from backups where status = 'ok';$q$,
      $q$declare v_c int; v_s numeric; v_hj date := (now() at time zone 'America/Sao_Paulo')::date;
  begin
    select count(*), coalesce(sum(valor), 0) into v_c, v_s from despesas where status = 'A pagar' and situacao = 'A pagar' and vencimento < v_hj;
    if v_c > 0 then ativos := array_append(ativos, 'sis:contas_vencidas'::text);
      perform _alertas_sistema_avisar('sis:contas_vencidas', v_c || ' conta(s) a pagar vencida(s)', 'Total de R$ ' || _dinheiro(v_s) || ' já passou do vencimento. Administrador → Dinheiro → Contas a pagar.', interval '12 hours'); end if;
    select count(*), coalesce(sum(valor), 0) into v_c, v_s from despesas where status = 'A pagar' and situacao = 'A pagar' and vencimento = v_hj;
    if v_c > 0 then ativos := array_append(ativos, 'sis:contas_hoje'::text);
      perform _alertas_sistema_avisar('sis:contas_hoje', v_c || ' conta(s) vence(m) hoje', 'Total de R$ ' || _dinheiro(v_s) || ' para pagar hoje. Administrador → Dinheiro → Contas a pagar.', interval '12 hours'); end if;
    select count(*), coalesce(sum(valor), 0) into v_c, v_s from despesas where status = 'A pagar' and situacao = 'A pagar' and vencimento = v_hj + 1;
    if v_c > 0 then ativos := array_append(ativos, ('sis:contas_amanha:' || (v_hj + 1))::text);
      perform _alertas_sistema_avisar('sis:contas_amanha:' || (v_hj + 1), v_c || ' conta(s) vence(m) amanhã', 'Total de R$ ' || _dinheiro(v_s) || ' vence amanhã. Administrador → Dinheiro → Contas a pagar.', interval '1 day'); end if;
    select count(*) into v_c from _margem_baixa();
    if v_c > 0 then ativos := array_append(ativos, 'sis:margem'::text);
      perform _alertas_sistema_avisar('sis:margem', v_c || ' produto(s) com margem baixa', 'Estão abaixo de ' || replace(_margem_minima()::text, '.', ',') || '% de margem. Administrador → Produtos → Margem baixa mostra o preço sugerido.', interval '7 days'); end if;
  end;
  select max(data_hora) into v_t from backups where status = 'ok';$q$);
    execute v;
  end if;
end $$;
