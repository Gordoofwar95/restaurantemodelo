-- 83 — Endereço automático do cliente também quando o CLIENTE é criado depois do pedido (ex.: cardápio digital).
create or replace function public._clientes_endereco_auto()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  perform public._cliente_endereco_auto(new.id);
  return new;
exception when others then
  begin perform public.ifood_aviso_registrar(null, 'cliente', 'Não consegui preencher o endereço do cliente automaticamente', left(sqlerrm, 300), '{}'::jsonb); exception when others then null; end;
  return new;
end $$;
revoke all on function public._clientes_endereco_auto() from public, anon, authenticated;
grant execute on function public._clientes_endereco_auto() to service_role;
create or replace trigger clientes_endereco_auto after insert or update of telefone on public.clientes
  for each row when (nullif(btrim(coalesce(new.endereco, '')), '') is null and pg_trigger_depth() < 2) execute function public._clientes_endereco_auto();
-- preenche quem já estava sem endereço:
select public._cliente_endereco_auto(id) from public.clientes where nullif(btrim(coalesce(endereco,'')),'') is null and unido_com is null;
