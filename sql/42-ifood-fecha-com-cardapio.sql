-- 42 · iFood: o botão de fechar/abrir o cardápio também fecha/abre a loja no iFood.
-- (Admin/Operador usam "Fechar cardápio" um pouco antes de fechar o caixa: o iFood fecha junto.)
-- Ao abrir o caixa, a loja do iFood só abre se o cardápio NÃO estiver fechado à mão.
-- Pode rodar de novo sem erro.
create or replace function pg_temp.rep(d text, a text, b text) returns text language plpgsql as $f$
begin
  if position(a in d) = 0 then raise exception 'Trecho não encontrado: %', left(a, 80); end if;
  return replace(d, a, b);
end $f$;

do $do$
declare d text; d2 text;
begin
  select pg_get_functiondef('public.api_salvar_cardapio_fechamento(jsonb)'::regprocedure) into d;
  if position('loja_fechar' in d) = 0 then
    d2 := pg_temp.rep(d, 'v_antes jsonb; v_n int := 0;', 'v_antes jsonb; v_n int := 0; v_ant_ativo boolean;');
    d2 := pg_temp.rep(d2, E'  perform _cfg_gravar(''CardapioFechadoManual'', jsonb_build_object(''ativo'', v_ativo, ''mensagem'', v_msg));',
$c$  v_ant_ativo := coalesce((select (valor->>'ativo')::boolean from sistema where chave = 'CardapioFechadoManual'), false);
  perform _cfg_gravar('CardapioFechadoManual', jsonb_build_object('ativo', v_ativo, 'mensagem', v_msg));
  -- iFood: fechar/abrir o cardápio também fecha/abre a loja no iFood (só quando o estado mudou)
  if v_ativo is distinct from v_ant_ativo and public._integracao_ligada('ifood') then
    if v_ativo then
      update ifood_loja set fechada_por_nos = true where id;
      perform public._ifood_enfileirar('LOJA', 'loja_fechar', '{}'::jsonb);
    else
      update ifood_loja set fechada_por_nos = false, pausada_ate = null where id;
      perform public._ifood_enfileirar('LOJA', 'loja_abrir', '{}'::jsonb);
    end if;
  end if;$c$);
    execute d2;
  end if;

  select pg_get_functiondef('public._ifood_trg_caixa()'::regprocedure) into d;
  if position('CardapioFechadoManual' in d) = 0 then
    d2 := pg_temp.rep(d, 'if tg_op = ''INSERT'' and new.status::text = ''Aberto'' then',
      'if tg_op = ''INSERT'' and new.status::text = ''Aberto'' and not coalesce((select (valor->>''ativo'')::boolean from sistema where chave = ''CardapioFechadoManual''), false) then');
    execute d2;
  end if;
end $do$;
