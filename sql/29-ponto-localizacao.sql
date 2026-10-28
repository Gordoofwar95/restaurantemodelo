-- 29 · Ponto com localização (18/10/2026)
-- O funcionário só bate o ponto se estiver perto do restaurante. O dono define o local em Administrador > Loja e equipe > Ponto.
-- Chave em "sistema": PONTO_LOCAL = {"lat":..,"lng":..,"raio":150}. Sem essa chave, o ponto funciona como antes (só guarda a localização, se vier).

alter table ponto_registros add column if not exists lat double precision;
alter table ponto_registros add column if not exists lng double precision;
alter table ponto_registros add column if not exists dist_m integer;
alter table ponto_registros add column if not exists saida_dist_m integer;

create or replace function _dist_metros(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns double precision language sql immutable as $$
  select 2 * 6371000 * asin(least(1, sqrt(power(sin(radians(b_lat - a_lat) / 2), 2) + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2))))
$$;

create or replace function api_ponto_local(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_lat double precision; v_lng double precision; v_raio int;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if coalesce(p->>'desligar', '') = 'true' then
    insert into sistema (chave, valor) values ('PONTO_LOCAL', 'null'::jsonb) on conflict (chave) do update set valor = excluded.valor;
    perform _auditar('Ponto: trava por localização desligada', '');
    return jsonb_build_object('ok', true, 'message', 'Trava por localização desligada.');
  end if;
  if nullif(p->>'lat', '') is not null then
    begin v_lat := (p->>'lat')::double precision; v_lng := (p->>'lng')::double precision; v_raio := coalesce(nullif(p->>'raio', '')::int, 150);
    exception when others then return _falha('Localização inválida.'); end;
    if v_lat not between -90 and 90 or v_lng not between -180 and 180 then return _falha('Localização inválida.'); end if;
    if v_raio < 30 or v_raio > 2000 then return _falha('O raio precisa ficar entre 30 e 2000 metros.'); end if;
    insert into sistema (chave, valor) values ('PONTO_LOCAL', jsonb_build_object('lat', v_lat, 'lng', v_lng, 'raio', v_raio))
      on conflict (chave) do update set valor = excluded.valor;
    perform _auditar('Ponto: local do restaurante definido', 'raio ' || v_raio || ' m');
    return jsonb_build_object('ok', true, 'message', 'Local salvo. O ponto só vale a até ' || v_raio || ' m daqui.');
  end if;
  select (valor->>'lat')::double precision, (valor->>'lng')::double precision, (valor->>'raio')::int into v_lat, v_lng, v_raio from sistema where chave = 'PONTO_LOCAL' and jsonb_typeof(valor) = 'object';
  return jsonb_build_object('ok', true, 'definido', v_lat is not null, 'raio', v_raio);
end $$;

create or replace function api_ponto_estado(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); r ponto_registros%rowtype; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_ini date; v_h numeric;
        v_exige boolean := exists (select 1 from sistema where chave = 'PONTO_LOCAL' and jsonb_typeof(valor) = 'object');
begin
  if auth_nivel() is null then return _negado(); end if;
  if v_eu is null then return jsonb_build_object('ok', true, 'vinculado', false); end if;
  v_ini := _escala_segunda(v_hoje);
  select * into r from ponto_registros where funcionario_id = v_eu and saida is null and not cancelado order by entrada desc limit 1;
  select coalesce(round(sum(extract(epoch from coalesce(saida, now()) - entrada)) / 3600.0, 2), 0) into v_h from ponto_registros
   where funcionario_id = v_eu and not cancelado and (entrada at time zone 'America/Sao_Paulo')::date between v_ini and v_ini + 6;
  return jsonb_build_object('ok', true, 'vinculado', true, 'aberto', r.id is not null, 'entrada', r.entrada, 'horasSemana', v_h, 'exigeLocal', v_exige);
end $$;

create or replace function api_ponto_bater(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); r ponto_registros%rowtype; v_cfg jsonb; v_lat double precision; v_lng double precision; v_prec double precision; v_dist double precision; v_d int; v_raio int; v_nome text;
begin
  if auth_nivel() is null then return _negado(); end if;
  if v_eu is null then return _falha('Seu acesso ainda não está ligado a um funcionário. Peça ao dono para usar "Importar acessos" na Escala.'); end if;
  begin v_lat := nullif(p->>'lat', '')::double precision; v_lng := nullif(p->>'lng', '')::double precision; v_prec := coalesce(nullif(p->>'precisao', '')::double precision, 0);
  exception when others then v_lat := null; v_lng := null; end;
  select valor into v_cfg from sistema where chave = 'PONTO_LOCAL' and jsonb_typeof(valor) = 'object';
  if v_lat is not null and v_lng is not null and v_cfg is not null then
    v_dist := _dist_metros(v_lat, v_lng, (v_cfg->>'lat')::double precision, (v_cfg->>'lng')::double precision);
    v_d := round(v_dist);
  end if;
  if v_cfg is not null then
    v_raio := coalesce((v_cfg->>'raio')::int, 150);
    if v_lat is null or v_lng is null then
      return _falha('Para bater o ponto, ative a localização do celular e permita o acesso do navegador a ela. Depois tente de novo.');
    end if;
    if v_dist - least(v_prec, 100) > v_raio then
      select nome into v_nome from funcionarios where id = v_eu;
      perform _auditar('Ponto bloqueado: fora do restaurante', coalesce(v_nome, '') || ' | a ' || v_d || ' m');
      return _falha('Você está a cerca de ' || case when v_d >= 1000 then to_char(round(v_d / 1000.0, 1), 'FM990.0') || ' km' else v_d || ' m' end || ' do restaurante. O ponto só pode ser batido no local.');
    end if;
  end if;
  perform pg_advisory_xact_lock(hashtext('ponto:' || v_eu));
  select * into r from ponto_registros where funcionario_id = v_eu and saida is null and not cancelado order by entrada desc limit 1;
  if r.id is not null and r.entrada > now() - interval '20 seconds' then return jsonb_build_object('ok', true, 'message', 'Já registrado agora há pouco.', 'aberto', true); end if;
  if r.id is not null and r.entrada > now() - interval '20 hours' then
    update ponto_registros set saida = now(), saida_dist_m = v_d where id = r.id;
    return jsonb_build_object('ok', true, 'aberto', false, 'message', 'Saída registrada às ' || to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI') || '. Trabalhou ' || to_char(round(extract(epoch from now() - r.entrada) / 3600.0, 2), 'FM990.00') || ' h neste turno.');
  end if;
  insert into ponto_registros (funcionario_id, entrada, lat, lng, dist_m) values (v_eu, now(), v_lat, v_lng, v_d);
  return jsonb_build_object('ok', true, 'aberto', true, 'message', 'Entrada registrada às ' || to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI') || '.' || case when r.id is not null then ' (A saída anterior ficou sem registro; o dono pode corrigir.)' else '' end);
end $$;

create or replace function api_ponto_relatorio(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_ini date := coalesce(nullif(p->>'inicio', '')::date, _escala_segunda((now() at time zone 'America/Sao_Paulo')::date)); v_fim date := coalesce(nullif(p->>'fim', '')::date, v_ini + 6); v_l jsonb; v_loc jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_fim < v_ini or v_fim - v_ini > 62 then return _falha('Período inválido (máximo de 62 dias).'); end if;
  select jsonb_build_object('definido', true, 'raio', (valor->>'raio')::int) into v_loc from sistema where chave = 'PONTO_LOCAL' and jsonb_typeof(valor) = 'object';
  with reg as (
    select r.funcionario_id, r.id, r.entrada, r.saida, r.observacao, r.origem, r.dist_m, r.saida_dist_m, (r.entrada at time zone 'America/Sao_Paulo')::date dia,
           extract(epoch from coalesce(r.saida, now()) - r.entrada) / 3600.0 h
      from ponto_registros r where not r.cancelado and (r.entrada at time zone 'America/Sao_Paulo')::date between v_ini and v_fim),
  sem as (select funcionario_id, _escala_segunda(dia) semana, sum(h) h from reg group by 1, 2),
  extra as (select funcionario_id, sum(greatest(h - 44, 0)) ex from sem group by 1),
  esc as (select t.funcionario_id, sum(extract(epoch from (t.data + t.fim + case when t.fim <= t.inicio then interval '1 day' else interval '0' end) - (t.data + t.inicio)) / 3600.0) h
            from escala_turnos t where t.tipo = 'Trabalho' and not t.cancelado and t.data between v_ini and v_fim group by 1),
  tot as (select funcionario_id, sum(h) h from reg group by 1)
  select coalesce(jsonb_agg(jsonb_build_object('funcionarioId', f.id, 'nome', f.nome, 'cargo', f.cargo,
      'horasFeitas', round(coalesce(tot.h, 0)::numeric, 2), 'horasEscaladas', round(coalesce(esc.h, 0)::numeric, 2),
      'diferenca', round((coalesce(tot.h, 0) - coalesce(esc.h, 0))::numeric, 2), 'horasExtras', round(coalesce(extra.ex, 0)::numeric, 2),
      'aberto', exists (select 1 from reg where reg.funcionario_id = f.id and reg.saida is null),
      'registros', coalesce((select jsonb_agg(jsonb_build_object('id', reg.id, 'dia', reg.dia, 'entrada', to_char(reg.entrada at time zone 'America/Sao_Paulo', 'HH24:MI'), 'saida', to_char(reg.saida at time zone 'America/Sao_Paulo', 'HH24:MI'),
          'horas', round(reg.h::numeric, 2), 'origem', reg.origem, 'observacao', reg.observacao, 'distEntrada', reg.dist_m, 'distSaida', reg.saida_dist_m) order by reg.entrada) from reg where reg.funcionario_id = f.id), '[]'::jsonb)
    ) order by f.nome), '[]'::jsonb) into v_l
    from funcionarios f left join tot on tot.funcionario_id = f.id left join esc on esc.funcionario_id = f.id left join extra on extra.funcionario_id = f.id
   where f.ativo or tot.h is not null;
  return jsonb_build_object('ok', true, 'inicio', v_ini, 'fim', v_fim, 'pessoas', v_l, 'local', coalesce(v_loc, jsonb_build_object('definido', false)));
end $$;
