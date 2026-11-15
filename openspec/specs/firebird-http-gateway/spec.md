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
O gateway SHALL limitar o número de sessões simultâneas, as sessões por endereço de cliente, o tamanho do corpo da requisição, o tamanho do lote de linhas em linhas e o tamanho do lote de linhas em bytes. Quando um limite de sessões ou de corpo é atingido, ele SHALL responder com erro de categoria limite. Quando o limite de bytes do lote é atingido, ele SHALL devolver um lote parcial, sem erro.

#### Scenario: Limite de sessões
- **WHEN** o número máximo de sessões está em uso e chega um pedido de nova sessão
- **THEN** o gateway recusa o pedido com erro de limite e as sessões existentes continuam funcionando

#### Scenario: Limite de bytes do lote
- **WHEN** uma busca pede 5 000 linhas de 10 KB cada e o limite de bytes do lote é 4 MB
- **THEN** o gateway devolve um lote de cerca de 400 linhas, sem erro e sem indicar fim do cursor

### Requirement: Encerramento limpo
Ao receber sinal de parada, o gateway SHALL parar de aceitar sessões novas, SHALL desfazer as transações abertas e SHALL fechar todas as conexões Firebird antes de sair.

#### Scenario: SIGTERM
- **WHEN** o processo recebe `SIGTERM` com sessões abertas
- **THEN** todas as transações abertas recebem rollback e o processo termina com código 0

### Requirement: Observabilidade
O gateway SHALL registrar em log a criação e o fim de sessões, os erros, a duração de cada requisição e, separadamente, o tempo que essa requisição gastou dentro das chamadas ao `libfbclient`. O log SHALL NOT conter senhas nem valores de parâmetros SQL.

#### Scenario: Log de criação de sessão
- **WHEN** uma sessão é criada
- **THEN** o log contém usuário, alias e endereço do cliente, e não contém a senha

#### Scenario: Tempo no Firebird por requisição
- **WHEN** uma requisição com preparação e execução é processada
- **THEN** a linha de log da requisição traz a duração total e a duração somada das chamadas ao `libfbclient`, as duas em milissegundos

### Requirement: Aliases em arquivo com recarga sem reinício
O gateway SHALL aceitar os aliases de banco num arquivo de texto indicado por `FBHTTP_ALIASES_FILE` (ou `aliases_file` no arquivo de configuração), com um alias por linha no formato `nome = destino`, linhas em branco e comentários iniciados por `#`. O gateway SHALL reler esse arquivo periodicamente (a cada 60 segundos) e SHALL aplicar a nova tabela aos ATTACH seguintes sem reiniciar o processo e sem encerrar sessões abertas. Uma recarga com arquivo inválido ou ilegível SHALL manter a tabela anterior e SHALL registrar o erro no log. Uma recarga que deixaria o gateway sem aliases e sem `firebird_host` SHALL ser recusada da mesma forma. O gateway SHALL recusar iniciar quando `aliases_file` e `aliases` forem informados juntos no arquivo de configuração. O gateway SHALL NOT ler aliases da variável `FBHTTP_ALIASES`; se ela estiver definida, SHALL registrar um aviso no log na inicialização.

#### Scenario: Inclusão de servidor sem reinício
- **WHEN** o operador acrescenta a linha `filial2 = 10.0.0.7:/dados/erp.fdb` ao arquivo de aliases com o gateway rodando
- **THEN** em até 60 segundos um ATTACH para `filial2` abre `10.0.0.7:/dados/erp.fdb`, sem reinício do gateway

#### Scenario: Remoção de servidor com sessão aberta
- **WHEN** o operador remove do arquivo um alias que tem sessões abertas
- **THEN** as sessões abertas continuam funcionando até serem fechadas ou expirarem, e novos ATTACH para esse alias são recusados como banco não permitido

#### Scenario: Arquivo inválido durante a execução
- **WHEN** o operador grava o arquivo com uma linha sem `=` ou com nome contendo `:`, `/` ou `\`
- **THEN** o gateway mantém a tabela anterior, continua aceitando os aliases antigos e registra no log o erro com o número da linha

#### Scenario: Arquivo inválido na inicialização
- **WHEN** o gateway inicia com `FBHTTP_ALIASES_FILE` apontando para um arquivo inexistente ou inválido
- **THEN** ele termina com código diferente de 0 e uma mensagem que cita o arquivo e o item inválido

#### Scenario: Duas fontes de aliases
- **WHEN** o gateway inicia com `aliases_file` e `aliases` no arquivo de configuração
- **THEN** ele termina com código diferente de 0 e uma mensagem que cita os dois itens

#### Scenario: Variável antiga definida
- **WHEN** o gateway inicia com `FBHTTP_ALIASES` definida
- **THEN** ele ignora o conteúdo da variável, não publica nenhum alias a partir dela e registra no log um aviso para usar `FBHTTP_ALIASES_FILE`
