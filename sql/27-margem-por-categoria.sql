-- =====================================================================
-- 27 · MARGEM BAIXA MAIS INTELIGENTE (18/10/2026)
--  1) Margem mínima por categoria (ex.: Bebidas 25%) além da geral; produto pode ser ignorado (e voltar a ser vigiado).
--  2) O aviso no celular só toca quando entra produto NOVO abaixo do mínimo (não repete toda semana).
--  3) Repetição dos avisos novos: margem nunca repete; evento a receber e contas na véspera 1x por dia; contas do dia e vencidas a cada 6 h.
-- Aditivo. Pode rodar de novo sem erro. Rode DEPOIS do 26.
-- =====================================================================

create or replace function public._margem_min_cat(p_cat uuid) returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce(nullif((select valor ->> p_cat::text from sistema where chave = 'MARGEM_POR_CATEGORIA'), '')::numeric, _margem_minima())
$$;

create or replace function public._margem_baixa() returns table (produto_id uuid, nome text, forma text, preco numeric, custo numeric, margem numeric, sugerido numeric)
language sql stable security definer set search_path to 'public' as $$
  select distinct on (pr.id) pr.id, pr.nome, f.nome, pp.preco, pp.custo,
         round((pp.preco - pp.custo) / pp.preco * 100, 1),
         ceil(pp.custo / (1 - _margem_min_cat(pr.categoria_id) / 100.0) * 10) / 10
    from produtos pr join produto_precos pp on pp.produto_id = pr.id left join formas_pagamento f on f.id = pp.forma_pagamento_id
   where pr.ativo and pp.preco > 0 and pp.custo > 0 and (pp.preco - pp.custo) / pp.preco * 100 < _margem_min_cat(pr.categoria_id)
     and not coalesce((select valor @> jsonb_build_array(pr.id::text) from sistema where chave = 'MARGEM_IGNORADOS'), false)
   order by pr.id, (pp.preco - pp.custo) / pp.preco
$$;

create or replace function public.api_margem_alerta(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_l jsonb; v_c jsonb; v_i jsonb; v_cfg jsonb := coalesce((select valor from sistema where chave = 'MARGEM_POR_CATEGORIA'), '{}'::jsonb);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select coalesce(jsonb_agg(jsonb_build_object('produtoId', m.produto_id, 'nome', m.nome, 'forma', m.forma, 'preco', m.preco, 'custo', m.custo, 'margem', m.margem, 'sugerido', m.sugerido,
           'categoria', c.nome, 'minimo', _margem_min_cat(pr.categoria_id)) order by m.margem), '[]'::jsonb) into v_l
    from _margem_baixa() m join produtos pr on pr.id = m.produto_id left join categorias c on c.id = pr.categoria_id;
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'minimo', nullif(v_cfg ->> c.id::text, '')::numeric) order by c.ordem, c.nome), '[]'::jsonb) into v_c from categorias c where c.ativa;
  select coalesce(jsonb_agg(jsonb_build_object('produtoId', pr.id, 'nome', pr.nome) order by pr.nome), '[]'::jsonb) into v_i
    from produtos pr where coalesce((select valor @> jsonb_build_array(pr.id::text) from sistema where chave = 'MARGEM_IGNORADOS'), false);
  return jsonb_build_object('ok', true, 'margemMin', _margem_minima(), 'itens', v_l, 'categorias', v_c, 'ignorados', v_i);
end $$;

create or replace function public.api_margem_config_salvar(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v numeric; r record; v_cats jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if coalesce(p->>'margemMin', '') <> '' then
    v := _num(p->>'margemMin', -1);
    if v < 1 or v > 95 then return _falha('Informe uma margem mínima entre 1% e 95%.'); end if;
    insert into sistema (chave, valor, atualizado_em) values ('MARGEM_MINIMA', to_jsonb(v), now())
      on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  end if;
  if jsonb_typeof(p->'categorias') = 'object' then
    v_cats := coalesce((select valor from sistema where chave = 'MARGEM_POR_CATEGORIA'), '{}'::jsonb);
    for r in select key, value from jsonb_each(p->'categorias') loop
      if r.value = 'null'::jsonb or coalesce(r.value #>> '{}', '') = '' then v_cats := v_cats - r.key;
      else
        v := _num(r.value #>> '{}', -1);
        if v < 1 or v > 95 then return _falha('Cada margem mínima deve ficar entre 1% e 95%.'); end if;
        v_cats := v_cats || jsonb_build_object(r.key, v);
      end if;
    end loop;
    insert into sistema (chave, valor, atualizado_em) values ('MARGEM_POR_CATEGORIA', v_cats, now())
      on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  end if;
  perform _auditar('Margem mínima alterada', left(coalesce(p::text, ''), 300));
  return jsonb_build_object('ok', true, 'message', 'Margens mínimas salvas.');
end $$;

create or replace function public.api_margem_ignorar(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_id text := p->>'produtoId'; v_ign boolean := coalesce((p->>'ignorar')::boolean, true); v_l jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if not exists (select 1 from produtos where id::text = v_id) then return _falha('Produto não encontrado.'); end if;
  v_l := coalesce((select valor from sistema where chave = 'MARGEM_IGNORADOS'), '[]'::jsonb);
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_l from jsonb_array_elements(v_l) x where x #>> '{}' <> v_id;
  if v_ign then v_l := v_l || jsonb_build_array(v_id); end if;
  insert into sistema (chave, valor, atualizado_em) values ('MARGEM_IGNORADOS', v_l, now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  perform _auditar(case when v_ign then 'Produto ignorado na margem baixa' else 'Produto voltou à margem baixa' end, v_id);
  return jsonb_build_object('ok', true, 'message', case when v_ign then 'Produto não será mais avisado.' else 'Produto voltou a ser vigiado.' end);
end $$;

-- repetição dos avisos novos (a função usa o intervalo geral para os demais)
do $$
declare v text;
begin
  select pg_get_functiondef('public._alertas_sistema_avisar(text,text,text,interval)'::regprocedure) into v;
  if v not like '%sis:margem:%' then
    v := replace(v, $q$if p_chave like 'sis:venc:%' then$q$,
      $q$if p_chave like 'sis:margem:%' then v_rep := interval '3650 days';
  elsif p_chave like 'sis:contas_amanha:%' or p_chave like 'sis:evento_receber:%' then v_rep := interval '1 day';
  elsif p_chave like 'sis:contas_%' then v_rep := interval '6 hours';
  end if;
  if p_chave like 'sis:venc:%' then$q$);
    if v not like '%sis:margem:%' then raise exception 'Não foi possível ajustar _alertas_sistema_avisar'; end if;
    execute v;
  end if;
end $$;

-- aviso de margem só para produto novo na lista
do $$
declare v text;
begin
  select pg_get_functiondef('public.alertas_sistema_cron()'::regprocedure) into v;
  if v not like '%MARGEM_AVISADOS%' then
    v := replace(v, $q$select count(*) into v_c from _margem_baixa();
    if v_c > 0 then ativos := array_append(ativos, 'sis:margem'::text);
      perform _alertas_sistema_avisar('sis:margem', v_c || ' produto(s) com margem baixa', 'Estão abaixo de ' || replace(_margem_minima()::text, '.', ',') || '% de margem. Administrador → Produtos → Margem baixa mostra o preço sugerido.', interval '7 days'); end if;$q$,
      $q$declare v_ids jsonb; v_old jsonb; v_novos jsonb; v_nomes text;
    begin
      select coalesce(jsonb_agg(produto_id order by produto_id), '[]'::jsonb) into v_ids from _margem_baixa();
      v_old := coalesce((select valor from sistema where chave = 'MARGEM_AVISADOS'), '[]'::jsonb);
      select coalesce(jsonb_agg(x), '[]'::jsonb) into v_novos from jsonb_array_elements(v_ids) x where not (v_old @> jsonb_build_array(x));
      v_c := jsonb_array_length(v_novos);
      if v_c > 0 then
        select string_agg(nome, ', ') into v_nomes from (select m.nome from _margem_baixa() m where v_novos @> jsonb_build_array(to_jsonb(m.produto_id)) order by m.nome limit 3) q;
        ativos := array_append(ativos, ('sis:margem:' || md5(v_novos::text))::text);
        perform _alertas_sistema_avisar('sis:margem:' || md5(v_novos::text), v_c || ' produto(s) com margem baixa', v_nomes || (case when v_c > 3 then ' e mais ' || (v_c - 3) else '' end) || ' ficou(aram) abaixo da margem mínima. Administrador → Produtos → Margem baixa mostra o preço sugerido.', interval '3650 days');
      end if;
      insert into sistema (chave, valor, atualizado_em) values ('MARGEM_AVISADOS', v_ids, now()) on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
    end;$q$);
    if v not like '%MARGEM_AVISADOS%' then raise exception 'Não foi possível ajustar alertas_sistema_cron'; end if;
    execute v;
  end if;
end $$;

-- ponto de partida: Bebidas com mínimo próprio de 25% (o dono ajusta na tela) e lista atual já considerada "avisada" (sem aviso na hora de instalar)
do $$
declare v_b uuid;
begin
  select id into v_b from categorias where nome = 'Bebidas' limit 1;
  if v_b is not null then
    insert into sistema (chave, valor, atualizado_em) values ('MARGEM_POR_CATEGORIA', jsonb_build_object(v_b::text, 25), now()) on conflict (chave) do nothing;
  end if;
  insert into sistema (chave, valor, atualizado_em)
    select 'MARGEM_AVISADOS', coalesce(jsonb_agg(produto_id order by produto_id), '[]'::jsonb), now() from _margem_baixa()
    on conflict (chave) do nothing;
end $$;
