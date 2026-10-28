-- 36 · Avaliações do iFood dentro dos Feedbacks (19/10/2026)
-- • Responder uma avaliação do iFood pela tela de Feedbacks também envia a resposta ao iFood (só o Administrador; integração ligada; até 600 letras).
-- • Responder pela aba iFood marca o feedback correspondente como respondido, com o mesmo texto.
create or replace function public.api_responder_feedback(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := _uuid(p->>'id'); v_txt text := left(btrim(coalesce(p->>'resposta', '')), 1000); v_nome text; v_user uuid; v_av text; v_ifood text := null;
begin
  if not tem_nivel('Admin','Operador') then return _negado(); end if;
  if v_txt = '' then return _falha('Escreva a resposta.'); end if;
  select nome into v_nome from usuarios where id = auth.uid();
  update feedbacks set resposta = v_txt, respondido_em = now(), respondido_por = coalesce(v_nome, ''), status = 'Respondido'
   where id = v_id returning user_id into v_user;
  if not found then return _falha('Feedback não encontrado.'); end if;
  select id into v_av from ifood_avaliacoes where feedback_id = v_id;
  if v_av is not null then
    if not tem_nivel('Admin') then v_ifood := 'so_admin';
    elsif not _integracao_ligada('ifood') then v_ifood := 'desligado';
    elsif length(v_txt) < 3 or length(v_txt) > 600 then v_ifood := 'tamanho';
    else
      update ifood_avaliacoes set resposta = v_txt, respondida_em = now() where id = v_av;
      insert into ifood_acoes (pedido_ifood, acao, dados) values ('LOJA', 'avaliacao_responder', jsonb_build_object('avaliacao', v_av, 'texto', v_txt)) on conflict do nothing;
      v_ifood := 'enviada';
    end if;
  end if;
  perform _auditar('Feedback respondido', 'Resposta enviada' || case when v_user is null then ' (cliente sem conta)' else '' end || case when v_ifood = 'enviada' then ' · enviada ao iFood' else '' end);
  return jsonb_build_object('ok', true, 'comConta', v_user is not null, 'ifood', v_ifood);
end $$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.api_ifood_avaliacao_responder(jsonb)'::regprocedure);
  if d like '%update feedbacks%' then return; end if;
  d := replace(d, 'update ifood_avaliacoes set resposta = v_texto, respondida_em = now() where id = p->>''id'';',
    'update ifood_avaliacoes set resposta = v_texto, respondida_em = now() where id = p->>''id'';' || chr(10) ||
    '  update feedbacks set resposta = v_texto, respondido_em = now(), respondido_por = coalesce((select nome from usuarios where id = auth.uid()), ''''), status = ''Respondido'' where id = (select feedback_id from ifood_avaliacoes where id = p->>''id'');');
  if d not like '%update feedbacks%' then raise exception 'trecho não encontrado em api_ifood_avaliacao_responder'; end if;
  execute d;
end $$;

-- A IA do sistema (resumos e perguntas) passa a ver o iFood como origem própria, em vez de misturá-lo com "Balcão"
do $$
declare d text; v_old text; v_new text; r record;
begin
  for r in select * from (values
      ('public.ia_periodo_(date,date,boolean)', 'select origem::text k, count(*) n from vendas', 'select (case when canal = ''iFood'' then ''iFood'' else origem::text end) k, count(*) n from vendas'),
      ('public.ia_resumo_periodo(date,date)', 'select origem::text origem, count(*) n, sum(valor_total) v from vendas', 'select (case when canal = ''iFood'' then ''iFood'' else origem::text end) origem, count(*) n, sum(valor_total) v from vendas')
    ) t(fn, v_old, v_new) loop
    d := pg_get_functiondef(r.fn::regprocedure);
    if d like '%canal = ''iFood'' then ''iFood'' else origem::text%' then continue; end if;
    d := replace(d, r.v_old, r.v_new);
    if d not like '%canal = ''iFood'' then ''iFood'' else origem::text%' then raise exception 'trecho não encontrado em %', r.fn; end if;
    execute d;
  end loop;
end $$;
