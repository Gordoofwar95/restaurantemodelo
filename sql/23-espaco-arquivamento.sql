-- =====================================================================
-- 23 · ESPAÇO DO BANCO E ARQUIVAMENTO CONFIGURÁVEL (18/10/2026)
--  1) Proteção dos 95% TRAVADA: sempre ligada e sempre em 95% (gatilho no banco; nem alteração direta consegue desligar).
--  2) "Tamanho do banco do meu plano" (500 MB grátis, 8 GB Pro, ou outro): api_espaco_plano_salvar. Porcentagens e proteção usam esse número.
--  3) Depois de cada arquivamento, o espaço é DEVOLVIDO de verdade: o banco só encolhe com "vacuum full"; uma tarefa de uso único é agendada
--     para 3 minutos depois do envio à planilha (sem isso o tamanho continuaria igual e a proteção nunca enxergaria o ganho).
--  4) Avisos de espaço aos 70% e 85% do limite do plano (antes: fixo em 400 MB).
-- Aditivo. Pode rodar de novo sem erro.
-- =====================================================================

-- 1) trava dos 95%
create or replace function public._backup_config_trava() returns trigger
language plpgsql set search_path to 'public' as $$
begin new.arquivar_emerg_ativo := true; new.arquivar_emerg_pct := 95; return new; end $$;
create or replace trigger backup_config_trava before insert or update on public.backup_config
  for each row execute function public._backup_config_trava();
update public.backup_config set arquivar_emerg_ativo = true, arquivar_emerg_pct = 95 where id;

-- 2) tamanho do banco do plano
create or replace function public.api_espaco_plano_salvar(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v numeric := _num(p->>'limiteMb', 0);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v < 100 or v > 2000000 then return _falha('Informe o tamanho do banco do seu plano em MB (entre 100 e 2.000.000). Grátis: 500. Pro: 8192.'); end if;
  insert into sistema (chave, valor, atualizado_em) values ('LIMITE_BANCO_MB', to_jsonb(v), now())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  perform _auditar('Tamanho do banco do plano alterado', v || ' MB');
  return jsonb_build_object('ok', true, 'message', 'Salvo: o sistema passa a considerar ' || v || ' MB como o limite do banco.', 'limiteMb', v);
end $$;
revoke all on function public.api_espaco_plano_salvar(jsonb) from public;
grant execute on function public.api_espaco_plano_salvar(jsonb) to authenticated, service_role;

-- 3) devolver o espaço depois de arquivar
create or replace function public._compactar_agendar() returns void
language plpgsql security definer set search_path to 'public', 'cron' as $$
declare r record; v_quando timestamptz := now() + interval '3 minutes'; v_pendente boolean := false;
begin
  for r in select jobname from cron.job where jobname like 'compactar-%' loop
    if coalesce(nullif(substring(r.jobname from 'compactar-(\d+)'), '')::bigint, 0) < extract(epoch from now() - interval '15 minutes') then
      perform cron.unschedule(r.jobname);
    else v_pendente := true; end if;
  end loop;
  if v_pendente then return; end if;
  perform cron.schedule('compactar-' || floor(extract(epoch from v_quando))::bigint,
    extract(minute from v_quando at time zone 'UTC')::int || ' ' || extract(hour from v_quando at time zone 'UTC')::int || ' ' ||
    extract(day from v_quando at time zone 'UTC')::int || ' ' || extract(month from v_quando at time zone 'UTC')::int || ' *',
    'vacuum full public.vendas, public.itens_venda, public.pagamentos_venda, public.caixa_sessoes, public.sangrias, public.vendas_resumo_arquivo, public.arquivo_historico');
end $$;
revoke all on function public._compactar_agendar() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'api_arquivar_confirmar_caixa' and p.prosrc not like '%_arquivar_confirmar_caixa_base%') then
    alter function public.api_arquivar_confirmar_caixa(uuid[]) rename to _arquivar_confirmar_caixa_base;
  end if;
end $$;
create or replace function public.api_arquivar_confirmar_caixa(p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare r jsonb;
begin
  r := _arquivar_confirmar_caixa_base(p_ids);
  begin perform _compactar_agendar(); exception when others then null; end;
  return r;
end $$;
revoke all on function public.api_arquivar_confirmar_caixa(uuid[]) from public, anon, authenticated;
grant execute on function public.api_arquivar_confirmar_caixa(uuid[]) to service_role;
revoke all on function public._arquivar_confirmar_caixa_base(uuid[]) from public, anon, authenticated;

create or replace function public.api_arquivar_confirmar_vendas(p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare r jsonb;
begin
  update pagamentos_online po set venda_numero = v.numero_pedido from vendas v where v.id = po.venda_id and po.venda_id = any(p_ids) and po.venda_numero is null;
  r := _arquivar_confirmar_vendas_base(p_ids);
  begin perform _compactar_agendar(); exception when others then null; end;
  return r;
end $$;
revoke all on function public.api_arquivar_confirmar_vendas(uuid[]) from public, anon, authenticated;
grant execute on function public.api_arquivar_confirmar_vendas(uuid[]) to service_role;

-- 4) avisos de espaço aos 70% e 85% do limite do plano (ajusta só o trecho do aviso dentro de alertas_sistema_cron)
do $$
declare v_def text;
begin
  select pg_get_functiondef('public.alertas_sistema_cron'::regproc) into v_def;
  if v_def like '%400 * 1024 * 1024%' then
    v_def := replace(v_def, $q$if v_tam > 400 * 1024 * 1024 then$q$, $q$if v_tam > _limite_banco_mb() * 1048576 * 0.70 then$q$);
    v_def := replace(v_def, $q$'Usando ' || round(v_tam / 1048576.0) || ' MB de 500 MB. Arquive vendas antigas em Sistema → Backup e espaço.', interval '24 hours'$q$,
      $q$case when v_tam > _limite_banco_mb() * 1048576 * 0.85 then 'Usando ' || round(v_tam / 1048576.0) || ' MB de ' || round(_limite_banco_mb()) || ' MB (mais de 85%). Aos 95% o sistema arquiva sozinho o que for mais antigo. Se o seu plano não é mais o grátis, confira o tamanho em Sistema → Backup e espaço.' else 'Usando ' || round(v_tam / 1048576.0) || ' MB de ' || round(_limite_banco_mb()) || ' MB (mais de 70%). Arquive vendas antigas em Sistema → Backup e espaço. Se o seu plano não é mais o grátis, confira o tamanho informado lá.' end, case when v_tam > _limite_banco_mb() * 1048576 * 0.85 then interval '12 hours' else interval '24 hours' end$q$);
    execute v_def;
  end if;
end $$;

-- 23b - Assistente: verbete "Arquivamento e uso do banco" atualizado (modo automático/manual, tamanho do plano, proteção dos 95% travada)
insert into public.ai_ajuda (slug,titulo,palavras_chave,passos,perfis,ativo,grupo,ordem,comuns) values
($t$man-admin-14-arquivamento-e-uso-do-banco$t$,$t$Arquivamento e uso do banco$t$,$t$arquivamento uso do banco espaço limite plano pago pro gratuito 500 mb 95% proteção automático manual desligar arquivar dias prazo planilha supabase cheio$t$,
$t$Administrador → Sistema → Backup e espaço → bloco "Uso do Supabase".
Em "Tamanho do banco do seu plano" informe o plano do Supabase: Grátis (500 MB), Pro (8 GB) ou outro tamanho (confira no painel do Supabase). A porcentagem de uso e a proteção usam esse número; se você pagar o Supabase, atualize aqui.
Em "Arquivamento por idade": Automático (todo dia de madrugada, vendas e caixas fechados com mais de X dias vão para a planilha, abas Arquivo_*) ou Só manual (o sistema não arquiva sozinho; você manda em "Mandar para a planilha agora"). O prazo é livre (mínimo 30 dias). "Simular" mostra o que sairia sem mover nada.
"Proteção de espaço" é sempre ligada e não dá para desligar nem mudar: ao chegar a 95% do tamanho do plano, o sistema manda para a planilha, aos poucos (até 1.000 vendas por hora), as vendas e caixas já encerrados, do mais antigo para o mais novo, e minutos depois devolve o espaço ao Supabase. O que tem menos de 1 dia, pedido em andamento e caixa aberto nunca saem; só remove do Supabase o que a planilha confirmou. Aos 70% e 85% você recebe aviso.
Relatórios e Visão Geral buscam o arquivo automaticamente quando o período pedido é antigo. Fotos ficam no Google Drive principal, com cópia no Drive da contingência. Ao anonimizar um cliente (LGPD), os pedidos dele arquivados na planilha também são limpos, de madrugada.$t$,
ARRAY['Admin'],true,'lista',14,$t$$t$)
on conflict (slug) do update set titulo=excluded.titulo, palavras_chave=excluded.palavras_chave, passos=excluded.passos, perfis=excluded.perfis, ativo=excluded.ativo, grupo=excluded.grupo, ordem=excluded.ordem, comuns=excluded.comuns, atualizado_em=now();
