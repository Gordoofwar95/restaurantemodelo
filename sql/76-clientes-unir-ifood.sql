-- 76 · Cliente do iFood (sem telefone) se junta ao cadastro do sistema (com telefone) quando NOME e ENDEREÇO batem.
-- Mantém o cadastro do sistema (telefone, fidelidade, conta Google) e acrescenta o código do cliente no iFood.
-- Tudo fica registrado em clientes_unioes e pode ser desfeito. Nada é apagado: o cadastro do iFood fica escondido (unido_com). Idempotente.
alter table public.clientes add column if not exists ligado_auto boolean not null default false;
alter table public.clientes add column if not exists unido_com uuid;
create index if not exists clientes_unido_com_idx on public.clientes (unido_com) where unido_com is not null;

create table if not exists public.clientes_unioes (
  id bigserial primary key,
  quando timestamptz not null default now(),
  s_id uuid not null,            -- cadastro do sistema (fica)
  f_id uuid not null,            -- cadastro do iFood (escondido)
  f_ifood_id text,
  f_nome text,
  s_endereco_antes text,
  auto boolean not null default false,
  por text,
  movidos jsonb not null default '{}'::jsonb,
  fidelidade jsonb not null default '{}'::jsonb,
  desfeito_em timestamptz,
  desfeito_por text
);
alter table public.clientes_unioes enable row level security;
revoke all on public.clientes_unioes from public, anon, authenticated;
grant all on public.clientes_unioes to service_role;

-- chave do endereço: "rua|número" (sem Av/Rua, sem acento). Null se não der para ler rua e número.
create or replace function public._end_chave(p text) returns text
 language plpgsql immutable set search_path to 'public' as $f$
declare s text; num text; rua text;
begin
  s := lower(translate(coalesce(p, ''), 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇç', 'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCc'));
  s := btrim(regexp_replace(regexp_replace(s, '[^a-z0-9,]', ' ', 'g'), '\s+', ' ', 'g'));
  if s = '' then return null; end if;
  num := coalesce((regexp_match(s, ',\s*(\d+)'))[1], (regexp_match(s, '\s(\d+)(?:\s|,|$)'))[1]);
  if num is null then return null; end if;
  rua := case when position(',' in s) > 0 then split_part(s, ',', 1) else regexp_replace(s, '\s+' || num || '(\s.*)?$', '') end;
  rua := btrim(regexp_replace(rua, '^(av|avenida|r|rua|al|alameda|tv|travessa|pca|praca|rod|rodovia|est|estrada|vl|vila)\s+', ''));
  if length(rua) < 3 then return null; end if;
  return rua || '|' || num;
end $f$;

create or replace function public._end_confere(a text, b text) returns boolean
 language plpgsql immutable set search_path to 'public' as $f$
declare ka text := public._end_chave(a); kb text := public._end_chave(b); ra text; rb text;
begin
  if ka is null or kb is null then return false; end if;
  if ka = kb then return true; end if;
  if split_part(ka, '|', 2) <> split_part(kb, '|', 2) then return false; end if;
  ra := split_part(ka, '|', 1); rb := split_part(kb, '|', 1);
  return (length(ra) >= 5 and position(ra in rb) > 0) or (length(rb) >= 5 and position(rb in ra) > 0);
end $f$;

-- o cliente do sistema (s) tem este endereço no cadastro ou em algum pedido de entrega anterior?
create or replace function public._cliente_tem_endereco(p_s uuid, p_end text) returns boolean
 language sql stable security definer set search_path to 'public' as $f$
  select exists (select 1 from clientes c where c.id = p_s and public._end_confere(c.endereco, p_end))
      or exists (select 1 from vendas v where v.cliente_id = p_s and v.endereco is not null and public._end_confere(v.endereco, p_end))
$f$;

-- junta o cadastro do iFood (p_f) ao cadastro do sistema (p_s)
create or replace function public._cliente_unir(p_f uuid, p_s uuid, p_auto boolean, p_por text) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare f clientes%rowtype; s clientes%rowtype; t record; ids jsonb; mov jsonb := '{}'::jsonb; fid jsonb := '{}'::jsonb;
  ff fidelidade%rowtype; fs fidelidade%rowtype; v_log bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended('cliente-unir', 0));
  select * into f from clientes where id = p_f for update;
  select * into s from clientes where id = p_s for update;
  if f.id is null or s.id is null or f.id = s.id then return jsonb_build_object('ok', false, 'message', 'Cadastro não encontrado.'); end if;
  if f.ifood_id is null or f.unido_com is not null or btrim(coalesce(f.telefone, '')) <> '' then return jsonb_build_object('ok', false, 'message', 'O primeiro cadastro precisa ser de um cliente do iFood, sem telefone.'); end if;
  if s.ifood_id is not null or s.unido_com is not null or btrim(coalesce(s.telefone, '')) = '' then return jsonb_build_object('ok', false, 'message', 'O segundo cadastro precisa ser um cliente do sistema, com telefone, que ainda não esteja ligado ao iFood.'); end if;
  insert into clientes_unioes (s_id, f_id, f_ifood_id, f_nome, s_endereco_antes, auto, por) values (s.id, f.id, f.ifood_id, f.nome, s.endereco, p_auto, p_por) returning id into v_log;
  for t in select * from (values ('vendas','cliente_id','id'), ('cupons','cliente_id','id'), ('cupons_usos','cliente_id','id'), ('feedbacks','cliente_id','id'), ('brindes','cliente_id','id'),
      ('indicacoes','indicador_id','id'), ('indicacoes','indicado_id','id'), ('fidelidade_marcas','cliente_id','venda_id'), ('vendas_resumo_arquivo','cliente_id','venda_id'),
      ('anonimizar_arquivo_fila','cliente_id','id'), ('contas_cliente','cliente_id','user_id')) x(tab, col, pk) loop
    if t.tab = 'contas_cliente' and exists (select 1 from contas_cliente where cliente_id = s.id) then continue; end if;
    execute format('with m as (update public.%I set %I = $1 where %I = $2 returning %I::text k) select coalesce(jsonb_agg(k), ''[]''::jsonb) from m', t.tab, t.col, t.col, t.pk) into ids using s.id, f.id;
    if jsonb_array_length(ids) > 0 then mov := mov || jsonb_build_object(t.tab || '.' || t.col || '.' || t.pk, ids); end if;
  end loop;
  select * into ff from fidelidade where cliente_id = f.id; select * into fs from fidelidade where cliente_id = s.id;
  if ff.id is not null and fs.id is null then
    update fidelidade set cliente_id = s.id where id = ff.id; fid := jsonb_build_object('moveu', ff.id);
  elsif ff.id is not null and fs.id is not null then
    fid := jsonb_build_object('soma', jsonb_build_object('f_fid', ff.id, 's_fid', fs.id, 'carimbos', ff.carimbos, 'premios', ff.premios_resgatados));
    update fidelidade set carimbos = carimbos + ff.carimbos, premios_resgatados = premios_resgatados + ff.premios_resgatados, atualizada_em = now() where id = fs.id;
    update fidelidade set carimbos = 0, premios_resgatados = 0 where id = ff.id;
  end if;
  update clientes set ifood_id = null, unido_com = s.id where id = f.id;
  update clientes set ifood_id = f.ifood_id, ligado_auto = p_auto, endereco = coalesce(nullif(btrim(endereco), ''), f.endereco) where id = s.id;
  update clientes_unioes set movidos = mov, fidelidade = fid where id = v_log;
  perform _auditar(case when p_auto then 'Clientes unidos (automático: nome e endereço)' else 'Clientes unidos (manual)' end, f.nome || ' (iFood) → ' || s.nome || ' · ' || coalesce(s.telefone, ''));
  return jsonb_build_object('ok', true, 'sId', s.id, 'log', v_log);
end $f$;
revoke all on function public._cliente_unir(uuid, uuid, boolean, text) from public, anon, authenticated;
grant execute on function public._cliente_unir(uuid, uuid, boolean, text) to service_role;

-- desfaz a última junção do cadastro do sistema (s)
create or replace function public._cliente_desunir(p_s uuid, p_por text) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare u clientes_unioes%rowtype; k text; ids jsonb; tab text; col text; pk text;
begin
  perform pg_advisory_xact_lock(hashtextextended('cliente-unir', 0));
  select * into u from clientes_unioes where s_id = p_s and desfeito_em is null order by id desc limit 1;
  if u.id is null then return jsonb_build_object('ok', false, 'message', 'Este cliente não tem uma junção para desfazer.'); end if;
  update clientes set ifood_id = null, ligado_auto = false, endereco = u.s_endereco_antes where id = u.s_id;
  update clientes set ifood_id = u.f_ifood_id, unido_com = null where id = u.f_id;
  for k, ids in select key, value from jsonb_each(u.movidos) loop
    tab := split_part(k, '.', 1); col := split_part(k, '.', 2); pk := split_part(k, '.', 3);
    execute format('update public.%I set %I = $1 where %I::text in (select jsonb_array_elements_text($2))', tab, col, pk) using u.f_id, ids;
  end loop;
  if u.fidelidade ? 'moveu' then
    update fidelidade set cliente_id = u.f_id where id = (u.fidelidade->>'moveu')::uuid;
  elsif u.fidelidade ? 'soma' then
    update fidelidade set carimbos = carimbos - (u.fidelidade->'soma'->>'carimbos')::int, premios_resgatados = premios_resgatados - (u.fidelidade->'soma'->>'premios')::int where id = (u.fidelidade->'soma'->>'s_fid')::uuid;
    update fidelidade set carimbos = (u.fidelidade->'soma'->>'carimbos')::int, premios_resgatados = (u.fidelidade->'soma'->>'premios')::int where id = (u.fidelidade->'soma'->>'f_fid')::uuid;
  end if;
  update clientes_unioes set desfeito_em = now(), desfeito_por = p_por where id = u.id;
  perform _auditar('Junção de clientes desfeita', coalesce(u.f_nome, '') || ' voltou a ser um cadastro do iFood');
  return jsonb_build_object('ok', true);
end $f$;
revoke all on function public._cliente_desunir(uuid, text) from public, anon, authenticated;
grant execute on function public._cliente_desunir(uuid, text) to service_role;

-- procura o ÚNICO cliente do sistema com o mesmo nome e endereço do cliente do iFood (f). Devolve o id dele ou null.
create or replace function public._cliente_par_do_ifood(p_f uuid) returns uuid
 language plpgsql stable security definer set search_path to 'public' as $f$
declare f clientes%rowtype; r uuid[];
begin
  select * into f from clientes where id = p_f;
  if f.id is null or f.ifood_id is null or f.unido_com is not null or btrim(coalesce(f.telefone, '')) <> '' then return null; end if;
  if public._end_chave(f.endereco) is null or length(public._ifood_norm(f.nome)) < 3 then return null; end if;
  select array_agg(c.id) into r from clientes c
   where c.ifood_id is null and c.unido_com is null and btrim(coalesce(c.telefone, '')) <> '' and public._ifood_norm(c.nome) = public._ifood_norm(f.nome)
     and public._cliente_tem_endereco(c.id, f.endereco)
     and not exists (select 1 from clientes_unioes u where u.f_id = f.id and u.s_id = c.id and u.desfeito_em is not null);
  return case when coalesce(array_length(r, 1), 0) = 1 then r[1] end;
end $f$;
revoke all on function public._cliente_par_do_ifood(uuid) from public, anon, authenticated;
grant execute on function public._cliente_par_do_ifood(uuid) to service_role;

-- quando um cliente do sistema é criado ou muda nome/telefone/endereço: procura o cadastro do iFood com o mesmo nome e endereço
create or replace function public._clientes_auto_unir() returns trigger
 language plpgsql security definer set search_path to 'public' as $f$
declare r uuid[]; v_f uuid;
begin
  if NEW.ifood_id is not null or NEW.unido_com is not null or btrim(coalesce(NEW.telefone, '')) = '' then return NEW; end if;
  if length(public._ifood_norm(NEW.nome)) < 3 then return NEW; end if;
  select array_agg(c.id) into r from clientes c
   where c.ifood_id is not null and c.unido_com is null and btrim(coalesce(c.telefone, '')) = '' and public._ifood_norm(c.nome) = public._ifood_norm(NEW.nome)
     and public._cliente_tem_endereco(NEW.id, c.endereco)
     and not exists (select 1 from clientes_unioes u where u.f_id = c.id and u.s_id = NEW.id and u.desfeito_em is not null);
  if coalesce(array_length(r, 1), 0) = 1 then v_f := r[1]; perform public._cliente_unir(v_f, NEW.id, true, 'automático'); end if;
  return NEW;
exception when others then
  begin perform public.ifood_aviso_registrar(null, 'cliente', 'Não consegui juntar um cliente do iFood automaticamente', left(sqlerrm, 300), '{}'::jsonb); exception when others then null; end;
  return NEW;
end $f$;
revoke all on function public._clientes_auto_unir() from public, anon, authenticated;
grant execute on function public._clientes_auto_unir() to service_role;
drop trigger if exists clientes_auto_unir on public.clientes;
create trigger clientes_auto_unir after insert or update of nome, telefone, endereco on public.clientes
  for each row when (pg_trigger_depth() < 2) execute function public._clientes_auto_unir();

-- pedido do iFood: tenta juntar o cliente ao cadastro do sistema e, se tiver telefone, coloca o telefone na comanda
do $$ declare d text;
begin
  select pg_get_functiondef('public._ifood_cliente(uuid, jsonb)'::regprocedure) into d;
  if d not like '%_cliente_par_do_ifood%' then
    if (length(d) - length(replace(d, E'  update vendas set cliente_id = v_id where id = p_venda and cliente_id is null;\n  return v_id;', ''))) = 0 then raise exception '_ifood_cliente mudou'; end if;
    d := replace(d, E'  update vendas set cliente_id = v_id where id = p_venda and cliente_id is null;\n  return v_id;',
$x$  declare v_par uuid; v_u jsonb;
  begin
    v_par := public._cliente_par_do_ifood(v_id);
    if v_par is not null then v_u := public._cliente_unir(v_id, v_par, true, 'automático'); if coalesce((v_u->>'ok')::boolean, false) then v_id := v_par; end if; end if;
  exception when others then
    begin perform public.ifood_aviso_registrar(null, 'cliente', 'Não consegui juntar o cliente do iFood ao cadastro', left(sqlerrm, 300), '{}'::jsonb); exception when others then null; end;
  end;
  update vendas set cliente_id = v_id where id = p_venda and cliente_id is null;
  declare v_tel text;
  begin
    select nullif(btrim(telefone), '') into v_tel from clientes where id = v_id;
    if v_tel is not null then update vendas set telefone_cliente = v_tel where id = p_venda; end if;
  end;
  return v_id;$x$);
    execute d;
  end if;
end $$;

-- a lista de fidelidade não mostra cadastros escondidos
create or replace view public.v_fidelidade as
 select c.nome, c.telefone, f.carimbos, f.premios_resgatados as premios, f.atualizada_em as atualizado, f.observacoes as observacao, f.cliente_id
   from public.fidelidade f join public.clientes c on c.id = f.cliente_id
  where c.unido_com is null;

-- telas: unir (manual, com senha) e desfazer
create or replace function public.api_unir_clientes(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare v_f uuid := _uuid(p->>'ifoodClienteId'); v_s uuid := _uuid(p->>'sistemaClienteId'); v_aut text; r jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if coalesce(btrim(p->>'senhaAdminConfirmacao'), '') = '' then return _falha('Digite a sua senha para confirmar (a senha é pedida sempre, inclusive para o Admin).'); end if;
  v_aut := _exige_admin(p->>'senhaAdminConfirmacao');
  if v_aut is null then return _falha('Senha de administrador incorreta.'); end if;
  r := public._cliente_unir(v_f, v_s, false, v_aut);
  if not coalesce((r->>'ok')::boolean, false) then return _falha(coalesce(r->>'message', 'Não foi possível juntar.')); end if;
  return jsonb_build_object('ok', true, 'message', 'Cadastros juntados. O telefone, a fidelidade e o histórico agora são de um cliente só.');
end $f$;
create or replace function public.api_desunir_cliente(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare v_s uuid := _uuid(p->>'id'); v_aut text; r jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if coalesce(btrim(p->>'senhaAdminConfirmacao'), '') = '' then return _falha('Digite a sua senha para confirmar (a senha é pedida sempre, inclusive para o Admin).'); end if;
  v_aut := _exige_admin(p->>'senhaAdminConfirmacao');
  if v_aut is null then return _falha('Senha de administrador incorreta.'); end if;
  r := public._cliente_desunir(v_s, v_aut);
  if not coalesce((r->>'ok')::boolean, false) then return _falha(coalesce(r->>'message', 'Não foi possível desfazer.')); end if;
  return jsonb_build_object('ok', true, 'message', 'Junção desfeita: o cliente do iFood voltou a ser um cadastro separado.');
end $f$;
revoke all on function public.api_unir_clientes(jsonb), public.api_desunir_cliente(jsonb) from public, anon;
grant execute on function public.api_unir_clientes(jsonb), public.api_desunir_cliente(jsonb) to authenticated, service_role;

-- tela do cliente: (a) cliente do sistema → nomes com que ele aparece no iFood; (b) cliente do iFood → sugestões para unir (mostra o motivo)
create or replace function public.api_cliente_ifood_info(p jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare v_id uuid := _uuid(p->>'id'); c clientes%rowtype; un jsonb; sug jsonb;
begin
  if not tem_nivel('Admin','Operador') then return _negado(); end if;
  select * into c from clientes where id = v_id;
  if c.id is null then return jsonb_build_object('ok', true, 'unioes', '[]'::jsonb, 'sugestoes', '[]'::jsonb); end if;
  select coalesce(jsonb_agg(jsonb_build_object('nomeIfood', u.f_nome, 'ifoodId', u.f_ifood_id, 'quando', u.quando, 'auto', u.auto, 'igual', public._ifood_norm(u.f_nome) = public._ifood_norm(c.nome)) order by u.id), '[]'::jsonb)
    into un from clientes_unioes u where u.s_id = c.id and u.desfeito_em is null;
  if c.ifood_id is not null and btrim(coalesce(c.telefone, '')) = '' and c.unido_com is null then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into sug from (
      select jsonb_build_object('id', s.id, 'nome', s.nome, 'telefone', s.telefone, 'endereco', s.endereco,
               'motivo', case when n and e then 'nome e endereço iguais' when e then 'mesmo endereço, nome diferente' else 'mesmo nome, endereço não confere' end) x
        from (select s.*, public._ifood_norm(s.nome) = public._ifood_norm(c.nome) n,
                (public._cliente_tem_endereco(s.id, c.endereco) or exists (select 1 from vendas v where v.cliente_id = c.id and v.endereco is not null and public._cliente_tem_endereco(s.id, v.endereco))) e
                from clientes s where s.ifood_id is null and s.unido_com is null and btrim(coalesce(s.telefone, '')) <> '') s
       where n or e order by (n and e) desc, e desc limit 5) q;
  end if;
  return jsonb_build_object('ok', true, 'unioes', un, 'sugestoes', coalesce(sug, '[]'::jsonb));
end $f$;
revoke all on function public.api_cliente_ifood_info(jsonb) from public, anon;
grant execute on function public.api_cliente_ifood_info(jsonb) to authenticated, service_role;
