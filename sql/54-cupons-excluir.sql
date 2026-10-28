-- =====================================================================
-- 54 - Excluir cupom (P-05)
-- ---------------------------------------------------------------------
-- Admin → Cupons: botão Excluir (pede a senha).
-- - Cupom NUNCA usado: apagado de vez.
-- - Cupom já usado em pedido: ARQUIVADO (some da lista, da conta do
--   cliente e do cardápio; o histórico dos pedidos continua certo).
--   O código fica livre para um cupom novo. Dá para restaurar.
-- - Cupom que estiver no carrinho de alguém: na hora de enviar, o
--   cliente vê "Esse cupom não está mais disponível".
-- Tudo aditivo. Pode rodar mais de uma vez.
-- =====================================================================

alter table public.cupons add column if not exists excluido_em timestamptz;
alter table public.cupons add column if not exists excluido_por uuid;
alter table public.cupons add column if not exists codigo_original text;

create or replace function public.api_excluir_cupom(p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_err text; c cupons%rowtype; v_usos int; v_novo text;
begin
  if not tem_nivel('Admin') then return _negado(); end if;
  v_err := _senha_acao(p->>'senha'); if v_err <> '' then return _falha(v_err); end if;
  select * into c from cupons where id = _uuid(p->>'id') for update;
  if c.id is null then return _falha('Cupom não encontrado.'); end if;

  if coalesce((p->>'restaurar')::boolean, false) then
    if c.excluido_em is null then return _falha('Este cupom não está excluído.'); end if;
    v_novo := coalesce(c.codigo_original, c.codigo);
    if exists (select 1 from cupons where codigo = v_novo and id <> c.id) then
      return _falha('Já existe outro cupom com o código ' || v_novo || '. Mude o código dele antes de restaurar este.');
    end if;
    update cupons set excluido_em = null, excluido_por = null, codigo = v_novo, codigo_original = null where id = c.id;
    perform _auditar('Cupom restaurado (continua desativado)', v_novo);
    return jsonb_build_object('ok', true, 'message', 'Cupom ' || v_novo || ' restaurado. Ele volta DESATIVADO: ative quando quiser.');
  end if;

  if c.excluido_em is not null then return _falha('Este cupom já foi excluído.'); end if;
  if c.automatico is not null then return _falha('Cupom automático (boas-vindas, aniversário, indicação) não se exclui: use Desligar.'); end if;
  select count(*) into v_usos from cupons_usos where cupom_id = c.id and not coalesce(anulado, false);
  select v_usos + count(*) into v_usos from cupons_concedidos where cupom_id = c.id and usado_em is not null;

  if v_usos = 0 then
    delete from cupons where id = c.id;          -- cupons_usos (anulados) e concedidos não usados saem juntos (cascade)
    perform _auditar('Cupom excluído (nunca usado)', c.codigo);
    return jsonb_build_object('ok', true, 'apagado', true, 'message', 'Cupom ' || c.codigo || ' excluído de vez (nunca tinha sido usado).');
  end if;

  v_novo := left(c.codigo, 28) || '-EXC' || to_char(now() at time zone 'America/Sao_Paulo', 'YYMMDDHH24MI');
  update cupons set excluido_em = now(), excluido_por = auth.uid(), ativa = false, visivel_conta = false,
                    codigo_original = c.codigo, codigo = v_novo where id = c.id;
  delete from cupons_concedidos where cupom_id = c.id and usado_em is null;   -- sai da conta dos clientes
  perform _auditar('Cupom excluído (arquivado: já usado em ' || v_usos || ' pedido(s))', c.codigo);
  return jsonb_build_object('ok', true, 'arquivado', true, 'message',
    'Cupom ' || c.codigo || ' excluído. Como já foi usado em ' || v_usos || ' pedido(s), ele foi ARQUIVADO: some da lista, da conta dos clientes e do cardápio, e os pedidos antigos continuam certos. O código ' || c.codigo || ' fica livre para um cupom novo.');
end $function$;
revoke all on function public.api_excluir_cupom(jsonb) from public, anon;
grant execute on function public.api_excluir_cupom(jsonb) to authenticated, service_role;

-- ativar/desativar não mexe em cupom excluído
do $$
declare d text;
begin
  d := pg_get_functiondef('public.api_alternar_cupom(jsonb)'::regprocedure);
  if position('excluido_em is null' in d) = 0 then
    if position('update cupons set ativa = v_on where id = _uuid(p->>''id'') returning codigo into v_cod;' in d) = 0 then raise exception '54: ponto de troca não encontrado em api_alternar_cupom'; end if;
    d := replace(d, 'update cupons set ativa = v_on where id = _uuid(p->>''id'') returning codigo into v_cod;',
                    'update cupons set ativa = v_on where id = _uuid(p->>''id'') and excluido_em is null returning codigo into v_cod;');
    execute d;
  end if;
end $$;

-- mensagem clara para quem estava com o cupom excluído no carrinho (o código antigo não existe mais)
do $$
declare d text;
begin
  d := pg_get_functiondef('public.api_validar_cupom_cardapio(jsonb)'::regprocedure);
  if position('não está mais disponível' in d) = 0 and position(E'  return v_r;\nend' in d) > 0 then
    d := replace(d, E'  return v_r;\nend', E'  if coalesce(v_r->>''ok'', '''') <> ''true'' and exists (select 1 from cupons where excluido_em is not null\n       and codigo_original = upper(regexp_replace(btrim(coalesce(p->>''codigo'', '''')), ''\\s+'', '''', ''g''))) then\n    v_r := jsonb_build_object(''ok'', false, ''message'', ''Esse cupom não está mais disponível.'');\n  end if;\n  return v_r;\nend');
    execute d;
  end if;
end $$;
