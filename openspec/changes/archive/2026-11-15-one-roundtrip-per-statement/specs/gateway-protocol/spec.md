# Spec Delta

## ADDED Requirements

### Requirement: Versão 2 do protocolo
O protocolo SHALL ter a versão 2, que substitui a versão 1 e acrescenta: id de comando escolhido pelo cliente na preparação, descrição esperada na execução (campo sempre presente, vazio quando não há) e lote limitado por bytes. O gateway SHALL aceitar só a versão 2. A versão 1 SHALL NOT ser aceita: não há instalação em produção que a use.

#### Scenario: Sessão na versão 2
- **WHEN** a biblioteca cria uma sessão com versão 2
- **THEN** o gateway aceita, e as requisições dessa sessão podem usar id de comando do cliente e descrição esperada

#### Scenario: Versão 1 recusada
- **WHEN** uma biblioteca antiga pede uma sessão com versão 1
- **THEN** o gateway recusa com o erro de versão, que informa que só a versão 2 é aceita, sem abrir conexão Firebird

### Requirement: Preparação com id escolhido pelo cliente
A operação de preparação SHALL aceitar um id de comando escolhido pelo cliente, na mesma faixa reservada já usada para transações. Com esse id, o gateway SHALL alocar o comando e registrá-lo com o id pedido, para que operações seguintes do mesmo lote possam usá-lo. Um id fora da faixa, ou já em uso na sessão, SHALL ser erro de protocolo. Se a preparação falhar, o id SHALL NOT ficar registrado.

#### Scenario: Preparação e execução no mesmo lote
- **WHEN** um lote contém a preparação de um SQL com id de comando escolhido pelo cliente, seguida da execução desse id
- **THEN** o gateway prepara, executa e devolve os dois resultados na mesma resposta

#### Scenario: Id já em uso
- **WHEN** a preparação chega com um id de comando que já identifica outro comando da sessão
- **THEN** o gateway responde erro de protocolo e não prepara nada

#### Scenario: Preparação falha
- **WHEN** a preparação com id do cliente falha no Firebird
- **THEN** a resposta traz o erro do Firebird, o id não existe na sessão e a execução seguinte do lote não é processada (lote para no primeiro erro de operação não adiada)

### Requirement: Validação da descrição na execução
A operação de execução SHALL levar um campo de descrição esperada de colunas e parâmetros (tipos, escala, subtipo e tamanho), que pode estar vazio. Quando preenchido, o gateway SHALL compará-lo com a descrição real do comando preparado e, se diferirem, SHALL responder um erro de categoria protocolo que identifica "descrição do comando mudou", sem executar. Com o campo vazio, a execução SHALL comportar-se como antes.

#### Scenario: Descrição igual
- **WHEN** a execução traz a descrição esperada e ela é igual à do comando preparado
- **THEN** o gateway executa normalmente

#### Scenario: Descrição diferente
- **WHEN** a execução traz uma descrição esperada com uma coluna a menos que a do comando preparado
- **THEN** o gateway responde erro de categoria protocolo que identifica a mudança de descrição, não executa, e a sessão continua utilizável

## MODIFIED Requirements

### Requirement: Lotes de linhas
A operação de execução de um comando com cursor SHALL devolver o primeiro lote de linhas na mesma resposta. A operação de busca SHALL devolver até N linhas por resposta, com N pedido pela biblioteca e limitado pelo gateway em linhas e em bytes, e SHALL informar se o cursor terminou. Um lote que parou pelo limite de bytes SHALL devolver pelo menos uma linha e SHALL NOT indicar fim do cursor.

#### Scenario: Consulta pequena em uma ida e volta
- **WHEN** a biblioteca executa um `SELECT` que retorna 30 linhas com lote de 100
- **THEN** uma única resposta traz as 30 linhas e a indicação de fim do cursor

#### Scenario: Lote limitado por bytes
- **WHEN** a biblioteca pede 5 000 linhas e as linhas somam mais que o limite de bytes do gateway
- **THEN** a resposta traz as linhas que cabem no limite, pelo menos uma, sem indicação de fim de cursor, e a busca seguinte continua da linha seguinte

### Requirement: Operações
O protocolo SHALL ter operações equivalentes às funções da API do Firebird que a biblioteca exporta: conexão e desconexão, informações do banco, transações (iniciar, confirmar, desfazer, com e sem retenção), comandos (alocar, preparar, descrever, executar, executar imediato, buscar linhas, liberar) e BLOBs (criar, abrir, ler, gravar, fechar, cancelar, informações). O protocolo SHALL também ter uma operação para manter a sessão viva. Operações de início de transação, preparação, confirmação, desfazimento e liberação SHALL poder ser marcadas como adiadas pelo cliente e viajar no mesmo lote de operações posteriores que dependem delas.

#### Scenario: Prepare devolve descrição completa
- **WHEN** a biblioteca prepara um `SELECT`
- **THEN** uma única resposta traz o handle do comando, o tipo do comando e a descrição de todas as colunas e parâmetros

#### Scenario: Lote com confirmação adiada, início, preparação e execução
- **WHEN** um lote traz, nesta ordem, a confirmação de uma transação anterior, o início de uma transação com id do cliente, a preparação de um comando com id do cliente e a execução desse comando nessa transação
- **THEN** o gateway processa as quatro operações em ordem numa única resposta
