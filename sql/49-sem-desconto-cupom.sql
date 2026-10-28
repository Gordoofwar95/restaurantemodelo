-- 49 · "Não aceita desconto nem cupom" em produtos e combos (preço já promocional)
-- O que faz:
--   * produtos.sem_desconto e combos.sem_desconto (padrão: não)
--   * cupom do cardápio: o desconto é calculado só sobre os itens que aceitam desconto (frete grátis do cupom continua valendo)
--   * desconto manual do Caixa (pede senha): idem, só sobre os itens que aceitam desconto
--   * o cardápio público enxerga a marca (v_cardapio_produtos / v_cardapio_combos) para avisar o cliente
--   * api_editar_sem_desconto(p) liga/desliga a marca (só Administrador)
-- Rode depois do 48. Pode rodar mais de uma vez (não duplica nada).

alter table public.produtos add column if not exists sem_desconto boolean not null default false;
alter table public.combos   add column if not exists sem_desconto boolean not null default false;

create or replace view public.v_cardapio_produtos as
 select id, nome, descricao, categoria_id, destaque, ordem_cardapio, foto_id_principal, foto_id_contingencia,
        foto_url_principal, foto_url_contingencia, foto_preferida, sem_desconto
   from public.produtos where ativo;
create or replace view public.v_cardapio_combos as
 select id, nome, categoria_id, destaque, ordem_cardapio, foto_id_principal, foto_id_contingencia,
        foto_url_principal, foto_url_contingencia, foto_preferida, sem_desconto
   from public.combos where ativo;

create or replace function public.api_editar_sem_desconto(p jsonb) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare v_prod uuid := nullif(btrim(coalesce(p->>'produtoId','')),'')::uuid;
        v_comb uuid := nullif(btrim(coalesce(p->>'comboId','')),'')::uuid;
        v_val boolean := coalesce((p->>'semDesconto')::boolean, false);
begin
  if not public.tem_nivel('Admin') then return public._negado(); end if;
  if (v_prod is null) = (v_comb is null) then return public._falha('Informe um produto ou um combo.'); end if;
  if v_prod is not null then
    update public.produtos set sem_desconto = v_val where id = v_prod;
  else
    update public.combos set sem_desconto = v_val where id = v_comb;
  end if;
  if not found then return public._falha('Item não encontrado.'); end if;
  return jsonb_build_object('ok', true, 'message', case when v_val then 'Este item não aceita desconto nem cupom.' else 'Este item volta a aceitar desconto e cupom.' end);
end $f$;
revoke all on function public.api_editar_sem_desconto(jsonb) from public, anon;
grant execute on function public.api_editar_sem_desconto(jsonb) to authenticated, service_role;

-- troca de texto dentro de uma função já existente (cada trecho tem que aparecer exatamente 1 vez)
create or replace function pg_temp.tb_trocar(d text, a text, b text) returns text language plpgsql as $f$
declare n int := (length(d) - length(replace(d, a, ''))) / greatest(length(a), 1);
begin
  if n <> 1 then raise exception 'trecho encontrado % vez(es) (esperado 1): %', n, left(a, 80); end if;
  return replace(d, a, b);
end $f$;

do $do$
declare o oid; d text; n int := 0;
begin
  -- 1) cupom do tipo "combo de produtos": produto marcado não conta
  for o in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_cupom_calcular'
            and pg_get_functiondef(p.oid) like '%valorUnitario%' and pg_get_functiondef(p.oid) not like '%sem_desconto%' loop
    d := pg_get_functiondef(o);
    d := pg_temp.tb_trocar(d, $a$and (not (i.e ? 'valorUnitario') or _num(i.e->>'valorUnitario') > 0)$a$,
      $b$and (not (i.e ? 'valorUnitario') or _num(i.e->>'valorUnitario') > 0)
             and not coalesce((select pr.sem_desconto from produtos pr where pr.id = coalesce(_uuid(i.e->>'produtoId'), case when i.e->>'tipo' = 'produto' then _uuid(i.e->>'id') end)), false)$b$);
    execute d; n := n + 1;
  end loop;

  -- 2) pedido do cardápio: cupom só sobre os itens que aceitam desconto
  for o in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_criar_pedido_publico'
            and pg_get_functiondef(p.oid) like '%_cupom_calcular(v_cod%' and pg_get_functiondef(p.oid) not like '%v_sem_desc%' loop
    d := pg_get_functiondef(o);
    d := pg_temp.tb_trocar(d, $a$v_cod text := ''; v_cup jsonb; v_desc numeric := 0;$a$,
      $b$v_blq boolean := false; v_sem_desc numeric := 0; v_cod text := ''; v_cup jsonb; v_desc numeric := 0;$b$);
    d := pg_temp.tb_trocar(d, $a$select count(*), coalesce(sum(a.preco), 0),$a$,
      $b$v_blq := coalesce(case when v_prod_id is not null then (select sem_desconto from produtos where id = v_prod_id) else (select sem_desconto from combos where id = v_comb_id) end, false);
    select count(*), coalesce(sum(a.preco), 0),$b$);
    d := pg_temp.tb_trocar(d, $a$v_orig := v_orig + round(v_qtd * (v_preco + v_extra), 2); v_custo := v_custo + v_qtd * v_custo_u;$a$,
      $b$v_orig := v_orig + round(v_qtd * (v_preco + v_extra), 2); v_custo := v_custo + v_qtd * v_custo_u;
    if v_blq then v_sem_desc := v_sem_desc + round(v_qtd * (v_preco + v_extra), 2); end if;$b$);
    d := pg_temp.tb_trocar(d, $a$v_cup := _cupom_calcular(v_cod, v_tel, v_orig, v_tipo::text, v_user, v_itens_ok, v_forma.id);$a$,
      $b$v_cup := _cupom_calcular(v_cod, v_tel, greatest(0, round(v_orig - v_sem_desc, 2)), v_tipo::text, v_user, v_itens_ok, v_forma.id);$b$);
    d := pg_temp.tb_trocar(d, $a$v_desc := (v_cup->>'desconto')::numeric; v_frete := (v_cup->>'freteGratis')::boolean;$a$,
      $b$if round(v_orig - v_sem_desc, 2) <= 0 and not coalesce((v_cup->>'freteGratis')::boolean, false) then return _falha('Os itens deste pedido têm preço promocional e não aceitam cupom.'); end if;
      v_desc := (v_cup->>'desconto')::numeric; v_frete := (v_cup->>'freteGratis')::boolean;$b$);
    execute d; n := n + 1;
  end loop;

  -- 3) Caixa: desconto manual só sobre os itens que aceitam desconto
  for o in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'api_iniciar_venda'
            and pg_get_functiondef(p.oid) not like '%v_sem_desc%' loop
    d := pg_get_functiondef(o);
    d := pg_temp.tb_trocar(d, $a$v_orig numeric := 0; v_custo numeric := 0; v_total_item numeric;$a$,
      $b$v_sem_desc numeric := 0; v_elig numeric; v_orig numeric := 0; v_custo numeric := 0; v_total_item numeric;$b$);
    d := pg_temp.tb_trocar(d, $a$v_orig := v_orig + v_total_item; v_custo := v_custo + v_qtd * v_c;$a$,
      $b$v_orig := v_orig + v_total_item; v_custo := v_custo + v_qtd * v_c;
    if coalesce((select sem_desconto from produtos where id = _uuid(it.e->>'produtoId')), (select sem_desconto from combos where id = _uuid(it.e->>'comboId')), false) then v_sem_desc := v_sem_desc + v_total_item; end if;$b$);
    d := pg_temp.tb_trocar(d, $a$v_sol := _num(v_desc->>'valor', -1);$a$,
      $b$v_sol := _num(v_desc->>'valor', -1); v_elig := round(v_orig - v_sem_desc, 2);
    if v_elig <= 0 then return _falha('Os itens desta venda têm preço promocional e não aceitam desconto.'); end if;$b$);
    d := pg_temp.tb_trocar(d, $a$v_desc_val := round(v_orig * (v_sol / 100), 2);$a$,
      $b$v_desc_val := round(v_elig * (v_sol / 100), 2);$b$);
    d := pg_temp.tb_trocar(d, $a$if v_sol > v_orig then return _falha('O desconto fixo não pode ser maior que o valor da venda.'); end if;$a$,
      $b$if v_sol > v_elig then return _falha('O desconto fixo não pode ser maior que o valor dos itens que aceitam desconto (R$ ' || _dinheiro(v_elig) || ').'); end if;$b$);
    execute d; n := n + 1;
  end loop;
  raise notice 'funções atualizadas: %', n;
end $do$;
