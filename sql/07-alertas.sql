-- =====================================================================
-- Fases 7.1 e 7.2 (auditoria 18/10/2026) — ALERTAS AUTOMÁTICOS. Só AVISAM: nunca mudam status, pagamento, estoque ou caixa.
-- 7.1: falhas do sistema e vencimentos → Admin (push + e-mail pela planilha principal).
-- 7.2: pedido parado no mesmo status → quem precisa agir (push com o app fechado; o app aberto toca o som e mostra a lista).
-- Tudo aditivo: 2 tabelas novas, funções novas, 2 agendamentos novos; api_push_inscrever passa a aceitar Cozinha e Garçom.
-- =====================================================================

create table if not exists public.alertas_config (
  id boolean primary key default true check (id),
  regras jsonb not null default '{}'::jsonb,         -- {"recebido":{"ligado":true,"min":3}, ...} (o que faltar usa o padrão)
  repetir_min int not null default 5,                 -- repetição do aviso enquanto continuar parado
  escalar_apos int not null default 3,                -- depois de N avisos sem ação, avisa também o Admin
  vencimentos jsonb not null default '[]'::jsonb,     -- [{"item":"Certificado digital","vence":"2027-03-01"}]
  email_ativo boolean not null default true,          -- alertas do sistema também por e-mail (dono da planilha principal)
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid
);
insert into public.alertas_config (id) values (true) on conflict (id) do nothing;
alter table public.alertas_config enable row level security;

create table if not exists public.alertas_envios (
  chave text primary key,                -- 'ped:<venda>:<regra>' ou 'sis:<assunto>'
  tipo text not null,                    -- 'pedido' | 'sistema'
  venda_id uuid,
  regra text,
  titulo text, texto text,
  primeiro_em timestamptz not null default now(),
  ultimo_em timestamptz not null default now(),
  vezes int not null default 1,
  resolvido_em timestamptz,
  adiado_ate timestamptz,
  silenciado boolean not null default false,
  silenciado_por uuid
);
create index if not exists alertas_envios_ativos on public.alertas_envios (tipo) where resolvido_em is null;
alter table public.alertas_envios enable row level security;

-- ---------- padrão das 7 regras (o dono ajusta no Admin) ----------
create or replace function public._alertas_padrao() returns jsonb language sql immutable as $$
  select '{"recebido":{"ligado":true,"min":3},"preparo":{"ligado":true,"min":25},"pronta_retirada":{"ligado":true,"min":10},
           "pronta_entrega":{"ligado":true,"min":8},"pronta_mesa":{"ligado":true,"min":5},"saiu":{"ligado":true,"min":45},
           "a_receber":{"ligado":true,"min":15}}'::jsonb
$$;

create or replace function public._alertas_cfg() returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare c alertas_config%rowtype; v_reg jsonb := _alertas_padrao(); k text;
begin
  select * into c from alertas_config where id;
  for k in select jsonb_object_keys(_alertas_padrao()) loop
    if c.regras ? k then v_reg := jsonb_set(v_reg, array[k], (v_reg->k) || (c.regras->k)); end if;
  end loop;
  return jsonb_build_object('regras', v_reg, 'repetirMin', coalesce(c.repetir_min, 5), 'escalarApos', coalesce(c.escalar_apos, 3),
                            'vencimentos', coalesce(c.vencimentos, '[]'::jsonb), 'emailAtivo', coalesce(c.email_ativo, true));
end $$;

-- ---------- 7.2: quais pedidos estão parados agora (hora do SERVIDOR) ----------
create or replace function public._alertas_pedidos_parados()
returns table (venda_id uuid, numero int, regra text, rotulo text, desde timestamptz, minutos int, niveis text[], tipo text)
language plpgsql stable security definer set search_path to 'public' as $$
declare v_cfg jsonb := _alertas_cfg()->'regras'; s caixa_sessoes%rowtype;
begin
  select * into s from caixa_sessoes where status = 'Aberto' order by abertura desc limit 1;
  if s.id is null then return; end if;                                  -- loja/caixa fechado: nada toca
  return query
  with base as (
    select v.id, v.numero_pedido, v.tipo::text tp, v.status_pedido::text sp, v.status_pagamento::text pg,
           v.data_hora, v.inicio_preparo_em, v.pronta_em, v.saiu_em, v.concluida_em,
           coalesce(v.observacoes_entrega, '') ilike '%AGENDADO%' agendado
      from vendas v
     where v.status = 'Confirmada'
       and (v.caixa_id = s.id or (v.caixa_id is null and v.data_hora >= s.abertura))   -- nada de caixa já fechado ou de dia anterior
       and coalesce(v.status_pedido::text, '') <> 'Suspenso'
       and not exists (select 1 from ocorrencias o where o.venda_id = v.id and o.status::text in ('Aberta', 'Em andamento'))
  ), r as (
    select id, numero_pedido, 'recebido' rg, 'Novo pedido sem aceite' rot, data_hora d, array['Cozinha','Operador'] nv, tp from base where sp = 'Recebido' and not agendado
    union all select id, numero_pedido, 'preparo', 'Em preparo há muito tempo', coalesce(inicio_preparo_em, data_hora), array['Cozinha','Operador'], tp from base where sp = 'Em preparo' and not agendado
    union all select id, numero_pedido, 'pronta_retirada', 'Pronta (retirada) sem marcar "Retirada"', coalesce(pronta_em, data_hora), array['Operador','Admin'], tp from base where sp = 'Pronta' and tp = 'Retirada'
    union all select id, numero_pedido, 'pronta_entrega', 'Pronta (entrega) sem sair para entrega', coalesce(pronta_em, data_hora), array['Operador','Admin'], tp from base where sp = 'Pronta' and tp = 'Entrega'
    union all select id, numero_pedido, 'pronta_mesa', 'Pronta (mesa) sem marcar "Servida"', coalesce(pronta_em, data_hora), array['Operador','Garçom'], tp from base where sp = 'Pronta' and tp = 'Mesa'
    union all select id, numero_pedido, 'saiu', 'Saiu para entrega e não foi concluído', coalesce(saiu_em, data_hora), array['Operador','Admin'], tp from base where sp = 'Saiu para entrega'
    union all select id, numero_pedido, 'a_receber', 'Pagamento "a receber" com o pedido pronto', coalesce(concluida_em, pronta_em, data_hora), array['Operador','Admin'], tp
      from base where pg = 'A Receber' and tp <> 'Mesa' and sp in ('Pronta', 'Retirada', 'Servida', 'Entregue')
  )
  select r.id, r.numero_pedido, r.rg, r.rot, r.d, floor(extract(epoch from (now() - r.d)) / 60)::int, r.nv, r.tp
    from r
   where coalesce((v_cfg->r.rg->>'ligado')::boolean, true)
     and now() - r.d >= make_interval(mins => greatest(1, coalesce((v_cfg->r.rg->>'min')::int, 10)));
end $$;

-- ---------- envio (push com filtro de perfil; e-mail opcional pela planilha principal) ----------
create or replace function public._alertas_push(p_titulo text, p_texto text, p_tag text, p_niveis text[], p_usuarios uuid[] default null)
returns void language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  if not exists (select 1 from push_inscricoes limit 1) then return; end if;
  perform chamar_edge('push-enviar', jsonb_build_object('tipo', 'alerta', 'titulo', p_titulo, 'texto', p_texto, 'tag', p_tag,
          'niveis', to_jsonb(p_niveis), 'usuarios', to_jsonb(p_usuarios)));
exception when others then null;
end $$;

create or replace function public._alertas_email(p_assunto text, p_texto text) returns void
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v_url text; v_chave text;
begin
  if not coalesce((select email_ativo from alertas_config where id), true) then return; end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'sheets_main_url';
  select decrypted_secret into v_chave from vault.decrypted_secrets where name = 'chave_servidor_planilha';
  if coalesce(v_url, '') = '' or coalesce(v_chave, '') = '' then return; end if;
  perform net.http_post(url := v_url, headers := '{"Content-Type":"text/plain"}'::jsonb,
          body := jsonb_build_object('chave', v_chave, 'action', 'sbAvisoEmail', 'assunto', left(p_assunto, 120), 'texto', left(p_texto, 1500)),
          timeout_milliseconds := 30000);
exception when others then null;   -- planilha sem a função nova: o push continua valendo
end $$;

-- ---------- 7.2: agendamento de 1 em 1 minuto ----------
create or replace function public.alertas_pedidos_cron() returns int
language plpgsql security definer set search_path to 'public' as $$
declare c jsonb := _alertas_cfg(); x record; e alertas_envios%rowtype; v_rep int := greatest(1, (c->>'repetirMin')::int);
        v_esc int := greatest(1, (c->>'escalarApos')::int); v_niv text[]; n int := 0; v_txt text; v_chaves text[] := '{}';
begin
  for x in select * from _alertas_pedidos_parados() loop
    v_chaves := array_append(v_chaves, 'ped:' || x.venda_id || ':' || x.regra);
    select * into e from alertas_envios where chave = 'ped:' || x.venda_id || ':' || x.regra for update;
    v_txt := x.rotulo || ' há ' || x.minutos || ' min';
    if e.chave is null or e.resolvido_em is not null then
      insert into alertas_envios (chave, tipo, venda_id, regra, titulo, texto) values ('ped:' || x.venda_id || ':' || x.regra, 'pedido', x.venda_id, x.regra, '⏰ Pedido #' || x.numero || ' parado', v_txt)
      on conflict (chave) do update set resolvido_em = null, primeiro_em = now(), ultimo_em = now(), vezes = 1, adiado_ate = null, silenciado = false, texto = excluded.texto;
      perform _alertas_push('⏰ Pedido #' || x.numero || ' parado', v_txt, 'parado-' || x.numero, x.niveis);
      n := n + 1;
    elsif not e.silenciado and coalesce(e.adiado_ate, '-infinity') <= now() and now() - e.ultimo_em >= make_interval(mins => v_rep) then
      v_niv := x.niveis; if e.vezes >= v_esc and not ('Admin' = any(v_niv)) then v_niv := array_append(v_niv, 'Admin'); end if;   -- escalada
      update alertas_envios set ultimo_em = now(), vezes = e.vezes + 1, texto = v_txt where chave = e.chave;
      perform _alertas_push('⏰ Pedido #' || x.numero || ' continua parado', v_txt || ' (' || (e.vezes + 1) || 'º aviso)', 'parado-' || x.numero, v_niv);
      n := n + 1;
    end if;
  end loop;
  -- resolveu (avançou o status, pagou, cancelou, suspendeu, abriu ocorrência, fechou o caixa): o aviso para
  update alertas_envios set resolvido_em = now() where tipo = 'pedido' and resolvido_em is null and not (chave = any(v_chaves));
  return n;
end $$;

-- ---------- 7.1: falhas do sistema e vencimentos (de 10 em 10 minutos) ----------
create or replace function public._alertas_sistema_avisar(p_chave text, p_titulo text, p_texto text, p_repetir interval default interval '6 hours')
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare e alertas_envios%rowtype;
begin
  select * into e from alertas_envios where chave = p_chave for update;
  if e.chave is not null and e.resolvido_em is null and (e.silenciado or now() - e.ultimo_em < p_repetir) then return false; end if;
  insert into alertas_envios (chave, tipo, titulo, texto) values (p_chave, 'sistema', p_titulo, p_texto)
  on conflict (chave) do update set ultimo_em = now(), vezes = case when alertas_envios.resolvido_em is null then alertas_envios.vezes + 1 else 1 end,
     resolvido_em = null, titulo = excluded.titulo, texto = excluded.texto, silenciado = false;
  insert into auditoria (usuario_login, acao, detalhes) values ('sistema', 'ALERTA: ' || left(p_titulo, 80), left(p_texto, 300));
  perform _alertas_push('⚠️ ' || p_titulo, p_texto, 'sis-' || left(p_chave, 40), array['Admin']);
  perform _alertas_email('Restaurante Demo — ' || p_titulo, p_texto || E'\n\nAviso automático do sistema (' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ').');
  return true;
end $$;

create or replace function public.alertas_sistema_cron() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare ativos text[] := '{}'; v_n int; v_t timestamptz; v_txt text; r record; v_dias int; v_cx caixa_sessoes%rowtype; v_tam bigint;
begin
  -- 1) cópia para a planilha principal parada
  select count(*), min(criado_em) into v_n, v_t from fila_sync where principal_ok_em is null;
  if v_n > 0 and v_t < now() - interval '30 minutes' then
    ativos := array_append(ativos, ('sis:sync_principal')::text);
    perform _alertas_sistema_avisar('sis:sync_principal', 'Cópia para a planilha parada', v_n || ' registro(s) esperando há ' || floor(extract(epoch from now() - v_t) / 60) || ' min. O sistema continua funcionando; confira em Sistema → Sincronização e contingência.');
  end if;
  -- 2) espelho da contingência atrasado
  select count(*), min(criado_em) into v_n, v_t from fila_sync where contingencia_ok_em is null;
  if v_n > 0 and v_t < now() - interval '90 minutes' then
    ativos := array_append(ativos, ('sis:sync_contingencia')::text);
    perform _alertas_sistema_avisar('sis:sync_contingencia', 'Planilha de contingência atrasada', v_n || ' registro(s) sem chegar na contingência há mais de 1h30. Se o Supabase cair agora, a reserva estará desatualizada.');
  end if;
  -- 3) tarefas agendadas falhando em sequência
  for r in select j.jobname, count(*) n, max(left(d.return_message, 120)) msg from cron.job_run_details d join cron.job j on j.jobid = d.jobid
            where d.status = 'failed' and d.start_time > now() - interval '30 minutes' group by j.jobname having count(*) >= 3 loop
    ativos := array_append(ativos, (('sis:cron_' || r.jobname))::text);
    perform _alertas_sistema_avisar('sis:cron_' || r.jobname, 'Tarefa automática falhando', 'A tarefa "' || r.jobname || '" falhou ' || r.n || 'x em 30 min: ' || coalesce(r.msg, ''));
  end loop;
  -- 4) Edge Functions respondendo erro em sequência
  select count(*) into v_n from net._http_response where created > now() - interval '30 minutes' and (status_code >= 500 or (status_code is null and error_msg is not null));
  if v_n >= 10 then
    ativos := array_append(ativos, ('sis:edge')::text);
    perform _alertas_sistema_avisar('sis:edge', 'Funções do servidor com erro', v_n || ' chamadas com erro nos últimos 30 min (backup, cópia, iFood, nota ou avisos).');
  end if;
  -- 5) Mercado Pago: dinheiro esperando decisão / aviso que não chega
  if _integracao_ligada('mercadopago') then
    select count(*) into v_n from pagamentos_online where decisao_pendente and decisao is null and atualizado_em < now() - interval '10 minutes';
    if v_n > 0 then ativos := array_append(ativos, ('sis:mp_decidir')::text);
      perform _alertas_sistema_avisar('sis:mp_decidir', 'Pagamento online esperando decisão', v_n || ' pagamento(s) aprovado(s) aguardando você decidir (seguir com o pedido ou reembolsar). Veja em Pedidos.', interval '1 hour'); end if;
    select count(*) into v_n from pagamentos_online where status = 'aguardando' and criado_em < now() - interval '45 minutes';
    if v_n > 0 then ativos := array_append(ativos, ('sis:mp_aviso')::text);
      perform _alertas_sistema_avisar('sis:mp_aviso', 'Mercado Pago sem resposta', v_n || ' pagamento(s) sem resposta do Mercado Pago há mais de 45 min. Confira o webhook no painel do Mercado Pago.'); end if;
  end if;
  -- 6) iFood ligado e sem conversar com o iFood
  if _integracao_ligada('ifood') and exists (select 1 from caixa_sessoes where status = 'Aberto') then
    select ultima_consulta_ok into v_t from ifood_estado where id;
    if v_t is null or v_t < now() - interval '10 minutes' then
      ativos := array_append(ativos, ('sis:ifood')::text);
      perform _alertas_sistema_avisar('sis:ifood', 'iFood sem conexão', 'O sistema não consegue buscar pedidos do iFood há mais de 10 min. Use o Gestor de Pedidos do iFood e lance no Caixa.', interval '1 hour');
    end if;
  end if;
  -- 7) caixa vencido e ainda aberto
  select * into v_cx from caixa_sessoes where status = 'Aberto' order by abertura desc limit 1;
  if v_cx.id is not null and _caixa_vencido(v_cx.id) and now() > _caixa_vence_em(v_cx.abertura) + interval '3 hours' then
    ativos := array_append(ativos, ('sis:caixa_vencido')::text);
    perform _alertas_sistema_avisar('sis:caixa_vencido', 'Caixa vencido ainda aberto', 'O caixa aberto em ' || to_char(v_cx.abertura at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' passou do horário. Feche em "Fechar caixa vencido" antes de vender.', interval '12 hours');
  end if;
  -- 8) espaço do banco (plano gratuito: 500 MB)
  v_tam := pg_database_size(current_database());
  if v_tam > 400 * 1024 * 1024 then
    ativos := array_append(ativos, ('sis:espaco')::text);
    perform _alertas_sistema_avisar('sis:espaco', 'Banco de dados quase cheio', 'Usando ' || round(v_tam / 1048576.0) || ' MB de 500 MB. Arquive vendas antigas em Sistema → Backup e espaço.', interval '24 hours');
  end if;
  -- 9) backup automático parado
  select max(data_hora) into v_t from backups where status = 'ok';
  if v_t is not null and v_t < now() - interval '26 hours' then
    ativos := array_append(ativos, ('sis:backup')::text);
    perform _alertas_sistema_avisar('sis:backup', 'Backup automático parado', 'O último backup que deu certo foi em ' || to_char(v_t at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || '.', interval '12 hours');
  end if;
  -- 10) conferência diária achou diferença
  select status, criado_em into v_txt, v_t from integridade_checks order by criado_em desc limit 1;
  if v_txt is not null and v_txt <> 'ok' and v_t > now() - interval '24 hours' then
    ativos := array_append(ativos, ('sis:integridade')::text);
    perform _alertas_sistema_avisar('sis:integridade', 'Conferência diária achou diferença', 'Supabase e planilha não bateram na conferência de hoje. Veja em Sistema → Sincronização e contingência.', interval '24 hours');
  end if;
  -- 11) vencimentos cadastrados pelo dono (30, 15, 7 e 1 dia antes; e vencido)
  for r in select e->>'item' item, (e->>'vence')::date vence from jsonb_array_elements(coalesce((select vencimentos from alertas_config where id), '[]'::jsonb)) e
            where coalesce(e->>'item', '') <> '' and coalesce(e->>'vence', '') ~ '^\d{4}-\d{2}-\d{2}$' loop
    v_dias := r.vence - (now() at time zone 'America/Sao_Paulo')::date;
    if v_dias <= 30 then
      v_txt := 'sis:venc:' || md5(r.item) || ':' || case when v_dias < 0 then 'vencido' when v_dias <= 1 then '1' when v_dias <= 7 then '7' when v_dias <= 15 then '15' else '30' end;
      ativos := array_append(ativos, (v_txt)::text);
      perform _alertas_sistema_avisar(v_txt, case when v_dias < 0 then r.item || ' VENCEU' else r.item || ' vence em ' || v_dias || ' dia(s)' end,
              r.item || ': vencimento em ' || to_char(r.vence, 'DD/MM/YYYY') || '. Renove antes para o sistema não parar.', interval '7 days');
    end if;
  end loop;
  update alertas_envios set resolvido_em = now() where tipo = 'sistema' and resolvido_em is null and not (chave = any(ativos));
  return jsonb_build_object('ok', true, 'ativos', to_jsonb(ativos));
end $$;

-- ---------- chamadas do app ----------
-- lista do app aberto (hora do servidor): cada perfil vê o que é dele; Admin/Desenvolvedor veem tudo
create or replace function public.api_alertas_pedidos(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_niv text := auth_nivel()::text; v_l jsonb;
begin
  if not tem_nivel('Admin', 'Operador', 'Cozinha', 'Garçom') then return _negado(); end if;
  select coalesce(jsonb_agg(jsonb_build_object('vendaId', x.venda_id, 'numero', x.numero, 'regra', x.regra, 'rotulo', x.rotulo, 'minutos', x.minutos,
           'vezes', coalesce(e.vezes, 0)) order by x.minutos desc), '[]'::jsonb) into v_l
    from _alertas_pedidos_parados() x left join alertas_envios e on e.chave = 'ped:' || x.venda_id || ':' || x.regra and e.resolvido_em is null
   where (v_niv in ('Admin', 'Desenvolvedor') or v_niv = any(x.niveis) or (coalesce(e.vezes, 0) >= (_alertas_cfg()->>'escalarApos')::int and v_niv = 'Admin'))
     and not coalesce(e.silenciado, false) and coalesce(e.adiado_ate, '-infinity') <= now();
  return jsonb_build_object('ok', true, 'agora', now(), 'alertas', v_l);
end $$;

-- adiar 10 min ou silenciar o aviso de um pedido (não muda o pedido)
create or replace function public.api_alertas_pedido_adiar(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := _uuid(p->>'vendaId'); v_ac text := coalesce(p->>'acao', 'adiar'); v_num int; x record; n int := 0;
begin
  if not tem_nivel('Admin', 'Operador', 'Cozinha', 'Garçom') then return _negado(); end if;
  if v_ac not in ('adiar', 'silenciar') then return _falha('Ação inválida.'); end if;
  select numero_pedido into v_num from vendas where id = v_id; if v_num is null then return _falha('Pedido não encontrado.'); end if;
  for x in select * from _alertas_pedidos_parados() where venda_id = v_id loop
    insert into alertas_envios (chave, tipo, venda_id, regra, titulo, texto) values ('ped:' || v_id || ':' || x.regra, 'pedido', v_id, x.regra, '⏰ Pedido #' || v_num || ' parado', x.rotulo)
    on conflict (chave) do nothing;
    update alertas_envios set adiado_ate = case when v_ac = 'adiar' then now() + interval '10 minutes' else adiado_ate end,
           silenciado = (v_ac = 'silenciar') or silenciado, silenciado_por = case when v_ac = 'silenciar' then auth.uid() else silenciado_por end, resolvido_em = null
     where chave = 'ped:' || v_id || ':' || x.regra;
    n := n + 1;
  end loop;
  if v_ac = 'silenciar' and n > 0 then perform _auditar('Alerta de pedido silenciado', '#' || v_num || ' — ' || coalesce(nullif(left(btrim(coalesce(p->>'motivo', '')), 120), ''), 'sem motivo')); end if;
  return jsonb_build_object('ok', true, 'message', case when n = 0 then 'Este pedido não tem aviso agora.' when v_ac = 'adiar' then 'Aviso adiado por 10 minutos.' else 'Aviso deste pedido silenciado.' end);
end $$;

create or replace function public.api_alertas_config(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  return jsonb_build_object('ok', true, 'padrao', _alertas_padrao()) || _alertas_cfg()
      || jsonb_build_object('ativos', coalesce((select jsonb_agg(jsonb_build_object('titulo', titulo, 'texto', texto, 'desde', primeiro_em, 'ultimo', ultimo_em, 'vezes', vezes) order by ultimo_em desc)
                                               from alertas_envios where tipo = 'sistema' and resolvido_em is null), '[]'::jsonb));
end $$;

create or replace function public.api_alertas_salvar(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_reg jsonb := '{}'::jsonb; k text; v_min int; v_ven jsonb := '[]'::jsonb; e jsonb; v_rep int; v_esc int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  for k in select jsonb_object_keys(_alertas_padrao()) loop
    if p->'regras' ? k then
      v_min := _num(p->'regras'->k->>'min', (_alertas_padrao()->k->>'min')::numeric)::int;
      if v_min < 1 or v_min > 240 then return _falha('Os tempos precisam ficar entre 1 e 240 minutos.'); end if;
      v_reg := v_reg || jsonb_build_object(k, jsonb_build_object('ligado', coalesce((p->'regras'->k->>'ligado')::boolean, true), 'min', v_min));
    end if;
  end loop;
  v_rep := _num(p->>'repetirMin', 5)::int; v_esc := _num(p->>'escalarApos', 3)::int;
  if v_rep < 1 or v_rep > 60 or v_esc < 1 or v_esc > 20 then return _falha('Repetição entre 1 e 60 min; escalada entre 1 e 20 avisos.'); end if;
  for e in select value from jsonb_array_elements(coalesce(p->'vencimentos', '[]'::jsonb)) loop
    if coalesce(btrim(e->>'item'), '') = '' then continue; end if;
    if coalesce(e->>'vence', '') !~ '^\d{4}-\d{2}-\d{2}$' then return _falha('Data inválida em "' || left(e->>'item', 40) || '".'); end if;
    v_ven := v_ven || jsonb_build_object('item', left(btrim(e->>'item'), 60), 'vence', e->>'vence');
  end loop;
  if jsonb_array_length(v_ven) > 20 then return _falha('No máximo 20 vencimentos.'); end if;
  update alertas_config set regras = v_reg, repetir_min = v_rep, escalar_apos = v_esc, vencimentos = v_ven,
         email_ativo = coalesce((p->>'emailAtivo')::boolean, email_ativo), atualizado_em = now(), atualizado_por = auth.uid() where id;
  perform _auditar('Alertas automáticos alterados', 'repetir ' || v_rep || ' min | escalar após ' || v_esc || ' | ' || jsonb_array_length(v_ven) || ' vencimento(s)');
  return jsonb_build_object('ok', true, 'message', 'Alertas salvos.');
end $$;

-- "Enviar aviso de teste": só para os aparelhos de quem pediu
create or replace function public.api_alertas_teste(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_n int;
begin
  if not tem_nivel('Admin', 'Operador', 'Cozinha', 'Garçom') then return _negado(); end if;
  select count(*) into v_n from push_inscricoes where usuario_id = auth.uid();
  if v_n = 0 then return jsonb_build_object('ok', true, 'semAparelho', true, 'message', 'Este usuário ainda não ligou os avisos com o app fechado. O som com o app aberto foi tocado neste aparelho.'); end if;
  perform _alertas_push('🔔 Aviso de teste', 'Se você recebeu, os avisos com o app fechado estão funcionando.', 'teste-alerta', null, array[auth.uid()]);
  return jsonb_build_object('ok', true, 'message', 'Aviso de teste enviado para ' || v_n || ' aparelho(s) deste usuário.');
end $$;

-- Cozinha e Garçom também podem ligar os avisos com o app fechado (antes: só Admin e Operador)
create or replace function public.api_push_inscrever(p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_ep text := btrim(coalesce(p->>'endpoint','')); v_k text := btrim(coalesce(p->'keys'->>'p256dh','')); v_a text := btrim(coalesce(p->'keys'->>'auth',''));
begin
  if not tem_nivel('Admin', 'Operador', 'Cozinha', 'Garçom') then return _negado(); end if;
  if v_ep not like 'https://%' or char_length(v_ep) > 800 or v_k = '' or v_a = '' or char_length(v_k) > 200 or char_length(v_a) > 100 then return _falha('Inscrição inválida.'); end if;
  insert into push_inscricoes (usuario_id, endpoint, p256dh, auth) values (auth.uid(), v_ep, v_k, v_a)
  on conflict (endpoint) do update set usuario_id = excluded.usuario_id, p256dh = excluded.p256dh, auth = excluded.auth, falhas = 0;
  perform _auditar('Avisos com app fechado ativados', null);
  return jsonb_build_object('ok', true, 'message', 'Avisos com o app fechado ativados neste aparelho.');
end $function$;

-- agendamentos
select cron.schedule('alertas-pedidos-minuto', '* * * * *', 'select public.alertas_pedidos_cron()');
select cron.schedule('alertas-sistema-10min', '*/10 * * * *', 'select public.alertas_sistema_cron()');
