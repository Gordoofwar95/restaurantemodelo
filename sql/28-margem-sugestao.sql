-- =====================================================================
-- 28 · MARGEM POR CATEGORIA PRÉ-PREENCHIDA PELOS PREÇOS ATUAIS (18/10/2026)
--  api_margem_sugestao: para cada categoria, a pior margem hoje e um mínimo sugerido (5 pontos abaixo, em múltiplos de 5),
--  para o aviso só tocar se um produto ficar pior do que o dono já pratica. Botão "Preencher pelos meus preços atuais" usa isso.
--  Também preenche agora a configuração (só categorias que o dono ainda não definiu).
-- Aditivo. Pode rodar de novo sem erro. Rode DEPOIS do 27.
-- =====================================================================
create or replace function public._margem_pior_por_categoria() returns table (categoria_id uuid, nome text, pior numeric, sugerido numeric)
language sql stable security definer set search_path to 'public' as $$
  select c.id, c.nome, round(min(m.margem), 1), greatest(1, floor((min(m.margem) - 5) / 5) * 5)
    from categorias c
    join (select distinct on (pr.id) pr.id, pr.categoria_id, (pp.preco - pp.custo) / pp.preco * 100 margem
            from produtos pr join produto_precos pp on pp.produto_id = pr.id
           where pr.ativo and pp.preco > 0 and pp.custo > 0 order by pr.id, (pp.preco - pp.custo) / pp.preco) m on m.categoria_id = c.id
   where c.ativa group by c.id, c.nome
$$;

create or replace function public.api_margem_sugestao(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_l jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', categoria_id, 'nome', nome, 'pior', pior, 'sugerido', sugerido) order by nome), '[]'::jsonb) into v_l from _margem_pior_por_categoria();
  return jsonb_build_object('ok', true, 'categorias', v_l);
end $$;

do $$
declare v_cfg jsonb; r record;
begin
  v_cfg := coalesce((select valor from sistema where chave = 'MARGEM_POR_CATEGORIA'), '{}'::jsonb);
  -- a pré-configuração anterior (só Bebidas = 25) é substituída pelos valores calculados dos preços atuais
  if v_cfg = jsonb_build_object((select id::text from categorias where nome = 'Bebidas' limit 1), 25) then v_cfg := '{}'::jsonb; end if;
  for r in select * from _margem_pior_por_categoria() loop
    if not (v_cfg ? r.categoria_id::text) then v_cfg := v_cfg || jsonb_build_object(r.categoria_id::text, r.sugerido); end if;
  end loop;
  insert into sistema (chave, valor, atualizado_em) values ('MARGEM_POR_CATEGORIA', v_cfg, now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  insert into sistema (chave, valor, atualizado_em) select 'MARGEM_AVISADOS', coalesce(jsonb_agg(produto_id order by produto_id), '[]'::jsonb), now() from _margem_baixa()
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
end $$;
