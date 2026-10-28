-- =====================================================================
-- 19 · MOSTRAR/ESCONDER VÁRIOS PRODUTOS DO CARDÁPIO DE UMA VEZ (18/10/2026)
-- Admin marca vários produtos e mostra ou esconde todos juntos (mesmo efeito do "Visível no cardápio" de cada produto). Fica na auditoria. Aditivo: 1 função nova.
-- =====================================================================
create or replace function public.api_visibilidade_lote_produtos(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_ids uuid[]; v_ativo boolean := coalesce(p->>'ativo', '') <> 'false'; v_n int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select coalesce(array_agg(_uuid(x)), '{}') into v_ids from jsonb_array_elements_text(coalesce(p->'ids', '[]'::jsonb)) x;
  if coalesce(array_length(v_ids, 1), 0) = 0 then return _falha('Marque pelo menos um produto.'); end if;
  if array_length(v_ids, 1) > 500 then return _falha('Marque no máximo 500 produtos por vez.'); end if;
  update produtos set ativo = v_ativo where id = any(v_ids) and ativo is distinct from v_ativo;
  get diagnostics v_n = row_count;
  perform _auditar('Cardápio em lote: ' || case when v_ativo then 'produtos mostrados' else 'produtos escondidos' end, v_n || ' produto(s) alterado(s)');
  return jsonb_build_object('ok', true, 'message', v_n || ' produto(s) ' || case when v_ativo then 'agora aparecem' else 'foram escondidos' end || ' no cardápio.', 'alterados', v_n);
end $$;

revoke all on function public.api_visibilidade_lote_produtos(jsonb) from public;
grant execute on function public.api_visibilidade_lote_produtos(jsonb) to authenticated, service_role;
