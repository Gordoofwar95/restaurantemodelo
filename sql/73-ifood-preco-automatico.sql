-- 73 · Preço do iFood sincroniza sozinho: ao salvar o preço da forma "iFood" de um produto/combo ligado a um item do iFood,
-- o sistema envia o novo preço ao iFood (usa a trava de variação e o histórico que já existiam). Idempotente.
-- Acima do limite de variação NÃO envia: cria um aviso na tela do iFood. Só funciona com o iFood ligado e "enviarPrecos" ligado.
create or replace function public._ifood_preco_auto() returns trigger
 language plpgsql security definer set search_path to 'public' as $f$
declare r ifood_itens%rowtype; v_lim numeric; v_pct numeric; v_id bigint; v_ped bigint; v_prod uuid := nullif(to_jsonb(NEW)->>'produto_id', '')::uuid; v_combo uuid := nullif(to_jsonb(NEW)->>'combo_id', '')::uuid;
begin
  if NEW.forma_pagamento_id is distinct from public._ifood_forma() or NEW.preco is null or NEW.preco <= 0 then return NEW; end if;
  if tg_op = 'UPDATE' and OLD.preco is not distinct from NEW.preco then return NEW; end if;
  if not public._integracao_ligada('ifood') then return NEW; end if;
  if not coalesce((select (config->>'enviarPrecos')::boolean from integracoes_config where provedor = 'ifood'), false) then return NEW; end if;
  v_lim := coalesce((select (config->>'limitePrecoPct')::numeric from integracoes_config where provedor = 'ifood'), 30);
  for r in select * from ifood_itens where ifood_item_id is not null
           and ((v_prod is not null and produto_id = v_prod) or (v_combo is not null and combo_id = v_combo)) loop
    if r.preco_ifood is not null and r.preco_ifood > 0 and abs(r.preco_ifood - NEW.preco) < 0.005 then continue; end if;
    v_pct := case when coalesce(r.preco_ifood, 0) > 0 then abs(NEW.preco - r.preco_ifood) / r.preco_ifood * 100 else 0 end;
    if v_pct > v_lim then
      perform public.ifood_aviso_registrar(null, 'preco', 'Preço NÃO enviado ao iFood: ' || left(r.nome, 80),
        'O novo preço (R$ ' || to_char(NEW.preco, 'FM999990.00') || ') varia ' || round(v_pct) || '% em relação ao do iFood (R$ ' || to_char(r.preco_ifood, 'FM999990.00') || '), acima do limite de ' || v_lim || '%. Confira e envie manualmente em Preços do iFood.', jsonb_build_object('chave', r.chave));
      continue;
    end if;
    -- um envio pendente do mesmo item é atualizado em vez de duplicado
    select id into v_ped from ifood_acoes where acao = 'catalogo_preco' and estado = 'pendente' and dados->>'chave' = r.chave limit 1;
    insert into ifood_precos_hist (chave, nome, preco_antes, preco_depois, origem, usuario) values (r.chave, r.nome, r.preco_ifood, NEW.preco, 'enviar', 'automático') returning id into v_id;
    if v_ped is not null then
      update ifood_acoes set dados = jsonb_build_object('chave', r.chave, 'itemId', r.ifood_item_id, 'preco', NEW.preco, 'hist', v_id) where id = v_ped;
    else
      insert into ifood_acoes (pedido_ifood, acao, dados) values ('LOJA', 'catalogo_preco', jsonb_build_object('chave', r.chave, 'itemId', r.ifood_item_id, 'preco', NEW.preco, 'hist', v_id)) on conflict do nothing;
    end if;
  end loop;
  return NEW;
exception when others then
  -- nunca atrapalha o salvamento do preço; o motivo fica visível para a equipe
  begin perform public.ifood_aviso_registrar(null, 'preco', 'Falha ao enviar preço ao iFood', left(sqlerrm, 300), '{}'::jsonb); exception when others then null; end;
  return NEW;
end $f$;
revoke all on function public._ifood_preco_auto() from public, anon, authenticated;
grant execute on function public._ifood_preco_auto() to service_role;

drop trigger if exists ifood_preco_auto_p on public.produto_precos;
create trigger ifood_preco_auto_p after insert or update of preco on public.produto_precos for each row execute function public._ifood_preco_auto();
drop trigger if exists ifood_preco_auto_c on public.combo_precos;
create trigger ifood_preco_auto_c after insert or update of preco on public.combo_precos for each row execute function public._ifood_preco_auto();

update public.integracoes_config set config = coalesce(config, '{}'::jsonb) || '{"enviarPrecos": true}'::jsonb where provedor = 'ifood';
