-- =====================================================================
-- 52 - Nenhum erro discreto
-- ---------------------------------------------------------------------
-- 1) Os erros que acontecem no CARDÁPIO (cliente sem login) passam a ser
--    registrados também (antes só os da equipe logada). Sem nome, sem
--    telefone, sem IP aberto: só a mensagem, a tela e a versão do app.
--    O IP vira um código embaralhado (md5) só para limitar abuso.
-- 2) Além dos erros de programa ("error"/"promise"), passa a registrar
--    os AVISOS DE FALHA que a tela mostrou para a pessoa ("aviso"),
--    por exemplo "Não foi possível concluir agora (erro 500)".
-- 3) Admin/Desenvolvedor: lista dos erros dos últimos dias (tela
--    Conexão e servidores → Erros do sistema) e botão "Resolvido".
-- Tudo aditivo. Pode rodar mais de uma vez.
-- =====================================================================

alter table public.erros_cliente add column if not exists ip_hash text not null default '';
alter table public.erros_cliente add column if not exists resolvido_em timestamptz;

alter table public.erros_cliente drop constraint if exists erros_cliente_tipo_check;
alter table public.erros_cliente add constraint erros_cliente_tipo_check
  check (tipo = any (array['error'::text, 'promise'::text, 'aviso'::text]));

create index if not exists erros_cliente_ultima_idx on public.erros_cliente (ultima_em desc);

-- equipe logada (mesma função de antes, agora aceita "aviso")
create or replace function public.registrar_erro_cliente(p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  uid uuid := auth.uid(); hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  tp text; msg text; ori text; pil text; h text; vezes int; novos int; total int;
begin
  if uid is null or auth_nivel() is null or p is null or jsonb_typeof(p) <> 'object' then return jsonb_build_object('ok', false); end if;
  tp := case when p->>'tipo' in ('promise', 'aviso') then p->>'tipo' else 'error' end;
  msg := erro_limpa_(p->>'mensagem', 300); ori := erro_limpa_(p->>'origem', 120); pil := erro_limpa_(p->>'pilha', 600);
  if msg = '' then return jsonb_build_object('ok', false); end if;
  h := md5(tp || '|' || msg || '|' || ori);
  vezes := case when (p->>'vezes') ~ '^[0-9]{1,2}$' then greatest((p->>'vezes')::int, 1) else 1 end;
  update erros_cliente set ocorrencias = least(ocorrencias + vezes, 9999), ultima_em = now() where hash = h and dia = hoje;
  if found then return jsonb_build_object('ok', true, 'novo', false); end if;
  select count(*) into novos from erros_cliente where usuario_id = uid and criado_em > now() - interval '1 hour';
  select count(*) into total from erros_cliente where dia = hoje and usuario_id is not null;
  if novos >= 20 or total >= 300 then return jsonb_build_object('ok', false, 'motivo', 'limite'); end if;
  insert into erros_cliente (usuario_id, nivel, tipo, mensagem, origem, pilha, tela, versao, aparelho, hash, ocorrencias)
  values (uid, coalesce(ia_nivel_real(), '?'), tp, msg, ori, pil,
          left(regexp_replace(coalesce(p->>'tela', ''), '[^a-zA-Z0-9_-]', '', 'g'), 40),
          left(regexp_replace(coalesce(p->>'versao', ''), '[^a-zA-Z0-9._-]', '', 'g'), 30),
          erro_limpa_(p->>'aparelho', 80), h, vezes)
  on conflict (hash, dia) do update set ocorrencias = least(erros_cliente.ocorrencias + vezes, 9999), ultima_em = now();
  return jsonb_build_object('ok', true, 'novo', true);
end $function$;

-- cliente do cardápio (sem login). Limites: 10 novos por hora por IP, 300 novos por dia no total.
create or replace function public.registrar_erro_publico(p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  tp text; msg text; ori text; pil text; h text; vezes int; novos int; total int; v_ip text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return jsonb_build_object('ok', false); end if;
  tp := case when p->>'tipo' in ('promise', 'aviso') then p->>'tipo' else 'error' end;
  msg := erro_limpa_(p->>'mensagem', 300); ori := erro_limpa_(p->>'origem', 120); pil := erro_limpa_(p->>'pilha', 600);
  if msg = '' then return jsonb_build_object('ok', false); end if;
  begin
    v_ip := split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', ''), ',', 1);
  exception when others then v_ip := ''; end;
  v_ip := case when v_ip = '' then '' else left(md5('rst-erro|' || v_ip), 16) end;
  h := md5('cardapio|' || tp || '|' || msg || '|' || ori);
  vezes := case when (p->>'vezes') ~ '^[0-9]{1,2}$' then greatest((p->>'vezes')::int, 1) else 1 end;
  update erros_cliente set ocorrencias = least(ocorrencias + vezes, 9999), ultima_em = now() where hash = h and dia = hoje;
  if found then return jsonb_build_object('ok', true, 'novo', false); end if;
  if v_ip <> '' then
    select count(*) into novos from erros_cliente where usuario_id is null and ip_hash = v_ip and criado_em > now() - interval '1 hour';
    if novos >= 10 then return jsonb_build_object('ok', false, 'motivo', 'limite'); end if;
  end if;
  select count(*) into total from erros_cliente where dia = hoje and usuario_id is null;
  if total >= 300 then return jsonb_build_object('ok', false, 'motivo', 'limite'); end if;
  insert into erros_cliente (usuario_id, nivel, tipo, mensagem, origem, pilha, tela, versao, aparelho, hash, ocorrencias, ip_hash)
  values (null, 'Cardápio', tp, msg, ori, pil,
          left(regexp_replace(coalesce(p->>'tela', ''), '[^a-zA-Z0-9_-]', '', 'g'), 40),
          left(regexp_replace(coalesce(p->>'versao', ''), '[^a-zA-Z0-9._-]', '', 'g'), 30),
          erro_limpa_(p->>'aparelho', 80), h, vezes, v_ip)
  on conflict (hash, dia) do update set ocorrencias = least(erros_cliente.ocorrencias + vezes, 9999), ultima_em = now();
  return jsonb_build_object('ok', true, 'novo', true);
end $function$;

-- Admin/Desenvolvedor: lista e "resolvido"
create or replace function public.api_erros_sistema(p jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_dias int; v_onde text; v_hash text;
begin
  if not tem_nivel('Admin', 'Desenvolvedor') then return _negado(); end if;
  v_hash := nullif(left(coalesce(p->>'resolver', ''), 40), '');
  if v_hash is not null then
    update erros_cliente set resolvido_em = now() where hash = v_hash;
    perform _auditar('Erro do sistema marcado como resolvido', v_hash);
  end if;
  v_dias := least(greatest(coalesce(nullif(p->>'dias', '')::int, 7), 1), 14);
  v_onde := coalesce(p->>'onde', 'todos');
  return jsonb_build_object('ok', true,
    'resumo', jsonb_build_object(
      'cardapio', (select coalesce(sum(ocorrencias), 0) from erros_cliente where usuario_id is null and ultima_em >= now() - make_interval(days => v_dias) and (resolvido_em is null or ultima_em > resolvido_em)),
      'equipe', (select coalesce(sum(ocorrencias), 0) from erros_cliente where usuario_id is not null and ultima_em >= now() - make_interval(days => v_dias) and (resolvido_em is null or ultima_em > resolvido_em))),
    'itens', coalesce((
      select jsonb_agg(x order by x->>'ultima' desc) from (
        select jsonb_build_object('hash', hash, 'tipo', max(tipo), 'onde', case when bool_or(usuario_id is null) then 'cardapio' else 'equipe' end,
               'niveis', string_agg(distinct coalesce(nivel, '?'), ', '), 'mensagem', max(mensagem), 'origem', max(origem), 'tela', max(tela),
               'versao', max(versao), 'pilha', max(left(pilha, 400)), 'ocorrencias', sum(ocorrencias), 'pessoas', count(distinct coalesce(usuario_id::text, nullif(ip_hash, ''), id::text)),
               'primeira', min(criado_em), 'ultima', max(ultima_em), 'aparelho', max(aparelho)) x
          from erros_cliente
         where ultima_em >= now() - make_interval(days => v_dias)
           and (resolvido_em is null or ultima_em > resolvido_em)
           and (v_onde = 'todos' or (v_onde = 'cardapio' and usuario_id is null) or (v_onde = 'equipe' and usuario_id is not null))
         group by hash
         order by max(ultima_em) desc
         limit 80) t), '[]'::jsonb));
end $function$;

revoke all on function public.registrar_erro_publico(jsonb) from public;
grant execute on function public.registrar_erro_publico(jsonb) to anon, authenticated, service_role;
revoke all on function public.registrar_erro_cliente(jsonb) from public, anon;
grant execute on function public.registrar_erro_cliente(jsonb) to authenticated, service_role;
revoke all on function public.api_erros_sistema(jsonb) from public, anon;
grant execute on function public.api_erros_sistema(jsonb) to authenticated, service_role;
