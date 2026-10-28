-- 79 · Endereço do cliente se preenche sozinho com o endereço de entrega mais usado (a partir da 1ª entrega; com várias, o mais repetido).
-- Só preenche quando o campo está vazio; nunca troca um endereço digitado. As entregas são ligadas ao cliente pelo id (iFood) ou pelo telefone (sistema).
create or replace function public._cliente_endereco_auto(p_cliente uuid) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare v_tel text;
begin
  if p_cliente is null then return; end if;
  select nullif(regexp_replace(coalesce(telefone, ''), '\D', '', 'g'), '') into v_tel from clientes where id = p_cliente;
  with g as (
    select (array_agg(endereco order by data_hora desc))[1] e, count(*) n, max(data_hora) ult
      from (select v.endereco, v.data_hora, coalesce(public._end_chave(v.endereco), public._ifood_norm(v.endereco)) k
              from vendas v where (v.cliente_id = p_cliente or (v_tel is not null and regexp_replace(coalesce(v.telefone_cliente, ''), '\D', '', 'g') = v_tel))
               and v.tipo = 'Entrega' and v.status = 'Confirmada' and nullif(btrim(v.endereco), '') is not null) q
     group by k having count(*) >= 1 order by count(*) desc, max(data_hora) desc limit 1)
  update clientes c set endereco = left(g.e, 300) from g where c.id = p_cliente and nullif(btrim(c.endereco), '') is null;
end $f$;
revoke all on function public._cliente_endereco_auto(uuid) from public, anon, authenticated;
grant execute on function public._cliente_endereco_auto(uuid) to service_role;

create or replace function public._vendas_endereco_cliente() returns trigger
 language plpgsql security definer set search_path to 'public' as $f$
declare v_id uuid; v_tel text := nullif(regexp_replace(coalesce(new.telefone_cliente, ''), '\D', '', 'g'), '');
begin
  if new.tipo = 'Entrega' and new.status = 'Confirmada' then
    if new.cliente_id is not null then perform public._cliente_endereco_auto(new.cliente_id); end if;
    if v_tel is not null then
      for v_id in select id from clientes where regexp_replace(coalesce(telefone, ''), '\D', '', 'g') = v_tel and id is distinct from new.cliente_id loop
        perform public._cliente_endereco_auto(v_id);
      end loop;
    end if;
  end if;
  return new;
exception when others then
  begin perform public.ifood_aviso_registrar(null, 'cliente', 'Não consegui preencher o endereço do cliente automaticamente', left(sqlerrm, 300), '{}'::jsonb); exception when others then null; end;
  return new;
end $f$;
revoke all on function public._vendas_endereco_cliente() from public, anon, authenticated;
grant execute on function public._vendas_endereco_cliente() to service_role;
drop trigger if exists vendas_endereco_cliente on public.vendas;
create trigger vendas_endereco_cliente after insert or update of status, endereco, cliente_id on public.vendas
  for each row when (pg_trigger_depth() < 2) execute function public._vendas_endereco_cliente();

-- clientes antigos com endereço vazio
select public._cliente_endereco_auto(c.id) from clientes c where nullif(btrim(c.endereco), '') is null and c.unido_com is null;
