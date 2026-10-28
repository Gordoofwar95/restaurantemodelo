-- 67 · iFood Avaliações v2 (v1.18) — revisado pela documentação OFICIAL do módulo Review. Pode rodar de novo sem erro.
-- H1 resposta de 10 a 300 letras · H2 número do pedido (order.id / order.shortId) · H3 resposta da LOJA separada da reação do cliente
-- H4 recusa do iFood visível (a resposta volta a ficar "sem resposta" e a equipe é avisada) · H5 status, prazo de 5 dias, selos
-- H7 detalhe (nome do cliente e questionário) · H8 nota oficial (summary).

alter table public.ifood_avaliacoes add column if not exists pedido_curto text;
alter table public.ifood_avaliacoes add column if not exists status text;
alter table public.ifood_avaliacoes add column if not exists visibilidade text;
alter table public.ifood_avaliacoes add column if not exists descartada boolean not null default false;
alter table public.ifood_avaliacoes add column if not exists moderada boolean not null default false;
alter table public.ifood_avaliacoes add column if not exists publicada_em timestamptz;
alter table public.ifood_avaliacoes add column if not exists prazo_em timestamptz;
alter table public.ifood_avaliacoes add column if not exists prazo_avisado boolean not null default false;
alter table public.ifood_avaliacoes add column if not exists resposta_estado text;      -- enviando | aceita | recusada
alter table public.ifood_avaliacoes add column if not exists resposta_erro text;
alter table public.ifood_avaliacoes add column if not exists resposta_enviada_em timestamptz;
alter table public.ifood_avaliacoes add column if not exists resposta_cliente text;
alter table public.ifood_avaliacoes add column if not exists cliente_nome text;
alter table public.ifood_avaliacoes add column if not exists questionario jsonb;
alter table public.ifood_avaliacoes add column if not exists detalhe_em timestamptz;

create table if not exists public.ifood_aval_resumo (
  id boolean primary key default true check (id),
  dados jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);
alter table public.ifood_aval_resumo enable row level security;
revoke all on public.ifood_aval_resumo from anon, authenticated;

-- a resposta foi recusada: volta a ficar "sem resposta", o feedback volta a "Novo" e a equipe é avisada (nenhum erro discreto)
create or replace function public.ifood_aval_resposta_falhou(p_id text, p_erro text, p_pode_repetir boolean default true) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare a ifood_avaliacoes%rowtype;
begin
  select * into a from ifood_avaliacoes where id = p_id;
  if not found then return; end if;
  update ifood_avaliacoes set resposta = null, respondida_em = null, resposta_estado = 'recusada', resposta_erro = left(p_erro, 400) where id = p_id;
  if a.feedback_id is not null then update feedbacks set resposta = null, respondido_em = null, respondido_por = '', status = 'Novo' where id = a.feedback_id; end if;
  perform ifood_aviso_registrar(a.pedido_ifood, 'aval_recusada', '❌ O iFood não aceitou sua resposta à avaliação',
    left(p_erro, 400) || case when p_pode_repetir then ' Você pode escrever outra resposta.' else '' end, jsonb_build_object('avaliacao', p_id));
end $f$;
revoke all on function public.ifood_aval_resposta_falhou(text, text, boolean) from public, anon, authenticated;
grant execute on function public.ifood_aval_resposta_falhou(text, text, boolean) to service_role;

-- chamada pela Edge Function depois de enviar a resposta (201 = recebida para validação; 400/409/422 = recusada)
create or replace function public.ifood_aval_resposta_resultado(p_id text, p_http int, p_corpo text default null) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare v_msg text;
begin
  if p_http between 200 and 299 then
    update ifood_avaliacoes set resposta_estado = 'enviando', resposta_erro = null where id = p_id and coalesce(resposta_estado, '') <> 'aceita';
    return;
  end if;
  v_msg := case
    when p_http = 400 then 'O iFood recusou o tamanho da resposta (precisa ter de 10 a 300 letras).'
    when p_http = 409 then 'Esta avaliação não aceita mais resposta (já foi respondida ou o prazo de 5 dias passou).'
    when p_http = 422 then 'O iFood recusou o conteúdo: evite links, telefones, nomes e dados pessoais, e palavras impróprias.'
    when p_http = 404 then 'O iFood não encontrou esta avaliação.'
    when p_http = 429 then 'Muitas chamadas ao iFood ao mesmo tempo. Tente de novo em alguns minutos.'
    else 'O iFood não recebeu a resposta (erro ' || p_http || ').' end;
  perform ifood_aval_resposta_falhou(p_id, v_msg || coalesce(' (' || left(p_corpo, 120) || ')', ''), p_http not in (404, 409));
end $f$;
revoke all on function public.ifood_aval_resposta_resultado(text, int, text) from public, anon, authenticated;
grant execute on function public.ifood_aval_resposta_resultado(text, int, text) to service_role;

-- grava as avaliações da listagem (v2: order.id / order.shortId; replies com from = MERCHANT ou CUSTOMER)
create or replace function public.ifood_avaliacoes_gravar(p_lista jsonb) returns integer
 language plpgsql security definer set search_path to 'public' as $function$
declare e jsonb; v_n int := 0; v_fb uuid; v_venda uuid; v_nota int; v_ja boolean; v_num text; v_ord text; v_curto text; v_mer text; v_cli text; v_st text; v_old ifood_avaliacoes%rowtype; v_cri timestamptz; v_rep jsonb;
begin
  for e in select value from jsonb_array_elements(coalesce(p_lista, '[]'::jsonb)) loop
    if nullif(e->>'id', '') is null then continue; end if;
    select * into v_old from ifood_avaliacoes where id = e->>'id'; v_ja := found;
    v_nota := round(public._ifood_n(coalesce(e->'score', e->'rating', e->'nota')))::int;
    v_ord := coalesce(nullif(e->'order'->>'id', ''), nullif(e->>'orderId', ''));
    v_curto := coalesce(nullif(e->'order'->>'shortId', ''), nullif(e->>'shortId', ''));
    v_rep := case when jsonb_typeof(e->'replies') = 'array' then e->'replies' else '[]'::jsonb end;
    select r->>'text' into v_mer from jsonb_array_elements(v_rep) r where upper(coalesce(r->>'from', 'MERCHANT')) = 'MERCHANT' and coalesce(r->>'text', '') <> '' order by r->>'createdAt' desc limit 1;
    select r->>'text' into v_cli from jsonb_array_elements(v_rep) r where upper(coalesce(r->>'from', '')) = 'CUSTOMER' and coalesce(r->>'text', '') <> '' order by r->>'createdAt' desc limit 1;
    v_mer := coalesce(v_mer, nullif(e->>'reply', ''));
    v_st := upper(nullif(e->>'status', ''));
    v_cri := nullif(e->>'createdAt', '')::timestamptz;
    select venda_id, numero_ifood into v_venda, v_num from ifood_pedidos where pedido_ifood = v_ord;
    insert into ifood_avaliacoes (id, pedido_ifood, pedido_curto, nota, comentario, criada_em, resposta, bruto, status, visibilidade, descartada, moderada, publicada_em, prazo_em, resposta_cliente, resposta_estado)
    values (e->>'id', v_ord, v_curto, v_nota, left(coalesce(e->>'comment', e->>'text', ''), 1000), v_cri, v_mer, e, v_st, upper(nullif(e->>'visibility', '')),
            coalesce((e->>'discarded')::boolean, false), coalesce((e->>'moderated')::boolean, false), nullif(e->>'published', '')::timestamptz,
            v_cri + interval '5 days', v_cli, case when v_mer is not null then 'aceita' end)
    on conflict (id) do update set
      pedido_ifood = coalesce(excluded.pedido_ifood, ifood_avaliacoes.pedido_ifood), pedido_curto = coalesce(excluded.pedido_curto, ifood_avaliacoes.pedido_curto),
      nota = excluded.nota, bruto = excluded.bruto, status = excluded.status, visibilidade = excluded.visibilidade, descartada = excluded.descartada, moderada = excluded.moderada,
      publicada_em = coalesce(excluded.publicada_em, ifood_avaliacoes.publicada_em), prazo_em = coalesce(ifood_avaliacoes.prazo_em, excluded.prazo_em), resposta_cliente = excluded.resposta_cliente,
      resposta = coalesce(excluded.resposta, ifood_avaliacoes.resposta),
      resposta_estado = case when excluded.resposta is not null then 'aceita' else ifood_avaliacoes.resposta_estado end,
      resposta_erro = case when excluded.resposta is not null then null else ifood_avaliacoes.resposta_erro end;
    -- a resposta ficou "enviando" mas o iFood continua sem a resposta depois de 20 min: a validação do iFood a recusou
    if v_ja and v_mer is null and v_old.resposta_estado = 'enviando' and v_old.resposta_enviada_em < now() - interval '20 minutes' and coalesce(v_st, 'NOT_REPLIED') = 'NOT_REPLIED' then
      perform ifood_aval_resposta_falhou(e->>'id', 'O iFood não publicou a resposta depois da validação dele (provavelmente tem link, telefone, dado pessoal ou palavra imprópria).', true);
    end if;
    -- liga o feedback à venda quando o pedido só apareceu agora
    if v_ja and v_old.feedback_id is not null and v_venda is not null then update feedbacks set venda_id = v_venda where id = v_old.feedback_id and venda_id is null; end if;
    if not v_ja then
      begin
        insert into feedbacks (venda_id, nota, comentario, data, status, origem) values (v_venda, greatest(least(v_nota, 5), 1), left(coalesce(e->>'comment', e->>'text', ''), 1000), coalesce(v_cri, now()), 'Novo', 'iFood') returning id into v_fb;
        update ifood_avaliacoes set feedback_id = v_fb where id = e->>'id';
      exception when others then null; end;
      if v_nota <= 2 or (v_nota = 3 and coalesce((select (config->>'avaliacaoAlerta')::boolean from integracoes_config where provedor = 'ifood'), false)) then perform _push_enviar('feedback', '⭐ Avaliação baixa no iFood (' || v_nota || ')', coalesce(left(e->>'comment', 100), 'Veja no painel'), 'ifood-aval-' || (e->>'id')); end if;
      v_n := v_n + 1;
    end if;
  end loop;
  -- falta 1 dia para o fim do prazo de resposta (5 dias): avisa uma vez
  for e in select jsonb_build_object('id', id, 'pedido', pedido_ifood) from ifood_avaliacoes
            where status = 'NOT_REPLIED' and not prazo_avisado and coalesce(resposta_estado, '') <> 'enviando' and nota < 5 and prazo_em between now() and now() + interval '1 day' loop
    update ifood_avaliacoes set prazo_avisado = true where id = e->>'id';
    perform ifood_aviso_registrar(e->>'pedido', 'aval_prazo', '⏰ Avaliação do iFood perde o prazo de resposta amanhã', 'Responda hoje: depois de 5 dias a avaliação é publicada sem a sua resposta.', jsonb_build_object('avaliacao', e->>'id'));
  end loop;
  return v_n;
end $function$;
revoke all on function public.ifood_avaliacoes_gravar(jsonb) from public, anon, authenticated;
grant execute on function public.ifood_avaliacoes_gravar(jsonb) to service_role;

create or replace function public.ifood_aval_detalhe_gravar(p_id text, p jsonb) returns void
 language sql security definer set search_path to 'public' as $f$
  update ifood_avaliacoes set cliente_nome = left(coalesce(p->>'customerName', cliente_nome), 80),
    questionario = case when jsonb_typeof(p->'questions') = 'array' then p->'questions' else questionario end, detalhe_em = now() where id = p_id
$f$;
create or replace function public.ifood_aval_resumo_gravar(p jsonb) returns void
 language sql security definer set search_path to 'public' as $f$
  insert into ifood_aval_resumo (id, dados, atualizado_em) values (true, coalesce(p, '{}'::jsonb), now())
  on conflict (id) do update set dados = excluded.dados, atualizado_em = now()
$f$;
-- avaliações novas sem detalhe (a Edge Function busca no máximo 5 por rodada)
create or replace function public.ifood_aval_detalhe_pendentes() returns jsonb
 language sql stable security definer set search_path to 'public' as $f$
  select coalesce(jsonb_agg(id), '[]'::jsonb) from (select id from ifood_avaliacoes where detalhe_em is null and criada_em > now() - interval '15 days' order by criada_em desc limit 5) x
$f$;
revoke all on function public.ifood_aval_detalhe_gravar(text, jsonb), public.ifood_aval_resumo_gravar(jsonb), public.ifood_aval_detalhe_pendentes() from public, anon, authenticated;
grant execute on function public.ifood_aval_detalhe_gravar(text, jsonb), public.ifood_aval_resumo_gravar(jsonb), public.ifood_aval_detalhe_pendentes() to service_role;

-- tela de avaliações (Admin): nota oficial + 30 dias, status, prazo, selos, questionário
create or replace function public.api_ifood_avaliacoes(p jsonb default '{}'::jsonb) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $function$
declare v_so boolean := coalesce(p->>'semResposta', '') = 'true';
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  return jsonb_build_object('ok', true, 'media30d', (select round(avg(nota), 2) from ifood_avaliacoes where coalesce(criada_em, visto_em) > now() - interval '30 days'),
    'oficial', (select dados || jsonb_build_object('em', atualizado_em) from ifood_aval_resumo where id),
    'semResposta', (select count(*) from ifood_avaliacoes where status = 'NOT_REPLIED' and nota < 5 and coalesce(resposta_estado, '') <> 'enviando' and prazo_em > now()),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'nota', a.nota, 'comentario', a.comentario, 'em', a.criada_em, 'resposta', a.resposta,
        'pedido', coalesce(i.numero_ifood, a.pedido_curto), 'status', a.status, 'visibilidade', a.visibilidade, 'descartada', a.descartada, 'moderada', a.moderada,
        'prazoEm', a.prazo_em, 'podeResponder', (coalesce(a.status, 'NOT_REPLIED') = 'NOT_REPLIED' and coalesce(a.resposta_estado, '') not in ('enviando', 'aceita') and (a.prazo_em is null or a.prazo_em > now())),
        'respostaEstado', a.resposta_estado, 'respostaErro', a.resposta_erro, 'respostaCliente', a.resposta_cliente, 'cliente', a.cliente_nome, 'questionario', a.questionario)
        order by coalesce(a.criada_em, a.visto_em) desc)
      from (select * from ifood_avaliacoes where (not v_so or (status = 'NOT_REPLIED' and nota < 5)) order by coalesce(criada_em, visto_em) desc limit 50) a
      left join ifood_pedidos i on i.pedido_ifood = a.pedido_ifood), '[]'::jsonb));
end $function$;

-- responder (Admin): 10 a 300 letras, só quando o iFood ainda aceita; a tela mostra "enviando" até o iFood confirmar
create or replace function public.api_ifood_avaliacao_responder(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare v_texto text := btrim(coalesce(p->>'texto', '')); a ifood_avaliacoes%rowtype;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  if length(v_texto) < 10 or length(v_texto) > 300 then return _falha('A resposta ao iFood precisa ter de 10 a 300 letras (tem ' || length(v_texto) || ').'); end if;
  select * into a from ifood_avaliacoes where id = p->>'id';
  if not found then return _falha('Avaliação não encontrada.'); end if;
  if coalesce(a.status, 'NOT_REPLIED') <> 'NOT_REPLIED' then return _falha('O iFood não aceita mais resposta a esta avaliação (status ' || a.status || ').'); end if;
  if a.resposta_estado = 'enviando' then return _falha('A resposta anterior ainda está sendo validada pelo iFood. Aguarde alguns minutos.'); end if;
  if a.prazo_em is not null and a.prazo_em < now() then return _falha('O prazo de 5 dias para responder já passou.'); end if;
  if not _integracao_ligada('ifood') then return _falha('O iFood está desligado.'); end if;
  update ifood_avaliacoes set resposta = v_texto, respondida_em = now(), resposta_estado = 'enviando', resposta_erro = null, resposta_enviada_em = now() where id = a.id;
  update feedbacks set resposta = v_texto, respondido_em = now(), respondido_por = coalesce((select nome from usuarios where id = auth.uid()), ''), status = 'Respondido' where id = a.feedback_id;
  insert into ifood_acoes (pedido_ifood, acao, dados) values ('LOJA', 'avaliacao_responder', jsonb_build_object('avaliacao', a.id, 'texto', v_texto, 'chave', gen_random_uuid()::text)) on conflict do nothing;
  perform _auditar('Resposta a avaliação do iFood', left(v_texto, 100));
  return jsonb_build_object('ok', true, 'message', 'Enviando ao iFood. A resposta só vale depois que o iFood a validar (alguns minutos); se ele recusar, você será avisado.') || api_ifood_avaliacoes('{}');
end $function$;

-- tela Feedbacks: o aviso de tamanho agora diz claramente que NÃO foi para o iFood
create or replace function public.api_responder_feedback(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := _uuid(p->>'id'); v_txt text := left(btrim(coalesce(p->>'resposta', '')), 1000); v_nome text; v_user uuid; v_av text; v_ifood text := null; v_ast text; v_prazo timestamptz; v_ares text;
begin
  if not tem_nivel('Admin','Operador') then return _negado(); end if;
  if v_txt = '' then return _falha('Escreva a resposta.'); end if;
  select id, status, prazo_em, resposta_estado into v_av, v_ast, v_prazo, v_ares from ifood_avaliacoes where feedback_id = v_id;
  -- avaliação do iFood: se o iFood não vai aceitar, a tela avisa ANTES de gravar como respondido
  if v_av is not null and tem_nivel('Admin') and _integracao_ligada('ifood') and (length(v_txt) < 10 or length(v_txt) > 300) then
    return jsonb_build_object('ok', false, 'message', 'Esta avaliação veio do iFood: a resposta precisa ter de 10 a 300 letras (tem ' || length(v_txt) || '). Ajuste o texto; nada foi enviado.');
  end if;
  if v_av is not null and tem_nivel('Admin') and _integracao_ligada('ifood') and coalesce(v_ast, 'NOT_REPLIED') <> 'NOT_REPLIED' then
    return jsonb_build_object('ok', false, 'message', 'O iFood não aceita mais resposta a esta avaliação (status ' || v_ast || ').');
  end if;
  select nome into v_nome from usuarios where id = auth.uid();
  update feedbacks set resposta = v_txt, respondido_em = now(), respondido_por = coalesce(v_nome, ''), status = 'Respondido'
   where id = v_id returning user_id into v_user;
  if not found then return _falha('Feedback não encontrado.'); end if;
  if v_av is not null then
    if not tem_nivel('Admin') then v_ifood := 'so_admin';
    elsif not _integracao_ligada('ifood') then v_ifood := 'desligado';
    elsif v_prazo is not null and v_prazo < now() then v_ifood := 'prazo';
    elsif v_ares = 'enviando' then v_ifood := 'aguardando';
    else
      update ifood_avaliacoes set resposta = v_txt, respondida_em = now(), resposta_estado = 'enviando', resposta_erro = null, resposta_enviada_em = now() where id = v_av;
      insert into ifood_acoes (pedido_ifood, acao, dados) values ('LOJA', 'avaliacao_responder', jsonb_build_object('avaliacao', v_av, 'texto', v_txt, 'chave', gen_random_uuid()::text)) on conflict do nothing;
      v_ifood := 'enviada';
    end if;
  end if;
  perform _auditar('Feedback respondido', 'Resposta enviada' || case when v_user is null then ' (cliente sem conta)' else '' end || case when v_ifood = 'enviada' then ' · enviada ao iFood' else '' end);
  return jsonb_build_object('ok', true, 'comConta', v_user is not null, 'ifood', v_ifood);
end $function$;
