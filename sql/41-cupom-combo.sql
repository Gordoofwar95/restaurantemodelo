-- 41 · Cupom "Combo por preço fixo": vale só quando o carrinho tem os produtos certos (ex.: 3 lanches + 1 refrigerante por R$ 65).
-- O desconto = (preço normal dos itens do combo) − (preço do combo). A entrega NÃO entra na conta (é somada depois).
-- Pode rodar de novo sem erro (cada trecho confere se já foi aplicado).

alter table public.cupons add column if not exists regra jsonb;

create or replace function pg_temp.rep(d text, a text, b text) returns text language plpgsql as $f$
begin
  if position(a in d) = 0 then raise exception 'Trecho não encontrado: %', left(a, 80); end if;
  return replace(d, a, b);
end $f$;

-- 1) _cupom_calcular ganha 2 argumentos (itens do carrinho e forma de pagamento) e o tipo "combo"
do $do$
declare d text; d2 text;
begin
  if exists (select 1 from pg_proc where proname = '_cupom_calcular' and pronamespace = 'public'::regnamespace and pronargs = 7) then return; end if;
  select pg_get_functiondef('public._cupom_calcular(text,text,numeric,text,uuid)'::regprocedure) into d;
  d2 := pg_temp.rep(d, 'p_tipo text, p_user uuid)', 'p_tipo text, p_user uuid, p_itens jsonb, p_forma uuid)');
  d2 := pg_temp.rep(d2, '  v_conta contas_cliente; v_cc cupons_concedidos;', '  v_conta contas_cliente; v_cc cupons_concedidos; g record; v_arr numeric[]; v_soma numeric; v_msg text;');
  d2 := pg_temp.rep(d2, E'  elsif c.tipo = ''frete'' then\n    v_desc := 0;',
$c$  elsif c.tipo = 'combo' then
    if p_itens is null or jsonb_typeof(p_itens) <> 'array' or c.regra is null then
      return _falha('Este cupom vale para um combo de produtos. Coloque os produtos no carrinho e aplique de novo.');
    end if;
    v_soma := 0;
    for g in select coalesce(nullif(x->>'qtd', '')::int, 1) q, x->'produtos' ps from jsonb_array_elements(c.regra->'grupos') x loop
      select coalesce(array_agg(u.preco order by u.preco), '{}'::numeric[]) into v_arr
        from (
          select coalesce(nullif(_num(i.e->>'precoBase'), 0), pp.preco, 0) preco, greatest(1, floor(_num(coalesce(i.e->>'quantidade', i.e->>'qtd')))::int) n
            from jsonb_array_elements(p_itens) i(e)
            left join produto_precos pp on pp.produto_id = coalesce(_uuid(i.e->>'produtoId'), case when i.e->>'tipo' = 'produto' then _uuid(i.e->>'id') end) and pp.forma_pagamento_id = p_forma
           where coalesce(_uuid(i.e->>'produtoId'), case when i.e->>'tipo' = 'produto' then _uuid(i.e->>'id') end) in (select _uuid(y->>'id') from jsonb_array_elements(g.ps) y)
             and (not (i.e ? 'valorUnitario') or _num(i.e->>'valorUnitario') > 0)
        ) u cross join lateral generate_series(1, u.n);
      if coalesce(array_length(v_arr, 1), 0) < g.q then
        select string_agg(coalesce(nullif(x->>'qtd', ''), '1') || ' ' || (select string_agg(y->>'nome', ' ou ') from jsonb_array_elements(x->'produtos') y), ' + ') into v_msg from jsonb_array_elements(c.regra->'grupos') x;
        return _falha('Para usar este cupom coloque no carrinho: ' || v_msg || '.');
      end if;
      v_soma := v_soma + (select coalesce(sum(z), 0) from unnest(v_arr[1:g.q]) z);   -- usa as unidades mais baratas
    end loop;
    v_desc := round(v_soma - c.valor, 2);
    if v_desc <= 0 then return _falha('Este cupom não gera desconto com os itens do carrinho.'); end if;
  elsif c.tipo = 'frete' then
    v_desc := 0;$c$);
  execute d2;
  execute 'revoke all on function public._cupom_calcular(text,text,numeric,text,uuid,jsonb,uuid) from public, anon, authenticated';
  execute 'grant execute on function public._cupom_calcular(text,text,numeric,text,uuid,jsonb,uuid) to service_role';
end $do$;

-- a versão de 5 argumentos passa a chamar a de 7 (sem itens: cupom combo pede os produtos)
create or replace function public._cupom_calcular(p_codigo text, p_tel text, p_subtotal numeric, p_tipo text, p_user uuid) returns jsonb
language sql security definer set search_path to 'public' as $$ select public._cupom_calcular(p_codigo, p_tel, p_subtotal, p_tipo, p_user, null::jsonb, null::uuid) $$;

-- 2) validação do cupom (admin): aceita o tipo "combo" e lê as linhas "3 x Produto A, Produto B"
do $do$
declare d text; d2 text;
begin
  select pg_get_functiondef('public._cupom_validar(jsonb,uuid)'::regprocedure) into d;
  if position('''combo''' in d) > 0 then return; end if;
  d2 := pg_temp.rep(d, 'declare v_fx jsonb', 'declare l record; nm record; pr record; v_q int; v_ps jsonb; v_rt text; v_reg jsonb; v_fx jsonb');
  d2 := pg_temp.rep(d2, 'array[''percentual'',''fixo'',''frete'',''progressivo'']', 'array[''percentual'',''fixo'',''frete'',''progressivo'',''combo'']');
  d2 := pg_temp.rep(d2, '  c.codigo := v_cod; c.nome',
$c$  if v_tipo = 'combo' then
    v_rt := btrim(coalesce(p->>'regraTexto', ''));
    if v_rt = '' then
      select regra into v_reg from cupons where id = p_id;
      if v_reg is null then erro := 'Informe os produtos do combo, uma linha por grupo (ex.: 3 x Lanche A, Lanche B).'; return; end if;
    else
      v_reg := '{"grupos":[]}'::jsonb;
      for l in select btrim(x) ln from unnest(regexp_split_to_array(v_rt, E'\n')) x where btrim(x) <> '' loop
        if l.ln !~ '^\d{1,2}\s*[xX×]\s*\S' then erro := 'Linha inválida do combo: "' || left(l.ln, 60) || '". Use o modelo: 3 x Produto A, Produto B'; return; end if;
        v_q := (substring(l.ln from '^(\d{1,2})'))::int;
        if v_q < 1 then erro := 'A quantidade do combo precisa ser 1 ou mais.'; return; end if;
        v_ps := '[]'::jsonb;
        for nm in select btrim(x) n from unnest(string_to_array(regexp_replace(l.ln, '^\d{1,2}\s*[xX×]\s*', ''), ',')) x where btrim(x) <> '' loop
          select id, nome into pr from produtos where lower(btrim(nome)) = lower(nm.n) and ativo limit 1;
          if pr.id is null then erro := 'Produto não encontrado (ou desativado): "' || nm.n || '". Escreva o nome igual ao do cadastro.'; return; end if;
          v_ps := v_ps || jsonb_build_array(jsonb_build_object('id', pr.id, 'nome', pr.nome));
        end loop;
        if jsonb_array_length(v_ps) = 0 then erro := 'Informe ao menos um produto na linha "' || left(l.ln, 60) || '".'; return; end if;
        v_reg := jsonb_set(v_reg, '{grupos}', (v_reg->'grupos') || jsonb_build_array(jsonb_build_object('qtd', v_q, 'produtos', v_ps)));
      end loop;
      if jsonb_array_length(v_reg->'grupos') = 0 or jsonb_array_length(v_reg->'grupos') > 6 then erro := 'O combo precisa de 1 a 6 grupos de produtos.'; return; end if;
    end if;
    v_reg := jsonb_set(v_reg, '{preco}', to_jsonb(round(v_val, 2)));
  end if;
  c.regra := case when v_tipo = 'combo' then v_reg else null end;
  c.codigo := v_cod; c.nome$c$);
  execute d2;
end $do$;

-- 3) salvar / editar cupom guardam a regra
do $do$
declare d text; d2 text;
begin
  select pg_get_functiondef('public.api_salvar_cupom(jsonb)'::regprocedure) into d;
  if position('regra' in d) = 0 then
    d2 := pg_temp.rep(d, 'automatico, validade_dias)', 'automatico, validade_dias, regra)');
    d2 := pg_temp.rep(d2, '(v.c).automatico, (v.c).validade_dias)', '(v.c).automatico, (v.c).validade_dias, (v.c).regra)');
    execute d2;
  end if;
  select pg_get_functiondef('public.api_editar_cupom(jsonb)'::regprocedure) into d;
  if position('regra' in d) = 0 then
    d2 := pg_temp.rep(d, 'validade_dias = (v.c).validade_dias', 'validade_dias = (v.c).validade_dias, regra = (v.c).regra');
    execute d2;
  end if;
end $do$;

-- 4) pré-visualização do cupom no carrinho: manda os itens e a forma de pagamento
do $do$
declare d text; d2 text;
begin
  select pg_get_functiondef('public.api_validar_cupom_cardapio(jsonb)'::regprocedure) into d;
  if position('p_itens' in d) > 0 or position('p->''itens''' in d) > 0 then return; end if;
  d2 := pg_temp.rep(d, 'p->>''tipoEntrega'', auth.uid())', 'p->>''tipoEntrega'', auth.uid(), p->''itens'', _uuid(p->>''formaPagamentoId''))');
  execute d2;
end $do$;

-- 5) criação do pedido: usa os itens reais (preço base, sem adicionais) e a forma escolhida
do $do$
declare d text; d2 text;
begin
  select pg_get_functiondef('public._criar_pedido_publico(jsonb,uuid,boolean)'::regprocedure) into d;
  if position('''precoBase''' in d) > 0 then return; end if;
  d2 := pg_temp.rep(d, '_cupom_calcular(v_cod, v_tel, v_orig, v_tipo::text, v_user)', '_cupom_calcular(v_cod, v_tel, v_orig, v_tipo::text, v_user, v_itens_ok, v_forma.id)');
  d2 := pg_temp.rep(d2, '''custoUnitario'', v_custo_u, ''adicionaisIds'', v_ads_ids)', '''custoUnitario'', v_custo_u, ''adicionaisIds'', v_ads_ids, ''precoBase'', v_preco)');
  execute d2;
end $do$;
