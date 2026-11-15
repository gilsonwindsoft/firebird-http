# Spec Delta

## MODIFIED Requirements

### Requirement: Limites de recursos
O gateway SHALL limitar o número de sessões simultâneas, as sessões por endereço de cliente, o tamanho do corpo da requisição, o tamanho do lote de linhas em linhas e o tamanho do lote de linhas em bytes. Quando um limite de sessões ou de corpo é atingido, ele SHALL responder com erro de categoria limite. Quando o limite de bytes do lote é atingido, ele SHALL devolver um lote parcial, sem erro.

#### Scenario: Limite de sessões
- **WHEN** o número máximo de sessões está em uso e chega um pedido de nova sessão
- **THEN** o gateway recusa o pedido com erro de limite e as sessões existentes continuam funcionando

#### Scenario: Limite de bytes do lote
- **WHEN** uma busca pede 5 000 linhas de 10 KB cada e o limite de bytes do lote é 4 MB
- **THEN** o gateway devolve um lote de cerca de 400 linhas, sem erro e sem indicar fim do cursor

### Requirement: Observabilidade
O gateway SHALL registrar em log a criação e o fim de sessões, os erros, a duração de cada requisição e, separadamente, o tempo que essa requisição gastou dentro das chamadas ao `libfbclient`. O log SHALL NOT conter senhas nem valores de parâmetros SQL.

#### Scenario: Log de criação de sessão
- **WHEN** uma sessão é criada
- **THEN** o log contém usuário, alias e endereço do cliente, e não contém a senha

#### Scenario: Tempo no Firebird por requisição
- **WHEN** uma requisição com preparação e execução é processada
- **THEN** a linha de log da requisição traz a duração total e a duração somada das chamadas ao `libfbclient`, as duas em milissegundos
