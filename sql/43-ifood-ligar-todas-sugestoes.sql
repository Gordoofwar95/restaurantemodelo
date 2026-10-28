-- 43: "Ligar todos os itens com nome igual" (Itens do iFood). Liga de uma vez todos os itens do iFood sem ligação
-- que têm sugestão única (mesmo nome de produto, adicional ou combo ativo). O resto continua para tratar à mão.
create or replace function public.api_ifood_ligar_item(p jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public'
as $$
declare v_chave text := p->>'chave'; v_tipo text := p->>'tipo'; v_id uuid := nullif(p->>'id', '')::uuid; v_ignorar boolean := coalesce((p->>'ignorar')::boolean, false);
  v_todas boolean := coalesce((p->>'todasSugestoes')::boolean, false); r record; s jsonb; v_n int := 0; v_resta int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_todas then
    for r in select chave, nome, tipo from ifood_itens where produto_id is null and combo_id is null and adicional_id is null and not ignorar loop
      s := public._ifood_sugestao(r.nome, r.tipo);
      if s is null then continue; end if;
      if s->>'tipo' = 'produto' then update ifood_itens set produto_id = (s->>'id')::uuid, ligado_em = now() where chave = r.chave;
      elsif s->>'tipo' = 'combo' then update ifood_itens set combo_id = (s->>'id')::uuid, ligado_em = now() where chave = r.chave;
      elsif s->>'tipo' = 'adicional' then update ifood_itens set adicional_id = (s->>'id')::uuid, ligado_em = now() where chave = r.chave;
      else continue; end if;
      v_n := v_n + 1;
    end loop;
    select count(*) into v_resta from ifood_itens where produto_id is null and combo_id is null and adicional_id is null and not ignorar;
    perform _auditar('Itens do iFood ligados em lote', v_n || ' item(ns) pelo nome igual');
    return api_ifood_itens('{}') || jsonb_build_object('ligados', v_n, 'restam', v_resta, 'message',
      v_n || ' item(ns) ligado(s) pelo nome igual.' || case when v_resta > 0 then ' Faltam ' || v_resta || ' para você tratar.' else ' Nada pendente.' end);
  end if;
  if not exists (select 1 from ifood_itens where chave = v_chave) then return _falha('Item não encontrado.'); end if;
  if v_ignorar then
    update ifood_itens set ignorar = true, produto_id = null, combo_id = null, adicional_id = null, ligado_em = now() where chave = v_chave;
  elsif v_tipo = 'produto' and exists (select 1 from produtos where id = v_id) then
    update ifood_itens set ignorar = false, produto_id = v_id, combo_id = null, adicional_id = null, ligado_em = now() where chave = v_chave;
  elsif v_tipo = 'combo' and exists (select 1 from combos where id = v_id) then
    update ifood_itens set ignorar = false, produto_id = null, combo_id = v_id, adicional_id = null, ligado_em = now() where chave = v_chave;
  elsif v_tipo = 'adicional' and exists (select 1 from adicionais where id = v_id) then
    update ifood_itens set ignorar = false, produto_id = null, combo_id = null, adicional_id = v_id, ligado_em = now() where chave = v_chave;
  elsif v_tipo = 'desligar' then
    update ifood_itens set ignorar = false, produto_id = null, combo_id = null, adicional_id = null, ligado_em = null where chave = v_chave;
  else return _falha('Escolha um item válido do sistema.'); end if;
  perform _auditar('Item do iFood ligado', v_chave || ' → ' || coalesce(v_tipo, '') || case when v_ignorar then ' (ignorar)' else '' end);
  return api_ifood_itens('{}');
end $$;
revoke all on function public.api_ifood_ligar_item(jsonb) from public, anon;
grant execute on function public.api_ifood_ligar_item(jsonb) to authenticated, service_role;
