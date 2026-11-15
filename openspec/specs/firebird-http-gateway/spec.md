# firebird-http-gateway Specification

## Purpose

Servidor HTTP que roda em Linux perto do Firebird 3–5, mantém uma sessão com estado para cada conexão aberta pela biblioteca `ws-fbclient.dll` e executa no banco as chamadas que ela envia.

## Requirements

### Requirement: Execução em Linux
O gateway SHALL rodar em Linux x86-64 como um serviço único, distribuído como imagem Docker com um `Dockerfile` e um `docker-compose.yml` prontos para uso. Ele SHALL ler a configuração (endereço, porta, TLS, aliases de banco publicados, limites e timeouts) de um arquivo e de variáveis de ambiente.

#### Scenario: Inicialização
- **WHEN** o serviço inicia com uma configuração válida
- **THEN** ele aceita requisições na porta configurada e registra no log a versão do protocolo e a versão do `libfbclient`

#### Scenario: Subida com Docker Compose
- **WHEN** o operador edita a configuração de exemplo e roda `docker compose up -d`
- **THEN** o gateway sobe num container com `libfbclient` incluído, aceita requisições na porta publicada e volta sozinho após reinício do host

#### Scenario: Configuração inválida
- **WHEN** o serviço inicia com TLS ativo e sem certificado legível
- **THEN** ele termina com código diferente de 0 e uma mensagem que cita o item inválido

### Requirement: Sessões com estado
O gateway SHALL abrir uma conexão Firebird dedicada para cada sessão. Ele SHALL manter entre requisições HTTP todos os comandos, cursores, BLOBs e transações dessa sessão, incluindo mais de uma transação ao mesmo tempo.

#### Scenario: Transação entre requisições
- **WHEN** a biblioteca inicia uma transação, executa um `INSERT` numa requisição e confirma em outra
- **THEN** a linha é gravada uma única vez, dentro da mesma transação

#### Scenario: Isolamento entre sessões
- **WHEN** duas sessões executam comandos ao mesmo tempo
- **THEN** cada sessão vê só os próprios dados não confirmados

### Requirement: Expiração de sessões
O gateway SHALL encerrar sessões sem atividade além do tempo configurado. Ao encerrar, ele SHALL desfazer as transações abertas e SHALL fechar a conexão Firebird.

#### Scenario: Cliente some com transação aberta
- **WHEN** um cliente para de enviar requisições com uma transação aberta e o tempo de inatividade termina
- **THEN** o gateway faz rollback, fecha a conexão Firebird e responde "sessão inválida" a requisições futuras com aquele identificador

### Requirement: Autenticação e autorização
O gateway SHALL abrir os bancos só no servidor Firebird configurado (`firebird_host`) ou nos destinos dos aliases configurados, e SHALL NOT conectar a um servidor indicado pelo cliente. O host que o cliente manda antes do primeiro `:` SHALL ser ignorado. Usuário e senha SHALL ser validados pelo próprio Firebird ao abrir a conexão. Toda requisição depois da criação SHALL exigir um token de sessão imprevisível.

#### Scenario: Banco no servidor configurado
- **WHEN** a biblioteca pede uma sessão para `localhost:alias_do_servidor` e o gateway tem `firebird_host` configurado
- **THEN** o gateway abre `alias_do_servidor` no `firebird_host`

#### Scenario: Outro servidor pedido pelo cliente
- **WHEN** a biblioteca pede uma sessão com um segundo host (`a:outro:/banco.fdb`), caminho UNC ou URL (`inet://`)
- **THEN** o gateway recusa a sessão sem abrir conexão Firebird

#### Scenario: Sem servidor configurado
- **WHEN** o gateway não tem `firebird_host` e o nome pedido não está nos aliases
- **THEN** o gateway recusa a sessão sem abrir conexão Firebird

#### Scenario: Senha errada
- **WHEN** o Firebird rejeita usuário ou senha
- **THEN** o gateway devolve o erro de login do Firebird e não cria sessão

#### Scenario: Token inválido
- **WHEN** uma requisição chega com token de sessão desconhecido
- **THEN** o gateway responde erro de sessão inválida e não executa nada

### Requirement: Limites de recursos
O gateway SHALL limitar o número de sessões simultâneas, as sessões por endereço de cliente, o tamanho do corpo da requisição e o tamanho do lote de linhas. Quando um limite é atingido, ele SHALL responder com erro de categoria limite.

#### Scenario: Limite de sessões
- **WHEN** o número máximo de sessões está em uso e chega um pedido de nova sessão
- **THEN** o gateway recusa o pedido com erro de limite e as sessões existentes continuam funcionando

### Requirement: Encerramento limpo
Ao receber sinal de parada, o gateway SHALL parar de aceitar sessões novas, SHALL desfazer as transações abertas e SHALL fechar todas as conexões Firebird antes de sair.

#### Scenario: SIGTERM
- **WHEN** o processo recebe `SIGTERM` com sessões abertas
- **THEN** todas as transações abertas recebem rollback e o processo termina com código 0

### Requirement: Observabilidade
O gateway SHALL registrar em log a criação e o fim de sessões, os erros e a duração de cada requisição. O log SHALL NOT conter senhas nem valores de parâmetros SQL.

#### Scenario: Log de criação de sessão
- **WHEN** uma sessão é criada
- **THEN** o log contém usuário, alias e endereço do cliente, e não contém a senha
