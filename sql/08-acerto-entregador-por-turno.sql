-- Acerto do entregador por TURNO DO CAIXA: a "data" do acerto (dataRef) é o dia em que o caixa abriu (horário de São Paulo).
-- Entrega concluída dentro de um caixa entra no acerto do dia da abertura desse caixa; sem caixa que a contenha, vale o dia do calendário (como antes).
create or replace function public._calc_fechamento_entrega(p_login text, p_data date, OUT qtd integer, OUT total_taxas numeric, OUT ajuda numeric, OUT total numeric, OUT ids uuid[])
 returns record language plpgsql security definer set search_path to 'public' as $$
declare uid uuid; ja boolean; aj numeric;
begin
  select id into uid from usuarios where lower(login) = lower(p_login) and nivel::text = 'Entregador';
  select count(*)::int, coalesce(round(sum(v.taxa_entrega), 2), 0), coalesce(array_agg(v.id), '{}'::uuid[]) into qtd, total_taxas, ids
    from vendas v where v.status = 'Confirmada' and v.tipo = 'Entrega' and v.status_pedido::text = 'Entregue' and v.entregador_id = uid
     and v.fechamento_entrega_id is null
     and coalesce(
           (select (s.abertura at time zone 'America/Sao_Paulo')::date from caixa_sessoes s
             where v.concluida_em >= s.abertura and (s.fechamento is null or v.concluida_em <= s.fechamento)
             order by s.abertura desc limit 1),
           (v.concluida_em at time zone 'America/Sao_Paulo')::date) = p_data;
  select exists (select 1 from fechamentos_entrega where entregador_id = uid and data_ref = p_data) into ja;
  select coalesce(_num(valor #>> '{}'), 0) into aj from sistema where chave = 'AjudaDiariaEntregador';
  ajuda := case when qtd > 0 and not ja then coalesce(aj, 0) else 0 end;
  total := round(total_taxas + ajuda, 2);
end $$;
