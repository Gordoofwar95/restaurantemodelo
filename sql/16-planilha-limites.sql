-- =====================================================================
-- 16 · LIMITES DA PLANILHA (18/10/2026)
-- A planilha principal guarda o arquivo (Arquivo_*) e o Google limita cada planilha a 10 milhões de células. Medidas:
--  • o arquivamento passa a registrar quantas células a planilha já reserva (sistema.planilha_celulas);
--  • aviso ao Admin (repetindo até resolver) quando passar de 80% (8 milhões) e quando o arquivamento falhar;
--  • nada é apagado do Supabase sem a planilha confirmar (lê de volta), então falta de espaço na planilha só PARA o arquivamento, não perde dados.
-- Aditivo: 2 funções novas e 1 agendamento. Pode rodar de novo sem erro.
-- =====================================================================
create or replace function public.api_planilha_uso_registrar(p_celulas bigint) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(p_celulas, 0) <= 0 then return; end if;
  insert into sistema (chave, valor, atualizado_em) values ('planilha_celulas', to_jsonb(p_celulas), now())
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
end $$;
revoke all on function public.api_planilha_uso_registrar(bigint) from public, anon, authenticated;
grant execute on function public.api_planilha_uso_registrar(bigint) to service_role;

create or replace function public.alertas_planilha_cron() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare ativos text[] := '{}'; v_cel bigint; v_pct int; r record;
begin
  -- 1) planilha principal ficando cheia (limite do Google: 10 milhões de células)
  select (valor #>> '{}')::bigint into v_cel from sistema where chave = 'planilha_celulas';
  if v_cel is not null then
    v_pct := round(v_cel / 100000.0);
    if v_pct >= 80 then
      ativos := array_append(ativos, 'sis:planilha_cheia');
      perform _alertas_sistema_avisar('sis:planilha_cheia', 'Planilha principal ficando cheia (' || v_pct || '%)',
        'A planilha já reserva ' || v_cel || ' de 10.000.000 células (limite do Google). Quando chegar a 100% o arquivamento para, mas nada se perde. Solução: criar uma planilha nova para o arquivo antigo (peça ajuda antes de passar de 90%).');
    end if;
  end if;
  -- 2) o último arquivamento (automático ou de emergência) terminou com erro
  select a.data_hora, a.detalhes into r from auditoria a
   where a.acao ilike 'Arquivamento%' and a.data_hora > now() - interval '26 hours' order by a.data_hora desc limit 1;
  if r.data_hora is not null and r.detalhes ~ '"erro":"' then
    ativos := array_append(ativos, 'sis:arquivo_falha');
    perform _alertas_sistema_avisar('sis:arquivo_falha', 'Arquivamento para a planilha falhou',
      'O último arquivamento terminou com erro: ' || left(substring(r.detalhes from '"erro":"([^"]*)"'), 200) || '. Nada foi apagado do Supabase. Veja em Sistema → Backup e espaço.');
  end if;
  update alertas_envios set resolvido_em = now() where tipo = 'sistema' and resolvido_em is null and chave in ('sis:planilha_cheia', 'sis:arquivo_falha') and not (chave = any(ativos));
  return jsonb_build_object('ok', true, 'ativos', to_jsonb(ativos));
end $$;
revoke all on function public.alertas_planilha_cron() from public, anon, authenticated;
grant execute on function public.alertas_planilha_cron() to service_role;

select cron.schedule('alertas-planilha-hora', '20 * * * *', 'select public.alertas_planilha_cron()');
