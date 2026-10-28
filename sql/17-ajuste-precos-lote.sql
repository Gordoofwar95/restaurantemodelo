-- =====================================================================
-- 17 · AJUSTE DE PREÇOS DOS PRODUTOS EM LOTE (18/10/2026)
-- Admin escolhe um percentual (-50% a +100%) e, se quiser, uma categoria; todos os preços dos produtos ativos dessa categoria são ajustados
-- de uma vez (arredondado em centavos). O custo não muda. Fica na auditoria. Aditivo: 1 função nova.
-- =====================================================================
create or replace function public.api_ajustar_precos_produtos_lote(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_pct numeric := _num(p->>'percentual', 0); v_cat text := nullif(btrim(coalesce(p->>'categoria', '')), ''); v_n int; v_prod int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_pct = 0 or v_pct < -50 or v_pct > 100 then return _falha('Informe um percentual entre -50 e 100 (diferente de zero).'); end if;
  with alvo as (
    select pp.id from produto_precos pp join produtos pr on pr.id = pp.produto_id left join categorias c on c.id = pr.categoria_id
     where pr.ativo and pp.preco > 0 and (v_cat is null or c.nome = v_cat)
  ), up as (
    update produto_precos x set preco = round(x.preco * (1 + v_pct / 100), 2) from alvo where x.id = alvo.id returning x.produto_id
  ) select count(*), count(distinct produto_id) into v_n, v_prod from up;
  perform _auditar('Preços ajustados em lote', v_pct || '% | ' || coalesce(v_cat, 'todas as categorias') || ' | ' || coalesce(v_prod, 0) || ' produto(s)');
  return jsonb_build_object('ok', true, 'message', coalesce(v_prod, 0) || ' produto(s) com preço ajustado em ' || v_pct || '%.', 'produtos', coalesce(v_prod, 0));
end $$;

revoke all on function public.api_ajustar_precos_produtos_lote(jsonb) from public;
grant execute on function public.api_ajustar_precos_produtos_lote(jsonb) to authenticated, service_role;
