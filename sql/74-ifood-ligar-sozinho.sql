-- 74 · Itens do iFood se ligam sozinhos quando o nome é EXATAMENTE igual ao de um produto, combo ou adicional ativo
-- (mesma regra da "sugestão"). Ficam marcados como "ligado automaticamente" e continuam com o botão Desfazer. Idempotente.
alter table public.ifood_itens add column if not exists ligado_auto boolean not null default false;

do $$
declare d text; n int;
begin
  -- 1) todo item visto (pedido ou cardápio) tenta a ligação pelo nome igual
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.proname = '_ifood_item_visto' and p.pronamespace = 'public'::regnamespace;
  if d not like '%ligado_auto%' then
    d := replace(d, 'declare r ifood_itens%rowtype; v_u uuid;', 'declare r ifood_itens%rowtype; v_u uuid; s jsonb;');
    n := (length(d) - length(replace(d, E'  end if;\n  return r;\nend', ''))) / length(E'  end if;\n  return r;\nend');
    if n <> 1 then raise exception '_ifood_item_visto mudou (fim: %)', n; end if;
    d := replace(d, E'  end if;\n  return r;\nend', $x$  end if;
  if r.produto_id is null and r.combo_id is null and r.adicional_id is null and not r.ignorar then
    s := public._ifood_sugestao(r.nome, p_tipo);
    if s is not null then
      update ifood_itens set produto_id = case when s->>'tipo' = 'produto' then (s->>'id')::uuid end, combo_id = case when s->>'tipo' = 'combo' then (s->>'id')::uuid end,
        adicional_id = case when s->>'tipo' = 'adicional' then (s->>'id')::uuid end, ligado_em = now(), ligado_auto = true where chave = p_chave returning * into r;
    end if;
  end if;
  return r;
end$x$);
    execute d;
  end if;
  -- 2) a lista de itens informa quais foram ligados sozinhos
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.proname = 'api_ifood_itens' and p.pronamespace = 'public'::regnamespace;
  if d not like '%ligado_auto%' then
    d := replace(d, '''ignorar'', i.ignorar,', '''ignorar'', i.ignorar, ''auto'', i.ligado_auto,'); execute d;
  end if;
  -- 3) ligar/desfazer à mão tira a marca de automático
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.proname = 'api_ifood_ligar_item' and p.pronamespace = 'public'::regnamespace;
  if d not like '%ligado_auto%' then
    d := replace(replace(d, 'ligado_em = now()', 'ligado_em = now(), ligado_auto = false'), 'ligado_em = null where', 'ligado_em = null, ligado_auto = false where'); execute d;
  end if;
end $$;

-- 4) liga agora os que já estão esperando (nome exatamente igual)
do $$
declare r record; s jsonb; k int := 0;
begin
  for r in select chave, nome, tipo from ifood_itens where produto_id is null and combo_id is null and adicional_id is null and not ignorar loop
    s := public._ifood_sugestao(r.nome, r.tipo);
    if s is null then continue; end if;
    update ifood_itens set produto_id = case when s->>'tipo' = 'produto' then (s->>'id')::uuid end, combo_id = case when s->>'tipo' = 'combo' then (s->>'id')::uuid end,
      adicional_id = case when s->>'tipo' = 'adicional' then (s->>'id')::uuid end, ligado_em = now(), ligado_auto = true where chave = r.chave;
    k := k + 1;
  end loop;
  if k > 0 then perform public._auditar('Itens do iFood ligados automaticamente', k || ' item(ns) pelo nome igual'); end if;
end $$;
