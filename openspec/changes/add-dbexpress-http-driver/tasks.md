# Tasks

## 1. Estrutura e descoberta da API usada

- [ ] 1.1 Criar a estrutura `client/` (projeto Delphi Win32 da DLL), `gateway/` (módulo Go) e `tests/` (scripts SQL e projeto Delphi de teste), e verificar que o projeto da DLL vazio compila em Win32 e que `go build ./...` passa no Linux
- [ ] 1.2 Construir o proxy de log `fbclient.dll` (D2): exporta a API pública do Firebird 3–5, grava nome, argumentos, itens de info e tags de DPB/TPB/BPB em arquivo, e encaminha ao `fbclient.dll` real; verificar com um `TSQLConnection` Devart que abre, consulta e fecha com o proxy e gera log
- [ ] 1.3 Rodar o proxy com as telas principais da aplicação real e com o projeto de teste; gerar `docs/api-surface.md` com as funções, itens de info e tags usados, e registrar se aparece `fb_get_master_interface` (se aparecer, parar e revisar o design antes do grupo 3)
- [ ] 1.4 Montar o banco de teste `tests/schema.sql` com todos os tipos do Firebird 3–5 que a aplicação usa (inteiros, NUMERIC/DECIMAL, INT128, DECFLOAT, FLOAT/DOUBLE, CHAR/VARCHAR em vários charsets, DATE/TIME/TIMESTAMP com e sem fuso, BOOLEAN, BLOB texto e binário, NULL) e verificar que o script cria o banco sem erro em FB 3, 4 e 5

## 2. Protocolo

- [ ] 2.1 Escrever `docs/protocol.md` com opcodes, layout dos registros binários, códigos de categoria de erro, regras de `seq` e limites (D6, D8, D10, D11); verificar que cada operação do spec `gateway-protocol` tem um opcode
- [ ] 2.2 Implementar codificador/decodificador do protocolo em Go com testes de ida e volta para cada opcode; verificar com `go test ./protocol/...`
- [ ] 2.3 Implementar codificador/decodificador do protocolo em Delphi com testes DUnitX que leem arquivos de exemplo gerados pelos testes Go; verificar que os dois lados leem os mesmos bytes

## 3. Gateway: base e sessões

- [ ] 3.0 Criar `gateway/Dockerfile` (multi-stage, cgo, Debian slim com `libfbclient2`, usuário não root), `docker-compose.yml` (restart, porta, volumes somente leitura de configuração e certificados, `stop_grace_period`), `gateway/config.example.yml` e `docker-compose.test.yml` com Firebird 3/4/5; verificar que `docker compose build` passa e que `docker compose -f docker-compose.test.yml up` sobe gateway e Firebird
- [ ] 3.1 Carregar configuração de arquivo e de variáveis de ambiente (endereço, TLS, aliases, limites, timeouts) e recusar configuração inválida; verificar com testes que cobrem TLS sem certificado e alias vazio
- [ ] 3.2 Criar o binding cgo mínimo para as funções `isc_*` listadas em `docs/api-surface.md` e verificar com um teste de integração que conecta, executa `SELECT 1 FROM RDB$DATABASE` e desconecta num Firebird de teste
- [ ] 3.3 Implementar servidor HTTP/TLS com `POST /v1/rpc`, limite de corpo, negociação de versão e tabela de sessões com token aleatório de 128 bits e mutex por sessão; verificar com testes de versão incompatível e token inválido
- [ ] 3.4 Implementar attach/detach com resolução de alias (D9), remoção de tags de DPB de sistema de arquivos e recusa de caminho fora da lista; verificar com testes de alias não publicado e senha errada
- [ ] 3.5 Implementar `seq` com resposta guardada, repetição durante execução e keep-alive fora da sequência (D11, D12); verificar com testes que reenviam um `INSERT` (uma linha gravada), reenviam durante um `SELECT` lento (uma execução) e enviam keep-alive durante consulta longa (resposta imediata)
- [ ] 3.6 Implementar expiração por inatividade, limites de sessões totais e por endereço, e encerramento por `SIGTERM` com rollback; verificar com testes de transação aberta expirada e de `SIGTERM` com sessão aberta
- [ ] 3.7 Implementar log estruturado de sessões, erros e duração sem senhas nem valores de parâmetros; verificar com teste que procura a senha no log e não encontra

## 4. Gateway: transações, comandos e BLOBs

- [ ] 4.1 Implementar opcodes de transação (start, commit, rollback, com e sem retenção, várias transações por conexão) e verificar com teste de duas transações simultâneas na mesma sessão
- [ ] 4.2 Implementar prepare combinado (allocate + prepare + describe + describe_bind + stmt_type) e free; verificar com teste que compara a descrição devolvida com a do `libfbclient` direto
- [ ] 4.3 Implementar execute, execute immediate, execute com cursor devolvendo o primeiro lote, fetch em lotes e lista de chamadas adiadas; verificar com teste de consulta de 10 000 linhas comparando bytes com fetch direto
- [ ] 4.4 Implementar status vector completo com textos de `fb_interpret` (D10); verificar com teste de violação de chave primária e sessão ainda utilizável depois
- [ ] 4.5 Implementar BLOB: open com info e conteúdo embutido até o limite, leitura em blocos, create/put em blocos/close/cancel; verificar com teste de BLOB de 2 KB e de 50 MB com hash igual ao do banco
- [ ] 4.6 Implementar os itens de `isc_database_info` e `isc_transaction_info` listados em `docs/api-surface.md`; verificar com teste que compara cada item com a chamada direta

## 5. DLL: base, transporte e conexão

- [ ] 5.1 Implementar leitura de `fbclienthttp.ini` e de variáveis `FBHTTP_*` com prioridade para o ambiente; verificar com testes DUnitX, incluindo URL ausente
- [ ] 5.2 Implementar transporte WinHTTP (sessão por processo, keep-alive por conexão, HTTPS com validação de certificado, opção explícita para HTTP ou certificado não confiável, timeouts, repetição com mesmo `seq`); verificar com testes contra o gateway com certificado válido, certificado autoassinado e gateway desligado
- [ ] 5.3 Implementar tabela de handles e barreira de exceção em cada export (D3, D7), com stubs "not supported by fbclienthttp" para todas as funções fora de `docs/api-surface.md`; verificar com teste de handle liberado que devolve o status de handle inválido sem violação de acesso
- [ ] 5.4 Implementar `isc_attach_database`, `isc_detach_database`, `isc_database_info`, keep-alive em segundo plano e conversão de falha de rede para `isc_network_error`; verificar com `TSQLConnection` Devart que abre e fecha pelo gateway sem `fbclient.dll` carregado (conferir módulos do processo)
- [ ] 5.5 Implementar status vector local, `fb_interpret`, `isc_interprete`, `isc_sql_interprete` e `isc_sqlcode`; verificar com teste de erro de sintaxe que compara a mensagem da exceção Devart com a do cliente nativo

## 6. DLL: transações, comandos e BLOBs

- [ ] 6.1 Implementar `isc_start_transaction`/`isc_start_multiple`, commit, rollback, retenção e `isc_transaction_info`; verificar com teste DUnitX de rollback e de duas transações abertas na mesma conexão
- [ ] 6.2 Implementar allocate/prepare/describe/describe_bind/sql_info com cache local e chamadas adiadas de free e set_cursor_name; verificar com teste que conta requisições HTTP de um prepare + execute + close (alvo: 1 requisição para o prepare, 1 para o execute com primeiro lote)
- [ ] 6.3 Implementar execute, execute2, execute immediate e fetch a partir do lote local, com escrita em `XSQLDA` num único módulo com checagem de limites; verificar com teste de 10 000 linhas e lote 500 com no máximo 21 requisições e com FastMM em full debug sem erros
- [ ] 6.4 Implementar BLOB (open2 com conteúdo embutido, get_segment local, leitura em blocos, create2, put_segment com buffer, close, cancel, blob_info); verificar com teste de BLOB de 2 KB em 1 requisição e de 50 MB com hash igual
- [ ] 6.5 Verificar uso por várias threads: duas threads com duas conexões consultando ao mesmo tempo por 1 minuto sem erro nem bloqueio

## 7. Integração e entrega

- [ ] 7.1 Teste de comparação: rodar `tests/` pelo `fbclient.dll` nativo e pela `fbclienthttp.dll` com o driver Devart em `TSQLConnection`/`TSQLQuery`/`TClientDataSet` (tipos, NULL, BLOB, erros, transações, `GetTableNames`/`GetFieldNames`) em FB 3, 4 e 5, e verificar resultado igual campo a campo
- [ ] 7.2 Rodar as telas principais da aplicação real com a DLL nova e verificar que funcionam sem mudança de código
- [ ] 7.3 Medir tempos com a aplicação real e o teste de comparação em rede local e com latência simulada de 30 ms; ajustar tamanho padrão do lote e limite de BLOB embutido; registrar resultados em `docs/performance.md`
- [ ] 7.4 Escrever `docs/deploy.md` com instalação por Docker Compose, TLS, aliases e rollback; verificar subindo do zero numa VM Linux limpa só com Docker, seguindo só o documento
- [ ] 7.5 Escrever `docs/client-setup.md` (cópia da DLL e do `.ini`, `VendorLib`, `Database`, rollback) e verificar configurando uma estação limpa seguindo só o documento
