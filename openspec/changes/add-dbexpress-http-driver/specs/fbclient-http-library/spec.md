# Spec Delta

## Purpose

DLL Windows 32 bits que o driver dbExpress da Devart carrega como `fbclient.dll` (parâmetro `VendorLib`), e que executa as chamadas da API do Firebird pelo gateway HTTP, sem cliente Firebird instalado na estação.

## ADDED Requirements

### Requirement: Substituição transparente do fbclient
A biblioteca SHALL ser uma DLL Windows 32 bits que exporta, com o mesmo nome, a mesma assinatura e a convenção `stdcall`, todas as funções da API do Firebird que o driver dbExpress da Devart chama. Uma aplicação SHALL funcionar só com a troca de `VendorLib` e de `Database`, sem outra mudança de código ou de driver.

#### Scenario: Abrir conexão
- **WHEN** a aplicação configura `VendorLib = fbclienthttp.dll` e `Database` com um alias publicado no gateway, e abre a `TSQLConnection`
- **THEN** a conexão abre sem erro e nenhum `fbclient.dll` é carregado no processo

#### Scenario: Função não suportada
- **WHEN** o driver chama uma função exportada que a biblioteca não implementa por completo
- **THEN** a função devolve um status vector de erro com mensagem "not supported by fbclienthttp", e o processo não trava

### Requirement: Configuração do gateway
A biblioteca SHALL ler a URL do gateway, as opções de TLS e os timeouts de um arquivo de configuração na pasta da DLL e de variáveis de ambiente. Variáveis de ambiente SHALL ter prioridade sobre o arquivo. O usuário, a senha, a role e o charset SHALL vir dos parâmetros que o driver já envia na conexão.

#### Scenario: URL ausente
- **WHEN** a conexão abre e não há URL do gateway configurada
- **THEN** a conexão falha com uma mensagem que diz onde configurar a URL

### Requirement: Mesmo comportamento do cliente nativo
Para o mesmo banco e a mesma sequência de chamadas, a biblioteca SHALL devolver os mesmos dados, a mesma descrição de colunas e parâmetros (`XSQLDA`), os mesmos códigos de status e as mesmas mensagens de erro que o `fbclient.dll` nativo devolveria. Isso vale para todos os tipos do Firebird 3–5 que o driver Devart usa, BLOBs, NULL e mais de uma transação na mesma conexão.

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

### Requirement: Busca em lotes
A biblioteca SHALL buscar linhas do gateway em lotes e SHALL entregar ao driver uma linha por chamada de busca a partir do lote já recebido. Uma busca atendida pelo lote local SHALL NOT gerar requisição de rede.

#### Scenario: Consulta com 10 000 linhas
- **WHEN** a aplicação percorre 10 000 linhas com lote de 500 linhas
- **THEN** a biblioteca faz no máximo 21 requisições de rede para essa consulta

### Requirement: Falhas de rede
A biblioteca SHALL converter falhas de rede e timeouts em status vectors de erro de conexão do Firebird, para que o driver gere a exceção normal de conexão perdida. Uma falha de rede SHALL NOT encerrar nem travar o processo.

#### Scenario: Gateway inacessível
- **WHEN** o gateway não responde dentro do timeout configurado
- **THEN** a aplicação recebe uma exceção de conexão do banco e o processo continua estável

#### Scenario: Sessão expirada
- **WHEN** a sessão expirou no gateway e a aplicação executa um comando
- **THEN** a aplicação recebe a exceção de conexão perdida e consegue reconectar abrindo a conexão de novo

### Requirement: Segurança de memória e threads
A biblioteca SHALL validar handles e ponteiros que recebe do driver, como o cliente nativo valida. Ela SHALL aceitar chamadas de threads diferentes, com cada conexão usada por uma thread de cada vez, como o cliente nativo aceita.

#### Scenario: Handle inválido
- **WHEN** o driver passa um handle de comando já liberado
- **THEN** a função devolve o status de handle inválido do Firebird, sem violação de acesso

#### Scenario: Duas conexões em threads diferentes
- **WHEN** duas threads usam duas conexões diferentes ao mesmo tempo
- **THEN** as duas funcionam sem bloquear uma à outra

### Requirement: Transporte seguro
A biblioteca SHALL usar HTTPS com validação de certificado por padrão. HTTP sem TLS, ou certificado não confiável, SHALL exigir uma opção explícita na configuração.

#### Scenario: Certificado inválido
- **WHEN** o gateway apresenta um certificado não confiável e a configuração não tem opção para aceitá-lo
- **THEN** a conexão falha com erro de certificado
