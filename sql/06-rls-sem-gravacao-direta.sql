-- Fase 7 (F2-2): a equipe só grava vendas, itens, pagamentos, sangrias, despesas, clientes e status de mesa pelas funções do sistema
-- (que calculam preço, conferem caixa e registram auditoria). As políticas de gravação direta ficam fechadas (false).
-- Sem DROP: as políticas continuam existindo; para voltar, ver o arquivo DESFAZER.
alter policy vendas_criar on public.vendas with check (false);
alter policy vendas_alterar on public.vendas using (false) with check (false);
alter policy itens_venda_criar on public.itens_venda with check (false);
alter policy itens_venda_alterar on public.itens_venda using (false) with check (false);
alter policy pagamentos_venda_criar on public.pagamentos_venda with check (false);
alter policy pagamentos_venda_alterar on public.pagamentos_venda using (false) with check (false);
alter policy sangrias_criar on public.sangrias with check (false);
alter policy despesas_criar on public.despesas with check (false);
alter policy despesas_alterar on public.despesas using (false) with check (false);
alter policy clientes_criar on public.clientes with check (false);
alter policy clientes_alterar on public.clientes using (false) with check (false);
alter policy clientes_excluir on public.clientes using (false);
alter policy mesas_status on public.mesas using (false) with check (false);
