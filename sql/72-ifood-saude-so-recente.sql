-- 72 · Saúde do sistema: o iFood só fica amarelo por ação com erro/dúvida das ÚLTIMAS 2 HORAS
-- (antes era 1 dia, e erros antigos mantinham o alerta aceso à toa). Os erros continuam visíveis na tela do iFood. Idempotente.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace s on s.oid=p.pronamespace where s.nspname='public' and p.proname='_saude_integracoes';
  if d like '%ifood_acoes where estado in (''erro'', ''duvida'') and criado_em > now() - interval ''1 day''%' then
    d := replace(d, 'ifood_acoes where estado in (''erro'', ''duvida'') and criado_em > now() - interval ''1 day''', 'ifood_acoes where estado in (''erro'', ''duvida'') and criado_em > now() - interval ''2 hours''');
    execute d;
  end if;
end $$;
