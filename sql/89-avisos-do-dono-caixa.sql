-- 89 · Avisos para todos os perfis Admin: caixa esquecido aberto, iFood com caixa fechado e resumo semanal do caixa.
create or replace function public._dono_avisar(p_chave text, p_titulo text, p_texto text, p_repetir interval default interval '6 hours')
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare e alertas_envios%rowtype;
begin
  select * into e from alertas_envios where chave = p_chave for update;
  if e.chave is not null and e.resolvido_em is null and (e.silenciado or now() - e.ultimo_em < p_repetir) then return false; end if;
  insert into alertas_envios (chave, tipo, titulo, texto) values (p_chave, 'dono', p_titulo, p_texto)
  on conflict (chave) do update set ultimo_em = now(), vezes = case when alertas_envios.resolvido_em is null then alertas_envios.vezes + 1 else 1 end,
     resolvido_em = null, titulo = excluded.titulo, texto = excluded.texto, silenciado = false;
  insert into auditoria (usuario_login, acao, detalhes) values ('sistema', 'AVISO AO ADMIN: ' || left(p_titulo, 80), left(p_texto, 300));
  perform _alertas_push('⚠️ ' || p_titulo, p_texto, 'dono-' || left(p_chave, 40), array['Admin']);
  return true;
end $$;

create or replace function public.alertas_dono_cron()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare ativos text[] := '{}'; v_cx caixa_sessoes%rowtype; v_n int; v_h int := extract(hour from (now() at time zone 'America/Sao_Paulo'))::int;
begin
  select * into v_cx from caixa_sessoes where status = 'Aberto' order by abertura desc limit 1;
  if v_cx.id is not null and _caixa_vencido(v_cx.id) and now() > _caixa_vence_em(v_cx.abertura) + interval '1 hour' then
    ativos := array_append(ativos, 'dono:caixa_vencido');
    perform _dono_avisar('dono:caixa_vencido', 'Caixa esquecido aberto',
      'O caixa aberto em ' || to_char(v_cx.abertura at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' passou do horário e ainda não foi fechado.', interval '6 hours');
  end if;
  if v_cx.id is null and v_h between 9 and 22 then
    select count(*) into v_n from vendas where canal = 'iFood' and caixa_id is null and status = 'Confirmada'
       and data_hora > now() - interval '3 days' and data_hora < now() - interval '10 minutes';
    if v_n > 0 then
      ativos := array_append(ativos, 'dono:ifood_sem_caixa');
      perform _dono_avisar('dono:ifood_sem_caixa', 'iFood com o caixa fechado',
        v_n || ' pedido(s) do iFood chegaram com o caixa fechado. Abra o caixa para eles entrarem nas vendas do dia.', interval '3 hours');
    end if;
  end if;
  update alertas_envios set resolvido_em = now() where tipo = 'dono' and resolvido_em is null and not (chave = any(ativos));
  return jsonb_build_object('ok', true, 'ativos', to_jsonb(ativos));
end $$;

create or replace function public.relatorio_dono_semanal()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_tot int; v_atr int; v_dif int; v_quem text; v_txt text;
begin
  select count(*), count(*) filter (where fechamento_atrasado), count(*) filter (where abs(coalesce(diferenca, 0)) > 0.009)
    into v_tot, v_atr, v_dif from caixa_sessoes where status = 'Fechado' and fechamento > now() - interval '7 days';
  select string_agg(distinct coalesce(u.login, '?'), ', ') into v_quem from caixa_sessoes c left join usuarios u on u.id = c.usuario_fechamento
    where c.status = 'Fechado' and c.fechamento > now() - interval '7 days' and c.fechamento_atrasado;
  v_txt := case when v_tot = 0 then 'Nenhum caixa foi fechado nesta semana.'
    when v_atr = 0 and v_dif = 0 then v_tot || ' caixa(s) na semana, todos fechados no prazo e sem diferença.'
    else v_tot || ' caixa(s) na semana: ' || v_atr || ' fechado(s) com atraso' || case when v_quem is not null then ' (' || v_quem || ')' else '' end || ', ' || v_dif || ' com diferença.' end;
  insert into auditoria (usuario_login, acao, detalhes) values ('sistema', 'RESUMO SEMANAL DO CAIXA', left(v_txt, 300));
  perform _alertas_push('📋 Caixa da semana', left(v_txt, 140), 'dono-semana', array['Admin']);
  return jsonb_build_object('ok', true, 'texto', v_txt);
end $$;

revoke all on function public._dono_avisar(text,text,text,interval), public.alertas_dono_cron(), public.relatorio_dono_semanal() from public, anon, authenticated;

select cron.schedule('alertas-dono-10min', '*/10 * * * *', 'select public.alertas_dono_cron()');
select cron.schedule('relatorio-dono-semanal', '0 12 * * 1', 'select public.relatorio_dono_semanal()');
