-- 39 · iFood: botão "Testar conexão" (antes, o item "Teste de conexão deu certo" só era marcado depois de LIGAR, e só dava para ligar depois dele)
--   • api_ifood_testar: Administrador pede o teste; a Edge Function "ifood-teste" pede um acesso ao iFood com as chaves digitadas e confere a loja;
--   • o item da lista passa a valer quando o último teste/consulta deu certo DEPOIS da última troca de chaves.
-- Pode rodar de novo sem erro.
do $$
declare d text;
begin
  select pg_get_functiondef('public._integ_pendencias(text,text)'::regprocedure) into d;
  if position('''teste_conexao''' in d) = 0 then
    if position('        when ''chaves'' then (' in d) = 0 then raise exception 'ponto de troca não encontrado em _integ_pendencias'; end if;
    d := replace(d, '        when ''chaves'' then (',
      '        when ''teste_conexao'' then exists (select 1 from ifood_estado e where e.id and e.token_ok is true and e.ultimo_erro is null and e.ultima_consulta_ok is not null and e.ultima_consulta_ok >= coalesce((select max(atualizado_em) from integracoes_segredos where chave like ''ifood\_%''), ''-infinity''::timestamptz))' || chr(10) || '        when ''chaves'' then (');
    execute d;
  end if;
end $$;

create or replace function public.api_ifood_testar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare e ifood_estado%rowtype; v_desde timestamptz;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if coalesce((p->>'ler')::boolean, false) then
    v_desde := nullif(p->>'desde', '')::timestamptz;
    select * into e from ifood_estado where id;
    if v_desde is null or e.ultima_consulta is null or e.ultima_consulta < v_desde then return jsonb_build_object('ok', true, 'pronto', false); end if;
    return jsonb_build_object('ok', true, 'pronto', true, 'certo', (coalesce(e.token_ok, false) and e.ultimo_erro is null), 'erro', e.ultimo_erro);
  end if;
  if (select count(*) from integracoes_segredos where chave in ('ifood_client_id', 'ifood_client_secret', 'ifood_merchant_id')) < 3 then
    return _falha('Digite antes o Client ID, o Client Secret e o código da loja (Merchant ID).');
  end if;
  perform public.chamar_edge('ifood-teste', '{}'::jsonb);
  return jsonb_build_object('ok', true, 'desde', now());
end $$;
revoke all on function public.api_ifood_testar(jsonb) from public, anon;
grant execute on function public.api_ifood_testar(jsonb) to authenticated, service_role;
