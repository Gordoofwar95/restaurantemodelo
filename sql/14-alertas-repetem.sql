-- =====================================================================
-- 14 · ALERTAS QUE SE REPETEM ATÉ O PROBLEMA SER RESOLVIDO (18/10/2026)
-- Antes: avisos do SISTEMA (caixa vencido, backup parado, planilha parada...) repetiam só a cada 6 h, 12 h, 24 h ou 7 dias.
-- Agora: repetem a cada "sistema_repetir_min" minutos (padrão 30, o Admin ajusta em Configurar avisos) enquanto o problema existir.
--   • e-mail: no máximo 1 a cada 6 h por problema (para não lotar a caixa); o push e o som seguem repetindo;
--   • vencimentos cadastrados: 1 vez por dia; no último dia e depois de vencido, a cada 6 h;
--   • o app aberto do Admin também mostra a faixa e toca o som a cada novo aviso do sistema.
-- Aviso de PEDIDO parado já repetia (a cada "repetirMin") até resolver, adiar ou silenciar; não muda.
-- Aditivo: 2 colunas novas e 4 funções recriadas. Nada é apagado.
-- =====================================================================

alter table public.alertas_config add column if not exists sistema_repetir_min int not null default 30;
alter table public.alertas_envios add column if not exists ultimo_email_em timestamptz;

create or replace function public._alertas_cfg() returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare c alertas_config%rowtype; v_reg jsonb := _alertas_padrao(); k text;
begin
  select * into c from alertas_config where id;
  for k in select jsonb_object_keys(_alertas_padrao()) loop
    if c.regras ? k then v_reg := jsonb_set(v_reg, array[k], (v_reg->k) || (c.regras->k)); end if;
  end loop;
  return jsonb_build_object('regras', v_reg, 'repetirMin', coalesce(c.repetir_min, 5), 'escalarApos', coalesce(c.escalar_apos, 3),
                            'sistemaRepetirMin', coalesce(c.sistema_repetir_min, 30),
                            'vencimentos', coalesce(c.vencimentos, '[]'::jsonb), 'emailAtivo', coalesce(c.email_ativo, true));
end $$;

create or replace function public._alertas_sistema_avisar(p_chave text, p_titulo text, p_texto text, p_repetir interval default interval '6 hours')
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare e alertas_envios%rowtype; v_rep interval; v_mail boolean;
begin
  v_rep := make_interval(mins => greatest(5, coalesce((select sistema_repetir_min from alertas_config where id), 30)));
  if p_chave like 'sis:venc:%' then   -- vencimento cadastrado: 1x por dia; último dia e vencido: a cada 6 h
    v_rep := case when p_chave like '%:vencido' or p_chave like '%:1' then interval '6 hours' else interval '1 day' end;
  end if;
  select * into e from alertas_envios where chave = p_chave for update;
  if e.chave is not null and e.resolvido_em is null and (e.silenciado or now() - e.ultimo_em < v_rep) then return false; end if;
  v_mail := e.chave is null or e.resolvido_em is not null or e.ultimo_email_em is null or now() - e.ultimo_email_em >= interval '6 hours';
  insert into alertas_envios (chave, tipo, titulo, texto) values (p_chave, 'sistema', p_titulo, p_texto)
  on conflict (chave) do update set ultimo_em = now(), vezes = case when alertas_envios.resolvido_em is null then alertas_envios.vezes + 1 else 1 end,
     resolvido_em = null, titulo = excluded.titulo, texto = excluded.texto, silenciado = false,
     ultimo_email_em = case when v_mail then now() else alertas_envios.ultimo_email_em end;
  if e.chave is null or e.resolvido_em is not null or e.vezes < 3 or e.vezes % 12 = 0 then   -- auditoria: não enche o registro com cada repetição
    insert into auditoria (usuario_login, acao, detalhes) values ('sistema', 'ALERTA: ' || left(p_titulo, 80), left(p_texto, 300));
  end if;
  perform _alertas_push('⚠️ ' || p_titulo, p_texto || case when coalesce(e.vezes, 0) >= 1 and e.resolvido_em is null then ' (aviso ' || (e.vezes + 1) || ', continua sem resolver)' else '' end, 'sis-' || left(p_chave, 40), array['Admin']);
  if v_mail then
    perform _alertas_email('Restaurante Demo — ' || p_titulo, p_texto || E'\n\nAviso automático do sistema (' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ').');
  end if;
  return true;
end $$;

create or replace function public.api_alertas_pedidos(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_niv text := auth_nivel()::text; v_l jsonb; v_s jsonb := '[]'::jsonb;
begin
  if not tem_nivel('Admin', 'Operador', 'Cozinha', 'Garçom') then return _negado(); end if;
  select coalesce(jsonb_agg(jsonb_build_object('vendaId', x.venda_id, 'numero', x.numero, 'regra', x.regra, 'rotulo', x.rotulo, 'minutos', x.minutos,
           'vezes', coalesce(e.vezes, 0)) order by x.minutos desc), '[]'::jsonb) into v_l
    from _alertas_pedidos_parados() x left join alertas_envios e on e.chave = 'ped:' || x.venda_id || ':' || x.regra and e.resolvido_em is null
   where (v_niv in ('Admin', 'Desenvolvedor') or v_niv = any(x.niveis) or (coalesce(e.vezes, 0) >= (_alertas_cfg()->>'escalarApos')::int and v_niv = 'Admin'))
     and not coalesce(e.silenciado, false) and coalesce(e.adiado_ate, '-infinity') <= now();
  if v_niv in ('Admin', 'Desenvolvedor') then   -- falhas do sistema e vencimentos ainda sem resolver
    select coalesce(jsonb_agg(jsonb_build_object('chave', chave, 'titulo', titulo, 'texto', texto, 'vezes', vezes) order by ultimo_em desc), '[]'::jsonb) into v_s
      from alertas_envios where tipo = 'sistema' and resolvido_em is null and not silenciado;
  end if;
  return jsonb_build_object('ok', true, 'agora', now(), 'alertas', v_l, 'sistema', v_s);
end $$;

create or replace function public.api_alertas_salvar(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_reg jsonb := '{}'::jsonb; k text; v_min int; v_ven jsonb := '[]'::jsonb; e jsonb; v_rep int; v_esc int; v_sis int;
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
  v_sis := _num(p->>'sistemaRepetirMin', coalesce((select sistema_repetir_min from alertas_config where id), 30))::int;
  if v_rep < 1 or v_rep > 60 or v_esc < 1 or v_esc > 20 then return _falha('Repetição entre 1 e 60 min; escalada entre 1 e 20 avisos.'); end if;
  if v_sis < 10 or v_sis > 240 then return _falha('A repetição dos avisos do sistema precisa ficar entre 10 e 240 minutos.'); end if;
  for e in select value from jsonb_array_elements(coalesce(p->'vencimentos', '[]'::jsonb)) loop
    if coalesce(btrim(e->>'item'), '') = '' then continue; end if;
    if coalesce(e->>'vence', '') !~ '^\d{4}-\d{2}-\d{2}$' then return _falha('Data inválida em "' || left(e->>'item', 40) || '".'); end if;
    v_ven := v_ven || jsonb_build_object('item', left(btrim(e->>'item'), 60), 'vence', e->>'vence');
  end loop;
  if jsonb_array_length(v_ven) > 20 then return _falha('No máximo 20 vencimentos.'); end if;
  update alertas_config set regras = v_reg, repetir_min = v_rep, escalar_apos = v_esc, sistema_repetir_min = v_sis, vencimentos = v_ven,
         email_ativo = coalesce((p->>'emailAtivo')::boolean, email_ativo), atualizado_em = now(), atualizado_por = auth.uid() where id;
  perform _auditar('Alertas automáticos alterados', 'repetir ' || v_rep || ' min | sistema ' || v_sis || ' min | escalar após ' || v_esc || ' | ' || jsonb_array_length(v_ven) || ' vencimento(s)');
  return jsonb_build_object('ok', true, 'message', 'Alertas salvos.');
end $$;
