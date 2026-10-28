-- 63 · iFood: estado da loja e acesso, revisados pela documentação OFICIAL dos módulos Merchant e Authentication (PDFs do portal, 25/10/2026).
-- Versão 1.15. Pode rodar de novo sem erro.
-- 1) Estado da loja: o iFood devolve um estado por operação (DELIVERY, TAKEOUT…) com uma lista de validações.
--    Antes o motivo mostrado era o da 1ª validação (quase sempre "Conectado", que está OK). Agora mostra a validação com
--    problema, em português e com o que fazer; CLOSED (fora do horário) não é tratado como erro; ERROR que dura mais de
--    2 minutos avisa no celular (uma vez, até voltar ao normal); guarda se a loja pode ser reaberta (reopenable).
-- 2) Acesso recusado (401/403): o iFood pede para NÃO repetir sem parar. Agora, depois de uma recusa, o sistema espera
--    5 minutos antes de tentar de novo (ou tenta logo se alguém salvar Client ID / Client Secret / Merchant ID novos).

alter table public.ifood_loja add column if not exists erro_desde timestamptz;
alter table public.ifood_loja add column if not exists erro_avisado boolean not null default false;
alter table public.ifood_loja add column if not exists reabrir_pode boolean;
alter table public.ifood_loja add column if not exists problemas jsonb;

create or replace function public._ifood_validacao_txt(p_code text) returns text language sql immutable as $f$
  select case lower(coalesce(p_code, ''))
    when 'is-connected' then 'Sem conexão com o sistema: o iFood não recebeu a consulta dos últimos 30 s (o sistema consulta sozinho; confira se o iFood está ligado aqui).'
    when 'opening-hours' then 'Fora do horário de funcionamento cadastrado no iFood.'
    when 'unavailabilities' then 'Loja em PAUSA no iFood. Toque em "Retomar" (só remove as pausas feitas pelo sistema; as feitas no Portal do Parceiro saem por lá).'
    when 'radius-restriction' then 'Sem entregadores na área de entrega. Aumente a área no Portal do Parceiro ou aguarde.'
    when 'payout-blocked' then 'Pendência financeira com o iFood. Resolva no Portal do Parceiro → Financeiro.'
    when 'terms-service-violation' then 'Bloqueio por violação dos termos do iFood. Abra um chamado no Portal do Parceiro.'
    when 'logistics-blocked' then 'Problema logístico do iFood (externo). Aguarde a resolução.'
    when 'catalog-enabled' then 'Cardápio desabilitado no iFood. Ative um cardápio no Portal do Parceiro.'
    when 'delivery-area' then 'Sem área de entrega configurada. Configure no Portal do Parceiro.'
    else null end
$f$;

create or replace function public.ifood_loja_gravar(p_status jsonb, p_interrupcao text default null) returns void
 language plpgsql security definer set search_path to 'public' as $function$
declare v_lista jsonb; v_op jsonb; v_disp boolean; v_sit text; v_motivo text; v_prob jsonb; v_reab boolean; l ifood_loja%rowtype;
begin
  v_lista := case when jsonb_typeof(p_status) = 'array' then p_status when p_status is null then '[]'::jsonb else jsonb_build_array(p_status) end;
  -- a operação que importa: DELIVERY (entrega); se não houver, a primeira
  select x into v_op from jsonb_array_elements(v_lista) x order by (upper(coalesce(x->>'operation', '')) = 'DELIVERY') desc limit 1;
  v_op := coalesce(v_op, '{}'::jsonb);
  v_sit := upper(coalesce(v_op->>'state', v_op->>'status', ''));
  v_disp := coalesce((v_op->>'available')::boolean, v_sit in ('OK', 'AVAILABLE', 'OPEN'));
  -- validações com problema (WARNING / ERROR), com o texto do iFood e o nosso "o que fazer"
  select coalesce(jsonb_agg(jsonb_build_object('codigo', v->>'code', 'estado', v->>'state',
           'titulo', coalesce(v->'message'->>'title', v->>'message'), 'descricao', v->'message'->>'description',
           'oQueFazer', _ifood_validacao_txt(v->>'code'))), '[]'::jsonb)
    into v_prob
    from jsonb_array_elements(case when jsonb_typeof(v_op->'validations') = 'array' then v_op->'validations' else '[]'::jsonb end) v
   where upper(coalesce(v->>'state', 'OK')) not in ('OK', 'CLOSED');
  v_motivo := coalesce(
     (select string_agg(coalesce(p->>'oQueFazer', coalesce(p->>'titulo', p->>'codigo') || coalesce(': ' || (p->>'descricao'), '')), ' · ') from jsonb_array_elements(v_prob) p),
     case when v_sit = 'CLOSED' then 'Fechada no iFood: fora do horário de funcionamento (é o esperado).' end,
     nullif(coalesce(v_op->'message'->>'title', '') || coalesce(' — ' || (v_op->'message'->>'subtitle'), ''), ''),
     case when jsonb_typeof(v_op->'message') = 'string' then v_op->>'message' end, '');
  v_reab := case when v_op ? 'reopenable' then coalesce((v_op->'reopenable'->>'reopenable')::boolean, (v_op->>'reopenable')::boolean) end;
  if v_reab = false and v_sit = 'ERROR' then
    v_motivo := v_motivo || ' · A loja está sob penalidade automática do iFood (não dá para reabrir agora): veja a mensagem acima.';
  end if;
  select * into l from ifood_loja where id;
  update ifood_loja set situacao = left(v_sit, 60), disponivel = v_disp, motivo = left(v_motivo, 600), problemas = v_prob, reabrir_pode = v_reab,
    interrupcao_id = coalesce(p_interrupcao, interrupcao_id), verificado_em = now(), bruto = p_status, atualizado_em = now(),
    erro_desde = case when v_sit = 'ERROR' then coalesce(l.erro_desde, now()) else null end,
    erro_avisado = case when v_sit = 'ERROR' then l.erro_avisado else false end
   where id;
  if v_sit = 'ERROR' and l.erro_desde is null then
    perform _integ_log('ifood', 'aviso', 'Loja no iFood em ERRO: ' || left(v_motivo, 250));
  elsif v_sit = 'ERROR' and not l.erro_avisado and l.erro_desde < now() - interval '2 minutes' then
    update ifood_loja set erro_avisado = true where id;
    begin perform _push_admins('iFood: loja sem receber pedidos', left(v_motivo, 180), 'ifood-loja');
    exception when others then null; end;
  elsif v_sit <> 'ERROR' and l.erro_desde is not null then
    perform _integ_log('ifood', 'info', 'Loja no iFood voltou ao normal (' || coalesce(nullif(v_sit, ''), '?') || ').');
  end if;
end $function$;
revoke all on function public.ifood_loja_gravar(jsonb, text) from public, anon, authenticated;
grant execute on function public.ifood_loja_gravar(jsonb, text) to service_role;

-- 401/403: espera 5 min entre tentativas (o iFood pede para não repetir sem parar). Credencial nova salva = tenta já.
create or replace function public.ifood_pode_consultar() returns boolean
 language sql stable security definer set search_path to 'public' as $f$
  select not (coalesce(e.token_ok, true) = false
              and e.ultimo_erro_em > now() - interval '5 minutes'
              and coalesce((select max(atualizado_em) from integracoes_segredos where chave in ('ifood_client_id', 'ifood_client_secret', 'ifood_merchant_id')), '-infinity') < e.ultimo_erro_em)
  from ifood_estado e where e.id
$f$;
revoke all on function public.ifood_pode_consultar() from public, anon, authenticated;
grant execute on function public.ifood_pode_consultar() to service_role;
