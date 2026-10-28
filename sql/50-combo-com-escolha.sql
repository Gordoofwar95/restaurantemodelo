-- 50 · Combo com escolha ("3 lanches": o cliente escolhe 3 entre os sabores, podendo repetir)
-- O que faz:
--   * combo_itens.escolha  = o produto é uma OPÇÃO de escolha (e não um item fixo do combo)
--   * combos.escolha_qtd   = quantos itens o cliente escolhe entre as opções (0 = combo comum, sem escolha)
--   * itens_venda.escolhas = o que o cliente escolheu em cada item vendido ([{produtoId, quantidade, nome}])
--   * o servidor confere a escolha (soma exata, só opções do combo, produtos ativos) no cardápio e no Caixa
--   * estoque, custo e cancelamento seguem o que foi escolhido (vendas antigas continuam como eram)
--   * o preço do combo continua fixo
-- Rode depois do 49. Pode rodar mais de uma vez (não duplica nada).

alter table public.combo_itens add column if not exists escolha boolean not null default false;
alter table public.combos      add column if not exists escolha_qtd integer not null default 0;
alter table public.itens_venda add column if not exists escolhas jsonb;

create or replace view public.v_cardapio_combo_itens as
 select ci.combo_id, ci.produto_id, ci.quantidade, ci.escolha
   from public.combo_itens ci join public.combos c on c.id = ci.combo_id and c.ativo;
create or replace view public.v_cardapio_combos as
 select id, nome, categoria_id, destaque, ordem_cardapio, foto_id_principal, foto_id_contingencia,
        foto_url_principal, foto_url_contingencia, foto_preferida, sem_desconto, escolha_qtd
   from public.combos where ativo;

-- confere a escolha de um combo e devolve a versão "limpa" (nomes do cadastro), o texto e o custo real
create or replace function public._combo_escolhas_validar(p_combo uuid, p_escolhas jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $f$
declare c combos%rowtype; r record; v_tot numeric := 0; v_texto text := ''; v_custo numeric := 0; v_arr jsonb := '[]'::jsonb; v_fixo numeric;
begin
  select * into c from combos where id = p_combo;
  if not found then return jsonb_build_object('ok', false, 'message', 'Combo não encontrado.'); end if;
  if coalesce(c.escolha_qtd, 0) <= 0 then return jsonb_build_object('ok', true, 'escolhas', null); end if;
  if jsonb_typeof(p_escolhas) is distinct from 'array' or jsonb_array_length(p_escolhas) > 20 then
    return jsonb_build_object('ok', false, 'message', 'Escolha os ' || c.escolha_qtd || ' itens de "' || c.nome || '".');
  end if;
  for r in
    select a.pid, a.q, p.nome, p.ativo, (ci.produto_id is not null) as permitido,
           coalesce((select max(pp.custo) from produto_precos pp where pp.produto_id = a.pid), 0) as custo
      from (select _uuid(x->>'produtoId') as pid, sum(_num(x->>'quantidade')) as q from jsonb_array_elements(p_escolhas) x group by 1) a
      left join produtos p on p.id = a.pid
      left join combo_itens ci on ci.combo_id = p_combo and ci.produto_id = a.pid and ci.escolha
     order by p.nome
  loop
    if r.pid is null or r.permitido is not true or not coalesce(r.ativo, false) then
      return jsonb_build_object('ok', false, 'message', 'Uma das opções escolhidas não está disponível em "' || c.nome || '".');
    end if;
    if r.q <= 0 or r.q <> floor(r.q) then return jsonb_build_object('ok', false, 'message', 'Quantidade inválida na escolha de "' || c.nome || '".'); end if;
    v_tot := v_tot + r.q; v_custo := v_custo + r.q * r.custo;
    v_texto := v_texto || case when v_texto <> '' then ', ' else '' end || r.q::int || 'x ' || r.nome;
    v_arr := v_arr || jsonb_build_array(jsonb_build_object('produtoId', r.pid, 'quantidade', r.q::int, 'nome', r.nome));
  end loop;
  if v_tot <> c.escolha_qtd then
    return jsonb_build_object('ok', false, 'message', 'Escolha exatamente ' || c.escolha_qtd || ' itens em "' || c.nome || '".');
  end if;
  select coalesce(sum(ci.quantidade * coalesce((select max(pp.custo) from produto_precos pp where pp.produto_id = ci.produto_id), 0)), 0)
    into v_fixo from combo_itens ci where ci.combo_id = p_combo and not ci.escolha;
  return jsonb_build_object('ok', true, 'escolhas', v_arr, 'texto', v_texto, 'custo', round(v_fixo + v_custo, 2));
end $f$;

create or replace function public._combo_escolhas_canon(p_combo uuid, p_esc jsonb) returns jsonb
language sql stable security definer set search_path to 'public' as $f$
  select case when p_combo is null or jsonb_typeof(p_esc) is distinct from 'array' then null
              else nullif(_combo_escolhas_validar(p_combo, p_esc)->'escolhas', 'null'::jsonb) end
$f$;

-- confere, no cadastro do combo, se a configuração da escolha faz sentido (null = ok)
create or replace function public._combo_escolha_valida(p jsonb) returns text
language plpgsql stable security definer set search_path to 'public' as $f$
declare v_q int := greatest(0, floor(coalesce(_num(p->>'escolhaQtd'), 0))::int); v_n int;
begin
  if jsonb_typeof(p->'itens') is distinct from 'array' then return null; end if;
  select count(*) into v_n from jsonb_array_elements(p->'itens') e where coalesce(e->>'escolha', '') in ('true', 't');
  if v_q = 0 and v_n = 0 then return null; end if;
  if v_q = 0 then return 'Informe quantos itens o cliente escolhe.'; end if;
  if v_n < 2 then return 'Marque pelo menos 2 produtos como opção de escolha.'; end if;
  if v_q > 20 then return 'O cliente pode escolher no máximo 20 itens.'; end if;
  return null;
end $f$;

revoke all on function public._combo_escolhas_validar(uuid, jsonb), public._combo_escolhas_canon(uuid, jsonb), public._combo_escolha_valida(jsonb) from public, anon, authenticated;
grant execute on function public._combo_escolhas_validar(uuid, jsonb), public._combo_escolhas_canon(uuid, jsonb), public._combo_escolha_valida(jsonb) to service_role;

create or replace function public._combo_gravar_itens(p_combo uuid, p_itens jsonb) returns void
language plpgsql security definer set search_path to 'public' as $f$
begin
  delete from combo_itens where combo_id = p_combo;
  insert into combo_itens (combo_id, produto_id, quantidade, escolha)
  select p_combo, _uuid(e->>'produtoId'), _num(e->>'quantidade')::int, coalesce(e->>'escolha', '') in ('true', 't')
  from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) e
  where _uuid(e->>'produtoId') is not null and _num(e->>'quantidade') > 0;
end $f$;

-- custo mostrado do combo: itens fixos + (quantos o cliente escolhe × a opção mais cara)
create or replace function public._custo_combo(p_combo uuid) returns numeric
language sql stable security definer set search_path to 'public' as $f$
  select case when count(*) = 0 then null else round(
           coalesce(sum(case when ci.escolha then 0 else ci.quantidade * coalesce((select max(pp.custo) from produto_precos pp where pp.produto_id = ci.produto_id), 0) end), 0)
           + coalesce((select c.escolha_qtd from combos c where c.id = p_combo), 0)
             * coalesce(max(case when ci.escolha then (select max(pp.custo) from produto_precos pp where pp.produto_id = ci.produto_id) end), 0), 2) end
  from combo_itens ci where ci.combo_id = p_combo
$f$;

-- baixa/estorno de estoque: itens fixos + o que o cliente escolheu (sem escolha registrada = comportamento antigo)
create or replace function public._consumo(p_itens jsonb) returns table(ingrediente_id uuid, qtd numeric)
language sql stable security definer set search_path to 'public' as $f$
  with it as (
    select _uuid(e->>'produtoId') as produto_id, _uuid(e->>'comboId') as combo_id,
           _num(e->>'quantidade') as q, e->'adicionaisIds' as ads, e->'escolhas' as esc
    from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) e
  ), consumo as (
    select pi.ingrediente_id, pi.quantidade_por_unidade * it.q as qtd
      from it join produto_ingredientes pi on pi.produto_id = it.produto_id
    union all
    select pi.ingrediente_id, pi.quantidade_por_unidade * ci.quantidade * it.q
      from it join combo_itens ci on ci.combo_id = it.combo_id and (not ci.escolha or jsonb_typeof(it.esc) is distinct from 'array')
              join produto_ingredientes pi on pi.produto_id = ci.produto_id
    union all
    select pi.ingrediente_id, pi.quantidade_por_unidade * esc.q * it.q
      from it
      cross join lateral (select _uuid(x->>'produtoId') as pid, _num(x->>'quantidade') as q
                            from jsonb_array_elements(case when jsonb_typeof(it.esc) = 'array' then it.esc else '[]'::jsonb end) x) esc
      join combo_itens cp on cp.combo_id = it.combo_id and cp.produto_id = esc.pid and cp.escolha
      join produto_ingredientes pi on pi.produto_id = esc.pid
    union all
    select a.ingrediente_id, coalesce(nullif(a.quantidade_descontar, 0), 1) * it.q
      from it
      cross join lateral jsonb_array_elements_text(case when jsonb_typeof(it.ads) = 'array' then it.ads else '[]'::jsonb end) x
      join adicionais a on a.id = _uuid(x)
      where a.ingrediente_id is not null
  )
  select c.ingrediente_id, sum(c.qtd) from consumo c where c.ingrediente_id is not null group by c.ingrediente_id having sum(c.qtd) <> 0
$f$;

create or replace function public._itens_da_venda(p_venda uuid) returns jsonb
language sql stable security definer set search_path to 'public' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('produtoId', i.produto_id, 'comboId', i.combo_id, 'quantidade', i.quantidade,
                                               'adicionaisIds', to_jsonb(i.adicionais_ids), 'escolhas', i.escolhas)), '[]'::jsonb)
  from itens_venda i where i.venda_id = p_venda
$f$;

-- troca de texto dentro de uma função já existente (cada trecho tem que aparecer exatamente 1 vez)
create or replace function pg_temp.tb_trocar(d text, a text, b text) returns text language plpgsql as $f$
declare n int := (length(d) - length(replace(d, a, ''))) / greatest(length(a), 1);
begin
  if n <> 1 then raise exception 'trecho encontrado % vez(es) (esperado 1): %', n, left(a, 80); end if;
  return replace(d, a, b);
end $f$;

do $do$
declare o oid; d text; n int := 0;
  ins_cab constant text := 'insert into itens_venda (venda_id, produto_id, combo_id, descricao, quantidade, valor_unitario, custo_unitario, valor_total_item, adicionais_ids)';
  canon constant text := ', _combo_escolhas_canon(_uuid(e->>''comboId''), e->''escolhas'')';
begin
  -- cadastro do combo: validação e quantos o cliente escolhe
  for o in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'api_add_combo' and pg_get_functiondef(p.oid) not like '%escolha%' loop
    d := pg_get_functiondef(o);
    d := pg_temp.tb_trocar(d, $a$if v_nome = '' then return _falha('Informe o nome do combo.'); end if;$a$,
      $b$if v_nome = '' then return _falha('Informe o nome do combo.'); end if;
  if _combo_escolha_valida(p) is not null then return _falha(_combo_escolha_valida(p)); end if;$b$);
    d := pg_temp.tb_trocar(d, $a$perform _combo_gravar_itens(v_id, p->'itens');$a$,
      $b$perform _combo_gravar_itens(v_id, p->'itens');
  update combos set escolha_qtd = greatest(0, floor(coalesce(_num(p->>'escolhaQtd'), 0))::int) where id = v_id;
  perform _recalc_combos(array[v_id]);$b$);
    execute d; n := n + 1;
  end loop;
  for o in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'api_editar_combo' and pg_get_functiondef(p.oid) not like '%escolha%' loop
    d := pg_get_functiondef(o);
    d := pg_temp.tb_trocar(d, $a$if v_nome = '' then return _falha('Informe o nome do combo.'); end if;$a$,
      $b$if v_nome = '' then return _falha('Informe o nome do combo.'); end if;
  if _combo_escolha_valida(p) is not null then return _falha(_combo_escolha_valida(p)); end if;$b$);
    d := pg_temp.tb_trocar(d, $a$if jsonb_typeof(p->'itens') = 'array' then perform _combo_gravar_itens(v_id, p->'itens'); end if;$a$,
      $b$if jsonb_typeof(p->'itens') = 'array' then
    perform _combo_gravar_itens(v_id, p->'itens');
    update combos set escolha_qtd = greatest(0, floor(coalesce(_num(p->>'escolhaQtd'), 0))::int) where id = v_id;
    perform _recalc_combos(array[v_id]);
  end if;$b$);
    execute d; n := n + 1;
  end loop;

  -- pedido do cardápio
  for o in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_criar_pedido_publico'
            and pg_get_functiondef(p.oid) like '%v_sem_desc%' and pg_get_functiondef(p.oid) not like '%v_esc jsonb%' loop
    d := pg_get_functiondef(o);
    d := pg_temp.tb_trocar(d, $a$v_blq boolean := false;$a$, $b$v_esc jsonb; v_ev jsonb; v_blq boolean := false;$b$);
    d := pg_temp.tb_trocar(d, $a$v_blq := coalesce(case when v_prod_id is not null then$a$,
      $b$v_esc := null; v_ev := null;
    if v_comb_id is not null then
      v_ev := _combo_escolhas_validar(v_comb_id, it.e->'escolhas');
      if not coalesce((v_ev->>'ok')::boolean, false) then return _falha(coalesce(v_ev->>'message', 'Escolha inválida no combo.')); end if;
      if jsonb_typeof(v_ev->'escolhas') = 'array' then v_esc := v_ev->'escolhas'; v_custo_u := (v_ev->>'custo')::numeric; end if;
    end if;
    v_blq := coalesce(case when v_prod_id is not null then$b$);
    d := pg_temp.tb_trocar(d, $a$'descricao', v_nome_item || v_ads || case when v_obs_item <> '' then ' — Obs: ' || v_obs_item else '' end,$a$,
      $b$'descricao', v_nome_item || coalesce(' (' || (v_ev->>'texto') || ')', '') || v_ads || case when v_obs_item <> '' then ' — Obs: ' || v_obs_item else '' end,$b$);
    d := pg_temp.tb_trocar(d, $a$'custoUnitario', v_custo_u, 'adicionaisIds', v_ads_ids, 'precoBase', v_preco));$a$,
      $b$'custoUnitario', v_custo_u, 'adicionaisIds', v_ads_ids, 'precoBase', v_preco, 'escolhas', v_esc));$b$);
    d := pg_temp.tb_trocar(d, ins_cab, replace(ins_cab, 'adicionais_ids)', 'adicionais_ids, escolhas)'));
    d := pg_temp.tb_trocar(d, E'\'{}\')\n  from jsonb_array_elements(v_itens_ok) e;', E'\'{}\')' || canon || E'\n  from jsonb_array_elements(v_itens_ok) e;');
    execute d; n := n + 1;
  end loop;

  -- venda do Caixa (e do garçom)
  for o in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'api_iniciar_venda'
            and pg_get_functiondef(p.oid) like '%v_sem_desc%' and pg_get_functiondef(p.oid) not like '%v_evc%' loop
    d := pg_get_functiondef(o);
    d := pg_temp.tb_trocar(d, $a$v_sem_desc numeric := 0; v_elig numeric;$a$, $b$v_ev jsonb; v_evc numeric; v_sem_desc numeric := 0; v_elig numeric;$b$);
    d := pg_temp.tb_trocar(d, $a$v_nome_item := coalesce(nullif(it.e->>'descricao', ''), 'item');$a$,
      $b$v_nome_item := coalesce(nullif(it.e->>'descricao', ''), 'item');
    v_ev := null; v_evc := null;
    if _uuid(it.e->>'comboId') is not null then
      v_ev := _combo_escolhas_validar(_uuid(it.e->>'comboId'), it.e->'escolhas');
      if not coalesce((v_ev->>'ok')::boolean, false) then return _falha(coalesce(v_ev->>'message', 'Escolha inválida no combo.')); end if;
      if jsonb_typeof(v_ev->'escolhas') = 'array' then v_evc := (v_ev->>'custo')::numeric; end if;
    end if;$b$);
    d := pg_temp.tb_trocar(d, 'abs(cp.custo - v_c) <= 0.011', 'abs(coalesce(v_evc, cp.custo) - v_c) <= 0.011');
    d := pg_temp.tb_trocar(d, ins_cab, replace(ins_cab, 'adicionais_ids)', 'adicionais_ids, escolhas)'));
    d := pg_temp.tb_trocar(d, E'x), \'{}\')\n  from jsonb_array_elements(v_itens) e;', E'x), \'{}\')' || canon || E'\n  from jsonb_array_elements(v_itens) e;');
    execute d; n := n + 1;
  end loop;

  -- pagamento online (Mercado Pago): a venda nasce da reserva
  for o in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_mp_criar_venda' and pg_get_functiondef(p.oid) not like '%escolhas%' loop
    d := pg_get_functiondef(o);
    d := pg_temp.tb_trocar(d, ins_cab, replace(ins_cab, 'adicionais_ids)', 'adicionais_ids, escolhas)'));
    d := pg_temp.tb_trocar(d, E'\'{}\')\n  from jsonb_array_elements(r.itens) e;', E'\'{}\')' || canon || E'\n  from jsonb_array_elements(r.itens) e;');
    execute d; n := n + 1;
  end loop;

  -- edição de venda: mantém a escolha dos itens que já tinham
  for o in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_editar_venda_base' and pg_get_functiondef(p.oid) not like '%escolhas%' loop
    d := pg_get_functiondef(o);
    d := pg_temp.tb_trocar(d, $a$'custoUnitario', v_c, 'adicionaisIds', v_ads));$a$,
      $b$'custoUnitario', v_c, 'adicionaisIds', v_ads,
                                                                 'escolhas', coalesce(case when jsonb_typeof(it.e->'escolhas') = 'array' then it.e->'escolhas' end, (select iv.escolhas from itens_venda iv where iv.venda_id = v.id and iv.descricao = it.e->>'descricao' limit 1))));$b$);
    d := pg_temp.tb_trocar(d, ins_cab, replace(ins_cab, 'adicionais_ids)', 'adicionais_ids, escolhas)'));
    d := pg_temp.tb_trocar(d, E'\'{}\')\n  from jsonb_array_elements(v_novos) e;', E'\'{}\')' || canon || E'\n  from jsonb_array_elements(v_novos) e;');
    execute d; n := n + 1;
  end loop;
  raise notice 'funções atualizadas: %', n;
end $do$;
