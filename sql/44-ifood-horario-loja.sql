-- 44: iFood Merchant — horário de funcionamento da loja (editar no sistema e enviar; ler do iFood).
alter table ifood_acoes drop constraint if exists ifood_acoes_acao_check;
alter table ifood_acoes add constraint ifood_acoes_acao_check check (acao = any (array['confirmar','iniciar_preparo','pronto','despachar','cancelar','negociacao_aceitar','negociacao_recusar','negociacao_alternativa','loja_fechar','loja_abrir','loja_pausar','loja_retomar','loja_horario_enviar','loja_horario_ler','catalogo_importar','catalogo_preco','catalogo_pausar','catalogo_retomar','avaliacao_responder']));

create or replace function public.api_ifood_horario(p jsonb default '{}'::jsonb) returns jsonb
  language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  return jsonb_build_object('ok', true,
    'horario', coalesce((select config->'horarioLoja' from integracoes_config where provedor = 'ifood'), '{}'::jsonb),
    'ifood', (select config->'horarioIfood' from integracoes_config where provedor = 'ifood'),
    'ifoodEm', (select config->>'horarioIfoodEm' from integracoes_config where provedor = 'ifood'));
end $$;

create or replace function public.api_ifood_horario_salvar(p jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public' as $$
declare v_h jsonb := coalesce(p->'horario', '{}'::jsonb); v_dia text; v_t jsonb; v_ini text; v_fim text; v_envia boolean := coalesce((p->>'enviar')::boolean, false);
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if jsonb_typeof(v_h) <> 'object' then return _falha('Horário inválido.'); end if;
  for v_dia in select jsonb_object_keys(v_h) loop
    if v_dia not in ('MONDAY','TUESDAY','WEDNESDAY','THURSDAY','FRIDAY','SATURDAY','SUNDAY') then return _falha('Dia inválido.'); end if;
    if jsonb_typeof(v_h->v_dia) <> 'array' or jsonb_array_length(v_h->v_dia) > 3 then return _falha('Use no máximo 3 faixas por dia.'); end if;
    for v_t in select * from jsonb_array_elements(v_h->v_dia) loop
      v_ini := v_t->>'inicio'; v_fim := v_t->>'fim';
      if v_ini !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or v_fim !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then return _falha('Horário deve ser HH:MM (ex.: 18:00).'); end if;
      if v_fim <= v_ini then return _falha('Em ' || v_dia || ' o fechamento precisa ser depois da abertura (no mesmo dia).'); end if;
    end loop;
  end loop;
  update integracoes_config set config = config || jsonb_build_object('horarioLoja', v_h) where provedor = 'ifood';
  if not found then return _falha('Cadastre a integração do iFood primeiro.'); end if;
  perform _auditar('Horário do iFood salvo', case when v_envia then 'e enviado ao iFood' else 'só no sistema' end);
  if v_envia then
    if not _integracao_ligada('ifood') then return _falha('Salvo, mas o iFood está desligado: nada foi enviado.'); end if;
    perform _ifood_enfileirar('LOJA', 'loja_horario_enviar', jsonb_build_object('horario', v_h, 'em', now()));
  end if;
  return jsonb_build_object('ok', true, 'message', case when v_envia then 'Salvo. Enviando ao iFood (confira em instantes com "Ler do iFood").' else 'Salvo no sistema.' end) || api_ifood_horario('{}');
end $$;

create or replace function public.api_ifood_horario_ler(p jsonb default '{}'::jsonb) returns jsonb
  language plpgsql security definer set search_path to 'public' as $$
begin
  if not tem_nivel('Admin', 'Operador') then return _negado(); end if;
  if not _integracao_ligada('ifood') then return _falha('O iFood está desligado.'); end if;
  perform _ifood_enfileirar('LOJA', 'loja_horario_ler', jsonb_build_object('em', now()));
  return jsonb_build_object('ok', true, 'message', 'Pedido enviado ao iFood. Toque em "Atualizar" em alguns segundos.') || api_ifood_horario('{}');
end $$;

create or replace function public.ifood_horario_gravar(p_turnos jsonb) returns void
  language sql security definer set search_path to 'public' as $$
  update integracoes_config set config = config || jsonb_build_object('horarioIfood', coalesce(p_turnos, '[]'::jsonb), 'horarioIfoodEm', now()::text) where provedor = 'ifood'
$$;

revoke all on function public.api_ifood_horario(jsonb), public.api_ifood_horario_salvar(jsonb), public.api_ifood_horario_ler(jsonb), public.ifood_horario_gravar(jsonb) from public, anon;
grant execute on function public.api_ifood_horario(jsonb), public.api_ifood_horario_salvar(jsonb), public.api_ifood_horario_ler(jsonb) to authenticated, service_role;
grant execute on function public.ifood_horario_gravar(jsonb) to service_role;
