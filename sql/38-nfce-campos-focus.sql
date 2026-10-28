-- 38 · Nota fiscal (NFC-e): ajusta o corpo enviado à Focus NFe ao exemplo oficial da Focus
--   • a lista de produtos se chama "items" (estava "itens": a Focus recusaria toda nota);
--   • totais da nota (valor_produtos, valor_desconto, valor_outras_despesas, valor_total) como no exemplo oficial;
--   • tipo_documento e finalidade_emissao explícitos (1 = saída, normal), como no exemplo oficial;
--   • cartão (crédito/débito): bandeira_operadora "99" (outras), como o exemplo oficial traz o campo.
-- Pode rodar de novo sem erro. A integração de nota fiscal continua desligada até você ligar.
do $$
declare d text;
begin
  select pg_get_functiondef('public.nfce_montar(bigint)'::regprocedure) into d;
  if position('''items'', v_itens' in d) = 0 then
    if position('''itens'', v_itens' in d) = 0 then raise exception 'trecho "itens" não encontrado em nfce_montar'; end if;
    d := replace(d, '''itens'', v_itens', '''items'', v_itens');
  end if;
  if position('''valor_produtos''' in d) = 0 then
    if position('''formas_pagamento'', v_pags)' in d) = 0 then raise exception 'trecho "formas_pagamento" não encontrado em nfce_montar'; end if;
    d := replace(d, '''formas_pagamento'', v_pags)',
      '''formas_pagamento'', v_pags, ''tipo_documento'', 1, ''finalidade_emissao'', 1, ''valor_produtos'', round(v_bruto, 2), ''valor_desconto'', round(v_desc, 2), ''valor_outras_despesas'', nullif(round(v_outras, 2), 0), ''valor_total'', v_total)');
  end if;
  if position('bandeira_operadora' in d) = 0 then
    if position('  v_cpf := coalesce(n.cpf, v.cpf_nota);' in d) = 0 then raise exception 'trecho "v_cpf" não encontrado em nfce_montar'; end if;
    d := replace(d, '  v_cpf := coalesce(n.cpf, v.cpf_nota);',
      '  select coalesce(jsonb_agg(case when x.e->>''forma_pagamento'' in (''03'', ''04'') then x.e || ''{"bandeira_operadora":"99"}''::jsonb else x.e end order by x.i), ''[]''::jsonb) into v_pags from jsonb_array_elements(v_pags) with ordinality as x(e, i);' || chr(10) || '  v_cpf := coalesce(n.cpf, v.cpf_nota);');
  end if;
  execute d;
end $$;
