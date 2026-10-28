-- =====================================================================
-- RESTAURANTE DEMO · 02-dados.sql
-- Dados iniciais NEUTROS: configurações, formas de pagamento, ajuda do assistente, cardápio de exemplo (fictício)
-- e os logins de teste. Rode DEPOIS do 01-estrutura.sql. Gatilhos e chaves estrangeiras ficam desligados durante a carga.
--
-- LOGIN INICIAL: Lucas (Desenvolvedor) — senha TROCAR-SENHA. Os demais usuários se criam pelo app, em Administrador › Usuários.
-- =====================================================================
set session_replication_role = replica;

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET row_security = off;

INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, last_sign_in_at, phone, is_anonymous, banned_until, deleted_at, is_sso_user) VALUES
	('00000000-0000-0000-0000-000000000000', '2fd45365-06f4-5413-be1e-ba822b35e029', 'authenticated', 'authenticated', 'lucas@usuarios.demo.app', extensions.crypt('TROCAR-SENHA', extensions.gen_salt('bf')), now(), '{"provider": "email", "providers": ["email"]}', '{}', now(), now(), now(), NULL, false, NULL, NULL, false);

INSERT INTO auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at) VALUES
	('dd92df7e-7b3d-5fda-8c6d-12a6bcfc3f40', '2fd45365-06f4-5413-be1e-ba822b35e029', '2fd45365-06f4-5413-be1e-ba822b35e029', '{"sub": "2fd45365-06f4-5413-be1e-ba822b35e029", "email": "lucas@usuarios.demo.app", "email_verified": true, "phone_verified": false}', 'email', now(), now(), now());

INSERT INTO public.usuarios (id, login, nome, telefone, nivel, ativo, criado_em) VALUES
	('2fd45365-06f4-5413-be1e-ba822b35e029', 'Lucas', 'Lucas', NULL, 'Desenvolvedor', true, now());

INSERT INTO public.ai_ajuda (id, slug, titulo, palavras_chave, passos, perfis, ativo, atualizado_em, grupo, ordem, comuns) OVERRIDING SYSTEM VALUE VALUES
	(10, 'clientes-fidelidade', 'Cadastrar cliente e ver fidelidade', 'cliente cadastrar novo fidelidade cartão histórico indicação telefone', 'Clientes → “+ Novo cliente”: só nome e telefone são obrigatórios.
Toque no cliente para ver histórico, total gasto, indicação e cartão fidelidade.', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(11, 'internet-caiu', 'Internet caiu ou sistema fora do ar (contingência)', 'internet caiu sem conexão offline contingência plano b queda fora do ar', 'Venda no Caixa: se você já entrou neste aparelho, o sistema oferece guardar a venda na CONTINGÊNCIA (só retirada ou entrega, sem desconto, sem mesa). Ela entra no sistema sozinha quando o servidor voltar; estoque e total do caixa só atualizam depois.
Não confirme a venda de novo se ela já apareceu.
Fechar caixa, cancelar, pagar e lançar despesa exigem conexão e nunca ficam guardados: espere o 🟢 e refaça.
Se nem a contingência responder, anote a venda e lance depois.', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(12, 'caixa-fechado-erro', 'Aparece que o caixa está fechado', 'caixa fechado abra o caixa antes erro venda não registra', 'Venda, despesa, sangria e fechar conta de mesa exigem caixa aberto, e o Cardápio Digital para de receber pedidos.
Abra o caixa pela aba Caixa → “Abrir caixa”.', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(9, 'pedido-qr-mesa', 'Cliente pedindo pela mesa (QR Code)', 'qr code mesa cliente pedir celular chamar garçom pedir a conta aceitar', 'O cliente aponta a câmera para o QR da mesa, escolhe os itens e envia.
O pedido chega em Pedidos como “Recebido” (📱 Cliente). Toque em ✅ Aceitar para ir ao preparo, ou ❌ Rejeitar.
Se o cliente tocar em “Chamar garçom”, a mesa aparece em 🍽️ Mesas com 🔔; toque em ✔ Atendido quando for lá.
Se tocar em “Pedir a conta”, a mesa vira “Pediu a conta” e você fecha como sempre.
O pedido de mesa feito pelo cliente nunca vai ao preparo sem o aceite.', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(13, 'criar-usuario', 'Criar usuário, trocar senha ou editar acesso', 'usuário criar acesso login senha perfil garçom cozinha entregador operador desenvolvedor esqueci senha redefinir', 'Administrador → Sistema → Usuários e Permissões.
Em “Criar acesso”, preencha Login e Senha e escolha o perfil (Operador de caixa, Garçom, Cozinha, Entregador, Admin ou Desenvolvedor).
Digite “Sua senha de administrador” e toque em “Criar acesso”.
Para mudar nome, telefone, perfil, situação ou redefinir a senha de alguém, toque em “editar” na lista “Usuários cadastrados”. Tudo fica na Auditoria. No seu próprio acesso o perfil fica travado e a senha se troca em “🔑 Senha”.
Funcionário esqueceu a senha: só o Administrador troca. Entregador que não aparece na escolha: está inativo ou sem o perfil Entregador.', '{Admin}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(14, 'cadastrar-produto', 'Cadastrar produto e estoque', 'produto cadastrar cardápio preço custo margem estoque ingrediente ficha técnica categoria', 'Administrador → Catálogo → Produtos → “Cadastrar produto”.
Informe nome, categoria, preço e custo (a margem aparece sozinha). O preço vale para todas as formas de pagamento.
Só abra “⚙️ Opções avançadas” para preço diferente numa forma (ex.: iFood) ou para a ficha técnica (ingredientes).
Se o item tem estoque próprio (bebida, por exemplo), marque a opção e informe quantidade e mínimo.
Cada venda baixa o estoque pela ficha técnica. Ingrediente no mínimo gera aviso em Notificações, sem bloquear a venda.', '{Admin}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(15, 'qr-code-mesas', 'Imprimir ou renovar o QR Code das mesas', 'qr code mesas imprimir baixar png novo código', 'Administrador → Operação → Mesas e QR Codes → “📲 QR Codes das mesas”.
Escolha a mesa e toque em “🖨️ Imprimir esta mesa” (ou “Imprimir todas”). Também dá para “⬇️ Baixar PNG”.
Se alguém espalhar o QR, use “🔄 Gerar novo código” e imprima o QR novo daquela mesa.', '{Admin}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(16, 'cardapio-digital', 'Configurar o Cardápio Digital', 'cardápio digital cliente destaques ordem esgotado categorias observação', 'Administrador → Catálogo → Cardápio Digital: escolha o que aparece para o cliente, destaques, ordem e frase de abertura. “Mais Pedidos” é automático.
Item “Esgotado”: se “bloquear venda sem estoque” estiver ligado (Catálogo → Estoque), o cardápio mostra “Esgotado” no que o estoque não cobre mais.
O cliente pode escrever uma observação em cada item (ex.: “sem cebola”); ela aparece na comanda da cozinha.', '{Admin}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(17, 'entregadores-taxas', 'Taxa de entrega e fechamento de entregadores', 'entregador taxa ajuda diária fechamento pagar acerto entrega', 'Administrador → Operação → Entregadores e taxas.
Defina a taxa padrão e a ajuda diária e salve.
No fechamento, escolha entregador e data, confira o total (taxas + ajuda diária) e informe o valor pago.
Confirme. A diferença fica registrada e o período fechado não muda mais, mesmo que a taxa mude depois.
A ajuda diária conta uma vez por dia e só se houve entrega. Se a conexão cair ao fechar, confira o histórico antes de tentar de novo, para não fechar duas vezes.', '{Admin}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(18, 'ajustes-pos-venda', 'Ajuste pós-venda: reembolso, crédito, cortesia', 'ajuste pós-venda reembolso crédito cortesia desconto retroativo devolução', 'Administrador → Financeiro → Ajustes pós-venda.
Busque a venda (nº do pedido, nome ou telefone); só aparecem pedidos já entregues.
Escolha o tipo (Reembolso em dinheiro, Crédito para próxima compra, Cortesia ou Desconto retroativo), o valor e o motivo.
Em reembolso e desconto retroativo, escolha se o dinheiro sai do caixa (o caixa precisa estar aberto) ou fora dele (Pix, estorno no cartão).
Toque em “Registrar ajuste”. Para desfazer, use “cancelar” na lista, com o motivo.
A venda original não muda. Reembolso e desconto retroativo não passam do valor da venda.', '{Admin}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(19, 'financeiro-relatorios', 'Financeiro, relatórios e auditoria', 'financeiro contas a pagar despesas mensais dre relatório auditoria fluxo lucro histórico', 'Financeiro: contas a pagar, despesas mensais, previsto × pago, fluxo de 30 dias, metas. Formas de pagamento: Operação → Pagamentos. Histórico: resumo de hoje, vendas, despesas e sessões de caixa.
O DRE fica em Relatórios (com a linha “Ajustes pós-venda”). Só despesa paga entra no lucro.
Relatórios imprimem em A4, 80mm ou 58mm.
Auditoria: descontos, cancelamentos, preços, estoque, usuários, restaurações e acessos negados.', '{Admin}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(20, 'backup', 'Fazer backup e restaurar', 'backup restaurar copia drive armazenamento espaço automático', 'Administrador → Sistema → Backup → “Fazer backup agora”.
Ative o backup automático e escolha a frequência.
Para restaurar, escolha o backup no histórico e confirme com sua senha de administrador.
Confira o uso do Drive: até 70% normal, 70–90% atenção, acima de 90% crítico. Drive cheio pode fazer backups e fotos falharem.', '{Admin}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(84, 'err-entregador-04-esqueci-de-marcar-entregue', 'Esqueci de marcar "Entregue"', 'esqueci de marcar "entregue"', 'Avise o Caixa ou o Administrador: eles marcam manualmente pelo pedido.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'erro', 103, ''),
	(134, 'man-operador-11-modo-emergencia-planilha-fora-do-ar', 'Modo emergência (servidor fora do ar)', 'modo emergência (planilha fora do ar)', 'Só funciona no mesmo aparelho em que você já fez login normal nos últimos 30 dias.
Quando o sistema não conseguir falar com o servidor (Supabase), oferece "Entrar em MODO EMERGÊNCIA como [seu login]".
Dá para: registrar venda de retirada/entrega pela contingência.
Não dá para: abrir/fechar caixa, cancelar, receber pagamento, mexer em estoque, ver financeiro.
Quando o servidor voltar, o app avisa e pede login de novo.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'lista', 11, ''),
	(29, 'man-admin-08-cliente-cancelou-o-pedido-cardapio', 'Cliente cancelou o pedido (Cardápio)', 'cliente cancelou o pedido (cardápio) admin', 'Nos primeiros 3 minutos, e só enquanto o pedido está “aguardando aceite”, o cliente pode cancelar sozinho pelo acompanhamento do pedido. O estoque volta e o motivo fica como “Cancelado pelo cliente (cardápio, até 3 min)”.
Depois de aceito, ou passados os 3 minutos, o cliente precisa ligar. Cancelar ou editar passa a ser com o Caixa/Administrador.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 50, ''),
	(30, 'man-admin-09-pedidos-e-entregas', 'Pedidos e entregas', 'pedidos e entregas admin', 'Pedido do Cardápio chega como “novo — aguardando aceite”: toque em “✅ Aceitar” ou “❌ Rejeitar”.
Quando o pedido ficar “Pronta” (retirada ou entrega) ou “Saiu para entrega”, e o cliente tiver telefone, toque em “📲 Avisar cliente”: abre o WhatsApp com a mensagem pronta e você só envia. Depois aparece “✔ avisado às…”.
Avance com “Marcar como…”: Em preparo → Pronta → Retirada (Servida, se for mesa).
Em Entregas, escolha o entregador no campo “Entregador” do pedido; ele avança até “Entregue”.
“⏸ Suspender” pausa o pedido (toque num motivo pronto, como "Cliente não atende", ou escreva). Recusar pedido também tem motivos prontos e “▶️ Retomar pedido” volta.
Venda “A Receber” só entra no caixa quando você toca em “marcar como recebido”.
Com só um entregador ativo, toda entrega já fica no nome dele. Com mais de um, escolha no campo "Entregador".
Depois de imprimir a comanda, fica um botão "🔁 Não saiu? Reimprimir" por 10 minutos; não precisa confirmar quando saiu certo.', '{Admin}', false, '2026-10-11 16:31:19.325087+00', 'secao', 51, 'Só dá para editar os itens com o pedido “Em preparo”.
Entregador esqueceu de marcar: marque você mesmo pelo botão do pedido.
Sem aviso de pedido novo: no Início, toque em “🔔 Ativar avisos” e “🔊 Testar som”. O aviso só chega com o app aberto e a tela ligada.'),
	(31, 'man-admin-10-entregas-taxas-e-fechamento-de-entregado', 'Entregas: taxas e fechamento de entregadores', 'entregas: taxas e fechamento de entregadores admin', 'Administrador → Operação → Entregadores e taxas.
Defina a taxa padrão e a ajuda diária e salve.
No fechamento, escolha entregador e data, confira o total (taxas + ajuda diária) e informe o valor pago.
Confirme. A diferença fica registrada e o período fechado não muda mais, mesmo que a taxa mude depois.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'secao', 52, 'A ajuda diária conta uma vez por dia e só se houve entrega.
Se a conexão cair ao fechar, confira o histórico antes de tentar de novo, para não fechar duas vezes.'),
	(32, 'man-admin-11-ocorrencias-e-notificacoes', 'Ocorrências e notificações', 'ocorrências e notificações admin', 'Ocorrências: Administrador → Painel → Ocorrências → “Tratar” para acompanhar e resolver. As abertas também aparecem no mural Notificações, onde o Caixa e o Administrador também têm o botão “Tratar”.
Administrador → Avisos (config): ligue ou desligue cada aviso e escolha quais perfis o recebem (Administrador, Operador ou Cozinha).', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 11, ''),
	(33, 'man-admin-12-financeiro-relatorios-e-auditoria', 'Financeiro, relatórios e auditoria', 'financeiro, relatórios e auditoria admin', 'Financeiro: contas a pagar, despesas mensais, previsto × pago, fluxo de 30 dias, metas. As formas de pagamento ficam em Operação → Pagamentos. Histórico: resumo de hoje, vendas, despesas e sessões de caixa. O DRE fica em Relatórios (com a linha “Ajustes pós-venda”). Só despesa paga entra no lucro.
Relatórios imprimem em A4, 80mm ou 58mm. Visão Geral e Relatórios atualizam ao abrir.
Auditoria: descontos, cancelamentos, preços, estoque, usuários, restaurações e acessos negados.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 53, ''),
	(34, 'man-admin-13-ajustes-pos-venda-reembolso-credito-cort', 'Ajustes pós-venda (reembolso, crédito, cortesia)', 'ajustes pós-venda (reembolso, crédito, cortesia) admin', 'Administrador → Financeiro → Ajustes pós-venda.
Busque a venda (nº do pedido, nome ou telefone) — só aparecem pedidos já entregues.
Escolha o tipo (Reembolso em dinheiro, Crédito para próxima compra, Cortesia ou Desconto retroativo), o valor e o motivo. Se o motivo for “Outro”, descreva.
Em reembolso e desconto retroativo, escolha se o dinheiro sai do caixa (o caixa precisa estar aberto) ou fora dele (Pix, estorno no cartão).
Toque em “Registrar ajuste”. Para desfazer, use “cancelar” na lista, com o motivo.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'secao', 13, 'A venda original NÃO muda e continua como Confirmada. No DRE o ajuste aparece na linha “Ajustes pós-venda”, separado das despesas.
Crédito não reduz o resultado na hora: quando o cliente usar, aplique como desconto no Caixa. Ele aparece como aviso abaixo do DRE.
Reembolso e desconto retroativo não passam do valor da venda (somando os ajustes já feitos nela).
Devolução que saiu do caixa de um turno já fechado não pode ser cancelada pelo sistema.'),
	(35, 'man-admin-14-backup-e-armazenamento', 'Backup e armazenamento', 'backup e armazenamento admin', 'Administrador → Sistema → Backup → “Fazer backup agora”.
Ative o backup automático e escolha a frequência.
Para restaurar, escolha o backup no histórico e confirme com sua senha de administrador.
Confira o uso do Drive: até 70% normal, 70–90% atenção, acima de 90% crítico.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'secao', 14, 'Drive cheio: backups e fotos podem falhar. Libere espaço.
A conferência de integridade aponta duplicidades, estoque negativo, caixa esquecido aberto e vendas paradas na contingência.'),
	(36, 'man-admin-15-contingencia-plano-b', 'Contingência (plano B)', 'contingência (plano b) admin', 'Administrador → Sistema → Sincronização e contingência → cartão “Contingência”. 🟢 = acessível (mostra quando o espelho foi atualizado e quantas vendas estão pendentes); 🔴 = não respondeu.
Toque em “🔄 Sincronizar espelho agora” para copiar produtos, preços e clientes para a contingência.
Toque uma vez em “Ativar sincronização automática diária (3h)”. Com ela ligada, o espelho se atualiza todo dia de madrugada e o sistema confere a cada 30 minutos se há vendas pendentes para trazer.
Se o Supabase ficou fora do ar e houve vendas na contingência, toque em “⬇️ Trazer vendas pendentes da contingência” e confirme.
Backups: cada backup (manual ou automático) também é copiado para o Drive da conta da contingência. No histórico de backups, a coluna “Cópia” mostra ✅ quando deu certo e ⚠️ quando falhou (o backup local continua valendo).
Fotos: ao sincronizar o espelho, as fotos do cardápio também ganham cópia na conta da contingência. Se a mensagem disser “faltam N”, toque em sincronizar de novo ou aguarde a sincronização das 3h.
Espaço: o cartão mostra quanto da conta da contingência está usado. Acima de 90% aparece um alerta em Notificações → Sistema; libere espaço nessa conta.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'secao', 54, 'Depois de trocar as chaves da contingência, peça a todos para sair e entrar de novo: a chave interna é buscada no login.
Troque as chaves só com a fila vazia (sem vendas pendentes), senão elas podem ficar presas.
Garçom, Cozinha e Entregador não usam a fila da contingência.'),
	(21, 'contingencia-admin', 'Contingência: sincronizar e trazer vendas pendentes', 'contingência sincronizar espelho vendas pendentes chaves planilha fora do ar', 'Administrador → Sistema → Sincronização e contingência → cartão “Contingência”. 🟢 = acessível; 🔴 = não respondeu.
Toque em “🔄 Sincronizar espelho agora” para copiar produtos, preços e clientes para a contingência.
Toque uma vez em “Ativar sincronização automática diária (3h)”.
Se o Supabase ficou fora do ar e houve vendas na contingência, toque em “⬇️ Trazer vendas pendentes da contingência” e confirme.
Depois de trocar as chaves da contingência, peça a todos para sair e entrar de novo, e troque as chaves só com a fila vazia.', '{Admin}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(22, 'man-admin-01-entrar-sair-e-status', 'Entrar, sair e status', 'entrar, sair e status, “login ou senha incorretos”, “sua sessão expirou”, “muitas tentativas erradas”', 'Digite Login e Senha e toque em “Entrar”.
Olhe o status no topo: 🟢 Online = tudo certo · 🟡 Sincronizando = aguarde · 🔴 Sem conexão = veja “E se der errado?” · 🟠 Contingência = o servidor está lento ou fora do ar e o app usa a reserva. Toque na bolinha colorida do topo para ver o estado do Supabase, da planilha principal e da contingência.
Para sair, toque em “Sair” no topo. Para trocar a sua senha, toque em “🔑 Senha” (precisa da senha atual e de ao menos 8 caracteres).
Suas abas: Início, Caixa, Pedidos (com Retiradas, Entregas e Mesas), Clientes e Administrador. Os avisos ficam no botão ✨ Assistente, na aba 🔔 Avisos. Um ponto dourado numa aba avisa que há algo novo.', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'secao', 1, '“Login ou senha incorretos”: confira os dados. Se esqueceu a senha, só o Administrador pode redefinir.
“Sua sessão expirou”: entre de novo; o que você estava digitando pode se perder.
“Muitas tentativas erradas”: depois de 5 erros o login fica bloqueado por 10 minutos, contados a partir do primeiro erro. Espere e tente de novo, sem insistir.'),
	(23, 'man-admin-02-onde-fica-cada-coisa', 'Onde fica cada coisa', 'onde fica cada coisa', 'A aba Administrador tem uma barra dividida em 6 grupos: Hoje (Visão Geral, Ocorrências, Feedbacks); Dinheiro (Contas a pagar e despesas, Histórico, Reembolsos e ajustes, Previsto e metas, Relatórios e DRE); Produtos (Produtos, combos e adicionais, Estoque, Compras e fornecedores, Custos e precificação); Vendas e cardápio (Cardápio Digital, Formas de pagamento, Promoções e cupons, Eventos); Loja e equipe (Mesas e QR Codes, Entregadores e taxas, Usuários e permissões, Configurar avisos); Sistema (Integrações e contas, Backup e espaço, Sincronização e contingência, Auditoria).
Ao entrar, escolha a tela no menu. O campo "Ir para…" no topo do menu acha uma tela pelo nome (ex.: cupom, estoque, iFood).
Caixa, Pedidos, Entregas e Clientes funcionam como nos outros perfis, e você pode tudo.', '{Admin}', true, '2026-10-16 21:46:37.03337+00', 'lista', 2, ''),
	(24, 'man-admin-03-criar-usuario-e-trocar-senha', 'Criar usuário e trocar senha', 'criar usuário e trocar senha, entregador não aparece na escolha de ent, funcionário esqueceu a senha, você esqueceu a sua', 'Administrador → Loja e equipe → Usuários e permissões.
Em "Criar acesso", preencha Login e Senha e escolha o perfil (Operador, Garçom, Cozinha, Entregador, Admin ou Desenvolvedor).
Digite "Sua senha de administrador" e toque em "Criar acesso".
Perfil Desenvolvedor: você cria como qualquer outro, mas depois de criado fica travado — só o próprio Desenvolvedor edita ou troca a senha. Nem você nem ele excluem esse acesso.
Para mudar nome, telefone, perfil, situação ou redefinir a senha de alguém, toque em "editar" na lista "Usuários cadastrados". Mudar perfil, situação ou senha, e também ativar, desativar ou excluir, pede a SUA senha de administrador (conferida de verdade). No seu próprio acesso o perfil fica travado e a senha se troca em "🔑 Senha".', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'secao', 3, 'Entregador não aparece na escolha de entregas: usuário inativo ou sem o perfil Entregador.
Funcionário esqueceu a senha: só você troca — não existe "esqueci minha senha".
Você esqueceu a sua: rode redefinirSenhaAdminEmergencia no editor do Apps Script.'),
	(25, 'man-admin-04-cadastrar-produtos-e-estoque', 'Cadastrar produtos e estoque', 'cadastrar produto novo produto receita ficha técnica ingrediente custo margem preparado aqui comprado pronto sem controle bebida estoque próprio copiar receita criar ingrediente gramas kg litro ml preços em lote paguei cadastro incompleto combo custo automático', 'Administrador → Produtos → Produtos, combos e adicionais → "+ Novo produto". Preencha nome, categoria, preço de venda e, se quiser, foto e descrição.
Em "Como é feito?" escolha: 🍳 Preparado aqui (lanches, porções), 🥤 Comprado pronto (bebidas, sobremesa embalada) ou ✍️ Sem controle.
Preparado aqui: digite o ingrediente, toque nele e diga quanto vai em cada um (kg/litro pedem gramas/ml). Não existe? Toque em "+ criar" ali mesmo. Use "📋 Copiar receita de outro produto" e só ajuste. O custo aparece sozinho.
Comprado pronto: "Paguei R$ __ por __ unidades" (ex.: 30 por 12 = R$ 2,50 por lata), quanto tem agora e o mínimo. Cada venda baixa 1 do estoque.
Sem controle: digite o custo se souber.
Em "⚙️ Mais opções": preço próprio do iFood, adicionais, destaque e prêmio.
Ingredientes: Produtos → Estoque → "+ Novo ingrediente" (nome, como compra, "Paguei R$ __ por __") ou "💲 Preços em lote" para vários de uma vez.
Produto novo já vem com os adicionais que os outros produtos da mesma categoria têm ("Comprado pronto", como bebida, vem sem nenhum). Desmarque o que não vale.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'secao', 4, 'O custo dos produtos e combos se atualiza sozinho quando o preço de um ingrediente muda (edição, lote ou compra recebida); combo = soma dos produtos. Trocar kg↔g ou l↔ml converte as receitas; trocar "un"↔kg não converte e o sistema avisa quais receitas revisar. O Estoque tem as abas Ingredientes e Bebidas e itens prontos; bebidas não aparecem na receita. "Cadastro incompleto" mostra produtos sem custo e ingredientes sem preço. Cada venda baixa o estoque pela receita; ingrediente no mínimo gera aviso. Bebida e item comprado pronto não têm adicionais.'),
	(26, 'man-admin-05-qr-code-das-mesas', 'QR Code das mesas', 'qr code das mesas admin', 'Administrador → Operação → Mesas e QR Codes → "📲 QR Codes das mesas".
Escolha a mesa e toque em "🖨️ Imprimir esta mesa" (ou "Imprimir todas"). Também dá para "⬇️ Baixar PNG".
Plastifique e deixe na mesa. O cliente pede pelo celular e você aceita o pedido em Pedidos.
Se alguém espalhar o QR, use "🔄 Gerar novo código" e imprima o QR novo daquela mesa.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'secao', 5, 'O QR usa o endereço do site em que o sistema está publicado — se o endereço mudar, é preciso imprimir de novo.'),
	(27, 'man-admin-06-cardapio-digital-promocoes-e-eventos', 'Cardápio Digital, promoções e eventos', 'cardápio digital, promoções e eventos admin', 'Cardápio Digital: escolha o que aparece para o cliente, destaques, ordem e frase de abertura. "Mais Pedidos" é automático.
Se o cliente pedir mais de 1 lanche com adicionais, os adicionais valem para todos — o cardápio avisa.
O cliente pode escrever uma observação em cada item; ela aparece na comanda da cozinha e no pedido.
Item "Esgotado": se "bloquear venda sem estoque" estiver ligado (Catálogo → Estoque), o cardápio mostra "Esgotado" no que o estoque não cobre.
O cardápio abre rápido porque guarda cópia no aparelho do cliente. Mudanças suas aparecem em instantes.
O cardápio só recebe pedidos com o caixa aberto; fechado, aparece "Estamos fechados no momento".
Promoções: cupons. Eventos: custos e recebimentos por evento. Custos e Precificação: simulador de preço.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 6, ''),
	(28, 'man-admin-07-caixa-abrir-vender-e-fechar', 'Caixa: abrir, vender e fechar', 'caixa: abrir, vender e fechar admin', 'Aba Caixa → "Abrir caixa" e informe o fundo de troco.
Em "Iniciar venda": 1. Cliente → 2. Itens → 3. Pagamento → 4. Finalizar.
Depois escolha 58mm, 80mm ou A4 e toque em Imprimir, Copiar ou WhatsApp.
Para encerrar, feche o caixa, informe o dinheiro contado e confira a diferença.
Mesas: o botão "🍽️ Mesas" mostra todas as mesas e quem pediu a conta.
Pedido de mesa no Caixa: "Pagar ao sair" deixa na conta; "Pagar agora" cobra na hora.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'secao', 7, '"Abra o caixa antes de registrar uma venda".
"A soma dos pagamentos precisa bater com o total".
Desconto nunca pode zerar a venda; no Caixa pede a sua senha.'),
	(1, 'abrir-caixa', 'Abrir o caixa', 'abrir caixa fundo de troco iniciar turno caixa fechado', 'Aba Caixa → “Abrir caixa”.
Informe o fundo de troco e confirme.
Sem caixa aberto não há venda, despesa nem sangria, e o Cardápio Digital não recebe pedidos.
Se aparecer “Já existe um caixa aberto”, feche o anterior (conte o dinheiro) antes de abrir outro.', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(2, 'fazer-venda', 'Fazer uma venda no Caixa', 'venda vender balcão retirada entrega mesa pedido pagamento dividir pagar troco finalizar imprimir a receber repetir', 'Abra o caixa antes, se ainda não estiver aberto.
1. Cliente: busque por nome ou telefone, ou toque em “Venda sem cadastro”. Escolha Retirada, Entrega (endereço, complemento, referência) ou Mesa.
2. Itens: toque nos produtos; os adicionais abrem numa janela.
3. Pagamento: escolha a forma. Em dinheiro, informe o valor recebido e veja o troco. Para dividir, marque “Dividir pagamento”. “A Receber” deixa a venda pendente.
4. Finalizar: confira o total e finalize. Escolha 58mm, 80mm ou A4 e toque em Imprimir, Copiar ou WhatsApp.
“↺ Repetir última venda” recarrega o carrinho anterior.
Erros comuns: “Abra o caixa antes de registrar uma venda” (abra o caixa); “A soma dos pagamentos precisa bater com o total” (ajuste os valores). Desconto nunca pode zerar a venda; o Operador precisa da senha do administrador para dar desconto.', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(3, 'fechar-caixa', 'Fechar o caixa', 'fechar caixa fechamento dinheiro contado diferença encerrar turno sair', 'Aba Caixa → fechar caixa.
Informe o dinheiro contado.
Confira o total por forma de pagamento, despesas, sangrias e a diferença; copie ou envie por WhatsApp.
Ao tocar em “Sair” com o caixa aberto, o sistema pergunta se você quer mesmo sair.', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(4, 'cancelar-editar-venda', 'Cancelar ou editar uma venda', 'cancelar venda excluir editar errei valor item lançamentos duplicado pedido duplicado estoque', 'Caixa → “Lançamentos desde a abertura”.
Toque em “editar” ou “excluir” na venda.
Cancelar pede o motivo (e a senha do administrador para o Operador). Se o pedido já estava pronto, diga se a mercadoria foi perdida ou volta ao estoque.
Itens de pedido só mudam enquanto ele está “Em preparo”.
Pedido duplicado: duplo toque não duplica (o sistema avisa que já foi registrado). Se o cliente pediu duas vezes de verdade, exclua um com o motivo “Pedido duplicado”.', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(5, 'despesa-sangria', 'Lançar despesa ou sangria', 'despesa sangria retirada dinheiro caixa gasto', 'Caixa → “+ Despesa” ou “− Sangria”.
Informe valor e motivo e confirme.
Sangria é retirada de dinheiro do caixa e não conta como despesa. As duas exigem caixa aberto.', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(6, 'fechar-conta-mesa', 'Fechar a conta de uma mesa', 'mesa conta fechar conta receber garçom pediu a conta aguardando fechamento dividir pagamento', 'O caixa precisa estar aberto.
Toque em “🍽️ Mesas” (topo do Caixa ou tela Início). Quem pediu a conta aparece primeiro, em destaque.
Em cada mesa você vê garçom, tempo, pedidos e total. “Ver pedidos” mostra o detalhe.
Toque em “💳 Fechar conta”, confira o total e escolha a forma de pagamento. Para dividir, marque “Dividir em duas formas” e informe o valor da primeira.
Erros comuns: “Abra o caixa antes de fechar a conta da mesa”; “A soma dos pagamentos não bate com a conta” (refaça com o total exato).', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(7, 'pedidos-aceitar-entregas', 'Aceitar pedidos, avançar status e atribuir entregador', 'pedido aceitar rejeitar cardápio status em preparo pronta entrega entregador avisar cliente whatsapp suspender retomar a receber recebido', 'Pedido do Cardápio chega como “novo — aguardando aceite”: toque em “✅ Aceitar” ou “❌ Rejeitar”.
Avance com “Marcar como…”: Em preparo → Pronta → Retirada (Servida, se for mesa).
Quando ficar “Pronta” ou “Saiu para entrega” e o cliente tiver telefone, toque em “📲 Avisar cliente” (abre o WhatsApp com a mensagem pronta).
Em Entregas, escolha o entregador no campo “Entregador” do pedido.
“⏸ Suspender” pausa o pedido (toque num motivo pronto, como "Cliente não atende", ou escreva). Recusar pedido também tem motivos prontos e “▶️ Retomar pedido” volta.
Venda “A Receber” só entra no caixa quando você toca em “marcar como recebido”.
Só dá para editar os itens com o pedido “Em preparo”. Se o entregador esqueceu de marcar, marque você pelo botão do pedido.
Com só um entregador ativo, toda entrega já fica no nome dele. Com mais de um, escolha no campo "Entregador".', '{Admin,Operador}', false, '2026-10-11 16:31:19.325087+00', 'secao', 0, ''),
	(8, 'cliente-cancelou-cardapio', 'Cliente cancelou o pedido feito pelo Cardápio', 'cliente cancelar pedido cardapio 3 minutos aguardando aceite', 'Nos primeiros 3 minutos, e só enquanto o pedido está “aguardando aceite”, o cliente cancela sozinho pelo acompanhamento do pedido. O estoque volta.
Depois de aceito, ou passados os 3 minutos, o cliente precisa ligar, e cancelar ou editar passa a ser com o Caixa/Administrador.', '{Admin,Operador}', false, '2026-10-07 23:36:19.985882+00', 'secao', 0, ''),
	(48, 'man-operador-08-editar-ou-cancelar-uma-venda', 'Editar ou cancelar uma venda', 'editar ou cancelar uma venda', 'Caixa → "Lançamentos desde a abertura".
Toque em "editar" ou "excluir".
Cancelar pede motivo e a senha do administrador. Se o pedido já estava pronto, diga se a mercadoria foi perdida ou volta ao estoque.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'secao', 8, ''),
	(49, 'man-operador-09-despesa-e-sangria', 'Despesa e sangria', 'despesa e sangria, sangria é retirada de dinheiro do caixa ', 'Caixa → "+ Despesa" ou "− Sangria".
Informe valor e motivo e confirme.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'secao', 9, 'Sangria é retirada de dinheiro do caixa e não conta como despesa.'),
	(50, 'man-operador-10-fechar-o-caixa', 'Fechar o caixa', 'fechar o caixa, ao tocar em "sair" com o caixa aberto, o', 'Caixa → fechar caixa.
Informe o dinheiro contado.
Confira o total por forma, despesas, sangrias e a diferença.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'secao', 10, 'Ao tocar em "Sair" com o caixa aberto, o sistema pergunta se você quer mesmo sair.'),
	(51, 'man-operador-11-clientes-e-fidelidade', 'Clientes e fidelidade', 'clientes e fidelidade operador', 'Clientes → “+ Novo cliente”: só nome e telefone são obrigatórios.
Toque no cliente para ver histórico, total gasto, indicação e cartão fidelidade.', '{Operador}', false, '2026-10-09 10:20:59.387621+00', 'secao', 11, ''),
	(52, 'man-operador-12-registrar-um-problema-ocorrencia', 'Registrar um problema (Ocorrência)', 'registrar um problema (ocorrência) operador', 'No cartão do pedido, toque em “⚠️ Ocorrência”.
Escolha o tipo, descreva o que aconteceu e confirme.
Ela aparece no mural Notificações e o Administrador resolve.', '{Operador}', false, '2026-10-09 10:20:59.387621+00', 'secao', 12, ''),
	(120, 'man-garcom-10-registrar-um-problema-ocorrencia', 'Registrar um problema (Ocorrência)', 'registrar um problema (ocorrência) garcom', 'No cartão do pedido, toque em “⚠️ Ocorrência”.
Escolha o tipo, descreva o que aconteceu e confirme.
O Administrador e o Operador são avisados e resolvem.', '{Garçom}', false, '2026-10-09 10:20:59.387621+00', 'secao', 10, ''),
	(37, 'err-admin-01-a-internet-caiu', 'A internet caiu', 'a internet caiu', 'Venda no Caixa: se você já entrou neste aparelho, o sistema oferece guardar a venda na CONTINGÊNCIA (só retirada ou entrega, sem desconto, sem mesa). Ela entra sozinha quando voltar. Não confirme se já apareceu. Caixa, cancelamento, pagamentos e estoque exigem conexão e nunca ficam guardados. Clientes, feedbacks e ocorrências ficam salvos no aparelho.', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'erro', 100, ''),
	(38, 'err-admin-02-o-caixa-esta-fechado', 'O caixa está fechado', 'o caixa está fechado erro problema admin', 'Venda, despesa e sangria exigem caixa aberto, e o Cardápio Digital para de receber pedidos. Abra o caixa pela aba Caixa. Se aparecer “Já existe um caixa aberto”, feche o anterior (conte o dinheiro) antes de abrir outro.', '{Admin}', true, '2026-10-08 00:57:18.607627+00', 'erro', 105, ''),
	(39, 'err-admin-03-pedido-duplicado', 'Pedido duplicado', 'pedido duplicado erro problema admin', 'Duplo toque ou internet lenta não duplicam: o sistema reconhece a repetição e avisa que já foi registrado. Se o cliente fez dois pedidos de verdade, cancele um: Caixa → “Lançamentos desde a abertura” → excluir, com o motivo “Pedido duplicado”. Se já estava pronto, diga se a mercadoria foi perdida ou volta ao estoque.', '{Admin}', false, '2026-10-08 00:57:18.607627+00', 'erro', 102, ''),
	(40, 'err-admin-04-alguem-alterou-este-registro', '"Alguém alterou este registro"', '"alguém alterou este registro"', 'Outra pessoa editou o mesmo cadastro antes de você. O sistema recarrega os dados reais; confira e refaça a edição.', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'erro', 103, ''),
	(41, 'man-operador-01-entrar-sair-e-status', 'Entrar, sair e status', 'entrar, sair e status, “login ou senha incorretos”, “sua sessão expirou”, “muitas tentativas erradas”', 'Digite Login e Senha e toque em “Entrar”.
Olhe o status no topo: 🟢 Online = tudo certo · 🟡 Sincronizando = aguarde · 🔴 Sem conexão = veja “E se der errado?” · 🟠 Contingência = o servidor está lento ou fora do ar e o app usa a reserva. Toque na bolinha colorida do topo para ver o estado do Supabase, da planilha principal e da contingência.
Para sair, toque em “Sair” no topo. Para trocar a sua senha, toque em “🔑 Senha” (precisa da senha atual e de ao menos 8 caracteres).
Suas abas: Início, Caixa, Pedidos (com Retiradas, Entregas e Mesas), Clientes e Operação (Ocorrências e Feedbacks). Os avisos ficam no botão ✨ Assistente, na aba 🔔 Avisos. Um ponto dourado numa aba avisa que há algo novo.', '{Operador}', true, '2026-10-16 03:03:49.796886+00', 'secao', 1, '“Login ou senha incorretos”: confira os dados. Se esqueceu a senha, só o Administrador pode redefinir.
“Sua sessão expirou”: entre de novo; o que você estava digitando pode se perder.
“Muitas tentativas erradas”: depois de 5 erros o login fica bloqueado por 10 minutos, contados a partir do primeiro erro. Espere e tente de novo, sem insistir.'),
	(42, 'man-operador-02-abrir-o-caixa', 'Abrir o caixa', 'abrir o caixa, sem caixa aberto não há venda, despesa n, "já existe um caixa aberto"', 'Aba Caixa → "Abrir caixa".
Informe o fundo de troco e confirme.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'secao', 2, 'Sem caixa aberto não há venda, despesa nem sangria, e o Cardápio Digital não recebe pedidos.
"Já existe um caixa aberto": feche o anterior antes.'),
	(43, 'man-operador-03-fazer-uma-venda', 'Fazer uma venda', 'fazer uma venda, "abra o caixa antes de registrar uma ven, "a soma dos pagamentos precisa bater com, desconto (% ou r$) pede a senha do admin', '1. Cliente: busque por nome ou telefone, ou "Venda sem cadastro". Escolha Retirada, Entrega ou Mesa.
2. Itens: toque nos produtos; adicionais abrem numa janela.
3. Pagamento e finalizar: escolha a forma. Em dinheiro, informe o recebido e veja o troco. Para dividir, marque "Dividir pagamento". Confira o total, escolha 58mm, 80mm ou A4 e toque em Imprimir, Copiar ou WhatsApp.
"↺ Repetir última venda" recarrega o carrinho anterior.
Se a forma de pagamento tem acréscimo (ex.: iFood), o Caixa mostra o valor a mais e já soma no total e no comprovante. Em pagamento dividido, o acréscimo vale só para a parte paga naquela forma.', '{Operador}', true, '2026-10-09 10:42:24.469108+00', 'secao', 3, '"Abra o caixa antes de registrar uma venda."
"A soma dos pagamentos precisa bater com o total".
Desconto (% ou R$) pede a senha do administrador.'),
	(44, 'man-operador-04-cliente-cancelou-o-pedido-cardapio', 'Cliente cancelou o pedido (Cardápio)', 'cliente cancelou o pedido (cardápio)', 'Nos primeiros 3 minutos, e só enquanto o pedido está "aguardando aceite", o cliente cancela sozinho. O estoque volta.
Depois de aceito, ou passados os 3 minutos, o cliente precisa ligar. Cancelar ou editar passa a ser com você ou o Admin.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'lista', 4, ''),
	(45, 'man-operador-05-pedidos-e-entregas', 'Pedidos e entregas', 'pedidos e entregas, só dá para editar os itens com o pedido , o entregador esqueceu de marcar, sem aviso de pedido novo', 'Pedido do Cardápio chega como "novo — aguardando aceite": toque em "✅ Aceitar" ou "❌ Rejeitar".
Quando ficar "Pronta" (retirada ou entrega) ou "Saiu para entrega", e o cliente tiver telefone, toque em "📲 Avisar cliente".
Avance com "Marcar como…": Em preparo → Pronta → Retirada (Servida, se for mesa).
Em Entregas, escolha o entregador no campo "Entregador".
Venda "A Receber": quando o cliente pagar, toque em "marcar como recebido".
"⏸ Suspender" pausa o pedido (toque num motivo pronto, como "Cliente não atende", ou escreva). Recusar pedido também tem motivos prontos e "▶️ Retomar" volta.
Com só um entregador ativo, toda entrega já fica no nome dele. Com mais de um, escolha no campo "Entregador".
Depois de imprimir a comanda, fica um botão "🔁 Não saiu? Reimprimir" por 10 minutos; não precisa confirmar quando saiu certo.', '{Operador}', true, '2026-10-11 16:31:19.325087+00', 'secao', 5, 'Só dá para editar os itens com o pedido "Em preparo".
O entregador esqueceu de marcar: marque você pelo botão do pedido.
Sem aviso de pedido novo: no Início, toque em "🔔 Ativar avisos" e "🔊 Testar som".'),
	(46, 'man-operador-06-cliente-pedindo-pela-mesa-qr-code', 'Cliente pedindo pela mesa (QR Code)', 'cliente pedindo pela mesa (qr code), o cliente só cancela enquanto o pedido e, pedido de mesa pelo cliente nunca vai ao', 'O cliente aponta a câmera para o QR da mesa, escolhe os itens e envia.
O pedido chega em Pedidos como "Recebido" (📱 Cliente). Toque em ✅ Aceitar, ou ❌ Rejeitar.
Se o cliente tocar em "Chamar garçom", a mesa aparece em 🍽️ Mesas com 🔔 — toque em ✔ Atendido quando for lá.
Se tocar em "Pedir a conta", a mesa vira "Pediu a conta" e você fecha como sempre.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'secao', 6, 'O cliente só cancela enquanto o pedido está "Recebido".
Pedido de mesa pelo cliente nunca vai ao preparo sem o aceite.'),
	(47, 'man-operador-07-fechar-a-conta-de-uma-mesa', 'Fechar a conta de uma mesa', 'fechar a conta de uma mesa, "abra o caixa antes de fechar a conta da, "a soma dos pagamentos não bate com a co', 'Quando o garçom pede a conta, a mesa fica "Aguardando fechamento".
Toque em "🍽️ Mesas". Quem pediu a conta aparece primeiro, com pontinho de aviso e som.
Em cada mesa: garçom, tempo, pedidos e total. "Ver pedidos" mostra o detalhe; "💳 Fechar conta" abre o pagamento.
Para dividir, marque "Dividir em duas formas" e informe o valor da primeira.
Se a forma escolhida tem acréscimo, ele é somado no fechamento e aparece no total a cobrar.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'secao', 7, '"Abra o caixa antes de fechar a conta da mesa".
"A soma dos pagamentos não bate com a conta".'),
	(53, 'err-operador-01-a-internet-caiu', 'A internet caiu', 'a internet caiu', 'O botão de finalizar trava com "Sem conexão". Se você já entrou neste aparelho, o sistema oferece guardar a venda na CONTINGÊNCIA (só retirada ou entrega, sem desconto, sem mesa): ela entra sozinha quando voltar. Fechar caixa, cancelar, pagar e lançar despesa exigem conexão.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'erro', 100, ''),
	(54, 'err-operador-02-o-caixa-esta-fechado', 'O caixa está fechado', 'o caixa está fechado erro problema operador', 'Abra o caixa (aba Caixa → “Abrir caixa”) antes de vender, lançar despesa ou sangria. Enquanto estiver fechado, o Cardápio Digital também não recebe pedidos.', '{Operador}', false, '2026-10-08 00:57:18.607627+00', 'erro', 101, ''),
	(55, 'err-operador-03-pedido-duplicado', 'Pedido duplicado', 'pedido duplicado erro problema operador', 'Duplo toque não duplica: o sistema avisa que a venda já foi registrada. Se o cliente pediu duas vezes, cancele um em “Lançamentos desde a abertura” → excluir, motivo “Pedido duplicado” (precisa da senha do administrador).', '{Operador}', false, '2026-10-08 00:57:18.607627+00', 'erro', 102, ''),
	(56, 'err-operador-04-errei-o-valor-ou-um-item', 'Errei o valor ou um item', 'errei o valor ou um item erro problema operador', 'Use “editar” em “Lançamentos desde a abertura”. Itens de pedido só mudam enquanto ele está “Em preparo”.', '{Operador}', false, '2026-10-08 00:57:18.607627+00', 'erro', 103, ''),
	(57, 'man-garcom-01-entrar-sair-e-status', 'Entrar, sair e status', 'entrar, sair e status, “login ou senha incorretos”, “sua sessão expirou”, “muitas tentativas erradas”', 'Digite Login e Senha e toque em “Entrar”.
Olhe o status no topo: 🟢 Online = tudo certo · 🟡 Sincronizando = aguarde · 🔴 Sem conexão = veja “E se der errado?” · 🟠 Contingência = o servidor está lento ou fora do ar e o app usa a reserva. Toque na bolinha colorida do topo para ver o estado do Supabase, da planilha principal e da contingência.
Para sair, toque em “Sair” no topo. Para trocar a sua senha, toque em “🔑 Senha” (precisa da senha atual e de ao menos 8 caracteres).
Suas abas: Início, Atendimento, Pedidos (com Retiradas, Entregas e Mesas) e Clientes. Um ponto dourado numa aba avisa que há algo novo.', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'secao', 1, '“Login ou senha incorretos”: confira os dados. Se esqueceu a senha, só o Administrador pode redefinir.
“Sua sessão expirou”: entre de novo; o que você estava digitando pode se perder.
“Muitas tentativas erradas”: depois de 5 erros o login fica bloqueado por 10 minutos, contados a partir do primeiro erro. Espere e tente de novo, sem insistir.'),
	(58, 'man-garcom-02-lancar-pedido-de-uma-mesa', 'Lançar pedido de uma mesa', 'lançar pedido de uma mesa, abrir mesa, mesa não aceita novos itens, mesa de outro garçom', 'Aba Caixa → etapa "1. Cliente" → escolha a mesa. Se estiver Livre, toque em "Abrir mesa".
Vá em "2. Itens", toque nos itens e escolha os adicionais.
Toque em "Lançar na mesa (enviar à cozinha)". Repita quantas vezes o cliente pedir mais.', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'secao', 2, '"A mesa N está … — não aceita novos itens": já está aguardando fechamento.
"Esta mesa está sob responsabilidade de outro garçom": a mesa é de quem a abriu; peça ao Caixa.
Você lança pedido de mesa, sem desconto e sem receber pagamento.'),
	(59, 'man-garcom-03-pedir-a-conta', 'Pedir a conta', 'pedir a conta, pedir fechamento de mesa', 'Caixa → escolha a mesa (ou toque em "🍽️ Mesas").
Toque em "Pedir fechamento" e confirme.
A mesa passa para "Aguardando fechamento". O Caixa recebe — ou você mesmo, com "💳 Receber conta".', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'secao', 3, 'Só dá para pedir fechamento de mesa "Ocupada".'),
	(60, 'man-garcom-04-cliente-pedindo-pela-mesa-qr-code', 'Cliente pedindo pela mesa (QR Code)', 'cliente pedindo pela mesa, qr code, chamar garçom', 'O cliente pode pedir pelo celular. Quem aceita o pedido é o Caixa.
Se ele tocar em "Chamar garçom", a mesa aparece em 🍽️ Mesas com 🔔 e o aparelho avisa.
Depois de atender, toque em ✔ Atendido.', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'secao', 4, 'Se a mesa pedir a conta, ela vira "Pediu a conta".'),
	(61, 'man-garcom-05-receber-a-conta-garcom', 'Receber a conta (garçom)', 'receber a conta, caixa fechado, mesa não é sua', 'Toque em "🍽️ Mesas" e ache a sua mesa.
Toque em "💳 Receber conta", confira o total e escolha a forma.
Para dividir, marque "Dividir em duas formas".
Confirme. A mesa fica livre e o valor entra no caixa.', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'secao', 5, '"O caixa está fechado": peça ao caixa para abrir.
"Esta mesa não está sob a sua responsabilidade": só quem abriu a mesa recebe.'),
	(62, 'man-garcom-06-acompanhar-e-servir', 'Acompanhar e servir', 'acompanhar e servir, servida', 'Aba Pedidos: veja o andamento de cada pedido.
Quando estiver "Pronta", leve à mesa e toque em "Marcar como “Servida”".', '{Garçom}', true, '2026-10-09 10:26:30.365372+00', 'secao', 6, ''),
	(63, 'man-garcom-07-aviso-de-pedido-pronto', 'Aviso de pedido pronto', 'aviso de pedido pronto, som', 'Na primeira vez, toque em "🔔 Ativar avisos e som".
Quando um pedido das SUAS mesas ficar "Pronta", o aparelho toca, vibra e o título da aba mostra "Pedido pronto".
A checagem roda mesmo com o app em segundo plano.', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'lista', 7, ''),
	(64, 'man-garcom-08-clientes', 'Clientes', 'clientes, novo cliente', 'Aba Clientes → "+ Novo cliente".
Só nome e telefone são obrigatórios.', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'secao', 8, ''),
	(65, 'man-garcom-09-registrar-um-problema-ocorrencia', 'Registrar um problema (Ocorrência)', 'registrar um problema, ocorrência', 'No cartão do pedido, toque em “⚠️ Ocorrência”.
Escolha o tipo, descreva o que aconteceu e confirme.
O Administrador e o Operador são avisados e resolvem.', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'secao', 9, ''),
	(66, 'err-garcom-01-a-internet-caiu', 'A internet caiu', 'a internet caiu', 'Você não tem fila de envio: se aparecer "Sem conexão — a mesa não foi aberta" (ou o fechamento não foi solicitado), nada foi gravado. Espere o 🟢, confira em Pedidos se o pedido já entrou e só então repita.', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'erro', 100, ''),
	(67, 'err-garcom-02-o-caixa-esta-fechado', 'O caixa está fechado', 'o caixa está fechado', 'Quem abre e fecha o caixa é o Caixa. Se a conta da mesa não puder ser recebida, avise o responsável.', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'erro', 101, ''),
	(68, 'err-garcom-03-pedido-duplicado-ou-item-errado', 'Pedido duplicado ou item errado', 'pedido duplicado ou item errado', 'Duplo toque não duplica. Se lançou item errado ou em dobro, peça ao Caixa para editar ou cancelar (itens só mudam com o pedido "Em preparo").', '{Garçom}', true, '2026-10-09 10:19:05.884579+00', 'erro', 102, ''),
	(82, 'err-entregador-02-o-cliente-nao-atende', 'O cliente não atende', 'o cliente não atende', 'Avise o Caixa: ele pode usar "⏸ Suspender" no pedido (com motivo) e retomar depois. Registre uma Ocorrência para ficar anotado.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'erro', 101, ''),
	(83, 'err-entregador-03-pedido-duplicado', 'Pedido duplicado', 'pedido duplicado', 'Se aparecerem dois cartões iguais, entregue só um e avise o Caixa, que cancela o repetido.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'erro', 102, ''),
	(69, 'man-cozinha-01-entrar-sair-e-status', 'Entrar, sair e status', 'entrar, sair e status, “login ou senha incorretos”, “sua sessão expirou”, “muitas tentativas erradas”', 'Digite Login e Senha e toque em “Entrar”.
Olhe o status no topo: 🟢 Online = tudo certo · 🟡 Sincronizando = aguarde · 🔴 Sem conexão = veja “E se der errado?” · 🟠 Contingência = o servidor está lento ou fora do ar e o app usa a reserva. Toque na bolinha colorida do topo para ver o estado do Supabase, da planilha principal e da contingência.
Para sair, toque em “Sair” no topo. Para trocar a sua senha, toque em “🔑 Senha” (precisa da senha atual e de ao menos 8 caracteres).
Suas abas: Início, Cozinha (os pedidos) e Notificações. Um ponto dourado numa aba avisa que há algo novo.', '{Cozinha}', true, '2026-10-09 10:17:28.988364+00', 'secao', 1, '“Login ou senha incorretos”: confira os dados. Se esqueceu a senha, só o Administrador pode redefinir.
“Sua sessão expirou”: entre de novo; o que você estava digitando pode se perder.
“Muitas tentativas erradas”: depois de 5 erros o login fica bloqueado por 10 minutos, contados a partir do primeiro erro. Espere e tente de novo, sem insistir.'),
	(70, 'man-cozinha-02-preparar-os-pedidos', 'Preparar os pedidos', 'preparar os pedidos, sem beep, o sistema mantém a tela ligada enquanto ', 'Aba Pedidos: três colunas (Novos, Em preparo, Prontos) com itens, adicionais e observações.
Observação do cliente em um item aparece em destaque com 📝 abaixo do item.
Para imprimir: "🖨️ Comanda" no pedido ou "🖨️ Imprimir novos". Marque "Imprimir sozinho quando chegar pedido" para imprimir automático (o navegador precisa estar em modo quiosque de impressão).
No Início, "🔊 Testar som" confere se o celular toca e "🔔 Ativar avisos" libera notificações.
Pedido novo chega com beep e piscada (o sistema confere a cada poucos segundos com o app aberto e online).
Toque em "▶️ Iniciar preparo" (no pedido do Cardápio: "Aceitar e iniciar preparo").
Terminou? Toque em "✅ Pronto".
No fim da tela, "📜 Concluídos neste turno" mostra o que já saiu (retirado, entregue ou servido), com o horário. A lista zera quando o caixa fecha.', '{Cozinha}', true, '2026-10-09 10:17:28.988364+00', 'secao', 2, 'Sem beep: toque em "🔊 Testar som" no Início, aumente o volume de mídia e tire o modo silencioso.
O sistema mantém a tela ligada enquanto o app está aberto. Se aparecer "⚠️ A tela NÃO está sendo mantida ligada", toque em "📱 Manter a tela ligada".'),
	(71, 'man-cozinha-03-registrar-um-problema-ocorrencia', 'Registrar um problema (Ocorrência)', 'registrar um problema (ocorrência) cozinha', 'No cartão do pedido, toque em “⚠️ Ocorrência”.
Escolha o tipo, descreva o que aconteceu e confirme.
O Administrador e o Caixa são avisados. Use para falta de ingrediente ou pedido que não pode ser produzido.', '{Cozinha}', false, '2026-10-09 10:20:59.387621+00', 'secao', 3, ''),
	(72, 'man-cozinha-04-notificacoes', 'Notificações', 'notificações cozinha', 'É o mural de avisos do dia a dia. Você só vê os que o Administrador liberou para a Cozinha.', '{Cozinha}', false, '2026-10-09 10:20:59.387621+00', 'lista', 4, ''),
	(73, 'err-cozinha-01-a-internet-caiu', 'A internet caiu', 'a internet caiu', 'O topo mostra "⚠️ Sem conexão com o servidor — tentando de novo em 3 min." Continue os pedidos já visíveis. Se tocar em "Iniciar preparo" e aparecer "Sem conexão — o preparo não foi registrado", repita quando voltar o 🟢.', '{Cozinha}', true, '2026-10-09 10:17:28.988364+00', 'erro', 100, ''),
	(74, 'err-cozinha-02-nao-chega-nenhum-pedido', 'Não chega nenhum pedido', 'não chega nenhum pedido', 'Confira o status no topo (🟢). Com o caixa fechado, o Cardápio Digital não recebe pedidos; avise o Caixa. Toque em "↻ Verificar agora".', '{Cozinha}', true, '2026-10-09 10:17:28.988364+00', 'erro', 101, ''),
	(75, 'err-cozinha-03-pedido-duplicado', 'Pedido duplicado', 'pedido duplicado', 'Se aparecerem dois iguais, faça só um e avise o Caixa para cancelar o repetido. Você também pode registrar uma Ocorrência no pedido.', '{Cozinha}', true, '2026-10-09 10:17:28.988364+00', 'erro', 102, ''),
	(76, 'man-entregador-01-entrar-sair-e-status', 'Entrar, sair e status', 'entrar, sair e status, “login ou senha incorretos”, “sua sessão expirou”, “muitas tentativas erradas”', 'Digite Login e Senha e toque em “Entrar”.
Olhe o status no topo: 🟢 Online = tudo certo · 🟡 Sincronizando = aguarde · 🔴 Sem conexão = veja “E se der errado?” · 🟠 Contingência = o servidor está lento ou fora do ar e o app usa a reserva. Toque na bolinha colorida do topo para ver o estado do Supabase, da planilha principal e da contingência.
Para sair, toque em “Sair” no topo. Para trocar a sua senha, toque em “🔑 Senha” (precisa da senha atual e de ao menos 8 caracteres).
Suas abas: Início, Minhas entregas e Meus ganhos. Um ponto dourado numa aba avisa que há algo novo.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'secao', 1, '“Login ou senha incorretos”: confira os dados. Se esqueceu a senha, só o Administrador pode redefinir.
“Sua sessão expirou”: entre de novo; o que você estava digitando pode se perder.
“Muitas tentativas erradas”: depois de 5 erros o login fica bloqueado por 10 minutos, contados a partir do primeiro erro. Espere e tente de novo, sem insistir.'),
	(77, 'man-entregador-02-fazer-uma-entrega', 'Fazer uma entrega', 'fazer uma entrega, não aparece nada, pedido "aguardando aceite"', 'Aba Minhas entregas: aparecem só as suas. Uma nova toca um aviso sonoro.
O cartão mostra itens, endereço, referência, telefone, total, taxa e "📍 Ver no Maps".
Quem marca o pedido como "Pronta" é a Cozinha. Quando pegar o pedido (status "Pronta"), toque em "Marcar como “Saiu para entrega”". Nesse momento o app começa a enviar sua localização.
Ao entregar, toque em "✅ Já entreguei". O envio de localização para sozinho.
Se o cartão diz "A receber", cobre o valor do cliente; quem registra o recebimento é o Caixa.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'secao', 2, 'Não aparece nada: ainda não atribuíram entrega a você. Avise o Caixa.
Pedido "aguardando aceite": o botão só aparece depois que o Caixa aceitar.'),
	(78, 'man-entregador-03-aviso-de-entrega-nova', 'Aviso de entrega nova', 'aviso de entrega nova', 'Na primeira vez, toque em "🔔 Ativar avisos e som" (canto da tela).
Quando o Caixa atribuir uma entrega, o aparelho toca, vibra e a aba mostra "Nova entrega".
A checagem roda com o app aberto, mesmo em segundo plano.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'lista', 3, ''),
	(79, 'man-entregador-04-meu-dia', 'Meu dia', 'meu dia entregador', 'Em Minhas entregas, “💰 Meu dia” mostra suas entregas de hoje, as taxas e a ajuda diária.
O total previsto é taxas + ajuda diária (uma vez por dia). O acerto oficial é feito pelo Administrador.', '{Entregador}', false, '2026-10-09 10:20:59.387621+00', 'lista', 4, ''),
	(80, 'man-entregador-05-registrar-um-problema-ocorrencia', 'Registrar um problema (Ocorrência)', 'registrar um problema (ocorrência) entregador', 'No cartão do pedido, toque em “⚠️ Ocorrência”.
Escolha o tipo, descreva o que aconteceu e confirme.
O Administrador é avisado. Use para cliente ausente, endereço errado ou problema na entrega.', '{Entregador}', false, '2026-10-09 10:20:59.387621+00', 'secao', 5, ''),
	(81, 'err-entregador-01-a-internet-caiu', 'A internet caiu', 'a internet caiu', 'O celular mostra o último estado salvo. Se o toque em "Saiu para entrega" ou "Já entreguei" falhar, confira o status no cartão e toque de novo quando voltar a conexão — o sistema não duplica.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'erro', 100, ''),
	(85, 'man-todos-90-balao', 'Usar o assistente (botão ✨ no canto da tela)', 'balao assistente ia ajuda perguntar texto como faco', 'Toque no balão 💬/✨ no canto inferior direito da tela.
Escreva o que precisa, em uma frase (ex.: “como abro o caixa?”). Não há botões de função: o sistema entende pelo texto.
A resposta vem do manual do seu perfil. Se não houver o passo, aparece “Não encontrei esse passo no manual do sistema.”
Perguntas financeiras só o Administrador consegue; para os demais perfis aparece o aviso fixo.
O balão não aparece na tela de login.
Dentro do assistente há duas abas: "✨ Conversa" e "🔔 Avisos". Em Avisos ficam os alertas que antes estavam em Notificações (pedidos aguardando, ocorrências, entregas, contas vencidas, falhas do sistema, estoque baixo, fidelidade, indicações, aniversariantes e clientes inativos). Toque num grupo para abrir.', '{Admin,Operador,Desenvolvedor}', true, '2026-10-09 10:21:12.959495+00', 'secao', 90, ''),
	(86, 'man-equipe-91-atendimento', 'Atender um cliente pelo balão', 'atendimento cliente chat assumir encerrar fila aguardando antes de pedir', 'Quando um cliente toca em “Falar com a equipe”, o balão mostra um contador e a linha “N clientes aguardando”.
Abra o balão, toque na linha e leia o resumo feito pela recepção automática (nome, telefone e pedido vinculado, ou “Pedido não localizado”).
Toque em “Assumir”, converse com o cliente e, ao terminar, toque em “Encerrar” e registre a solução.
Depois de encerrar, a mesma caixa de texto volta a responder suas perguntas normais.
“Antes de pedir” é cliente que ainda vai pedir: não gera ocorrência.
Abra o assistente na aba "✨ Conversa". A aba "🔔 Avisos" mostra os alertas do restaurante.', '{Admin,Operador}', true, '2026-10-09 10:21:12.959495+00', 'secao', 91, ''),
	(87, 'man-entregador-92-localizacao', 'Localização na entrega (GPS)', 'localizacao gps entrega mapa posicao permitir', 'Ao tocar em “Saiu para entrega”, permita a localização quando o celular perguntar.
Mantenha o app aberto na tela durante a entrega: o GPS só é enviado assim, a cada cerca de 18 segundos.
Ao marcar “Já entreguei”, o envio para e a posição é apagada.
Se negar o GPS, a entrega continua normal; só a equipe e o cliente deixam de ver a localização.', '{Entregador}', false, '2026-10-08 00:57:18.607627+00', 'secao', 92, ''),
	(88, 'man-caixa-93-ver-localizacao', 'Ver onde está o entregador', 'localizacao entregador mapa distancia ver onde esta', 'Em Pedidos → Entregas, nos pedidos “Saiu para entrega”, toque em “📍 Ver localização”.
A janela mostra há quanto tempo a posição foi atualizada e, se o cliente compartilhou o destino, a distância aproximada.
Toque em “Abrir no mapa” para ver o ponto no Google Maps.
Se aparecer “Posição indisponível”, o entregador está sem GPS ou com o app fechado.', '{Admin,Operador}', false, '2026-10-08 00:57:18.607627+00', 'secao', 93, ''),
	(91, 'man-cozinha-03-confirmar-impressao-da-comanda', 'Confirmar impressão da comanda', 'confirmar impressão da comanda', 'Depois de mandar imprimir, fica um botão discreto "🔁 Não saiu? Reimprimir" por 10 minutos. Se saiu certo, ninguém precisa confirmar nada.
🔁 Não saiu? Reimprimir: o sistema tira o pedido de "impressos" e manda de novo.
✖ Saiu, ocultar: esconde o botão.', '{Cozinha}', true, '2026-10-09 10:17:28.988364+00', 'lista', 3, ''),
	(92, 'man-cozinha-04-pedido-alterado-depois-de-impresso', 'Pedido alterado depois de impresso', 'pedido alterado depois de impresso', 'O aparelho guarda uma "foto" da comanda quando você imprime ou quando o pedido aparece na tela.
Se um Admin/Operador editar o pedido, a foto deixa de bater. O cartão ganha faixa vermelha "PEDIDO ALTERADO" e toca dois bipes uma vez.
Para resolver: "🖨️ Reimprimir comanda atualizada" ou "👍 Ciente".', '{Cozinha}', true, '2026-10-09 10:17:28.988364+00', 'lista', 4, ''),
	(93, 'man-cozinha-05-registrar-um-problema-ocorrencia', 'Registrar um problema (Ocorrência)', 'registrar um problema (ocorrência)', 'No cartão do pedido, toque em “⚠️ Ocorrência”.
Escolha o tipo, descreva o que aconteceu e confirme.
O Administrador e o Operador são avisados. Use para falta de ingrediente ou pedido que não pode ser produzido.', '{Cozinha}', true, '2026-10-09 10:17:28.988364+00', 'secao', 5, ''),
	(94, 'man-cozinha-06-notificacoes', 'Notificações', 'notificações', 'Mural de avisos. Você só vê os que o Administrador liberou para a Cozinha.', '{Cozinha}', true, '2026-10-09 10:17:28.988364+00', 'lista', 6, ''),
	(98, 'err-cozinha-04-nao-sei-se-a-comanda-saiu', 'Não sei se a comanda saiu', 'não sei se a comanda saiu', 'O botão "🔁 Não saiu? Reimprimir" fica visível por 10 minutos depois de imprimir. Se a comanda não saiu, toque nele. Se saiu certo, não precisa fazer nada.', '{Cozinha}', true, '2026-10-09 10:17:28.988364+00', 'erro', 103, ''),
	(102, 'man-entregador-04-localizacao-sua-privacidade', 'Localização (sua privacidade)', 'localização (sua privacidade)', 'O envio só liga quando você tem entrega em "Saiu para entrega" — não fica rodando o dia inteiro.
Não guarda histórico: a posição é atualizada em cima da anterior e o banco limpa ao sair do status.
Precisa do GPS permitido no navegador. Se negar, a entrega continua normal; só o mapa do restaurante fica sem sua posição.
Ao marcar "Já entreguei", o envio para automaticamente.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'lista', 4, ''),
	(103, 'man-entregador-05-meu-dia', 'Meu dia', 'meu dia', 'Em Minhas entregas, "💰 Meu dia" mostra suas entregas de hoje, as taxas e a ajuda diária.
O total previsto é taxas + ajuda diária (uma vez por dia). O acerto oficial é feito pelo Administrador.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'lista', 5, ''),
	(104, 'man-entregador-06-balao-de-atendimento', 'Balão de atendimento', 'balão de atendimento entregador', 'Toque no botão do canto para perguntar ao assistente.
Exemplos: "quantas entregas fiz hoje?", "como marco que saiu para entrega?".
Se houver cliente esperando atendimento, aparece um contador vermelho no botão.', '{Entregador}', false, '2026-10-09 10:20:59.387621+00', 'lista', 6, ''),
	(105, 'man-entregador-07-registrar-um-problema-ocorrencia', 'Registrar um problema (Ocorrência)', 'registrar um problema (ocorrência) entregador', 'No cartão do pedido, toque em “⚠️ Ocorrência”.
Escolha o tipo, descreva o que aconteceu e confirme.
O Administrador e o Operador são avisados. Use para cliente ausente, endereço errado ou problema na entrega.', '{Entregador}', false, '2026-10-09 10:20:59.387621+00', 'secao', 7, ''),
	(110, 'err-entregador-05-o-mapa-nao-mostra-minha-posicao', 'O mapa não mostra minha posição', 'o mapa não mostra minha posição', 'Confira se o GPS está ligado e se o navegador tem permissão de localização para o site.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'erro', 104, '');
INSERT INTO public.ai_ajuda (id, slug, titulo, palavras_chave, passos, perfis, ativo, atualizado_em, grupo, ordem, comuns) OVERRIDING SYSTEM VALUE VALUES
	(118, 'man-garcom-08-balao-de-atendimento', 'Balão de atendimento', 'balão de atendimento garcom', 'Toque no botão do canto para perguntar ao assistente.
Exemplos: "como abro uma mesa?", "como pedir a conta?", "tem cliente aguardando?".
Se houver cliente esperando, aparece um contador vermelho no botão.', '{Garçom}', false, '2026-10-09 10:20:59.387621+00', 'lista', 8, ''),
	(119, 'man-garcom-09-clientes', 'Clientes', 'clientes garcom', 'Aba Clientes → "+ Novo cliente".
Só nome e telefone são obrigatórios.', '{Garçom}', false, '2026-10-09 10:20:59.387621+00', 'secao', 9, ''),
	(135, 'man-operador-12-fila-de-envio', 'Fila de envio', 'fila de envio', 'Cadastro de cliente, fidelidade, feedback e ocorrência podem ficar guardados no aparelho quando a internet cai. Aparece "na fila" no topo.
Toque para ver estado, tentativas e motivo. Você pode tentar de novo, descartar ou enviar agora.
Venda, pagamento, sangria, cancelamento e estoque NUNCA ficam na fila.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'lista', 12, ''),
	(136, 'man-operador-13-balao-de-atendimento', 'Balão de atendimento', 'balão de atendimento', 'O botão no canto é o assistente quando você está logado. Para o cliente ele é o atendente virtual (IA); quando o problema é com a equipe, o chamado chega aqui.
Escreva perguntas como: "como faço uma venda?", "quanto tem de pão no estoque?", "tem cliente aguardando?".
Se houver cliente esperando, o botão mostra um contador vermelho. Toque para ver a fila e assumir um atendimento.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'lista', 13, ''),
	(137, 'man-operador-14-localizacao-do-entregador', 'Localização do entregador', 'localização do entregador', 'Em Entregas, quando o pedido estiver "Saiu para entrega" e tiver entregador atribuído, aparece "📍 Ver localização".
Abre um mapa com a última posição (o entregador envia a cada ~18 s, só enquanto estiver na rua).', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'lista', 14, ''),
	(138, 'man-operador-15-o-que-voce-tem-em-administrador', 'O que você tem em Administrador', 'o que você tem em administrador', 'A aba aparece com o nome "Operação". A barra é reduzida: só o grupo "💬 Atendimento", com duas telas — Ocorrências e Feedbacks.
Ocorrências: filtro Abertas/Todas e botão "Tratar". Você pode mudar status (Aberta → Em andamento → Resolvida), anotar responsável e descrever a solução.
Feedbacks: tudo o que os clientes enviaram. Você pode marcar como Visto ou Respondido.
Atalho mais rápido no dia a dia: no Assistente, a aba "🔔 Avisos" mostra as ocorrências abertas, com botão "Tratar" direto.
Você NÃO tem acesso às outras telas do Administrador (financeiro, usuários, backup, catálogo etc.).', '{Operador}', true, '2026-10-16 03:03:49.796886+00', 'lista', 15, ''),
	(139, 'man-operador-16-clientes-e-fidelidade', 'Clientes e fidelidade', 'clientes e fidelidade, "nenhum prêmio cadastrado"', 'Clientes → "+ Novo cliente": só nome e telefone são obrigatórios.
Toque no cliente para ver histórico, total gasto, indicação e cartão fidelidade.
Com as 10 marcas, ou com uma indicação pendente, escolha o prêmio e toque em "🎁 Resgatar". Precisa do caixa aberto; o estoque baixa e o cliente não paga.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'secao', 16, '"Nenhum prêmio cadastrado": peça ao Administrador para marcar um produto como prêmio.'),
	(140, 'man-operador-17-registrar-um-problema-ocorrencia', 'Registrar um problema (Ocorrência)', 'registrar um problema (ocorrência)', 'No cartão do pedido, toque em “⚠️ Ocorrência”.
Escolha o tipo, descreva o que aconteceu e confirme.
Ela aparece na aba "🔔 Avisos" do Assistente e você pode tratar direto pelo botão "Tratar".', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'secao', 17, ''),
	(142, 'err-operador-02-supabase-fora-do-ar-faixa-laranja', 'Supabase fora do ar (faixa laranja)', 'supabase fora do ar (faixa laranja)', 'Modo reserva automático. O cartão "Pedidos na reserva" fica em Pedidos (somente consulta). Você pode continuar registrando retirada/entrega na contingência — sem desconto, sem mesa, sem cupom.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'erro', 101, ''),
	(143, 'err-operador-03-o-caixa-esta-fechado', 'O caixa está fechado', 'o caixa está fechado', 'Abra o caixa antes de vender, lançar despesa ou sangria. Enquanto estiver fechado, o Cardápio Digital também não recebe pedidos.', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'erro', 102, ''),
	(144, 'err-operador-04-pedido-duplicado', 'Pedido duplicado', 'pedido duplicado', 'Duplo toque não duplica. Se o cliente pediu duas vezes, cancele um em "Lançamentos desde a abertura" → excluir, motivo "Pedido duplicado".', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'erro', 103, ''),
	(145, 'err-operador-05-errei-o-valor-ou-um-item', 'Errei o valor ou um item', 'errei o valor ou um item', 'Use "editar" em "Lançamentos desde a abertura". Itens de pedido só mudam enquanto o pedido está "Em preparo".', '{Operador}', true, '2026-10-09 10:19:39.43679+00', 'erro', 104, ''),
	(153, 'man-admin-08-modo-emergencia-planilha-fora-do-ar', 'Modo emergência (servidor fora do ar)', 'modo emergência (planilha fora do ar) admin', 'Só funciona no mesmo aparelho em que você já fez login normal ao menos uma vez nos últimos 30 dias. Cada login novo renova o prazo.
Quando o sistema não consegue falar com o servidor (Supabase), aparece a pergunta: "Entrar em MODO EMERGÊNCIA como [seu login]?". A senha é conferida no aparelho.
O que dá: registrar venda de retirada/entrega pela contingência, usando o catálogo da última sincronização. Sem mesa, sem desconto.
O que NÃO dá: abrir/fechar caixa, cancelar, receber pagamento, mexer em estoque, ver financeiro.
Um aviso laranja fixo no topo mostra "MODO EMERGÊNCIA". Um vigia testa o servidor a cada 30 s. Assim que ele responde, o app pede login de novo.
Errar a senha 5 vezes no modo emergência bloqueia por 5 minutos.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 8, ''),
	(154, 'man-admin-09-contingencia-e-modo-reserva', 'Contingência e modo reserva', 'contingência e modo reserva admin', 'O Supabase é o servidor principal; a planilha principal é a reserva e a planilha de contingência é o último recurso. Se o Supabase cai, o modo reserva segura o app e a contingência segura o cardápio e as vendas.
No modo reserva: faixa laranja no topo e cartão "Pedidos na reserva (somente consulta)" em Pedidos. Mostra o que estava em andamento no último espelho e o que entrou na fila da contingência.
Ao voltar, o Admin recebe sozinho as vendas da contingência. Falhas ficam na tela de Contingência.
Tempo real (WebSocket) e modo reserva são automáticos.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 9, ''),
	(155, 'man-admin-10-fila-de-envio-e-erros-de-sincronizacao', 'Fila de envio e erros de sincronização', 'fila de envio e erros de sincronização admin', 'Itens como cadastro de cliente, fidelidade, feedback e ocorrência podem ficar guardados no aparelho quando a internet cai. Aparece o botão "na fila" no topo.
Toque nele para ver estado, tentativas e motivo. Você pode tentar de novo, descartar ou enviar agora.
Venda, pagamento, sangria, cancelamento e estoque NUNCA ficam na fila.
Se a sessão expirar com itens na fila, eles viram "com erro" e voltam só quando alguém entrar de novo e tocar em "Tentar de novo".', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 10, ''),
	(156, 'man-admin-11-localizacao-do-entregador', 'Localização do entregador', 'localização do entregador admin', 'No cartão da entrega, se o status for "Saiu para entrega" e houver entregador atribuído, aparece "📍 Ver localização".
Abre um mapa embutido (Leaflet local) e um botão "Abrir no mapa".
A posição só existe se o entregador estiver com o app aberto e GPS permitido. O envio é a cada ~18 s e só enquanto houver entrega em "Saiu para entrega".
O cliente vê apenas a distância aproximada.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 11, ''),
	(157, 'man-admin-12-balao-de-atendimento-e-assistente-de-ia', 'Balão de atendimento e assistente de IA', 'balão de atendimento e assistente de ia admin', 'No canto da tela tem um botão único. Para o cliente, é o atendimento. Para funcionário logado, é o assistente.
Assistente (Admin e Operador): escreva em português. Exemplos: "como faço uma venda?", "quanto tem de pão no estoque?", "tem cliente aguardando?", "qual produto vendeu mais hoje?".
Período: reconhece "hoje", "ontem", "7 dias", "30 dias", "mês". Pergunta de mês anterior avisa que os dados estão arquivados (veja Relatórios).
A IA é somente leitura. Não altera preço, não cancela, não muda status.
Se você for Desenvolvedor real (sem "Ver como"), o balão aceita comandos: "atualizar código", "enviar apps script", "analise o index.html", "o que mudou", "testar ajuda".
Quando o Supabase cai (ou a IA falha seguidas vezes), o balão avisa e o sistema segue normal.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 12, ''),
	(158, 'man-admin-13-arquivamento-e-uso-do-banco', 'Arquivamento e uso do banco', 'arquivamento e uso do banco admin', 'Administrador → Sistema → Espaço e fotos → bloco "Uso do Supabase".
Por padrão, vendas e caixas fechados com mais de 90 dias saem do Supabase e vão para a planilha (abas Arquivo_*), de madrugada. Você pode mudar a regra (90/60/30 dias) e forçar "Mandar para a planilha agora".
Relatórios e Visão Geral buscam esse arquivo automaticamente quando o período pedido é antigo.
Fotos: só no Google Drive. Administrador → Espaço e fotos → "Copiar fotos antigas para a contingência".', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 13, ''),
	(159, 'man-admin-14-exemplos-de-pergunta-ao-assistente', 'Exemplos de pergunta ao assistente', 'exemplos de pergunta ao assistente admin', '"Resumo de hoje" — faturamento, pedidos, ticket.
"Como estão as vendas comparadas com ontem?"
"Qual produto vendeu mais nos últimos 7 dias?"
"Em que horário vendemos mais?"
"Tem algo fora do normal?" — anomalias do dia.
"O que precisa comprar?" — sugestão de compras pelo consumo.
"Como cancelo uma venda?" / "Como fecho o caixa?" — passo a passo do manual.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 14, ''),
	(160, 'man-admin-15-backup-e-armazenamento', 'Backup e armazenamento', 'backup e armazenamento admin', 'Administrador → Sistema → Backup → "Fazer backup agora".
Ative o backup automático e escolha a frequência e a retenção.
Para restaurar, escolha o backup no histórico e confirme com sua senha de administrador.
Confira o uso do Drive: até 70% normal, 70–90% atenção, acima de 90% crítico.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'secao', 15, 'Drive cheio: backups e fotos podem falhar.
A conferência de integridade aponta duplicidades, estoque negativo, caixa esquecido aberto e vendas paradas na contingência.'),
	(161, 'man-admin-16-ocorrencias', 'Ocorrências', 'ocorrências admin', 'Você trata direto pelo mural Notificações, no cartão "⚠️ Ocorrências abertas" → botão "Tratar".
A tela completa (com filtro Abertas/Todas) continua em Administrador → Painel → Ocorrências.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 16, ''),
	(162, 'man-admin-17-ajustes-pos-venda-reembolso-credito-cort', 'Ajustes pós-venda (reembolso, crédito, cortesia)', 'ajustes pós-venda (reembolso, crédito, cortesia) admin', 'Administrador → Financeiro → Ajustes pós-venda.
Busque a venda (nº do pedido, nome ou telefone) — só aparecem pedidos já entregues.
Escolha o tipo (Reembolso em dinheiro, Crédito para próxima compra, Cortesia ou Desconto retroativo), o valor e o motivo.
Em reembolso e desconto retroativo, escolha se o dinheiro sai do caixa (o caixa precisa estar aberto) ou fora dele.
Toque em "Registrar ajuste". Para desfazer, use "cancelar" na lista, com o motivo.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'secao', 17, 'A venda original NÃO muda. No DRE o ajuste aparece como "Ajustes pós-venda".
Crédito não reduz o resultado na hora: quando o cliente usar, aplique como desconto no Caixa.
Reembolso e desconto retroativo não passam do valor da venda (somando ajustes já feitos).'),
	(163, 'man-admin-18-desenvolvedor-exclusivo', '🛠️ Desenvolvedor (exclusivo)', '🛠️ desenvolvedor (exclusivo) admin', 'Esta seção só aparece para quem entrou com acesso de nível Desenvolvedor (e sem "Ver como"). Ninguém mais vê.
Barra "Modo Desenvolvedor — vendo o sistema como:". Escolha um perfil (Operador, Garçom, Cozinha, Entregador) ou uma PESSOA específica e a tela muda para a dela. Suas ações continuam com acesso total.
Voltar para a visão normal: selecione "Admin (visão normal)".
Comandos exclusivos no balão: "atualizar código" envia o index.html desta página, "enviar apps script" abre o seletor de arquivos .gs, "analise o index.html" / "analise o apps script" roda a auditoria, "o que mudou" compara blocos entre versões, "testar ajuda" roda o auto-teste dos manuais.
Auto-teste da Ajuda (também no console): testarAjuda_() — valida os 6 manuais em sequência e devolve o resultado.
Painel de uso da IA: dentro do balão de status (✨) → "Uso da IA".
Diagnóstico do sistema: Administrador → Sistema → Sincronização e contingência → "Conferência de integridade". Somente leitura.
Ao criar/editar usuário Desenvolvedor: você cria como qualquer outro, mas depois de criado o acesso fica travado. Nem você nem ele excluem. Só o próprio Desenvolvedor edita a senha.
Se um funcionário comum tentar um comando de Dev no balão, o servidor recusa (checagem dupla).', '{Desenvolvedor}', false, '2026-10-09 10:20:59.387621+00', 'lista', 18, ''),
	(164, 'man-admin-19-i-sobre-o-sistema', 'ℹ️ Sobre o sistema', 'ℹ️ sobre o sistema admin', 'A Ajuda é atualizada junto com o sistema. Se algum passo aqui não bater com a tela, recarregue a página (Ctrl+Shift+R no computador, ou feche e reabra o app no celular).
Para dúvida ou problema: use o balão de atendimento (canto da tela) ou fale com o responsável técnico.
O app registra erros de JavaScript deste aparelho e envia para o Supabase (com o login de quem estava usando). Nada de dado pessoal de cliente sai por esse caminho.', '{Admin}', false, '2026-10-09 10:20:59.387621+00', 'lista', 19, ''),
	(166, 'err-admin-02-supabase-fora-do-ar-faixa-laranja', 'Supabase fora do ar (faixa laranja)', 'supabase fora do ar (faixa laranja)', 'Modo reserva automático: o app para o tempo real, volta às atualizações de 3 min, abre o cartão "Pedidos na reserva" em Pedidos e libera o Caixa para registrar venda na contingência. Ao voltar, a fila é reenviada e as vendas da contingência são reconciliadas sozinhas.', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'erro', 101, ''),
	(167, 'err-admin-03-sua-sessao-expirou', '"Sua sessão expirou"', '"sua sessão expirou"', 'Entre de novo. Itens que estavam na fila viram "com erro" e voltam pelo botão "na fila" no topo → "Tentar de novo".', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'erro', 102, ''),
	(169, 'err-admin-05-pedido-duplicado', 'Pedido duplicado', 'pedido duplicado', 'Duplo toque ou internet lenta não duplicam. Se o cliente fez dois pedidos de verdade, cancele um: Caixa → "Lançamentos desde a abertura" → excluir, motivo "Pedido duplicado".', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'erro', 104, ''),
	(186, 'man-entregador-06-registrar-um-problema-ocorrencia', 'Registrar um problema (Ocorrência)', 'registrar um problema (ocorrência)', 'No cartão do pedido, toque em “⚠️ Ocorrência”.
Escolha o tipo, descreva o que aconteceu e confirme.
O Administrador e o Operador são avisados. Use para cliente ausente, endereço errado ou problema na entrega.', '{Entregador}', true, '2026-10-09 10:18:49.28704+00', 'secao', 6, ''),
	(230, 'man-admin-05-premios-fidelidade-e-indicacao', 'Prêmios: fidelidade e indicação', 'prêmios: fidelidade e indicação, o caixa precisa estar aberto, "nenhum prêmio cadastrado", as indicações pendentes também aparecem ', 'Marque os produtos que podem ser prêmio em Produtos → Produtos, combos e adicionais → Editar → "🎁 Este produto é um prêmio".
Clientes → toque no cliente. Com as 10 marcas do cartão, ou com uma indicação pendente, aparece o prêmio para escolher e o botão "🎁 Resgatar prêmio" (ou "Resgatar indicação").
Confirme. O cartão zera (ou a indicação é marcada), o estoque do produto baixa e o custo entra no financeiro. O cliente não paga nada.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'secao', 5, 'O caixa precisa estar aberto: o prêmio fica registrado no turno.
"Nenhum prêmio cadastrado": nenhum produto ativo está marcado como prêmio daquele tipo.
As indicações pendentes também aparecem em 🔔 Avisos (no Assistente).'),
	(231, 'man-admin-06-qr-code-das-mesas', 'QR Code das mesas', 'qr code das mesas, o endereço do site está fixo nos qr', 'Administrador → Loja e equipe → Mesas e QR Codes → "📲 QR Codes das mesas".
Escolha a mesa e toque em "🖨️ Imprimir esta mesa" (ou "Imprimir todas"). Também dá para "⬇️ Baixar PNG".
Plastifique e deixe na mesa. O cliente pede pelo celular e você aceita o pedido em Pedidos.
Se alguém espalhar o QR, use "🔄 Gerar novo código" e imprima o QR novo daquela mesa.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'secao', 6, 'O QR usa o endereço do site em que o sistema está publicado — se o endereço mudar, é preciso imprimir de novo.'),
	(232, 'man-admin-07-cardapio-digital-promocoes-e-eventos', 'Cardápio Digital, promoções e eventos', 'cardápio digital, promoções e eventos', 'Cardápio Digital: escolha o que aparece para o cliente, destaques, ordem e frase de abertura. "Mais Pedidos" é automático.
Se o cliente pedir mais de 1 lanche com adicionais, os adicionais valem para todos — o cardápio avisa.
O cliente pode escrever uma observação em cada item; ela aparece na comanda da cozinha e no pedido.
Item "Esgotado": se "bloquear venda sem estoque" estiver ligado (Produtos → Estoque), o cardápio mostra "Esgotado" no que o estoque não cobre.
No celular, "Mais pedidos", "Destaques" e cada categoria rolam para o lado. O cliente toca no botão vermelho "+" para adicionar e na foto para ver o item ampliado. O botão redondo de balão abre o Atendimento.
Na entrega, o endereço vem com rua e bairro preenchidos pela localização do cliente (só se ele permitir). O número da casa é sempre digitado por ele e o pedido não segue sem ele.
O cardápio abre rápido porque guarda cópia no aparelho do cliente. Mudanças suas aparecem em instantes.
O cardápio só recebe pedidos com o caixa aberto; fechado, aparece "Estamos fechados no momento".
Promoções: cupons. Eventos: custos e recebimentos por evento. Custos e Precificação: simulador de preço ("Aplicar como preço base" vale para todas as formas de pagamento).
Abrir ou fechar o cardápio: use o botão "🌐 Cardápio aberto" em Início ou no Caixa. Um toque fecha (com mensagem opcional para o cliente) e outro reabre, sem fechar o caixa. Pedido de mesa por QR Code continua valendo.
Dados do restaurante: nome, endereço, telefone, horário e redes sociais (texto livre) aparecem no rodapé do cardápio do cliente e nas mensagens de WhatsApp e relatórios.
Cupom progressivo: em Promoções → novo cupom, tipo "Progressivo (por faixa)", uma faixa por linha (ex.: "50 5" e "100 10" = R$ 5 a partir de R$ 50 e R$ 10 a partir de R$ 100). Vale a maior faixa alcançada, contando só os itens (sem taxa de entrega).', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 7, ''),
	(233, 'man-admin-08-caixa-abrir-vender-e-fechar', 'Caixa: abrir, vender e fechar', 'caixa: abrir, vender e fechar, "abra o caixa antes de registrar uma ven, "a soma dos pagamentos precisa bater com, desconto nunca pode zerar a venda; no ca', 'Aba Caixa → "Abrir caixa" e informe o fundo de troco.
Em "Iniciar venda": 1. Cliente → 2. Itens → 3. Pagamento e finalizar.
Na etapa 3, escolha 58mm, 80mm ou A4 e toque em Imprimir, Copiar ou WhatsApp.
Para encerrar, feche o caixa, informe o dinheiro contado e confira a diferença.
Mesas: o botão "🍽️ Mesas" mostra todas as mesas e quem pediu a conta.
Pedido de mesa no Caixa: "Pagar ao sair" deixa na conta; "Pagar agora" cobra na hora.
Imprimir o pedido: em Pedidos, nos cartões de Retirada e de Mesa, o botão "🖨️ Imprimir pedido da retirada" (ou "da mesa") imprime o cliente, os itens, o total e se já está pago ou se é para cobrar. Nas entregas, "🖨️ Imprimir para o entregador" traz também o endereço. O botão só aparece depois que o pedido foi aceito. O tamanho do papel dessas três impressões se escolhe em Pedidos → Entregas ("Papel da impressão").
Se a forma de pagamento tem acréscimo (ex.: iFood), o Caixa mostra o valor a mais e já soma no total e no comprovante. Em pagamento dividido, o acréscimo vale só para a parte paga naquela forma.
Para dividir o pagamento, marque "Dividir pagamento" na etapa 3. "↺ Repetir última venda" recarrega o carrinho anterior.
Caixa vencido: se o caixa passou do corte, venda nova, sangria e resgate de prêmio ficam bloqueados. Use "Fechar caixa vencido" no fim da tela do Caixa (veja "Caixa vencido").
Se houver pagamento do Mercado Pago a decidir, aparece uma faixa discreta no Caixa (veja "Mercado Pago").', '{Admin}', true, '2026-10-17 09:27:56.719023+00', 'secao', 8, '"Abra o caixa antes de registrar uma venda".
"A soma dos pagamentos precisa bater com o total".
Desconto nunca pode zerar a venda; no Caixa pede a sua senha.'),
	(234, 'man-admin-09-modo-emergencia-planilha-fora-do-ar', 'Modo emergência (servidor fora do ar)', 'modo emergência (planilha fora do ar)', 'Só funciona no mesmo aparelho em que você já fez login normal ao menos uma vez nos últimos 30 dias. Cada login novo renova o prazo.
Quando o sistema não consegue falar com o servidor (Supabase), aparece a pergunta: "Entrar em MODO EMERGÊNCIA como [seu login]?". A senha é conferida no aparelho.
O que dá: registrar venda de retirada/entrega pela contingência, usando o catálogo da última sincronização. Sem mesa, sem desconto.
O que NÃO dá: abrir/fechar caixa, cancelar, receber pagamento, mexer em estoque, ver financeiro.
Um aviso laranja fixo no topo mostra "MODO EMERGÊNCIA". Um vigia testa o servidor a cada 30 s. Assim que ele responde, o app pede login de novo.
Errar a senha 5 vezes no modo emergência bloqueia por 5 minutos.', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'lista', 9, ''),
	(235, 'man-admin-10-contingencia-e-modo-reserva', 'Contingência e modo reserva', 'contingência e modo reserva', 'O Supabase é o servidor principal; a planilha principal é a reserva e a planilha de contingência é o último recurso. Se o Supabase cai, o modo reserva segura o app e a contingência segura o cardápio e as vendas.
No modo reserva: faixa laranja no topo e cartão "Pedidos na reserva (somente consulta)" em Pedidos. Mostra o que estava em andamento no último espelho e o que entrou na fila da contingência.
Ao voltar, o Admin recebe sozinho as vendas da contingência. Falhas ficam na tela de Contingência.
Tempo real (WebSocket) e modo reserva são automáticos.
Administrador → Sistema → Sincronização e contingência: mostra o uso de espaço da planilha de contingência, "🔄 Sincronizar espelho agora" e "⬇️ Trazer vendas pendentes da contingência".
O espelho da contingência (cardápio, preços, clientes e pedidos em andamento) se atualiza sozinho a cada 10 minutos e por completo todo dia às 3h. Não há nada para ligar.', '{Admin}', true, '2026-10-11 16:31:19.325087+00', 'lista', 10, ''),
	(236, 'man-admin-11-fila-de-envio-e-erros-de-sincronizacao', 'Fila de envio e erros de sincronização', 'fila de envio e erros de sincronização', 'Itens como cadastro de cliente, fidelidade, feedback e ocorrência podem ficar guardados no aparelho quando a internet cai. Aparece o botão "na fila" no topo.
Toque nele para ver estado, tentativas e motivo. Você pode tentar de novo, descartar ou enviar agora.
Venda, pagamento, sangria, cancelamento e estoque NUNCA ficam na fila.
Se a sessão expirar com itens na fila, eles viram "com erro" e voltam só quando alguém entrar de novo e tocar em "Tentar de novo".', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'lista', 11, ''),
	(237, 'man-admin-12-localizacao-do-entregador', 'Localização do entregador', 'localização do entregador', 'No cartão da entrega, se o status for "Saiu para entrega" e houver entregador atribuído, aparece "📍 Ver localização".
Abre um mapa embutido (Leaflet local) e um botão "Abrir no mapa".
A posição só existe se o entregador estiver com o app aberto e GPS permitido. O envio é a cada ~18 s e só enquanto houver entrega em "Saiu para entrega".
O cliente vê apenas a distância aproximada.', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'lista', 12, ''),
	(238, 'man-admin-13-balao-de-atendimento-e-assistente-de-ia', 'Balão de atendimento e assistente de IA', 'balão de atendimento e assistente de ia', 'No canto da tela tem um botão único. Para o cliente, é o atendimento. Para funcionário logado, é o assistente.
Dentro do assistente há duas abas: "✨ Conversa" (perguntas à IA e atendimento de clientes) e "🔔 Avisos" (o que antes ficava em Notificações). O botão do canto mostra "🔔 n" quando há aviso.
Em Avisos aparecem só os itens que precisam de você, em grupos que se abrem ao toque: pedidos aguardando aceite, ocorrências, entregas com problema, contas vencidas, falhas do sistema, estoque baixo, cartão fidelidade quase completo, indicações pendentes, aniversariantes do mês e clientes inativos. O que está em dia fica numa linha só ("✅ Em dia: …").
Quais avisos aparecem para cada perfil se escolhe em Administrador → Loja e equipe → Configurar avisos. Botões como "Tratar" abrem a tela da ocorrência por cima.
Assistente (Admin e Operador, só leitura): escreva em português. Exemplos: "como faço uma venda?", "quanto tem de pão no estoque?", "tem cliente aguardando?", "qual produto vendeu mais hoje?".
Período: reconhece "hoje", "ontem", "7 dias", "30 dias", "mês". Pergunta de mês anterior avisa que os dados estão arquivados (veja Relatórios).
A IA é somente leitura. Não altera preço, não cancela, não muda status. Ela só responde assuntos do restaurante e nunca mostra senha nem dados de contato de clientes. O Operador recebe só o que é da função de Caixa.
Para o cliente, o balão é o atendente virtual: responde cardápio, preços, promoções, formas de pagamento e andamento do pedido (pelo celular dele). Se for problema, oferece "Falar com a equipe"; aí o chamado aparece para você no balão (aba Conversa).
Se a IA ficar sem cota ou fora do ar, o cliente continua vendo o botão para falar com a equipe, que não depende da IA.
Quando o Supabase cai (ou a IA falha seguidas vezes), o balão avisa e o sistema segue normal.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 13, ''),
	(239, 'man-admin-14-arquivamento-e-uso-do-banco', 'Arquivamento e uso do banco', 'arquivamento e uso do banco', 'Administrador → Sistema → Backup e espaço → bloco "Uso do Supabase".
Por padrão, vendas e caixas fechados com mais de 90 dias saem do Supabase e vão para a planilha (abas Arquivo_*), de madrugada. Você pode mudar a regra (90/60/30 dias) e forçar "Mandar para a planilha agora".
"Proteção de espaço": se o uso chegar a 90%, 95% ou 98% do limite (você escolhe), o sistema manda para a planilha as vendas e caixas já encerrados, mesmo com menos de 30 dias. O que tem menos de 1 dia, os pedidos em andamento e o caixa aberto nunca saem; só apaga o que a planilha confirmou. Verifica de hora em hora.
Relatórios e Visão Geral buscam esse arquivo automaticamente quando o período pedido é antigo.
Fotos: ficam no Google Drive principal, com cópia no Drive da contingência. É automático.
Em Backup e espaço, o botão "Simular" no arquivamento mostra quantos pedidos e caixas sairiam do Supabase, quantos ficam e se o resumo guardado confere com a planilha, sem mover nada. Ao anonimizar um cliente (LGPD), os pedidos dele arquivados na planilha também são limpos, de madrugada.', '{Admin}', true, '2026-10-17 09:27:56.719023+00', 'lista', 14, ''),
	(240, 'man-admin-15-exemplos-de-pergunta-ao-assistente', 'Exemplos de pergunta ao assistente', 'exemplos de pergunta ao assistente', '"Resumo de hoje" — faturamento, pedidos, ticket.
"Como estão as vendas comparadas com ontem?"
"Qual produto vendeu mais nos últimos 7 dias?"
"Em que horário vendemos mais?"
"Tem algo fora do normal?" — anomalias do dia.
"O que precisa comprar?" — sugestão de compras pelo consumo.
"Como cancelo uma venda?" / "Como fecho o caixa?" — passo a passo do manual.', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'lista', 15, ''),
	(241, 'man-admin-16-backup-e-armazenamento', 'Backup e armazenamento', 'backup e armazenamento, drive cheio, a conferência de integridade aponta dupl', 'Administrador → Sistema → Backup e espaço → "Fazer backup agora" (começa na hora, sem pergunta).
Ative o backup automático e escolha o horário e a retenção (por quantos dias guardar).
Para restaurar, escolha o backup no histórico e confirme com sua senha de administrador.
Para apagar um backup, toque em "Excluir" no histórico e confirme com a sua senha de administrador.
Se o backup ficou sem cópia no Drive, aparece o motivo e o botão "Enviar ao Drive" para tentar de novo. O backup tenta até 3 vezes sozinho.
Na mesma tela ficam "Uso do Supabase" (arquivamento) e "Google Drive" (espaço: até 70% normal, 70–90% atenção, acima de 90% crítico).', '{Admin}', true, '2026-10-11 16:31:19.325087+00', 'secao', 16, 'Drive cheio: backups e fotos podem falhar.
A conferência de integridade aponta duplicidades, estoque negativo, caixa esquecido aberto e vendas paradas na contingência.'),
	(242, 'man-admin-17-ocorrencias', 'Ocorrências', 'ocorrências', 'Você trata direto pelo Assistente: aba "🔔 Avisos" → "⚠️ Ocorrências abertas" → botão "Tratar".
A tela completa (com filtro Abertas/Todas) continua em Administrador → Hoje → Ocorrências.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 17, ''),
	(243, 'man-admin-18-ajustes-pos-venda-reembolso-credito-cortesia', 'Ajustes pós-venda (reembolso, crédito, cortesia)', 'ajustes pós-venda (reembolso, crédito, cortesia), a venda original não muda. no dre o ajus, crédito não reduz o resultado na hora, reembolso e desconto retroativo não pass', 'Administrador → Dinheiro → Reembolsos e ajustes.
Busque a venda (nº do pedido, nome ou telefone) — só aparecem pedidos já entregues.
Escolha o tipo (Reembolso em dinheiro, Crédito para próxima compra, Cortesia ou Desconto retroativo), o valor e o motivo.
Em reembolso e desconto retroativo, escolha se o dinheiro sai do caixa (o caixa precisa estar aberto) ou fora dele.
Toque em "Registrar ajuste". Para desfazer, use "cancelar" na lista, com o motivo.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'secao', 18, 'A venda original NÃO muda. No DRE o ajuste aparece como "Ajustes pós-venda".
Crédito não reduz o resultado na hora: quando o cliente usar, aplique como desconto no Caixa.
Reembolso e desconto retroativo não passam do valor da venda (somando ajustes já feitos).'),
	(244, 'man-admin-19-desenvolvedor-exclusivo', '🛠️ Desenvolvedor (exclusivo)', '🛠️ desenvolvedor (exclusivo)', 'Esta seção só aparece para quem entrou com acesso de nível Desenvolvedor (e sem "Ver como"). Ninguém mais vê.
Barra "Modo Desenvolvedor — vendo o sistema como:". Escolha um perfil (Operador, Garçom, Cozinha, Entregador) ou uma PESSOA específica e a tela muda para a dela. Suas ações continuam com acesso total.
Voltar para a visão normal: selecione "Admin (visão normal)".
Auto-teste da Ajuda (também no console): testarAjuda_() — valida os 7 manuais em sequência e devolve o resultado.
Painel de uso da IA (custo, erros e cota): dentro do balão (✨) → "Uso da IA". A IA de análise de código do Desenvolvedor foi retirada.
Diagnóstico do sistema: Administrador → Sistema → Sincronização e contingência → "Conferência de integridade". Somente leitura.
Ao criar/editar usuário Desenvolvedor: você cria como qualquer outro, mas depois de criado o acesso fica travado. Nem você nem ele excluem. Só o próprio Desenvolvedor edita a senha.
O servidor sempre confere o nível de quem pede; não adianta forçar "Ver como" para ganhar acesso.', '{Desenvolvedor}', true, '2026-10-16 03:03:49.796886+00', 'lista', 19, ''),
	(245, 'man-admin-20-sobre-o-sistema', 'ℹ️ Sobre o sistema', 'ℹ️ sobre o sistema', 'Versão em uso neste aparelho: v-etapa-13 — publicada em 09/10/2026.
A Ajuda é atualizada junto com o sistema. Se algum passo aqui não bater com a tela, recarregue a página (Ctrl+Shift+R no computador, ou feche e reabra o app no celular).
Esta versão inclui: aviso de pedido novo em segundos, modo reserva automático (Supabase), modo emergência (planilha), fila de envio para cadastros, confirmação de impressão da comanda + alerta "PEDIDO ALTERADO", localização do entregador, balão único com IA, arquivamento automático (por idade e por espaço), prêmios de fidelidade e indicação, atendente virtual no cardápio e backup com exclusão e reenvio ao Drive.
Para dúvida ou problema: use o balão de atendimento (canto da tela) ou fale com o responsável técnico.
O app registra erros de JavaScript deste aparelho e envia para o Supabase (com o login de quem estava usando). Nada de dado pessoal de cliente sai por esse caminho.', '{Admin}', true, '2026-10-09 10:20:30.45071+00', 'lista', 20, ''),
	(251, 'man-admin-90-buscar', 'Buscar (lupa no topo)', 'buscar busca lupa cliente pedido produto linha do tempo', 'Toque na lupa 🔍 no topo, digite pelo menos 2 letras ou números e veja clientes (nome sem precisar de acento, ou telefone), pedidos (número, nome ou telefone do cliente) e produtos/combos.
No cliente, toque em "abrir". No pedido, toque em "ver pedido completo": aparece a Linha do tempo (feito, aceito, pronto, saiu, entregue e o tempo de cada etapa).', '{Admin}', true, '2026-10-09 16:18:22.325986+00', 'lista', 90, ''),
	(252, 'man-operador-90-buscar', 'Buscar (lupa no topo)', 'buscar busca lupa cliente pedido produto linha do tempo', 'Toque na lupa 🔍 no topo, digite pelo menos 2 letras ou números e veja clientes (nome sem precisar de acento, ou telefone), pedidos (número, nome ou telefone do cliente) e produtos/combos.
No cliente, toque em "abrir". No pedido, toque em "ver pedido completo": aparece a Linha do tempo (feito, aceito, pronto, saiu, entregue e o tempo de cada etapa).', '{Operador}', true, '2026-10-09 16:18:22.325986+00', 'lista', 90, ''),
	(253, 'man-garcom-90-buscar', 'Buscar (lupa no topo)', 'buscar busca lupa cliente pedido produto', 'Toque na lupa 🔍 no topo e digite o nome do cliente, o número do pedido ou o nome de um produto. Você não vê valores nem telefone dos pedidos.', '{Garçom}', false, '2026-10-09 16:18:22.325986+00', 'lista', 90, ''),
	(254, 'man-cozinha-90-buscar', 'Buscar (lupa no topo)', 'buscar busca lupa pedido produto', 'Toque na lupa 🔍 no topo e digite o número do pedido, o nome do cliente ou o nome de um produto para achar um pedido rápido.', '{Cozinha}', false, '2026-10-09 16:18:22.325986+00', 'lista', 90, ''),
	(255, 'man-admin-91-baixar-csv-excel', 'Baixar para o Excel (CSV)', 'csv excel exportar baixar relatório vendas itens despesas planilha', 'Administrador → Dinheiro → Relatórios e DRE: escolha o período e toque em "Baixar este relatório (CSV)".
Em "Dados completos do período" baixe Vendas, Itens vendidos ou Despesas. Meses arquivados entram sozinhos (as despesas só se estiverem no app). O arquivo abre direto no Excel.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 91, ''),
	(256, 'man-operador-92-cep-e-filtros', 'CEP na entrega e filtros do histórico do cliente', 'cep endereço entrega viacep histórico cliente filtro', 'No Caixa, em Entrega, digite o CEP (opcional) para preencher rua e bairro; confira e digite o número.
No perfil do cliente, o histórico tem filtros de período, entrega/retirada e pago/a receber.', '{Admin,Operador}', true, '2026-10-09 16:27:54.399428+00', 'lista', 92, ''),
	(257, 'man-admin-93-compras-fornecedores', 'Compras, fornecedores e análises avançadas', 'compra comprei fornecedor picanha estoque custo despesa recebida pedido margem forma de pagamento dia da semana ano passado 90 dias 12 meses fardo embalagens unidades em cada não entra no estoque aviso laranja digitar item compra bebida', 'Compras e fornecedores (só Administrador): Administrador → Produtos → "Compras e fornecedores". Cadastre o fornecedor, depois registre a compra: itens do estoque (ou "outro item"), quantidade, unidade e valor total pago por item.
Compra "Recebida" soma no estoque e atualiza o custo médio do insumo; "Pedido" só guarda e você marca como recebida quando chegar. Toda compra recebida vira uma despesa (Paga ou A pagar, com vencimento).
Marque "saiu do caixa" só se o dinheiro saiu da gaveta. Compra recebida não é cancelada: corrija pelo estoque ou pela despesa. Pedido não recebido pode ser cancelado com motivo.
Assistente: diga "comprei 30kg de picanha do fornecedor X por R$ 900". A IA só monta um cartão; nada é gravado até tocar em "Confirmar e gravar". "Revisar na tela" permite ajustar antes. Fornecedor ou item não encontrado bloqueia o botão: cadastre antes.
Relatórios → "Análise avançada": margem líquida por forma de pagamento, vendas por dia da semana e comparação com o mesmo período do ano passado. Há também os períodos "Últimos 90 dias" e "Últimos 12 meses".
Ao marcar um pedido de compra como recebido, escolha "✅ Já paguei" ou "🕒 Vou pagar depois" (aí aparece o calendário do vencimento).', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 93, 'Compras e a gravação pela IA são só do Administrador e do Desenvolvedor.'),
	(258, 'man-admin-94-auditoria-ip', 'Auditoria e acessos (IP)', 'auditoria ip login acesso falha de login senha errada sessão quem entrou aparelho', 'Administrador → Sistema → Auditoria: lista ações sensíveis (descontos, cancelamentos, preços, estoque, usuários, compras), entradas no sistema ("Login") e tentativas com senha errada ("Falha de login").
Cada linha mostra quem fez, o perfil, o aparelho e o IP de origem. Use o período e a busca (nome, ação ou IP); mostra até 300 linhas.
Vários "Falha de login" seguidos do mesmo IP podem ser tentativa de adivinhar a senha: troque a senha do usuário e encerre as sessões dele.
O IP é apagado após 90 dias (o restante do registro fica). Em Usuários → sessões abertas, cada aparelho também mostra o IP da entrada.', '{Admin}', true, '2026-10-09 17:01:33.814217+00', 'lista', 94, 'Auditoria e IPs são só do Administrador e do Desenvolvedor.'),
	(259, 'man-admin-95-avisos-app-fechado', 'Avisos com o app fechado', 'aviso notificação push app fechado novo pedido cliente atendimento celular sino iphone', 'Toque no sino 🔔 do topo e em "Ligar avisos com o app fechado". Permita as notificações quando o navegador pedir.
Depois o celular avisa "Novo pedido" (do cardápio) e "Cliente no atendimento" mesmo com o app fechado ou a tela bloqueada. O aviso não mostra nome nem telefone do cliente.
No iPhone: abra no Safari, Compartilhar → "Adicionar à Tela de Início" e abra o app por esse ícone antes de ligar. No Android basta ligar.
Para desligar, toque no mesmo botão. Ao sair do sistema, o aparelho deixa de receber os avisos de quem saiu.', '{Admin,Operador}', true, '2026-10-09 17:07:16.519729+00', 'lista', 95, 'O som e a vibração do app aberto continuam como antes.'),
	(260, 'man-admin-96-modo-reserva', 'Modo reserva (quando o sistema cai)', 'modo reserva caiu fora do ar faixa laranja contingência supabase indisponível fila queda', 'Uma faixa laranja "Modo reserva" no topo avisa que o servidor principal está fora.
Funciona: venda do Caixa (retirada ou entrega, sem desconto e sem cupom), pedido do cardápio e consulta dos pedidos em Pedidos.
Na fila (seguem sozinhos na volta): cadastro de cliente, fidelidade, feedback e ocorrência. Não repita a ação.
Espera a volta (aparece "indisponível até o Supabase voltar" e nada é gravado): mudar status, estoque, compras, relatórios, avisos e Assistente. Anote à mão e lance depois.', '{Admin,Operador}', true, '2026-10-09 17:26:31.435849+00', 'lista', 96, 'Quando a faixa sumir, confira se os pedidos feitos na queda aparecem em Pedidos.'),
	(261, 'man-admin-97-saude-sistema', 'Saúde do sistema', 'saúde sistema conexão servidores backup conferência vendas tarefas automáticas bolinha verde vermelha', 'A "Saúde do sistema" fica dentro de "Conexão e servidores": toque na bolinha colorida do topo.
Lá aparecem os servidores e, logo abaixo, cada item: cópia para a planilha, backup (diário às 04:00), cópia no Drive, conferência diária de vendas, tarefas automáticas e Assistente.
A própria bolinha do topo muda de cor: verde = tudo certo, amarela = atenção, rosa = precisa de cuidado (se a conexão cair, ela fica vermelha ou laranja). Amarelo pede atenção; vermelho pede ação (ex.: backup com mais de 48 h ou vendas diferentes entre Supabase e planilha).
Desenvolvedor: o botão "Simular queda (treino)" fica em "Conexão e servidores" e finge a queda só neste aparelho. "Encerrar simulação" volta ao normal.', '{Admin}', true, '2026-10-09 17:26:31.435849+00', 'lista', 97, 'Só Admin e Desenvolvedor veem a Saúde do sistema.'),
	(262, 'man-admin-98-botao-abrir-fechar-cardapio', 'Abrir ou fechar o cardápio em um toque', 'abrir fechar cardápio botão cardápio fechado clientes pedir início caixa reabrir', 'Em Início e no Caixa há um botão discreto "🌐 Cardápio aberto".
Toque para fechar: o app pede uma mensagem opcional para o cliente. Os clientes deixam de conseguir pedir.
Quando estiver fechado o botão vira "🌐 Cardápio fechado"; toque para liberar.
O cardápio só recebe pedidos com o caixa aberto, mesmo reaberto.', '{Admin,Operador}', true, '2026-10-09 18:03:35.303879+00', 'lista', 98, 'Disponível para Administrador, Operador e Desenvolvedor.'),
	(263, 'man-admin-99-menu-de-baixo', 'Menu de baixo no celular', 'menu barra embaixo celular navegação abas início caixa pedidos mais bolinha vermelha', 'No celular, o menu fica fixo na parte de baixo da tela: Início, Caixa, Pedidos e as outras telas do seu perfil. A aba aberta fica em dourado.
Quando há mais telas do que cabem, aparece "Mais" com as demais. Uma bolinha vermelha avisa que há algo novo naquela aba.
No computador o menu continua no topo.', '{Admin,Operador}', true, '2026-10-09 18:47:29.517141+00', 'lista', 99, 'O botão do Assistente sobe um pouco para não ficar em cima do menu.'),
	(264, 'man-admin-100-endereco-cidades-entrega', 'Endereço de entrega (número e cidade)', 'endereço número casa cidade entrega cep localização distrito', 'No cardápio, o cliente preenche Rua e bairro, NÚMERO e CIDADE. A localização do celular e o CEP preenchem rua, bairro e cidade sozinhos.
Sem o número (ou "s/n") o pedido não é enviado.
No pedido, o endereço aparece como "Rua, Bairro, nº 123 — Cidade".', '{Admin}', true, '2026-10-09 21:45:20.546817+00', 'lista', 100, 'Se a localização preencher a cidade errada, o cliente pode corrigir no campo Cidade.'),
	(265, 'man-admin-101-contas-e-acessos', 'Contas e acessos', 'contas acessos email senha link supabase github planilha apps script cofre ver senha chave ia gemini groq nvidia cloudflare reserva', 'Administrador → Sistema → Integrações e contas: lista das contas do sistema (Supabase, GitHub, planilhas…) com e-mail, link e observação.
"+ Nova conta" cadastra; "Editar" muda os dados ou a senha; "Excluir" apaga a conta e a senha guardada.
A senha fica no cofre criptografado do Supabase. Para ver, toque em "Ver senha" e digite a SUA senha de administrador; ela aparece por 30 segundos e fica registrado na Auditoria.
Chaves das IAs (Gemini, Groq, NVIDIA e Cloudflare): na mesma tela. "Ver chave" e "Trocar chave" pedem a senha de administrador; a chave nova vale na hora. NVIDIA e Cloudflare são IAs de reserva: sem chave, nada muda; com chave, entram quando o Gemini e a Groq falham ou esgotam o limite grátis.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 101, 'Nunca mande senhas por mensagem: digite direto nesta tela.'),
	(266, 'man-admin-102-avisos-cliente', 'Avisos do pedido para o cliente e feedbacks', 'aviso notificacao celular cliente status pedido confirmado pronto saiu entrega entregue como foi seu pedido feedback chat origem', 'O cliente que aceita os avisos (convite no topo do cardápio ou no cartão "Pedido enviado") recebe no celular: confirmado (Em preparo), pronto (só retirada), saiu para entrega, entregue/retirado e cancelado.
O aviso sai sozinho quando a equipe muda o status. Mostra só o número do pedido, nunca nome, telefone ou endereço.
30 minutos depois de entregue (até 3 horas) chega "Como foi seu pedido?", se o cliente ainda não deu feedback daquele pedido.
Em Hoje → Feedbacks aparece de onde veio: "veio pelo aviso do pedido", "veio pelo chat" ou sem marca (rodapé).', '{Admin,Operador}', true, '2026-10-16 03:03:49.796886+00', 'lista', 102, 'Pedido de mesa (QR Code) não recebe aviso. No iPhone o cliente precisa instalar o app (Adicionar à Tela de Início).'),
	(267, 'man-admin-102-integracoes', 'Integrações: iFood e Nota fiscal', 'integrações ifood nota fiscal nfce focus ligar desligar interruptor chaves guia checklist', 'Administrador → Sistema → Integrações e contas → cartão "Integrações": o iFood e a Nota fiscal já vêm prontos no sistema, mas DESLIGADOS. Desligado, o sistema funciona exatamente como antes.
Cada integração tem um guia passo a passo na própria tela e um checklist. Só dá para ligar quando todos os passos estiverem prontos; ligar pede a senha de administrador.
As chaves são digitadas só nesta tela, ficam guardadas com segurança e só aparecem com a sua senha. Nunca envie chaves por mensagem.
Para desligar, toque em "Desligar" e confirme com a senha: o sistema volta a funcionar como antes, e o que já foi gravado fica guardado.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 102, 'Só Administrador e Desenvolvedor veem esta tela.'),
	(268, 'man-admin-103-ifood', 'iFood: pedidos, itens ligados e simulação', 'ifood pedido itens ligar ligação produto sem ligação reprocessar simulação teste confirmar', 'Com o iFood ligado (Integrações e contas → Integrações), os pedidos entram sozinhos como venda normal, com a marca "iFood #número", aviso no celular e baixa dos ingredientes.
Itens do iFood: cada item do cardápio do iFood precisa ser ligado a um produto do sistema (Integrações e contas → Integrações → Itens do iFood). O sistema sugere pelo nome; você confirma. Item sem ligação entra no pedido mesmo assim, com o aviso "SEM LIGAÇÃO"; depois de ligar, toque em "Refazer pedidos sem ligação".
O andamento (em preparo, pronta, saiu para entrega) é avisado ao iFood automaticamente quando você muda o status do pedido. Se o iFood não confirmar uma ação, aparece um alerta na lista de pedidos do iFood.
Desenvolvedor: "Simular pedido do iFood (treino)" cria um pedido de mentira, sem enviar nada ao iFood; cancele a venda depois do treino.
Valor da venda: a venda grava o que fica para a loja — itens menos o desconto que a loja paga, mais a taxa de entrega só quando a loja entrega. Cupom pago pelo iFood e a taxa de serviço do iFood ficam fora. Entregador do iFood: o pedido mostra "ENTREGA PELO iFOOD" e "Saiu para entrega" não é enviado ao iFood.
Pedido do iFood cancelado não gera reembolso para a loja devolver: quem devolve ao cliente é o iFood.', '{Admin,Operador}', true, '2026-10-16 03:03:49.796886+00', 'lista', 103, 'Itens do iFood e simulação: só Administrador/Desenvolvedor.'),
	(269, 'man-admin-104-ifood-operacao', 'iFood: negociação de cancelamento e loja', 'ifood cancelamento negociação reembolso aceitar recusar alternativa pausar loja abrir fechar', 'Quando o cliente pede cancelamento ou reembolso no iFood, a equipe recebe um aviso no celular. Abra Integrações e contas → Integrações → iFood → "Negociações": veja o pedido e o prazo, e toque em Aceitar, Recusar ou, quando houver, em uma alternativa. Se o prazo acabar, o iFood decide.
Loja no iFood: o mesmo cartão tem os botões "Pausar 30 min / 1 h", "Retomar", "Fechar" e "Abrir". Com o ajuste "Abrir e fechar a loja no iFood junto com o caixa" ligado, abrir o caixa abre a loja e fechar o caixa fecha.
O painel de Saúde mostra se a loja está aberta ou indisponível no iFood.', '{Admin,Operador}', true, '2026-10-16 03:03:49.796886+00', 'lista', 104, 'Pausar, abrir e fechar: Administrador e Operador.'),
	(270, 'man-admin-105-ifood-inteligencia', 'iFood: preços, estoque, repasses, avaliações e relatório', 'ifood preço importar enviar desfazer pausar estoque repasse receber comissão avaliação relatório canal margem imposto', 'Preços (Integrações → iFood → Preços): "Importar cardápio" traz os preços do iFood; a tabela mostra preço no sistema × preço no iFood × diferença. "Gravar no sistema" grava o preço do iFood no campo "Preço no iFood". "Enviar ao iFood" só funciona com o ajuste "Enviar nossos preços ao iFood" ligado, bloqueia variações acima do limite e guarda histórico com botão Desfazer.
Pausa por estoque: com o ajuste ligado, o item some do iFood quando um ingrediente acaba e volta quando repõe.
Financeiro: mostra quanto falta receber do iFood (pedidos pagos no app ainda sem repasse, já sem a comissão), os repasses recebidos e a comissão real. Comissão: cadastre o % do iFood em Vendas e cardápio → Formas de pagamento, forma "iFood"; ela entra nas taxas de cada pedido e é trocada pela comissão real quando o repasse chega.
Avaliações: as notas do iFood aparecem aqui e em Feedbacks; nota baixa avisa a equipe; você responde pelo painel.
Relatório por canal: vendas, ticket, margem (já sem custo, taxas e comissão e imposto estimado) e cancelamentos de balcão, cardápio e iFood.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 105, 'Só Administrador.'),
	(271, 'man-admin-106-fiscal-cadastro', 'Nota fiscal: dados da empresa e perfis fiscais', 'nota fiscal nfc-e cadastro fiscal perfil ncm csosn cfop contador cnpj csc imposto simples', 'Integrações e contas → Integrações → Nota fiscal → "Dados fiscais": preencha razão social, CNPJ, inscrição estadual, endereço, código do município (7 números), regime, número do CSC e a alíquota efetiva do Simples (o contador informa). O código secreto do CSC é digitado no botão do próprio cartão, nunca por mensagem.
Perfis fiscais: cada perfil reúne NCM, CFOP e CSOSN (ou CST). Crie poucos (ex.: Lanches, Bebidas, Sobremesas), marque um como padrão e ligue categorias/itens que sejam exceção. "Itens sem perfil" lista o que ainda falta.
Planilha do contador: "Baixar planilha" gera um arquivo com todos os produtos; o contador preenche perfil, NCM, CSOSN e CFOP, e "Enviar planilha" aplica tudo de uma vez.
A alíquota dos dados fiscais é a padrão do imposto estimado; a de cada mês fica em Dinheiro → Relatórios e DRE, cartão DRE (veja "Imposto sobre vendas"). O imposto aparece no resultado com ou sem a nota fiscal ligada.', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 106, 'Só Administrador.'),
	(272, 'man-admin-107-nfce-emissao', 'Nota fiscal: emissão automática, CPF na nota e lista de notas', 'nota fiscal nfc-e emitir emissão cpf rejeitada reemitir danfe focus lista notas contingência', 'Com a nota fiscal ligada (Integrações e contas → Integrações → Nota fiscal), cada venda do canal escolhido gera a nota sozinha: ao pagar (balcão) ou na entrega (delivery/iFood). A nota sai cerca de 1 minuto depois da venda, para dar tempo de informar o CPF.
CPF na nota: só se o cliente pedir. No Caixa, antes de finalizar, digite o CPF no campo "CPF na nota". Depois que a nota sai não dá mais para incluir.
Lista "Notas fiscais": filtre por situação (autorizada, rejeitada, pendência, em contingência). Se uma nota foi rejeitada, o texto explica o motivo em português; corrija (ex.: perfil fiscal do produto) e toque em "Reemitir". "Abrir DANFE" mostra o cupom com QR Code; "Enviar ao cliente" abre o WhatsApp com o link.
Nunca é emitida nota de item sem perfil fiscal: a nota fica como pendência até você definir o perfil.
Desenvolvedor: "Nota de treino" cria uma nota de mentira, sem falar com a Focus.', '{Admin,Operador,Garçom}', true, '2026-10-16 03:03:49.796886+00', 'lista', 107, 'Lista de notas e reemissão: só Administrador. CPF na nota: quem faz a venda.'),
	(273, 'man-admin-108-nfce-fechamento', 'Nota fiscal: cancelamento, numeração pulada, conferência e pacote do contador', 'nota fiscal nfc-e cancelar cancelamento inutilizar inutilização conferência vendas sem nota pacote contador limite plano 500', 'Cancelamento: se você cancela uma venda que já tem nota, o sistema cancela a nota sozinho desde que sejam menos de 30 minutos da emissão. Passou do prazo, a nota fica marcada "cancelamento para o contador orientar" (nada é apagado) e aparece na Saúde do sistema.
Conferência (Integrações → Nota fiscal → Conferência): lista as vendas que deveriam ter nota e não têm (com botão Emitir), notas com problema e números pulados. Para número pulado, toque em Inutilizar (pede sua senha) e informe o motivo.
Pacote do contador: escolha o mês e baixe a planilha com número, série, chave, valor e situação de cada nota, mais a lista de links dos XML. A Focus também baixa todos os XML do mês no painel dela.
Limite do plano: a tela mostra quantas notas já foram emitidas no mês (plano de 500); a 80% aparece um aviso na Saúde do sistema.', '{Admin}', true, '2026-10-11 05:34:21.230964+00', 'lista', 108, 'Só Administrador.'),
	(274, 'man-admin-99-assistente-grava-mais', 'Assistente: registrar coisas pelo chat', 'assistente ia registrar lançar despesa pagar estoque entrada perda inventário contagem ingrediente cliente ocorrência sangria compra receber cancelar ajuste pós-venda brinde confirmar cartão', 'Peça em frase normal, por exemplo: "comprei 3 kg de farinha do fornecedor X por R$ 20", "perdi 2 kg de farinha", "paguei R$ 120 de luz", "contei 12 kg de açúcar", "sangria de R$ 50 para troco".
O Assistente nunca grava sozinho: aparece um cartão com o que será gravado. Se faltar algo ou não achar o nome, o cartão avisa em laranja e o botão Confirmar fica travado.
Toque em "Confirmar e gravar" para gravar ou em "Descartar" para não gravar nada.
Pode registrar: compra, receber ou cancelar pedido de compra, fornecedor, despesa nova, pagar despesa, cancelar despesa, entrada/perda/contagem de estoque, cadastrar ou editar ingrediente, cliente, ocorrência, sangria, ajuste pós-venda e brinde.
Cancelar despesa e ajuste pós-venda pedem a senha de administrador no cartão.
Nunca pelo Assistente: excluir qualquer coisa, cancelar ou editar venda, abrir ou fechar caixa, usuários e senhas, contas e acessos, preços, cardápio e configurações. Faça nas telas.', '{Admin}', true, '2026-10-11 05:34:30.809322+00', 'lista', 99, 'Só Administrador e Desenvolvedor. Sangria e despesa do caixa exigem o caixa aberto.'),
	(275, 'man-admin-98-reembolsos', 'Reembolsos de vendas canceladas', 'reembolso reembolsos devolver devolução estorno venda cancelada paga pix dinheiro cartão pendente devolvido', 'Cancelou uma venda que já estava paga? O sistema cria sozinho um reembolso pendente.
Administrador → Dinheiro → Reembolsos e ajustes → "Reembolsos de vendas canceladas".
Devolva o dinheiro ao cliente (Pix, dinheiro ou estorno no cartão).
Toque em "marcar devolvido" e, se quiser, toque em como foi devolvido (Pix, Dinheiro ou Estorno no cartão).', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 98, 'Só o Administrador marca como devolvido; o Operador consegue ver a lista. Venda cancelada que ainda não estava paga não gera reembolso. Pedido do iFood cancelado não gera reembolso: quem devolve ao cliente é o iFood.'),
	(276, 'man-admin-97-listas-acoes', 'Listas: onde ficaram editar, entrada, perda e excluir', 'editar excluir entrada perda inventário desativar ativar botão sumiu três pontinhos ⋯ lista estoque produtos combos usuários ações assistente max botão redondo modo desenvolvedor recolher', 'Nas listas de Estoque, Produtos, Combos e Usuários, toque na linha (ou no ⋯ no fim dela).
Abre uma janela com as ações: Editar, Entrada, Perda, Inventário, Excluir (no estoque) ou Editar, Desativar/Ativar, Excluir (nos usuários).
No produto e no combo, tocar na linha já abre a edição; o ⋯ mostra também Excluir.
O botão do Assistente é o rosto do Max, redondo, no canto de baixo; os avisos aparecem no número 🔔 dele.
Entrada, perda e inventário abrem uma janela só, com a quantidade e o motivo juntos. Na perda, toque num motivo pronto (Estragou, Venceu…) ou escreva o seu.', '{Admin}', true, '2026-10-11 16:31:19.325087+00', 'lista', 97, 'A caixa do Modo Desenvolvedor fica recolhida numa linha; toque em ▸ para abrir.'),
	(277, 'man-admin-109-imposto-vendas', 'Imposto sobre vendas (estimado) e DAS', 'imposto alíquota aliquota simples das dre resultado margem lucro estimado contador taxa de entrega imposto das vendas', 'Administrador → Dinheiro → Relatórios e DRE → cartão "DRE e relatório mensal": escolha o mês e, em "Imposto sobre vendas deste mês", digite a alíquota que o contador informar (ex.: 6 ou 6,5) e toque em Salvar.
A alíquota vale para aquele mês e para os seguintes, até salvar outra. Mês sem alíquota própria usa a do mês anterior mais próximo; sem nenhuma, usa a dos dados fiscais da empresa.
O imposto é calculado sobre tudo o que foi faturado no mês (vendas e eventos) e aparece no DRE, na Visão Geral (IMPOSTOS), nos relatórios e na margem do cadastro de produto, de combo e da Calculadora. Funciona com ou sem a nota fiscal ligada. O custo do produto não muda.
DAS: lance o pagamento como despesa na categoria "Imposto das vendas (DAS)". Com alíquota cadastrada, ele não entra de novo nas despesas (o imposto já foi estimado); o DRE mostra quanto foi pago para comparar. Sem alíquota, o DAS entra como despesa comum.
O DRE mostra também a linha "Taxa de entrega e acréscimos cobrados": a taxa cobrada do cliente entra na receita e o repasse ao entregador entra nas despesas (Entregadores).', '{Admin}', true, '2026-10-16 03:03:49.796886+00', 'lista', 109, 'Só o Administrador vê e altera a alíquota. É uma estimativa; o valor oficial é o DAS calculado pelo contador.'),
	(278, 'man-admin-110-computador', 'No computador (notebook ou monitor)', 'computador notebook monitor pc tela grande menu lateral topo abas pedidos lado a lado caixa carrinho direita milhar', 'Em tela a partir de 900 px de largura, o topo fica numa linha só (logo à esquerda, usuário e botões à direita) e as abas ficam sempre à vista no alto, mesmo rolando a página.
Administrador: as telas aparecem num menu ao lado, com os 6 grupos abertos (Hoje, Dinheiro, Produtos, Vendas e cardápio, Loja e equipe, Sistema). O campo "Ir para…" no topo do menu acha uma tela pelo nome. Um clique abre a tela; se o menu não couber, role dentro dele. Para o Operador, a aba Operação mostra Ocorrências e Feedbacks no menu ao lado.
Pedidos: os pedidos ficam lado a lado (2 ou 3 por linha). Caixa: a escolha fica à esquerda; carrinho, total e pagamento ficam à direita.
Valores aparecem com ponto de milhar (R$ 1.475,90) e o negativo com o sinal na frente (−R$ 3.691,11).', '{Admin,Operador}', true, '2026-10-17 09:27:56.719023+00', 'lista', 110, 'Todas as funções do celular existem no computador: o que muda é só a organização da tela.'),
	(279, 'man-admin-111-visitas-cardapio', 'Tela Início e visitas ao cardápio', 'visitas cardápio acessos clientes abriram contador início resumo alerta faixa mesas', 'No Início: alerta numa faixa fina no topo (só quando há algo), pedidos em andamento, caixa e vendas de hoje, visitas ao cardápio e mesas (com o valor a receber das mesas).
"Cardápio hoje" conta os clientes que abriram o cardápio eletrônico hoje: cada celular ou computador conta 1 vez por dia. Zera à meia-noite.
Aparelhos da equipe não contam: depois que alguém entra no sistema interno naquele aparelho, ele nunca mais conta.
É uma estimativa: a mesma pessoa em dois aparelhos conta duas vezes; aba anônima ou navegador limpo contam de novo.', '{Admin,Operador}', true, '2026-10-11 23:17:22.096614+00', 'lista', 111, 'Administrador e Operador veem as visitas.'),
	(280, 'man-admin-98-cupons-contas', 'Cupons: editar, só para conta, automáticos e conta do cliente', 'cupom editar cupons automáticos boas-vindas aniversário indique e ganhe indicação conta cliente google login só para conta cliente específico texto privacidade lgpd cnpj razão social aviso anonimizar baixar dados apagar conta', 'Em Promoções, toque em Editar em qualquer cupom para mudar valor, prazo, limite ou texto.
Cupom pode ser só para quem tem conta, só para um cliente (escolha na lista) e pode aparecer em Minha conta do cliente.
No cartão Cupons automáticos ficam boas-vindas, aniversário e indique e ganhe (quem indicou e quem foi indicado). Todos começam desligados: toque em Editar, ajuste e ligue.
Boas-vindas e indicado valem 1 vez por cliente. Pedido cancelado devolve o cupom.
O cliente entra com o Google (opcional) em Entrar, no topo do cardápio. O histórico e o cartão fidelidade se juntam à conta depois do primeiro pedido concluído feito logado.
No fim de Promoções, o cartão Privacidade mostra as contas, guarda razão social e CNPJ (aparecem no Aviso quando preenchidos), muda o prazo para anonimizar clientes sem pedidos (padrão 3 anos) e publica nova versão do Aviso.
O cliente baixa os próprios dados e apaga a conta em Minha conta, Meus dados.', '{Admin}', true, '2026-10-12 01:28:20.904708+00', 'lista', 98, 'O endereço do Aviso de Privacidade para o Google está no cartão Privacidade (termina em ?privacidade=1).'),
	(281, 'man-admin-111-conta-cliente', 'Conta do cliente (login com Google) e privacidade', 'conta cliente login google entrar minha conta cadastro privacidade lgpd aviso aceite promoções endereços repetir pedido fidelidade indique ganhe indicação apagar conta exportar dados cnpj anonimizar', 'O cliente pode entrar com o Google pelo botão "Entrar" do cardápio. É opcional: quem não entra pede normalmente. Na primeira vez ele aceita o Aviso de Privacidade e, separado, escolhe se quer receber promoções.
Em "Minha conta" o cliente vê os pedidos (e repete um com um toque), o cartão fidelidade, os cupons, os endereços salvos, o link do "indique e ganhe" e a Privacidade (baixar os dados dele ou apagar a conta).
A conta só se junta ao histórico do cliente depois do primeiro pedido entregue ou retirado feito logado.
Administrador, em Promoções: cada cupom tem Editar; dá para marcar "só para quem tem conta", "só para um cliente", mostrar em "Minha conta" e escrever um texto para o cliente. Os cupons automáticos (boas-vindas, aniversário e indique e ganhe para quem foi indicado) começam desligados: ajuste o benefício e ligue.
Pedido cancelado devolve o cupom de conta ao cliente e não conta como uso; o brinde (prêmio) usado nele volta para o cliente.
No cartão Privacidade (LGPD) da mesma tela: razão social e CNPJ (em branco = não aparecem no aviso), prazo para anonimizar clientes parados (3 anos) e "Publicar nova versão do Aviso" (todos aceitam de novo).
Atenção: o telefone digitado no pedido não é verificado.
Brindes: marque os produtos-prêmio em Editar produto › Mais opções (Prêmio de fidelidade / Prêmio de indicação). Com o cartão fidelidade completo, o cliente escolhe o prêmio em "Minha conta" ou no carrinho. Quem indica ganha 1 brinde (a escolher entre os produtos marcados como prêmio de indicação) quando o amigo conclui o 1º pedido; se esse pedido for cancelado, o brinde some.
O brinde pode ir junto com outros itens ou sozinho: sai a R$ 0,00 (entra nos relatórios, com o custo, e baixa o estoque) e a entrega, se for entrega, é cobrada. Não há pedido mínimo. Pedido cancelado devolve o brinde. O botão Entrar/Minha conta fica numa faixa abaixo do banner do cardápio.', '{Admin,Operador}', true, '2026-10-12 02:23:19.545114+00', 'lista', 112, 'Sem conta, o cliente pede como sempre. No modo reserva não há login.'),
	(282, 'man-admin-112-feedback-resposta', 'Responder feedback do cliente (e feedback ligado à conta)', 'feedback responder resposta cliente conta reclamação elogio sugestão whatsapp respondido pedido estrelas anônimo', 'Hoje → Feedbacks (Operador: Atendimento → Feedbacks). Cada feedback mostra a nota, o comentário, o pedido (se houver) e se veio "👤 com conta" ou "sem conta".
Toque em "💬 Responder", escreva a resposta (até 1000 letras) e salve. O feedback vira "Respondido". Dá para editar a resposta depois.
Cliente COM conta: vê a sua resposta em Minha conta › Pedidos, no próprio pedido. Cliente SEM conta (anônimo ou sem login): a resposta fica só registrada; use o botão "WhatsApp" para falar com ele pelo telefone, quando ele deixou.
No cardápio, quem está com a conta ligada tem o botão "⭐ Feedback" em cada pedido (um feedback por pedido). O botão de feedback do rodapé continua funcionando para qualquer pessoa, com ou sem login.', '{Admin,Operador}', true, '2026-10-16 03:03:49.796886+00', 'lista', 113, 'Anônimo e sem telefone: não há como responder. A resposta é visível ao cliente só se ele deu o feedback logado na conta dele.'),
	(283, 'man-admin-113-leitor-fiscal', 'Ler nota fiscal ou cupom pelo Max', 'nota fiscal cupom fiscal foto XML leitor fiscal Max compra fornecedor estoque despesa financeiro', 'Abra Administrador → Pergunte à IA → Leitor Fiscal IA. Envie uma foto legível, um XML de NF-e ou cole o texto da nota. Confira emitente, CNPJ, data, chave, fornecedor, itens, quantidades e valores. A soma dos itens deve bater com o total. Só toque em Confirmar e lançar compra depois de conferir: a confirmação registra a compra e pode atualizar estoque e financeiro. A foto fica em armazenamento privado e é excluída automaticamente após 30 dias. Se a leitura falhar, digite os dados manualmente.', '{Admin,Operador}', false, '2026-10-16 09:38:48.893007+00', 'lista', 113, 'Não lance uma nota do próprio Restaurante Demo como compra. Nota repetida pela chave fiscal é bloqueada. Pagamento dividido deve ser conferido e lançado manualmente nesta versão.'),
	(284, 'man-admin-114-caixa-vencido', 'Caixa vencido', 'caixa vencido esqueci fechar liberar emergência fechamento atrasado corte venda bloqueada 06:00', 'O caixa vence no primeiro corte (padrão 06:00, horário de Brasília) depois de ter pelo menos 6 horas aberto, e nunca passa de 24 horas. Quando vence, venda nova de balcão e de mesa, sangria e resgate de prêmio ficam bloqueados. Preparar, despachar, entregar e receber pedidos já aceitos continuam livres. Pedidos do iFood e do cardápio continuam entrando e podem ser aceitos.
Fechar: Caixa → botão "Fechar caixa vencido" no fim da tela (Admin e Operador). Informe o dinheiro contado e, se quiser, o motivo. A diferença fica registrada como "fechamento atrasado" em Administrador → Dinheiro → Histórico → Sessões de caixa. O caixa só fecha sem mesas abertas, pedidos pendentes ou não recebidos.
Emergência (só Admin): "Liberar por algumas horas" (padrão 4 h, máximo 12 h), com motivo obrigatório. Fica na auditoria, avisa os Administradores e aparece na Visão Geral. Expira sozinho.
Aviso: a partir de 2 horas antes do corte aparece uma faixa no Início (com atalho para o Caixa) e no Caixa. O Admin ajusta a regra em Caixa → "Regra do caixa vencido" (embaixo do botão de fechar).
Garçom e Cozinha veem "caixa vencido, chame o responsável".', '{Admin,Operador}', true, '2026-10-16 21:46:37.03337+00', 'lista', 114, ''),
	(285, 'man-admin-115-mercado-pago', 'Mercado Pago (pagamento online)', 'mercado pago pix cartão online crédito débito pagamento online checkout webhook liberar pedido reembolsar chaves teste produção', 'Onde: Administrador → Sistema → Integrações e contas → 💳 Mercado Pago. O quadro "👉 Próximo passo" mostra o que falta fazer.
Configurar (quem faz é o dono): conta de vendedor verificada; aplicação com Checkout Transparente; chaves de TESTE (Public Key e Access Token); aviso (webhook) com o evento "Order (Mercado Pago)" e a chave secreta; teste guiado com Pix e cartão; só então as chaves de PRODUÇÃO e "Ligar em PRODUÇÃO".
Formas de pagamento pelo site: cada forma tem só duas opções, "Só na entrega" ou "Também online". Online vale para Pix, crédito e débito. A forma continua valendo na entrega, com os mesmos preços, taxas e acréscimos.
Ajustes: validade do Pix (5 a 120 minutos; combinado 15), e-mails que veem o pagamento online em TESTE e e-mail do comprador de teste.
No cardápio, o cliente precisa entrar com a conta para pagar pelo site. O pedido só entra como Pago depois da confirmação do Mercado Pago.
Pagamentos que precisam de decisão: se o dinheiro foi aprovado mas o pedido não entrou sozinho na cozinha, a lista aparece em Mercado Pago ("No dia a dia") e numa faixa discreta no Caixa. "Liberar pedido" envia para a cozinha; "Reembolsar" registra a decisão e chama o Mercado Pago para devolver. Confira o resultado antes de repetir uma tentativa.
Relatórios → "Mercado Pago — resumo do mês" mostra recebimentos e taxas do mês.', '{Admin}', true, '2026-10-17 09:27:56.719023+00', 'lista', 115, 'O pedido de teste aprovado vira pedido de verdade na cozinha e no caixa: avise a equipe e cancele depois.
Desligada, a integração faz o cardápio voltar a funcionar só com pagamento na entrega. Ligar e desligar pedem a senha de administrador.'),
	(286, 'man-admin-116-entregadores-fechamento', 'Entregadores: taxa e fechamento', 'entregadores taxa de entrega ajuda diária fechamento de entregadores pagar entregador fechar período fechamentos anteriores', 'Administrador → Loja e equipe → Entregadores e taxas.
Em "Taxa e ajuda diária", defina a taxa de entrega padrão e a ajuda diária do entregador e salve. A taxa é do cliente e vai 100% para o entregador. Mudanças valem só para pedidos e fechamentos futuros.
Em "Fechamento de entregadores", escolha o entregador e o dia e toque em Calcular. O total devido é as taxas das entregas concluídas do dia mais a ajuda diária (uma vez por dia).
Informe o valor pago e a forma: Dinheiro (sai da gaveta do caixa) ou Pix (não sai da gaveta). Se o valor pago for diferente do devido, a observação é obrigatória.
Toque em "Fechar período". Os fechamentos aparecem em "Fechamentos anteriores" e não mudam mais.', '{Admin}', true, '2026-10-17 09:27:56.719023+00', 'lista', 116, 'A ajuda diária conta uma vez por dia e só se houve entrega.
O valor pago ao entregador entra nas despesas (Entregadores) no DRE.
Se a conexão cair ao fechar, confira "Fechamentos anteriores" antes de tentar de novo, para não fechar duas vezes.'),
	(287, 'man-admin-117-clientes-perfil-360', 'Clientes: Perfil 360, segmentos e preferências fixas', 'clientes perfil 360 segmento novo fiel vip em risco ticket médio frequência itens favoritos preferências fixas sem cebola alergia conta google filtro', 'Clientes → toque no cliente. No topo do perfil, o Perfil 360 mostra o segmento (Novo, Fiel, VIP ou Em risco), gasto total, ticket médio, frequência, itens favoritos e se tem conta Google. Na lista, cada cliente tem o selo do segmento, e os filtros são Em risco, VIP, Fiéis e Novos.
Os pedidos antigos arquivados entram na conta, pelo telefone do cliente.
Preferências fixas (ex.: sem cebola, alergias): preencha no perfil do cliente. Cada pedido novo guarda uma cópia, e as preferências aparecem na tela da cozinha, na comanda impressa e nos detalhes do pedido.
O cliente com conta também edita as dele em Minha conta › Meus dados e as vê no checkout antes de pedir.', '{Admin,Operador}', true, '2026-10-17 09:27:56.719023+00', 'lista', 117, ''),
	(288, 'man-admin-118-cupons-risco-vip', 'Cupons automáticos: Sentimos sua falta e Cliente VIP', 'cupom automático sentimos sua falta cliente em risco 45 dias cliente vip aviso push promoções cupons automáticos', 'Administrador → Vendas e cardápio → Promoções e cupons → Cupons automáticos.
Há dois cupons para fidelizar: "Sentimos sua falta" (cliente em risco, mais de 45 dias sem pedir) e "Cliente VIP". Já vêm DESLIGADOS: ajuste o valor e ligue.
Só recebe quem tem conta Google e aceitou promoções. O cupom aparece em Minha conta do cliente.
Quem está em Em risco ou VIP também recebe um aviso (push) junto com o cupom, se tiver o aviso ligado no aparelho.', '{Admin}', true, '2026-10-17 09:27:56.719023+00', 'lista', 118, ''),
	(289, 'man-admin-119-formas-pagamento', 'Formas de pagamento (Taxas e prazos / No cardápio)', 'formas de pagamento taxas prazos no cardápio acréscimo ifood pagamento cardápio', 'Administrador → Vendas e cardápio → Formas de pagamento. É uma tela só, com duas abas: "Taxas e prazos" e "No cardápio" (o que o cliente vê).
Esta tela substituiu a antiga aba Pagamentos do Cardápio Digital.
Para pagamento online (Pix, crédito e débito), veja Mercado Pago em Integrações e contas.', '{Admin}', true, '2026-10-17 09:27:56.719023+00', 'lista', 119, '');

INSERT INTO public.ai_config (id, ia_ligada, recursos, provedor_principal, provedor_reserva, modelo_gemini, modelo_groq, cota_diaria_global, cota_diaria_usuario, limite_por_minuto, cache_ttl_min, cota_diaria_operador, limite_por_minuto_operador, recursos_operador, atualizado_em, extras_publico, modelo_nvidia, modelo_cloudflare, modelo_groq_rapido) VALUES
	(true, true, '{"ajuda": true, "alertas": true, "compras": true, "pergunte": true, "anomalias": true, "conversar": true, "resumo_dia": true, "suporte_pedido": false}', 'gemini', 'groq', 'gemini-3.8-flash', 'qwen/qwen3.8-27b', 1200, 300, 10, 10, 150, 8, '{"ajuda": true, "conversar": true}', '2026-10-15 09:52:35.797135+00', true, 'nvidia/nemotron-3-super-120b-a12b', '@cf/meta/llama-3.3-70b-instruct-fp8-fast', 'llama-3.1-8b-instant');

INSERT INTO public.backup_config (id, auto_retencao_dias, arquivar_ativo, arquivar_dias, atualizado_em, arquivar_emerg_ativo, arquivar_emerg_pct, arquivar_emerg_ultimo) VALUES
	(true, 7, true, 90, '2026-10-06 02:57:32.342839+00', true, 95, NULL);

INSERT INTO public.caixa_config (id, corte_hora, vida_minima_horas, teto_horas, aviso_horas, liberacao_padrao_horas, liberacao_max_horas, atualizado_em) VALUES
	(true, '06:00:00', 6, 24, 2, 4, 12, '2026-10-16 02:20:22.552275+00');

INSERT INTO public.chat_config (id, chat_publico_ligado, ia_publica_cota_dia, janela_horas, atualizado_em) VALUES
	(true, true, 200, 48, '2026-10-08 09:41:03.954366+00');

INSERT INTO public.configuracoes_fotos (id, onde_guardar, destino_padrao_upload, drive_preferido, sincronizacao_drives, backup_frio_storage, replicar_antigas, atualizado_em, historico_fotos_ativo) VALUES
	(true, 'drive_apenas', 'ambos', 'auto', 'manual', NULL, 'ativas', '2026-10-09 10:10:25.670399+00', true);

INSERT INTO public.contingencia_config (id, timeout_supabase_ms, falhas_para_planilha, timeout_planilha_ms, falhas_para_contingencia, reconciliacao_lote, atualizado_em) VALUES
	(true, 8000, 3, 12000, 3, 50, '2026-10-06 02:57:32.342839+00');

INSERT INTO public.fiscal_empresa (id, razao_social, nome_fantasia, cnpj, inscricao_estadual, regime, cep, logradouro, numero, complemento, bairro, municipio, codigo_municipio, uf, telefone, csc_id, serie, aliquota_simples, perfil_padrao_id, atualizado_em) VALUES
	(true, NULL, NULL, NULL, NULL, 'simples', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, 0.00, NULL, '2026-10-11 05:30:05.619474+00');

INSERT INTO public.ifood_estado (id, ultima_consulta, ultima_consulta_ok, ultimo_pedido_em, token_ok, ultimo_erro, ultimo_erro_em, trava_dono, trava_ate, atualizado_em, financeiro_em, avaliacoes_em) VALUES
	(true, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2026-10-11 05:25:36.895217+00', NULL, NULL);

INSERT INTO public.ifood_loja (id, situacao, disponivel, motivo, pausada_ate, interrupcao_id, fechada_por_nos, verificado_em, bruto, atualizado_em) VALUES
	(true, NULL, NULL, NULL, NULL, NULL, false, NULL, NULL, '2026-10-11 05:28:39.382194+00');

INSERT INTO public.formas_pagamento (id, nome, ativa, visivel_cardapio, taxa_percentual, taxa_fixa, prazo_dias, permite_troco, ordem, acrescimo_percentual, acrescimo_fixo, preco_proprio, aceita_online, tipo_online) VALUES
	('17b14f91-68d9-4a94-9374-c64846414581', 'Pix', true, true, 0.00, 0.00, 0, false, 2, 0, 0, false, true, 'pix'),
	('19f2f926-8a9e-41a7-ba5f-2280b672950e', 'Cartão de Débito', true, true, 0.00, 0.00, 0, false, 3, 0, 0, false, true, 'debito'),
	('212c5286-05f4-47aa-8c00-ed7968551e08', 'Alelo', true, true, 0.00, 0.00, 0, false, 5, 0, 0, false, false, NULL),
	('21d76d26-8608-47b8-b387-1e9f5b150715', 'iFood', true, false, 0.00, 0.00, 0, false, 6, 0, 0, true, false, NULL),
	('415454fb-f2a6-4265-95d9-15fd0143cc1b', 'iFood (pagar na entrega)', false, false, 0.00, 0.00, 0, false, 99, 0, 0, false, false, NULL),
	('49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 'Dinheiro', true, true, 0.00, 0.00, 0, true, 1, 0, 0, false, false, NULL),
	('5ed453d4-554c-458d-b03b-a10f5c110f20', 'iFood (pago no app)', false, false, 0.00, 0.00, 0, false, 99, 0, 0, false, false, NULL),
	('d0e73585-ca32-43f7-8051-8469cc6034ba', 'Cartão de Crédito', true, true, 0.00, 0.00, 0, false, 4, 0, 0, false, true, 'credito');

INSERT INTO public.integracoes_config (provedor, ligado, modo, ligado_em, ligado_por, checklist, config, atualizado_em) VALUES
	('ifood', false, 'homologacao', NULL, NULL, '{"conta_dev": false}', '{"baixaEstoque": "confirmacao", "enviarPrecos": true, "pausarSemEstoque": true, "abrirFecharComCaixa": true, "modoHomologacao": true, "retencaoClientesDias": 90, "confirmacaoAutomatica": true}', '2026-10-18 00:36:18.024188+00'),
	('mercadopago', false, 'homologacao', NULL, NULL, '{}', '{"pixValidadeMin": 15, "testeNoCardapio": false}', '2026-10-14 20:33:43.459043+00'),
	('nfce', false, 'homologacao', NULL, NULL, '{}', '{"canais": ["balcao"], "emitirQuando": "pagamento"}', '2026-10-11 17:39:17.433512+00');

INSERT INTO public.promocoes (id, nome, tipo, regra_duplicidade, beneficio, ativa) VALUES
	('4238e8ee-8978-42e6-8655-12e4be0f5652', 'Indicação de amigos', 'Indicação', 'O indicado só pode aparecer uma vez', '1 batata pequena para quem indicou', true),
	('9407cd22-4c89-46c0-9990-1351c9650b49', 'Cartão Fidelidade', 'Fidelidade (carimbos)', 'Soma marca a cada venda com cliente associado', '1 porção de batata frita a cada 10 marcas', true);

INSERT INTO public.cupons (id, codigo, nome, tipo, valor, frete_gratis, data_inicio, data_fim, hora_inicio, hora_fim, limite_total, limite_por_cliente, valor_minimo, ativa, acumula, criado_em, criado_por, faixas, somente_conta, cliente_id, mensagem, visivel_conta, automatico, validade_dias) VALUES
	('02e0b88a-3207-47c2-8b96-7e664852ce97', 'INDICADOR', 'Indique e ganhe — quem indicou', 'fixo', 10.00, false, NULL, NULL, NULL, NULL, 0, 1, 30.00, false, false, '2026-10-12 01:08:43.04162+00', NULL, '[]', true, NULL, 'Seu amigo fez o primeiro pedido! Este cupom é seu.', false, 'indicacao_indicador', 30),
	('2c08b506-75a8-422d-89e3-7bb0c43e4751', 'SAUDADE', 'Sentimos sua falta', 'fixo', 10.00, false, NULL, NULL, NULL, NULL, 0, 1, 30.00, false, false, '2026-10-16 23:22:57.62432+00', NULL, '[]', true, NULL, 'Sentimos sua falta! Um presente do Restaurante Demo para você voltar.', false, 'em_risco', 14),
	('61dbccc6-f701-4881-8618-2bf2ec79e830', 'VIPCLIENTE', 'Cliente VIP', 'fixo', 15.00, false, NULL, NULL, NULL, NULL, 0, 1, 40.00, false, false, '2026-10-16 23:22:57.62432+00', NULL, '[]', true, NULL, 'Obrigado por ser cliente VIP do Restaurante Demo! Este cupom é seu.', false, 'vip', 30),
	('66f3d578-8850-41cf-b7de-00f2685bd851', 'ANIVERSARIO', 'Aniversário', 'fixo', 10.00, false, NULL, NULL, NULL, NULL, 0, 1, 30.00, false, false, '2026-10-12 01:08:43.04162+00', NULL, '[]', true, NULL, 'Feliz aniversário! Um presente do Restaurante Demo para você.', false, 'aniversario', 7),
	('7e4df2e3-6b0e-4b0e-af4d-0ba8f042200c', 'INDICADO', 'Indique e ganhe — quem foi indicado', 'fixo', 10.00, false, NULL, NULL, NULL, NULL, 0, 1, 30.00, false, false, '2026-10-12 01:08:43.04162+00', NULL, '[]', true, NULL, 'Você chegou por indicação de um amigo. Este cupom é seu.', false, 'indicacao_indicado', 30),
	('dbec3c0b-8d70-4159-8d1e-7ddb53dfd7ef', 'BOASVINDAS', 'Boas-vindas', 'percentual', 10.00, false, NULL, NULL, NULL, NULL, 0, 1, 0.00, false, false, '2026-10-12 01:08:43.04162+00', NULL, '[]', true, NULL, 'Cupom de boas-vindas pela sua conta!', false, 'boas_vindas', 30);

INSERT INTO public.versoes_sync (grupo, n) VALUES
	('cad', 1),
	('din', 1);

INSERT INTO public.sync_estado (id, principal_ultimo_ok, principal_ultimo_erro, principal_ultimo_erro_msg, contingencia_ultimo_ok, contingencia_ultimo_erro, contingencia_ultimo_erro_msg, contingencia_atraso_minutos, alerta_itens_limite, alerta_horas_limite, atualizado_em) VALUES
	(true, NULL, NULL, NULL, NULL, NULL, NULL, 60, 500, 6, now());

INSERT INTO public.sistema (chave, valor, atualizado_em) VALUES
	('AjudaDiariaEntregador', '0.00', now()),
	('AvisoPrivacidadeVersao', '1', now()),
	('BACKUP_AUTO_ATIVO', 'true', now()),
	('BACKUP_FREQ', '"diario"', now()),
	('BACKUP_HORA', '4', now()),
	('BLOQUEAR_ESTOQUE_NEGATIVO', 'false', now()),
	('CardapioFechadoManual', '{"ativo": false, "mensagem": ""}', now()),
	('CardapioFrase', '""', now()),
	('CardapioKicker', '""', now()),
	('CardapioPeriodosFechado', '[]', now()),
	('CardapioTempoEntrega', '""', now()),
	('CardapioTempoMesa', '""', now()),
	('CardapioTempoRetirada', '""', now()),
	('LgpdAnosAnonimizar', '3', now()),
	('MANUTENCAO', 'null', now()),
	('MetaDiaria', '0', now()),
	('MetaMensal', '0', now()),
	('NotificacoesConfig', '{"pedido": {"ativo": true, "perfis": ["Admin", "Cozinha", "Operador"]}, "entrega": {"ativo": true, "perfis": ["Admin", "Operador"]}, "estoque": {"ativo": true, "perfis": ["Admin", "Cozinha", "Operador"]}, "sistema": {"ativo": true, "perfis": ["Admin"]}, "inativos": {"ativo": true, "perfis": ["Admin", "Operador"]}, "indicacao": {"ativo": true, "perfis": ["Admin", "Operador"]}, "fidelidade": {"ativo": true, "perfis": ["Admin", "Operador"]}, "financeiro": {"ativo": true, "perfis": ["Admin"]}, "ocorrencia": {"ativo": true, "perfis": ["Admin", "Operador"]}, "aniversario": {"ativo": true, "perfis": ["Admin", "Operador"]}}', now()),
	('RestauranteEndereco', '"Rua Exemplo, 123 - Centro"', now()),
	('RestauranteNome', '"Restaurante Demo"', now()),
	('RestauranteRedes', '"Instagram: @restaurantedemo"', now()),
	('RestauranteTelefone', '"(11) 90000-0000"', now()),
	('TaxaEntregaPadrao', '6.00', now());

INSERT INTO public.mesas (id, numero, status, capacidade, observacao, garcom_responsavel_id, chamado_tipo, chamado_em) VALUES
	('24e4b5dd-e2f4-58b1-8f51-972cc90e3219', '1', 'Livre', 4, NULL, NULL, NULL, NULL),
	('83c4417e-7a7e-53fc-b98b-33546b9f02ae', '2', 'Livre', 4, NULL, NULL, NULL, NULL),
	('82e79dd3-2b09-5e91-b9d0-16a614614f47', '3', 'Livre', 4, NULL, NULL, NULL, NULL),
	('83f7d335-62aa-50c8-8f18-c1d363757490', '4', 'Livre', 4, NULL, NULL, NULL, NULL),
	('b69dbce4-1bc1-54bb-8bc0-305ff9b97307', '5', 'Livre', 4, NULL, NULL, NULL, NULL),
	('c2346f57-89e3-5d02-ae78-7a445cbb138f', '6', 'Livre', 4, NULL, NULL, NULL, NULL),
	('4af869b8-5ca7-5871-af62-c89fbb52255e', '7', 'Livre', 4, NULL, NULL, NULL, NULL),
	('4867374b-da9c-51d0-9fb7-8999e2fe0ca9', '8', 'Livre', 4, NULL, NULL, NULL, NULL);

INSERT INTO public.estoque (id, ingrediente, quantidade, quantidade_minima, unidade, custo_unitario, status) VALUES
	('42a3fa1e-b75c-5d03-b1b9-b8d363cdb580', 'Pão de hambúrguer', 100.000, 20.000, 'un', 2.2000, 'Ativo'),
	('e095410c-c189-5d6b-b893-008aa1019ac5', 'Hambúrguer 150g', 100.000, 20.000, 'un', 4.5000, 'Ativo'),
	('9b3ed9d7-3c06-5ddd-a5b0-95df914e720c', 'Queijo mussarela', 8.000, 2.000, 'kg', 38.0000, 'Ativo'),
	('6bc778ed-7155-5666-9ef1-e6ca668e4b6e', 'Cheddar', 4.000, 1.000, 'kg', 42.0000, 'Ativo'),
	('414543a7-573b-520b-b10d-870bf78d6f33', 'Bacon', 5.000, 1.000, 'kg', 40.0000, 'Ativo'),
	('3cd50833-8489-5aab-8749-8fa497f4bfab', 'Alface', 3.000, 1.000, 'kg', 12.0000, 'Ativo'),
	('e3253237-598a-57b7-b775-b56466afb880', 'Tomate', 4.000, 1.000, 'kg', 8.0000, 'Ativo'),
	('589e4cf1-1dc2-5431-a13d-99e1058c045a', 'Cebola roxa', 3.000, 1.000, 'kg', 10.0000, 'Ativo'),
	('d02ef049-673b-5c84-845a-32c74d80acf8', 'Maionese da casa', 5.000, 1.000, 'kg', 14.0000, 'Ativo'),
	('7d72ff6b-02ff-522c-a6e0-aeadd40e96a2', 'Batata congelada', 30.000, 8.000, 'kg', 11.0000, 'Ativo'),
	('d20d723c-71be-55f7-aad1-3f22924e4d49', 'Frango empanado', 40.000, 10.000, 'un', 3.8000, 'Ativo'),
	('83c9e091-335d-5485-b16a-9961ee1267ed', 'Pão de hot dog', 50.000, 10.000, 'un', 1.8000, 'Ativo'),
	('baf51f6a-d445-5d0d-98f9-e967b9b653e3', 'Salsicha', 60.000, 10.000, 'un', 1.2000, 'Ativo'),
	('34b0bc05-9f4e-5d17-b423-e692332335f4', 'Refrigerante lata', 80.000, 20.000, 'un', 3.2000, 'Ativo'),
	('707f1d53-9a4e-5ef1-bd8a-c2a7621ac384', 'Suco de laranja 300ml', 40.000, 10.000, 'un', 2.5000, 'Ativo'),
	('08bf4eb3-687c-54a3-b38a-5b4c5c3bcf68', 'Água mineral', 80.000, 20.000, 'un', 1.1000, 'Ativo'),
	('919a3f8e-4de8-501c-8415-9e1bf455c74c', 'Sorvete (pote)', 6.000, 2.000, 'kg', 28.0000, 'Ativo'),
	('d7a4189f-6ee8-59e6-a00d-85e90b375572', 'Calda de chocolate', 3.000, 1.000, 'kg', 24.0000, 'Ativo');

INSERT INTO public.categorias (id, nome, ativa, ordem, perfil_fiscal_id) VALUES
	('0f386fe5-09df-5376-a0d0-fa4ab91813d1', 'Combos', true, 1, NULL),
	('cbb425fd-343b-5fb4-9e3b-ada3363469d8', 'Lanches', true, 2, NULL),
	('35986d3f-2e5a-5fd2-8ea2-e04b5382849e', 'Hot Dogs', true, 3, NULL),
	('2973a099-bfc3-599e-a5a3-1b28dbbbace2', 'Porções', true, 4, NULL),
	('c040ca9e-278f-5b0e-af45-cba47358db03', 'Bebidas', true, 5, NULL),
	('a9b16afe-62e9-510e-a0be-4aaad8ec225b', 'Sobremesas', true, 6, NULL);

INSERT INTO public.produtos (id, nome, descricao, categoria_id, ativo, destaque, estoque_proprio_ingrediente_id, ordem_cardapio, foto_id_principal, foto_id_contingencia, foto_url_principal, foto_url_contingencia, foto_preferida, premio_fidelidade, premio_indicacao, perfil_fiscal_id) VALUES
	('eeb93f2a-378a-5417-8587-2fdd47ad73ec', 'Clássico', 'Pão, hambúrguer 150g, queijo, alface, tomate e maionese da casa', 'cbb425fd-343b-5fb4-9e3b-ada3363469d8', true, true, NULL, 1, NULL, NULL, NULL, NULL, 'principal', false, false, NULL),
	('98b4f2d4-2024-5765-b1e5-2bd23f55fd16', 'Cheddar Bacon', 'Pão, hambúrguer 150g, cheddar cremoso, bacon crocante e maionese da casa', 'cbb425fd-343b-5fb4-9e3b-ada3363469d8', true, true, NULL, 2, NULL, NULL, NULL, NULL, 'principal', false, false, NULL),
	('d064f045-dc51-5458-a345-9a1cbb0aa173', 'Duplo Cheddar', 'Pão, dois hambúrgueres 150g, cheddar em dobro e cebola roxa', 'cbb425fd-343b-5fb4-9e3b-ada3363469d8', true, false, NULL, 3, NULL, NULL, NULL, NULL, 'principal', false, false, NULL),
	('b031a180-1426-57ea-af57-42baa47e866f', 'Frango Crocante', 'Pão, frango empanado, queijo, alface, tomate e maionese da casa', 'cbb425fd-343b-5fb4-9e3b-ada3363469d8', true, false, NULL, 4, NULL, NULL, NULL, NULL, 'principal', false, false, NULL),
	('068e3113-2fcf-5c2d-b598-e9123c35a208', 'Hot Dog Tradicional', 'Pão, duas salsichas, queijo e maionese da casa', '35986d3f-2e5a-5fd2-8ea2-e04b5382849e', true, false, NULL, 1, NULL, NULL, NULL, NULL, 'principal', false, false, NULL),
	('d3419a4d-e153-5ecc-8001-c13084f849e2', 'Batata Frita 300g', 'Porção de batatas em palito, crocantes', '2973a099-bfc3-599e-a5a3-1b28dbbbace2', true, false, NULL, 1, NULL, NULL, NULL, NULL, 'principal', false, false, NULL),
	('f3956615-8b83-5c19-a642-b623112407b3', 'Batata com Cheddar e Bacon', 'Batata frita 300g coberta com cheddar e bacon', '2973a099-bfc3-599e-a5a3-1b28dbbbace2', true, true, NULL, 2, NULL, NULL, NULL, NULL, 'principal', false, false, NULL),
	('b517404e-3fe2-5ea7-b830-77285ed3b17e', 'Refrigerante Lata', 'Lata 350ml gelada', 'c040ca9e-278f-5b0e-af45-cba47358db03', true, false, '34b0bc05-9f4e-5d17-b423-e692332335f4', 1, NULL, NULL, NULL, NULL, 'principal', false, false, NULL),
	('00af665c-d8d1-5a50-baf0-ed7588538e33', 'Suco de Laranja 300ml', 'Suco natural da casa', 'c040ca9e-278f-5b0e-af45-cba47358db03', true, false, '707f1d53-9a4e-5ef1-bd8a-c2a7621ac384', 2, NULL, NULL, NULL, NULL, 'principal', false, false, NULL),
	('e7f454b0-7c03-5761-9ff8-8d89af357fbd', 'Água Mineral', 'Garrafa 500ml sem gás', 'c040ca9e-278f-5b0e-af45-cba47358db03', true, false, '08bf4eb3-687c-54a3-b38a-5b4c5c3bcf68', 3, NULL, NULL, NULL, NULL, 'principal', false, false, NULL),
	('158d10c9-664c-5894-bc89-0110bdf46a2f', 'Sorvete com Calda', 'Duas bolas de sorvete com calda de chocolate', 'a9b16afe-62e9-510e-a0be-4aaad8ec225b', true, false, NULL, 1, NULL, NULL, NULL, NULL, 'principal', false, false, NULL);

INSERT INTO public.produto_ingredientes (id, produto_id, ingrediente_id, quantidade_por_unidade) VALUES
	('19bf6fa8-16b6-5da0-97e8-656733ad5757', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '42a3fa1e-b75c-5d03-b1b9-b8d363cdb580', 1.000),
	('20847d1f-2200-5fdf-ae51-bb26af570d21', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', 'e095410c-c189-5d6b-b893-008aa1019ac5', 1.000),
	('fff8ca56-a3a8-5bb7-9eab-a54c6c9f4a23', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '9b3ed9d7-3c06-5ddd-a5b0-95df914e720c', 0.030),
	('8458faf5-fad5-54c3-8744-5df3f098f393', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '3cd50833-8489-5aab-8749-8fa497f4bfab', 0.020),
	('7879f6c0-77d1-5019-b0a5-e539b46a85e1', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', 'e3253237-598a-57b7-b775-b56466afb880', 0.030),
	('b0f06cc1-958f-50c5-baa3-88662fe65d8a', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', 'd02ef049-673b-5c84-845a-32c74d80acf8', 0.020),
	('22cfa65e-919f-5cd3-967b-bbd16a35a560', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '42a3fa1e-b75c-5d03-b1b9-b8d363cdb580', 1.000),
	('600cf454-d8d4-56d0-ba6a-4102c5884c54', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', 'e095410c-c189-5d6b-b893-008aa1019ac5', 1.000),
	('8e24b9fc-70e6-54ff-b157-acc0cf02fd98', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '6bc778ed-7155-5666-9ef1-e6ca668e4b6e', 0.040),
	('748cfb5e-d168-580f-9787-4e76f4831e83', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '414543a7-573b-520b-b10d-870bf78d6f33', 0.030),
	('636989fb-68d3-5853-bc18-54cb1ab1c1c9', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', 'd02ef049-673b-5c84-845a-32c74d80acf8', 0.020),
	('7327397f-923d-55e0-9f99-5317c9040574', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '42a3fa1e-b75c-5d03-b1b9-b8d363cdb580', 1.000),
	('ec532339-2979-5e79-9975-eaaae5ed75be', 'd064f045-dc51-5458-a345-9a1cbb0aa173', 'e095410c-c189-5d6b-b893-008aa1019ac5', 2.000),
	('60f1ca19-4941-5007-9096-1ee3e5fb653a', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '6bc778ed-7155-5666-9ef1-e6ca668e4b6e', 0.060),
	('f525fe23-8925-5ffe-ae9e-0c57ec0fc429', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '589e4cf1-1dc2-5431-a13d-99e1058c045a', 0.020),
	('01be8fdc-04dc-53c3-98f1-f43e4edb2744', 'b031a180-1426-57ea-af57-42baa47e866f', '42a3fa1e-b75c-5d03-b1b9-b8d363cdb580', 1.000),
	('1efa554e-f278-5c60-a55f-4441ed04d635', 'b031a180-1426-57ea-af57-42baa47e866f', 'd20d723c-71be-55f7-aad1-3f22924e4d49', 1.000),
	('da235e39-0657-5140-83f4-02f435843fe9', 'b031a180-1426-57ea-af57-42baa47e866f', '9b3ed9d7-3c06-5ddd-a5b0-95df914e720c', 0.030),
	('4926fe75-028f-54fd-a430-03f534408cb9', 'b031a180-1426-57ea-af57-42baa47e866f', '3cd50833-8489-5aab-8749-8fa497f4bfab', 0.020),
	('3417d00c-2deb-54ea-ae6e-0d59d387c5b0', 'b031a180-1426-57ea-af57-42baa47e866f', 'e3253237-598a-57b7-b775-b56466afb880', 0.030),
	('45ccbd04-456e-5792-af9c-0cb0b11d3b2b', 'b031a180-1426-57ea-af57-42baa47e866f', 'd02ef049-673b-5c84-845a-32c74d80acf8', 0.020),
	('93134328-d470-57bc-a90b-16faeec29c09', '068e3113-2fcf-5c2d-b598-e9123c35a208', '83c9e091-335d-5485-b16a-9961ee1267ed', 1.000),
	('c3e16579-051d-5a08-bd8f-d7682063a6e6', '068e3113-2fcf-5c2d-b598-e9123c35a208', 'baf51f6a-d445-5d0d-98f9-e967b9b653e3', 2.000),
	('676ce09e-47ae-5218-b1a6-3a6d1887435c', '068e3113-2fcf-5c2d-b598-e9123c35a208', '9b3ed9d7-3c06-5ddd-a5b0-95df914e720c', 0.020),
	('ec7e5762-e024-5c51-9e1e-39373785cff7', '068e3113-2fcf-5c2d-b598-e9123c35a208', 'd02ef049-673b-5c84-845a-32c74d80acf8', 0.020),
	('60b75e90-d871-5abb-b36f-68327dca43bc', 'd3419a4d-e153-5ecc-8001-c13084f849e2', '7d72ff6b-02ff-522c-a6e0-aeadd40e96a2', 0.300),
	('c4a0b929-7e23-5d2d-a26a-abe3f2d943ed', 'f3956615-8b83-5c19-a642-b623112407b3', '7d72ff6b-02ff-522c-a6e0-aeadd40e96a2', 0.300),
	('eb74b93a-3969-592a-a4f7-199a1dc63741', 'f3956615-8b83-5c19-a642-b623112407b3', '6bc778ed-7155-5666-9ef1-e6ca668e4b6e', 0.050),
	('2f937fb3-2b47-5678-a527-6c9c2fec5d2c', 'f3956615-8b83-5c19-a642-b623112407b3', '414543a7-573b-520b-b10d-870bf78d6f33', 0.030),
	('097f1903-0a51-5d04-b3e8-3911bb04ae37', '158d10c9-664c-5894-bc89-0110bdf46a2f', '919a3f8e-4de8-501c-8415-9e1bf455c74c', 0.150),
	('4c4ef365-f2a3-5981-9f21-faa5db0af204', '158d10c9-664c-5894-bc89-0110bdf46a2f', 'd7a4189f-6ee8-59e6-a00d-85e90b375572', 0.030);

INSERT INTO public.produto_precos (id, produto_id, forma_pagamento_id, preco, custo) VALUES
	('3e677a4e-34b8-559e-af96-f5728755fd0e', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '17b14f91-68d9-4a94-9374-c64846414581', 24.90, 8.60),
	('79d2dc63-8cc6-5e48-a639-dc89fb8436f2', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 24.90, 8.60),
	('44e1ed1e-52cb-5a57-ab71-6cdaf72b827a', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '212c5286-05f4-47aa-8c00-ed7968551e08', 24.90, 8.60),
	('5ec17bbf-a265-5287-b893-2e8526f04298', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '21d76d26-8608-47b8-b387-1e9f5b150715', 28.90, 8.60),
	('43dc0976-4704-52e0-9bfa-bceaf0dd6be9', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 24.90, 8.60),
	('12a56e7f-5ec1-568d-945e-170f0f4ec916', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 24.90, 8.60),
	('3010c2c9-8b8b-5699-a978-639b88fd6a7a', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '17b14f91-68d9-4a94-9374-c64846414581', 29.90, 9.86),
	('a43e5d1c-0cc1-5788-a399-c06bf532fa22', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 29.90, 9.86),
	('027def7b-4555-587a-abe4-72f016b889e7', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '212c5286-05f4-47aa-8c00-ed7968551e08', 29.90, 9.86),
	('02006a54-be63-571b-ab1c-87143fb4e106', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '21d76d26-8608-47b8-b387-1e9f5b150715', 33.90, 9.86),
	('8b5795fa-094a-5197-b9a7-4dfe6af35d56', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 29.90, 9.86),
	('0784b3a1-c333-5578-8c6f-b6966772f416', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 29.90, 9.86),
	('e1c8daab-726f-59a8-af26-d175bdc89b4a', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '17b14f91-68d9-4a94-9374-c64846414581', 34.90, 13.92),
	('610cafc2-646b-54d4-be16-4a5265e1dd41', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 34.90, 13.92),
	('fc53d961-e186-5c65-a04d-6bb4b1acdaef', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '212c5286-05f4-47aa-8c00-ed7968551e08', 34.90, 13.92),
	('d58006e5-6b65-57dd-992e-8433e42bd044', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '21d76d26-8608-47b8-b387-1e9f5b150715', 39.90, 13.92),
	('6016493c-8381-5613-a8a8-309d2bd2e78e', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 34.90, 13.92),
	('0ef1a050-1b65-5b71-b850-3ccf84d974b7', 'd064f045-dc51-5458-a345-9a1cbb0aa173', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 34.90, 13.92),
	('4431a5c5-fc98-5d73-a27e-e5ec68a7a662', 'b031a180-1426-57ea-af57-42baa47e866f', '17b14f91-68d9-4a94-9374-c64846414581', 27.90, 7.90),
	('f0afe268-4e6d-5bcc-9d98-40de737cd666', 'b031a180-1426-57ea-af57-42baa47e866f', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 27.90, 7.90),
	('cc93548c-cc1b-57b3-afd2-19f3e9a911f4', 'b031a180-1426-57ea-af57-42baa47e866f', '212c5286-05f4-47aa-8c00-ed7968551e08', 27.90, 7.90),
	('3b4eff0a-89b8-5362-822a-dddb39949be4', 'b031a180-1426-57ea-af57-42baa47e866f', '21d76d26-8608-47b8-b387-1e9f5b150715', 31.90, 7.90),
	('295d6303-d400-5fdc-b52f-f8cefe44865b', 'b031a180-1426-57ea-af57-42baa47e866f', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 27.90, 7.90),
	('920e3660-d89a-52c6-8aaa-13d8fadd9306', 'b031a180-1426-57ea-af57-42baa47e866f', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 27.90, 7.90),
	('0b12b246-a71b-529f-94d3-b5f021d9e2b9', '068e3113-2fcf-5c2d-b598-e9123c35a208', '17b14f91-68d9-4a94-9374-c64846414581', 18.90, 5.24),
	('1e34fc93-4006-5cac-9480-fca3988e5968', '068e3113-2fcf-5c2d-b598-e9123c35a208', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 18.90, 5.24),
	('c83a53db-4a7f-5749-add0-d41303e21a8f', '068e3113-2fcf-5c2d-b598-e9123c35a208', '212c5286-05f4-47aa-8c00-ed7968551e08', 18.90, 5.24),
	('d69db3d7-7e4d-50d5-aadd-e114741a62e4', '068e3113-2fcf-5c2d-b598-e9123c35a208', '21d76d26-8608-47b8-b387-1e9f5b150715', 21.90, 5.24),
	('74d7d54c-5df4-5036-95a5-0272eaea85f2', '068e3113-2fcf-5c2d-b598-e9123c35a208', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 18.90, 5.24),
	('ea512b38-e980-5f32-b025-e4456890d0c1', '068e3113-2fcf-5c2d-b598-e9123c35a208', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 18.90, 5.24),
	('18e91ea0-96db-5b7f-a56b-69964132bb0b', 'd3419a4d-e153-5ecc-8001-c13084f849e2', '17b14f91-68d9-4a94-9374-c64846414581', 19.90, 3.30),
	('5f1a0045-471c-5080-b760-cd6a61a59253', 'd3419a4d-e153-5ecc-8001-c13084f849e2', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 19.90, 3.30),
	('e00494af-9b79-5c36-bbf8-7642eee04179', 'd3419a4d-e153-5ecc-8001-c13084f849e2', '212c5286-05f4-47aa-8c00-ed7968551e08', 19.90, 3.30),
	('b9fe81f5-dae6-530e-9c27-40588c923949', 'd3419a4d-e153-5ecc-8001-c13084f849e2', '21d76d26-8608-47b8-b387-1e9f5b150715', 22.90, 3.30),
	('06247bde-6d37-5bd4-9b76-7b800580f583', 'd3419a4d-e153-5ecc-8001-c13084f849e2', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 19.90, 3.30),
	('92e3772b-867e-5a1a-8dac-10fe1bbc0613', 'd3419a4d-e153-5ecc-8001-c13084f849e2', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 19.90, 3.30),
	('077a41c8-c3a4-5802-8b85-2cc11e73ce03', 'f3956615-8b83-5c19-a642-b623112407b3', '17b14f91-68d9-4a94-9374-c64846414581', 28.90, 6.60),
	('48ef33b3-00a8-5928-b2aa-93c47ec347bc', 'f3956615-8b83-5c19-a642-b623112407b3', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 28.90, 6.60),
	('bd183518-37d0-5e6a-8976-3bc8dddb4b8b', 'f3956615-8b83-5c19-a642-b623112407b3', '212c5286-05f4-47aa-8c00-ed7968551e08', 28.90, 6.60),
	('104b06b5-eda0-5990-8f4a-689f9430c791', 'f3956615-8b83-5c19-a642-b623112407b3', '21d76d26-8608-47b8-b387-1e9f5b150715', 32.90, 6.60),
	('bab0e71a-a129-54cd-8211-4b961a9be45b', 'f3956615-8b83-5c19-a642-b623112407b3', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 28.90, 6.60),
	('44271a26-a205-5c81-b985-57132710cd16', 'f3956615-8b83-5c19-a642-b623112407b3', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 28.90, 6.60),
	('a2ec5634-ca51-5927-a869-1ae8456af301', 'b517404e-3fe2-5ea7-b830-77285ed3b17e', '17b14f91-68d9-4a94-9374-c64846414581', 6.00, 3.20),
	('4cb6fead-0d27-537d-bd71-78a3755a2e4e', 'b517404e-3fe2-5ea7-b830-77285ed3b17e', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 6.00, 3.20),
	('1af5857e-fa1f-5b8e-a2c1-9d0140bd8925', 'b517404e-3fe2-5ea7-b830-77285ed3b17e', '212c5286-05f4-47aa-8c00-ed7968551e08', 6.00, 3.20),
	('f15df662-75c2-5fde-9a4d-07a39d7bb592', 'b517404e-3fe2-5ea7-b830-77285ed3b17e', '21d76d26-8608-47b8-b387-1e9f5b150715', 6.90, 3.20),
	('fc5cb2a7-1002-54cf-a72c-f798d6d72442', 'b517404e-3fe2-5ea7-b830-77285ed3b17e', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 6.00, 3.20),
	('92260e8f-9877-5856-bfc4-3db6e247e164', 'b517404e-3fe2-5ea7-b830-77285ed3b17e', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 6.00, 3.20),
	('72521252-1ae7-56a2-b394-d34d79fb3159', '00af665c-d8d1-5a50-baf0-ed7588538e33', '17b14f91-68d9-4a94-9374-c64846414581', 8.00, 2.50),
	('b44a360b-9ca0-5e41-bce9-956afbe299f3', '00af665c-d8d1-5a50-baf0-ed7588538e33', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 8.00, 2.50),
	('f53b2687-b735-5c42-8c08-c5dba30f266b', '00af665c-d8d1-5a50-baf0-ed7588538e33', '212c5286-05f4-47aa-8c00-ed7968551e08', 8.00, 2.50),
	('a3db9ff1-63d7-5698-be39-5a7514c84faa', '00af665c-d8d1-5a50-baf0-ed7588538e33', '21d76d26-8608-47b8-b387-1e9f5b150715', 8.90, 2.50),
	('c5aabb5e-84d1-57f7-bf69-1bda0fbc9617', '00af665c-d8d1-5a50-baf0-ed7588538e33', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 8.00, 2.50),
	('bdd7fe4e-b0c7-53b5-9dde-8ec726223942', '00af665c-d8d1-5a50-baf0-ed7588538e33', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 8.00, 2.50),
	('366aafc2-11f3-5761-aa87-8990b6098e84', 'e7f454b0-7c03-5761-9ff8-8d89af357fbd', '17b14f91-68d9-4a94-9374-c64846414581', 4.00, 1.10),
	('1f4f53c3-c398-577c-8abb-d86f79afda9e', 'e7f454b0-7c03-5761-9ff8-8d89af357fbd', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 4.00, 1.10),
	('5733d071-060f-5ea8-92ed-9827baa7b091', 'e7f454b0-7c03-5761-9ff8-8d89af357fbd', '212c5286-05f4-47aa-8c00-ed7968551e08', 4.00, 1.10),
	('1cefc152-9a01-5ad4-9f33-ae9e20d84783', 'e7f454b0-7c03-5761-9ff8-8d89af357fbd', '21d76d26-8608-47b8-b387-1e9f5b150715', 4.90, 1.10),
	('f70b5f87-06da-5b96-ba0a-295e44471d8b', 'e7f454b0-7c03-5761-9ff8-8d89af357fbd', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 4.00, 1.10),
	('f23e66df-f1c0-5601-a26b-33a15e424554', 'e7f454b0-7c03-5761-9ff8-8d89af357fbd', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 4.00, 1.10),
	('eb9e5bfb-d161-5189-a379-ab64bcc0c88f', '158d10c9-664c-5894-bc89-0110bdf46a2f', '17b14f91-68d9-4a94-9374-c64846414581', 12.90, 4.92),
	('a565c545-44ae-5207-870b-5f9d709ba091', '158d10c9-664c-5894-bc89-0110bdf46a2f', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 12.90, 4.92),
	('a6adba12-15b8-57d4-b2e1-bd1dfaa16740', '158d10c9-664c-5894-bc89-0110bdf46a2f', '212c5286-05f4-47aa-8c00-ed7968551e08', 12.90, 4.92),
	('19523557-1f3a-50f2-8ae1-e90c22a00082', '158d10c9-664c-5894-bc89-0110bdf46a2f', '21d76d26-8608-47b8-b387-1e9f5b150715', 14.90, 4.92),
	('793f1277-d08a-5b4d-a258-b09ce1f0d671', '158d10c9-664c-5894-bc89-0110bdf46a2f', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 12.90, 4.92),
	('92bc6a54-6c80-577f-b3d1-db74e9678a86', '158d10c9-664c-5894-bc89-0110bdf46a2f', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 12.90, 4.92);

INSERT INTO public.adicionais (id, nome, preco, ativo, ingrediente_id, quantidade_descontar) VALUES
	('941805df-8408-5015-9503-cdb1431a111e', 'Queijo extra (mussarela)', 3.00, true, '9b3ed9d7-3c06-5ddd-a5b0-95df914e720c', 0.030),
	('89359d37-14fd-5356-b91c-e162a8b3d3db', 'Bacon extra', 4.00, true, '414543a7-573b-520b-b10d-870bf78d6f33', 0.030),
	('239f51b2-d3ea-5b74-8553-15a77f9b5200', 'Cheddar extra', 3.00, true, '6bc778ed-7155-5666-9ef1-e6ca668e4b6e', 0.040),
	('1f8c286c-7129-5ba3-85e6-6800c9ad77bd', 'Hambúrguer extra (150g)', 7.00, true, 'e095410c-c189-5d6b-b893-008aa1019ac5', 1.000);

INSERT INTO public.produto_adicionais (id, produto_id, adicional_id) VALUES
	('b8841805-b433-5e0a-b482-a6fef96b994b', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '941805df-8408-5015-9503-cdb1431a111e'),
	('fb00086a-ee0a-5a83-a881-419a709ba030', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '89359d37-14fd-5356-b91c-e162a8b3d3db'),
	('c2b7faa3-476b-53e7-ae7b-29b63cdb7257', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '239f51b2-d3ea-5b74-8553-15a77f9b5200'),
	('55e76ef0-f787-54d2-a63e-1b9b37eba304', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', '1f8c286c-7129-5ba3-85e6-6800c9ad77bd'),
	('38044b88-9368-5772-9584-7b0e9be3c6ea', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '941805df-8408-5015-9503-cdb1431a111e'),
	('c6127eb1-6650-531e-bf22-a201b15fffc0', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '89359d37-14fd-5356-b91c-e162a8b3d3db'),
	('0cbc8964-b55e-5986-b3c2-5af8a1e2069b', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '239f51b2-d3ea-5b74-8553-15a77f9b5200'),
	('ba6fc61f-3c4c-5b41-8796-5b7ac224f17d', '98b4f2d4-2024-5765-b1e5-2bd23f55fd16', '1f8c286c-7129-5ba3-85e6-6800c9ad77bd'),
	('673a2299-a09b-5052-b13f-f406c3d8b280', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '941805df-8408-5015-9503-cdb1431a111e'),
	('0489845e-9dfc-5cda-91ab-acb89f526c9e', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '89359d37-14fd-5356-b91c-e162a8b3d3db'),
	('59dab4eb-b1b3-53ee-bd6f-2aa770c8dd92', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '239f51b2-d3ea-5b74-8553-15a77f9b5200'),
	('5ae09029-447b-5d7d-9dc3-27db7b6e33a1', 'd064f045-dc51-5458-a345-9a1cbb0aa173', '1f8c286c-7129-5ba3-85e6-6800c9ad77bd'),
	('70a1fec7-d27b-50d8-bf40-ea74dbddd38d', 'b031a180-1426-57ea-af57-42baa47e866f', '941805df-8408-5015-9503-cdb1431a111e'),
	('5e2fd9f5-b228-530a-a51e-8cdc342f2134', 'b031a180-1426-57ea-af57-42baa47e866f', '89359d37-14fd-5356-b91c-e162a8b3d3db'),
	('2323e056-d342-552d-89d4-b648dc112ec6', 'b031a180-1426-57ea-af57-42baa47e866f', '239f51b2-d3ea-5b74-8553-15a77f9b5200'),
	('ef37fad6-213a-5a03-bc37-bf7828df0492', 'b031a180-1426-57ea-af57-42baa47e866f', '1f8c286c-7129-5ba3-85e6-6800c9ad77bd'),
	('9915e8cb-c4dd-5a2c-9d7b-be527979bdc7', '068e3113-2fcf-5c2d-b598-e9123c35a208', '941805df-8408-5015-9503-cdb1431a111e'),
	('ac53636c-bf87-5475-8496-2bf71d627179', '068e3113-2fcf-5c2d-b598-e9123c35a208', '89359d37-14fd-5356-b91c-e162a8b3d3db'),
	('9cf10131-751e-5ed2-9e2a-974ed159ce77', '068e3113-2fcf-5c2d-b598-e9123c35a208', '239f51b2-d3ea-5b74-8553-15a77f9b5200'),
	('19a866c3-0b28-5b3b-acc6-de5bd235b1fb', '068e3113-2fcf-5c2d-b598-e9123c35a208', '1f8c286c-7129-5ba3-85e6-6800c9ad77bd');

INSERT INTO public.combos (id, nome, categoria_id, ativo, destaque, ordem_cardapio, foto_id_principal, foto_id_contingencia, foto_url_principal, foto_url_contingencia, foto_preferida, perfil_fiscal_id) VALUES
	('43fe4fc6-8971-5f77-85f1-f1c39487dff7', 'Combo Clássico', '0f386fe5-09df-5376-a0d0-fa4ab91813d1', true, true, 1, NULL, NULL, NULL, NULL, 'principal', NULL);

INSERT INTO public.combo_itens (id, combo_id, produto_id, quantidade) VALUES
	('9fb21240-fb7b-5ddb-a32d-fe5a5aa2557b', '43fe4fc6-8971-5f77-85f1-f1c39487dff7', 'eeb93f2a-378a-5417-8587-2fdd47ad73ec', 1),
	('b7c21339-563b-52de-bb48-aca96128e5f7', '43fe4fc6-8971-5f77-85f1-f1c39487dff7', 'd3419a4d-e153-5ecc-8001-c13084f849e2', 1),
	('695ec5a1-057c-547d-8bba-13742aa33753', '43fe4fc6-8971-5f77-85f1-f1c39487dff7', 'b517404e-3fe2-5ea7-b830-77285ed3b17e', 1);

INSERT INTO public.combo_precos (id, combo_id, forma_pagamento_id, preco, custo) VALUES
	('51739537-eb9b-5d54-88e1-f79b0e9c78ab', '43fe4fc6-8971-5f77-85f1-f1c39487dff7', '17b14f91-68d9-4a94-9374-c64846414581', 44.90, 15.10),
	('904ded39-1acb-5887-9505-dece97a0176d', '43fe4fc6-8971-5f77-85f1-f1c39487dff7', '19f2f926-8a9e-41a7-ba5f-2280b672950e', 44.90, 15.10),
	('c8177c7b-1623-587c-af4f-c28504666c4a', '43fe4fc6-8971-5f77-85f1-f1c39487dff7', '212c5286-05f4-47aa-8c00-ed7968551e08', 44.90, 15.10),
	('f9349c87-b64d-5cde-9303-ce54ac9ba832', '43fe4fc6-8971-5f77-85f1-f1c39487dff7', '21d76d26-8608-47b8-b387-1e9f5b150715', 51.90, 15.10),
	('aa0a64fe-ccf7-5a1a-9b6b-2aee3e9f2f1d', '43fe4fc6-8971-5f77-85f1-f1c39487dff7', '49db43bc-75cc-49e6-a4f2-4cbab36c7e71', 44.90, 15.10),
	('74fc08b0-b447-582b-a15f-d65a2e46c610', '43fe4fc6-8971-5f77-85f1-f1c39487dff7', 'd0e73585-ca32-43f7-8051-8469cc6034ba', 44.90, 15.10);


-- contadores (sequências)
select pg_catalog.setval('public.vendas_numero_pedido_seq', 1, false);
select pg_catalog.setval('public.ocorrencias_numero_seq', 1, false);
select pg_catalog.setval('public.arquivo_historico_id_seq', 1, false);

select pg_catalog.setval('public.ai_ajuda_id_seq', 289, true);


set session_replication_role = origin;
