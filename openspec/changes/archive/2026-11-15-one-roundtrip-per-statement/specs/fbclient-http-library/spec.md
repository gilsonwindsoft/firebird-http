# Spec Delta

## ADDED Requirements

### Requirement: Cache de preparação por conexão
A biblioteca SHALL guardar, por conexão, o resultado da preparação de cada comando (tipo do comando, descrição de colunas e de parâmetros, itens de informação do comando), indexado pelo texto SQL e pelo dialeto. Quando o driver prepara de novo um SQL que está no cache, a biblioteca SHALL responder `isc_dsql_prepare`, `isc_dsql_describe`, `isc_dsql_describe_bind` e `isc_dsql_sql_info` a partir do cache, sem requisição de rede, e SHALL enviar a preparação real ao gateway na mesma requisição da primeira operação que usa o comando (execução, informação ou liberação). O cache SHALL ter tamanho máximo configurável, com descarte das entradas menos usadas, e SHALL poder ser desligado na configuração.

#### Scenario: SQL repetido custa uma ida e volta
- **WHEN** a aplicação já executou `SELECT * FROM CLIENTES WHERE ID = :ID` nesta conexão, e abre de novo um `TSQLQuery` com o mesmo SQL numa transação ainda não iniciada no gateway
- **THEN** a biblioteca faz uma única requisição de rede, que leva o início da transação, a preparação e a execução com o primeiro lote, e o dataset tem as mesmas linhas, colunas e tipos que teria com o cliente nativo

#### Scenario: SQL novo
- **WHEN** a aplicação prepara um SQL que não está no cache desta conexão
- **THEN** a biblioteca faz a requisição de preparação na hora, responde a descrição real ao driver e guarda o resultado no cache

#### Scenario: Descrição mudou no servidor
- **WHEN** um SQL está no cache, o schema mudou de forma que a descrição real de colunas ou parâmetros difere da guardada, e a aplicação prepara e executa esse SQL
- **THEN** a execução devolve ao driver um status vector de erro que informa que a descrição do comando mudou, a biblioteca remove a entrada do cache, e a próxima preparação do mesmo SQL vai ao gateway e devolve a descrição nova

#### Scenario: Preparação adiada falha com erro do Firebird
- **WHEN** a preparação adiada de um SQL do cache falha no gateway (por exemplo, a tabela foi removida)
- **THEN** a aplicação recebe o erro do Firebird na chamada que disparou a requisição, com o mesmo código e mensagem que receberia no `isc_dsql_prepare` nativo, e a entrada sai do cache

#### Scenario: Cache desligado
- **WHEN** a configuração desliga o cache de preparação
- **THEN** toda preparação vai ao gateway na hora, como antes desta mudança

#### Scenario: Gateway com outra versão do protocolo
- **WHEN** a biblioteca pede uma sessão com a versão 2 do protocolo e o gateway responde erro de versão
- **THEN** a conexão falha com uma mensagem que informa a versão pedida e as versões que o gateway aceita, sem tentar outra versão

### Requirement: Encerramento adiado de transação sem escrita
A biblioteca SHALL registrar, por transação, se algum comando capaz de escrever foi executado nela: qualquer comando cujo tipo não seja `SELECT` ou `SELECT FOR UPDATE`, qualquer execução imediata, e qualquer criação ou gravação de BLOB. Para uma transação sem escrita registrada, `isc_commit_transaction`, `isc_commit_retaining`, `isc_rollback_transaction` e `isc_rollback_retaining` SHALL devolver sucesso sem requisição de rede, e a operação SHALL ser enviada ao gateway na próxima requisição da conexão, antes das demais operações dessa requisição e na ordem em que foi pedida. Uma transação que nunca foi iniciada no gateway e é encerrada SHALL NOT gerar operação alguma. Operações adiadas SHALL ser enviadas também quando a conexão fica ociosa por mais que um tempo curto configurável, no `isc_detach_database`, e sempre antes de um `COMMIT` ou `ROLLBACK` de transação com escrita. Para uma transação com escrita registrada, o encerramento SHALL continuar síncrono: a chamada só retorna depois que o gateway confirmou. O adiamento SHALL poder ser desligado na configuração.

#### Scenario: Dataset só de leitura
- **WHEN** a aplicação abre um `TSQLQuery` com `SELECT`, lê as linhas, fecha o dataset e o driver confirma a transação
- **THEN** a confirmação retorna sem requisição de rede, e a operação de confirmação vai na próxima requisição da conexão

#### Scenario: Ordem preservada
- **WHEN** a aplicação confirma uma transação só de leitura e em seguida inicia outra transação e executa um comando
- **THEN** o gateway recebe numa única requisição, nesta ordem: a confirmação da transação anterior, o início da nova transação e o comando

#### Scenario: Transação com escrita
- **WHEN** a aplicação executa um `UPDATE` numa transação e chama `Commit`
- **THEN** a chamada de `Commit` só retorna depois que o gateway confirmou a transação no Firebird, e qualquer operação adiada vai na mesma requisição, antes da confirmação

#### Scenario: Conexão ociosa com encerramento pendente
- **WHEN** uma confirmação adiada está pendente e a conexão fica ociosa além do tempo configurado
- **THEN** a biblioteca envia a operação pendente sem esperar nova chamada da aplicação, e a transação Firebird correspondente é encerrada no gateway

#### Scenario: Erro na operação adiada
- **WHEN** a confirmação adiada de uma transação só de leitura falha no gateway
- **THEN** o erro não interrompe as demais operações da requisição e é registrado no log de diagnóstico

### Requirement: Diagnóstico de requisições
Com o log de diagnóstico ativo, a biblioteca SHALL registrar, para cada requisição de rede, as operações enviadas, o tamanho do corpo enviado e recebido e a duração em milissegundos. A biblioteca SHALL manter contadores por conexão de requisições feitas e de tempo total gasto em rede, consultáveis pelo teste de comparação. O log SHALL NOT conter texto SQL, valores de parâmetros nem senhas.

#### Scenario: Requisição registrada
- **WHEN** a biblioteca envia uma requisição com início de transação, preparação e execução, com o log de diagnóstico ativo
- **THEN** o log tem uma linha com os três códigos de operação, os tamanhos e a duração, e não tem o texto do SQL

## MODIFIED Requirements

### Requirement: Mesmo comportamento do cliente nativo
Para o mesmo banco e a mesma sequência de chamadas, a biblioteca SHALL devolver os mesmos dados, a mesma descrição de colunas e parâmetros (`XSQLDA`), os mesmos códigos de status e as mesmas mensagens de erro que o `fbclient.dll` nativo devolveria. Isso vale para todos os tipos do Firebird 3–5 que o driver Devart usa, BLOBs, NULL e mais de uma transação na mesma conexão. A única exceção permitida é a descrição de um comando cujo SQL está no cache de preparação e cujo schema mudou depois: nesse caso a biblioteca SHALL devolver um erro na execução e SHALL devolver a descrição nova na preparação seguinte, conforme o requisito "Cache de preparação por conexão".

#### Scenario: Consulta com parâmetros
- **WHEN** um `TSQLQuery` com `SELECT ... WHERE ID = :ID` é aberto com `ID = 10`
- **THEN** o dataset tem as mesmas linhas, colunas, tipos e valores que tem com o `fbclient.dll` nativo

#### Scenario: Decimal sem perda
- **WHEN** uma consulta lê `NUMERIC(18,4)` com valor `12345678901234.5678`
- **THEN** o campo contém exatamente `12345678901234.5678`

#### Scenario: BLOB grande
- **WHEN** uma consulta lê um BLOB binário de 50 MB
- **THEN** o campo contém os mesmos bytes que estão no banco

#### Scenario: Erro do Firebird
- **WHEN** um `INSERT` viola uma chave primária
- **THEN** a aplicação recebe a mesma exceção, com o mesmo código e a mesma mensagem que recebe com o cliente nativo

#### Scenario: Rollback
- **WHEN** a aplicação inicia transação, executa `INSERT` e chama `Rollback`
- **THEN** a linha não existe no banco

#### Scenario: Metadados
- **WHEN** a aplicação chama `TSQLConnection.GetTableNames`
- **THEN** a lista é igual à lista obtida com o cliente nativo

#### Scenario: Roteiro de comparação com cache e adiamento ligados
- **WHEN** o roteiro de comparação (`fbcompare`) roda com o cliente nativo e com a biblioteca, com cache de preparação e encerramento adiado ligados, em FB 3
- **THEN** as duas saídas são iguais

### Requirement: Busca em lotes
A biblioteca SHALL buscar linhas do gateway em lotes e SHALL entregar ao driver uma linha por chamada de busca a partir do lote já recebido. Uma busca atendida pelo lote local SHALL NOT gerar requisição de rede. O tamanho do lote pedido SHALL ser configurável, com padrão de 5 000 linhas, e o gateway pode devolver menos linhas quando atinge o limite de bytes por lote.

#### Scenario: Consulta com 10 000 linhas
- **WHEN** a aplicação percorre 10 000 linhas de até 100 bytes cada com o lote padrão de 5 000 linhas
- **THEN** a biblioteca faz no máximo 3 requisições de rede para essa consulta, incluindo a execução

#### Scenario: Lote limitado por bytes
- **WHEN** o gateway devolve um lote menor que o pedido por ter atingido o limite de bytes, sem indicar fim do cursor
- **THEN** a biblioteca continua a entregar linhas e pede o próximo lote quando o atual acaba
