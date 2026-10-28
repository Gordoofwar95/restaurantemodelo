-- 12 - Assistente: 2 verbetes novos (cadastro de produto: aviso de "falta para ficar completo", sugestão de preço e Duplicar; e prints da Ajuda). Pode rodar de novo.
-- Desfazer: delete from public.ai_ajuda where slug in ('man-admin-123-produto-duplicar-sugestao','man-admin-124-ajuda-com-prints');
insert into public.ai_ajuda (slug,titulo,palavras_chave,passos,perfis,ativo,grupo,ordem,comuns) values
($t$man-admin-123-produto-duplicar-sugestao$t$,$t$Produto: duplicar, "falta para ficar completo" e sugestão de preço$t$,$t$duplicar produto copiar produto parecido novo produto completo falta preço sugerido sugestão preço margem lucro 40% usar custo receita ficha técnica$t$,
$t$Administrador → Produtos. Para criar um produto parecido com outro, toque em ⋯ (três pontos) na linha do produto → "📄 Duplicar". Abre o formulário já preenchido, com a receita copiada; nada é salvo até você tocar em "Cadastrar".
No formulário (novo ou edição) aparece o aviso "Falta para ficar completo" listando o que ainda não foi preenchido (custo, receita, categoria…). É só um lembrete: você pode salvar mesmo assim.
Se a margem de lucro estiver abaixo de 40%, aparece a "Sugestão de preço" (para ~50% de lucro) com o botão "Usar", que preenche o preço. Você decide se usa ou não; o preço nunca muda sozinho.$t$,
ARRAY['Admin'],true,'secao',123,$t$$t$),
($t$man-admin-124-ajuda-com-prints$t$,$t$Ajuda com prints (onde clicar) e busca$t$,$t$ajuda prints imagens fotos onde clicar buscar busca pesquisar ajuda tutorial passo a passo celular pc$t$,
$t$Toque em ❓ (Ajuda). No campo de busca digite uma palavra (ex.: caixa, entrega, cupom): só aparecem os assuntos que têm esse texto e o primeiro já abre.
Vários assuntos (abrir e fechar caixa, clientes, produtos, mesas, alertas…) trazem prints reais da tela, com números vermelhos que correspondem aos passos. No celular aparece o print do celular; no computador, o do PC.
O cliente tem a própria Ajuda ("Como pedir / Ajuda", no rodapé do cardápio), também com prints do cardápio, do item e do carrinho.$t$,
ARRAY['Admin','Operador','Garçom','Cozinha','Entregador'],true,'secao',124,$t$$t$)
on conflict (slug) do update set titulo=excluded.titulo, palavras_chave=excluded.palavras_chave, passos=excluded.passos, perfis=excluded.perfis, ativo=excluded.ativo, grupo=excluded.grupo, ordem=excluded.ordem, comuns=excluded.comuns, atualizado_em=now();
