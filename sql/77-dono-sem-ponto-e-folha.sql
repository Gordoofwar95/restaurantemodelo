-- 77 · "Dono": pessoa que não bate ponto e não entra na folha (marque o dono em Equipe). Qualquer outro Admin cadastrado continua batendo ponto e entrando na folha.
alter table public.funcionarios add column if not exists dono boolean not null default false;

do $$ declare x record; d text;
begin
  for x in select * from (values
    ('public.api_ponto_bater(jsonb)', E'  if v_eu is null then return _falha(''Seu acesso ainda', E'  if v_eu is not null and exists (select 1 from funcionarios where id = v_eu and dono) then return _falha(''Você é o dono: não precisa bater ponto.''); end if;\n  if v_eu is null then return _falha(''Seu acesso ainda'),
    ('public.api_ponto_estado(jsonb)', 'if v_eu is null then return jsonb_build_object(''ok'', true, ''vinculado'', false); end if;', 'if v_eu is null or exists (select 1 from funcionarios where id = v_eu and dono) then return jsonb_build_object(''ok'', true, ''vinculado'', false); end if;'),
    ('public.api_ponto_relatorio(jsonb)', 'where f.ativo or tot.h is not null;', 'where (f.ativo or tot.h is not null) and not f.dono;'),
    ('public.api_equipe_folha(jsonb)', 'x.tipo in (''Salário'', ''Adiantamento'', ''Vale'')) s on true;', 'x.tipo in (''Salário'', ''Adiantamento'', ''Vale'')) s on true where not f.dono;'),
    ('public.api_equipe_folha(jsonb)', 'into v_prev from funcionarios where ativo;', 'into v_prev from funcionarios where ativo and not dono;'),
    ('public.api_escala_semana(jsonb)', 'from funcionarios f where f.ativo or (v_adm and exists (select 1 from escala_turnos t where t.funcionario_id = f.id and t.data between v_ini and v_fim and not t.cancelado));', 'from funcionarios f where not f.dono and (f.ativo or (v_adm and exists (select 1 from escala_turnos t where t.funcionario_id = f.id and t.data between v_ini and v_fim and not t.cancelado)));'),
    ('public.api_equipe_reserva(jsonb)', 'where f.ativo and f.salario > 0) q;', 'where f.ativo and not f.dono and f.salario > 0) q;'),
    ('public.api_minha_escala(jsonb)', 'where usuario_id = auth.uid() and ativo;', 'where usuario_id = auth.uid() and ativo and not dono;'),
    ('public.equipe_pendencias_cron()', 'from funcionarios where ativo and salario > 0 and', 'from funcionarios where ativo and not dono and salario > 0 and'),
    ('public.ponto_pendencias_cron()', 'where pr.saida is null and not pr.cancelado', 'where not f.dono and pr.saida is null and not pr.cancelado')
  ) v(sig, a, b) loop
    d := pg_get_functiondef(x.sig::regprocedure);
    if position(x.b in d) > 0 then continue; end if;
    if (length(d) - length(replace(d, x.a, ''))) <> length(x.a) then raise exception 'trecho nao encontrado ou repetido em %: %', x.sig, left(x.a, 60); end if;
    execute replace(d, x.a, x.b);
  end loop;
end $$;
