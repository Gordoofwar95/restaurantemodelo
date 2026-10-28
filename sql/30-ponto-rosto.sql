-- 30 · Ponto com reconhecimento facial e foto da batida (18/10/2026)
-- • O "código do rosto" (128 números, não é foto) é gravado na PRIMEIRA batida do funcionário, com o aceite (LGPD).
-- • A comparação é feita aqui no banco. Rosto confere = batida normal. Não confere = o funcionário pode mandar a selfie e a batida
--   fica marcada "pendente" para o dono aprovar ou cancelar (Administrador > Loja e equipe > Ponto).
-- • A foto de cada batida vai para o Drive principal e para o da contingência (pasta privada) e é apagada após 45 dias
--   (rotina diária ponto-fotos-45-dias, que chama a Edge Function ponto-foto com a ação "limpar").
-- • Chave em "sistema": PONTO_ROSTO = {"ligado":true,"limite":0.55}. Sem a chave vale ligado = true.

create table if not exists public.ponto_rosto (
  funcionario_id uuid primary key,
  descritor double precision[] not null,
  consentimento_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.ponto_rosto enable row level security;
revoke all on public.ponto_rosto from anon, authenticated;
grant all on public.ponto_rosto to service_role;

alter table public.ponto_registros add column if not exists rosto_ent text;
alter table public.ponto_registros add column if not exists rosto_sai text;
alter table public.ponto_registros add column if not exists rosto_dist_ent real;
alter table public.ponto_registros add column if not exists rosto_dist_sai real;
alter table public.ponto_registros add column if not exists foto_ent text;
alter table public.ponto_registros add column if not exists foto_sai text;

create or replace function public._dist_descritor(a double precision[], b double precision[])
returns double precision language sql immutable as $$
  select sqrt(coalesce(sum(power(x - y, 2)), 0)) from unnest(a, b) as t(x, y)
$$;

create or replace function public._ponto_rosto_cfg()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('ligado', coalesce((select (valor->>'ligado')::boolean from sistema where chave = 'PONTO_ROSTO' and jsonb_typeof(valor) = 'object'), true),
                            'limite', coalesce((select (valor->>'limite')::numeric from sistema where chave = 'PONTO_ROSTO' and jsonb_typeof(valor) = 'object'), 0.55))
$$;

create or replace function public.api_ponto_rosto_config(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c jsonb := _ponto_rosto_cfg(); v_lig boolean; v_lim numeric;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if p ? 'ligado' or p ? 'limite' then
    v_lig := coalesce(nullif(p->>'ligado', '')::boolean, (c->>'ligado')::boolean);
    v_lim := coalesce(nullif(p->>'limite', '')::numeric, (c->>'limite')::numeric);
    if v_lim < 0.40 or v_lim > 0.70 then return _falha('O rigor precisa ficar entre 0,40 e 0,70.'); end if;
    insert into sistema (chave, valor) values ('PONTO_ROSTO', jsonb_build_object('ligado', v_lig, 'limite', v_lim))
      on conflict (chave) do update set valor = excluded.valor;
    perform _auditar('Ponto: reconhecimento facial ' || case when v_lig then 'ligado' else 'desligado' end, 'limite ' || v_lim);
    c := _ponto_rosto_cfg();
  end if;
  return jsonb_build_object('ok', true, 'ligado', (c->>'ligado')::boolean, 'limite', (c->>'limite')::numeric);
end $$;

create or replace function public.api_ponto_rosto_apagar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_f uuid := _uuid(p->>'funcionarioId'); v_n text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  select nome into v_n from funcionarios where id = v_f;
  if v_n is null then return _falha('Funcionário não encontrado.'); end if;
  update ponto_rosto set descritor = '{}', atualizado_em = now() where funcionario_id = v_f;   -- sobrescreve o código do rosto por vazio (apaga o dado biométrico)
  perform _auditar('Ponto: rosto apagado', v_n);
  return jsonb_build_object('ok', true, 'message', 'Rosto de ' || v_n || ' apagado. Na próxima batida ele cadastra de novo.');
end $$;

create or replace function public.api_ponto_aprovar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_f uuid;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  update ponto_registros set rosto_ent = case when rosto_ent = 'pendente' then 'aprovado' else rosto_ent end,
                             rosto_sai = case when rosto_sai = 'pendente' then 'aprovado' else rosto_sai end
   where id = v_id and not cancelado returning funcionario_id into v_f;
  if v_f is null then return _falha('Registro não encontrado.'); end if;
  perform _auditar('Ponto: batida aprovada pelo dono', (select nome from funcionarios where id = v_f));
  return jsonb_build_object('ok', true, 'message', 'Batida aprovada.');
end $$;

-- A foto só pode ser enviada pelo próprio funcionário, logo depois de bater o ponto, uma vez por lado.
create or replace function public.api_ponto_foto_pode(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); v_id uuid := nullif(p->>'registroId', '')::uuid; v_lado text := p->>'lado'; r ponto_registros%rowtype;
begin
  if auth_nivel() is null then return _negado(); end if;
  if v_eu is null or v_id is null or v_lado not in ('entrada', 'saida') then return _falha('Pedido inválido.'); end if;
  select * into r from ponto_registros where id = v_id and funcionario_id = v_eu and not cancelado;
  if r.id is null then return _falha('Registro não encontrado.'); end if;
  if v_lado = 'entrada' and (r.foto_ent is not null or r.criado_em < now() - interval '10 minutes') then return _falha('A foto da entrada já foi enviada ou passou do prazo.'); end if;
  if v_lado = 'saida' and (r.saida is null or r.foto_sai is not null or r.saida < now() - interval '10 minutes') then return _falha('A foto da saída já foi enviada ou passou do prazo.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_ponto_foto_anexar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); v_id uuid := nullif(p->>'registroId', '')::uuid; v_lado text := p->>'lado'; v_path text := p->>'path'; v_ok jsonb;
begin
  v_ok := api_ponto_foto_pode(p);
  if not coalesce((v_ok->>'ok')::boolean, false) then return v_ok; end if;
  if v_path is null or v_path !~ '^(drive:[A-Za-z0-9_-]{10,80})?(\|)?(cont:[A-Za-z0-9_-]{10,80})?$' or v_path = '' then return _falha('Caminho da foto inválido.'); end if;
  if v_lado = 'entrada' then update ponto_registros set foto_ent = v_path where id = v_id and funcionario_id = v_eu;
  else update ponto_registros set foto_sai = v_path where id = v_id and funcionario_id = v_eu; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_ponto_estado(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); r ponto_registros%rowtype; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_ini date; v_h numeric;
        v_exige boolean := exists (select 1 from sistema where chave = 'PONTO_LOCAL' and jsonb_typeof(valor) = 'object');
        v_cfg jsonb := _ponto_rosto_cfg();
begin
  if auth_nivel() is null then return _negado(); end if;
  if v_eu is null then return jsonb_build_object('ok', true, 'vinculado', false); end if;
  v_ini := _escala_segunda(v_hoje);
  select * into r from ponto_registros where funcionario_id = v_eu and saida is null and not cancelado order by entrada desc limit 1;
  select coalesce(round(sum(extract(epoch from coalesce(saida, now()) - entrada)) / 3600.0, 2), 0) into v_h from ponto_registros
   where funcionario_id = v_eu and not cancelado and (entrada at time zone 'America/Sao_Paulo')::date between v_ini and v_ini + 6;
  return jsonb_build_object('ok', true, 'vinculado', true, 'aberto', r.id is not null, 'entrada', r.entrada, 'horasSemana', v_h, 'exigeLocal', v_exige,
    'rostoLigado', (v_cfg->>'ligado')::boolean, 'temRosto', exists (select 1 from ponto_rosto where funcionario_id = v_eu and array_length(descritor, 1) = 128));
end $$;

create or replace function public.api_ponto_bater(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_eu uuid := _func_do_usuario(); r ponto_registros%rowtype; v_cfg jsonb; v_lat double precision; v_lng double precision; v_prec double precision; v_dist double precision; v_d int; v_raio int; v_nome text;
        v_rc jsonb := _ponto_rosto_cfg(); v_desc double precision[]; v_tpl double precision[]; v_rd double precision; v_st text; v_pend boolean := coalesce(p->>'pendente', '') = 'true'; v_novo uuid; v_lado text;
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

  -- rosto
  if (v_rc->>'ligado')::boolean then
    begin select array_agg(x::double precision) into v_desc from jsonb_array_elements_text(p->'descritor') x; exception when others then v_desc := null; end;
    if v_desc is not null and (array_length(v_desc, 1) <> 128 or exists (select 1 from unnest(v_desc) z where z is null or z <> z)) then v_desc := null; end if;
    select descritor into v_tpl from ponto_rosto where funcionario_id = v_eu and array_length(descritor, 1) = 128;
    if v_tpl is null then
      if v_desc is not null and not v_pend then
        if coalesce(p->>'consentimento', '') <> 'true' then
          return jsonb_build_object('ok', false, 'rosto', 'consentimento', 'message', 'Para cadastrar seu rosto é preciso aceitar o termo.');
        end if;
        insert into ponto_rosto (funcionario_id, descritor) values (v_eu, v_desc) on conflict (funcionario_id) do update set descritor = excluded.descritor, consentimento_em = now(), atualizado_em = now();
        perform _auditar('Ponto: rosto cadastrado', coalesce((select nome from funcionarios where id = v_eu), ''));
        v_st := 'cadastro'; v_rd := 0;
      else
        v_st := 'pendente';
      end if;
    else
      if v_desc is not null then v_rd := _dist_descritor(v_tpl, v_desc); end if;
      if v_rd is not null and v_rd <= (v_rc->>'limite')::double precision then v_st := 'ok';
      elsif v_pend then v_st := 'pendente';
      else
        return jsonb_build_object('ok', false, 'rosto', case when v_desc is null then 'sem_rosto' else 'nao_reconhecido' end,
          'message', case when v_desc is null then 'Não consegui ver o seu rosto. Olhe para a câmera, com boa luz, e tente de novo.' else 'Não reconheci o seu rosto. Tente de novo com boa luz, sem boné ou óculos escuros.' end);
      end if;
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('ponto:' || v_eu));
  select * into r from ponto_registros where funcionario_id = v_eu and saida is null and not cancelado order by entrada desc limit 1;
  if r.id is not null and r.entrada > now() - interval '20 seconds' then return jsonb_build_object('ok', true, 'message', 'Já registrado agora há pouco.', 'aberto', true); end if;
  if r.id is not null and r.entrada > now() - interval '20 hours' then
    update ponto_registros set saida = now(), saida_dist_m = v_d, rosto_sai = v_st, rosto_dist_sai = v_rd where id = r.id;
    return jsonb_build_object('ok', true, 'aberto', false, 'registroId', r.id, 'lado', 'saida', 'rosto', v_st,
      'message', 'Saída registrada às ' || to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI') || '. Trabalhou ' || to_char(round(extract(epoch from now() - r.entrada) / 3600.0, 2), 'FM990.00') || ' h neste turno.' || case when v_st = 'pendente' then ' O dono vai conferir a foto.' else '' end);
  end if;
  insert into ponto_registros (funcionario_id, entrada, lat, lng, dist_m, rosto_ent, rosto_dist_ent) values (v_eu, now(), v_lat, v_lng, v_d, v_st, v_rd) returning id into v_novo;
  return jsonb_build_object('ok', true, 'aberto', true, 'registroId', v_novo, 'lado', 'entrada', 'rosto', v_st,
    'message', case when v_st = 'cadastro' then 'Rosto cadastrado. ' else '' end || 'Entrada registrada às ' || to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI') || '.' || case when r.id is not null then ' (A saída anterior ficou sem registro; o dono pode corrigir.)' else '' end || case when v_st = 'pendente' then ' O dono vai conferir a foto.' else '' end);
end $$;

create or replace function public.api_ponto_relatorio(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_ini date := coalesce(nullif(p->>'inicio', '')::date, _escala_segunda((now() at time zone 'America/Sao_Paulo')::date)); v_fim date := coalesce(nullif(p->>'fim', '')::date, v_ini + 6); v_l jsonb; v_loc jsonb;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if v_fim < v_ini or v_fim - v_ini > 62 then return _falha('Período inválido (máximo de 62 dias).'); end if;
  select jsonb_build_object('definido', true, 'raio', (valor->>'raio')::int) into v_loc from sistema where chave = 'PONTO_LOCAL' and jsonb_typeof(valor) = 'object';
  with reg as (
    select r.funcionario_id, r.id, r.entrada, r.saida, r.observacao, r.origem, r.dist_m, r.saida_dist_m, r.rosto_ent, r.rosto_sai, r.foto_ent, r.foto_sai, (r.entrada at time zone 'America/Sao_Paulo')::date dia,
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
      'temRosto', exists (select 1 from ponto_rosto pr where pr.funcionario_id = f.id and array_length(pr.descritor, 1) = 128),
      'registros', coalesce((select jsonb_agg(jsonb_build_object('id', reg.id, 'dia', reg.dia, 'entrada', to_char(reg.entrada at time zone 'America/Sao_Paulo', 'HH24:MI'), 'saida', to_char(reg.saida at time zone 'America/Sao_Paulo', 'HH24:MI'),
          'horas', round(reg.h::numeric, 2), 'origem', reg.origem, 'observacao', reg.observacao, 'distEntrada', reg.dist_m, 'distSaida', reg.saida_dist_m,
          'rostoEntrada', reg.rosto_ent, 'rostoSaida', reg.rosto_sai, 'fotoEntrada', reg.foto_ent is not null, 'fotoSaida', reg.foto_sai is not null) order by reg.entrada) from reg where reg.funcionario_id = f.id), '[]'::jsonb)
    ) order by f.nome), '[]'::jsonb) into v_l
    from funcionarios f left join tot on tot.funcionario_id = f.id left join esc on esc.funcionario_id = f.id left join extra on extra.funcionario_id = f.id
   where f.ativo or tot.h is not null;
  return jsonb_build_object('ok', true, 'inicio', v_ini, 'fim', v_fim, 'pessoas', v_l, 'local', coalesce(v_loc, jsonb_build_object('definido', false)), 'rosto', _ponto_rosto_cfg());
end $$;

-- permissões das funções novas (as antigas mantêm as suas)
do $$
declare f text;
begin
  foreach f in array array['api_ponto_local(jsonb)', 'api_ponto_rosto_config(jsonb)', 'api_ponto_rosto_apagar(jsonb)', 'api_ponto_aprovar(jsonb)', 'api_ponto_foto_pode(jsonb)', 'api_ponto_foto_anexar(jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
  revoke all on function public._dist_descritor(double precision[], double precision[]) from public, anon, authenticated;
  revoke all on function public._dist_metros(double precision, double precision, double precision, double precision) from public, anon, authenticated;
  revoke all on function public._ponto_rosto_cfg() from public, anon, authenticated;
end $$;

-- limpeza diária das fotos com mais de 45 dias (a Edge Function apaga nos dois Drives e limpa os caminhos)
select cron.schedule('ponto-fotos-45-dias', '40 6 * * *', $$select public.chamar_edge('ponto-foto', '{"acao":"limpar"}'::jsonb)$$);
