# Design

## Context

Ver proposal.md para a motivação. O projeto é novo e ainda não tem código. Restrições fixas:

- Cliente: aplicação Delphi 10.x–12, só Win32, `TSQLConnection` com o driver dbExpress da Devart para InterBase/Firebird. O driver não muda. Ele carrega a biblioteca cliente indicada em `VendorLib`.
- Servidor: Linux, Firebird 3, 4 ou 5.
- Transações explícitas precisam valer entre várias chamadas HTTP (sessões com estado).
- A DLL e o gateway não precisam usar a mesma linguagem.

Os requisitos estão em `specs/fbclient-http-library`, `specs/firebird-http-gateway` e `specs/gateway-protocol`.

## Goals / Non-Goals

**Goals:**
- Uma ponte de chamada remota (RPC) para a API cliente do Firebird. O resultado é igual ao do cliente nativo, porque um `libfbclient` real faz o trabalho.
- Menos idas e voltas na rede do que uma ponte ingênua de uma requisição por chamada. Lotes de linhas, leitura antecipada de BLOBs e chamadas adiadas resolvem isso.
- Implementação pequena o bastante para duas pessoas manterem.

**Non-Goals:**
- A API orientada a objetos do Firebird 3+ (`fb_get_master_interface`). Implementar só se a tarefa 1.3 mostrar que o driver Devart precisa dela.
- Services API (`isc_service_*`), eventos (`isc_que_events`), backup e gestão de usuários.
- Build Win64, pool de conexões, balanceamento entre vários gateways e cache de dados.
- Suporte a outros drivers além do dbExpress da Devart. dbxfb, IBX e FireDAC podem funcionar depois, mas não são testados.

## Decisions

### D1. Substituir o `fbclient.dll`, não o driver dbExpress
Escolha do usuário. A API C do Firebird é documentada, `stdcall`, independente da versão do Delphi, e o layout dos dados (`XSQLDA`) é fixo. A alternativa era um driver dbExpress próprio. Ela foi rejeitada porque a ABI de driver DBX não tem documentação, muda entre versões do Delphi e exige copiar à mão o mapeamento de tipos do driver nativo.

### D2. Descobrir a API usada por medição, não por suposição
Antes da DLL real, construir um **proxy de log** (feito; resultado em `docs/api-surface.md`: só API legada, 22 funções) `fbclient.dll`. O proxy exporta a API pública completa, grava cada chamada (nome, argumentos, itens de info, tags de DPB/TPB/BPB) num log e encaminha a chamada ao `fbclient.dll` real. Rodar as telas principais da aplicação e uma suíte de teste com ele. O log define a lista exata de exports, os itens de info e as tags de bloco de parâmetros a suportar. Todos os outros exports devolvem o status "não suportado". O log também confirma se o driver Devart usa só a API legada `isc_*` ou também a API OO. A API OO é o maior risco de escopo.

### D3. Linguagem da DLL: Delphi (Win32)
A latência de rede (milissegundos) é muito maior que o tempo de CPU local (microssegundos por chamada). Por isso a linguagem da DLL quase não afeta a velocidade. Delphi é a linguagem da equipe, compila DLL 32 bits com exports `stdcall` sem dependência de runtime e acessa a WinHTTP direto. Rust ou C eram alternativas. Têm velocidade parecida e mais segurança de memória no código cheio de ponteiros do `XSQLDA`, mas obrigam a equipe a manter uma segunda linguagem. Mitigação para segurança de memória: cada função exportada captura todas as exceções na fronteira e as converte em status vector, e todo handle passa por uma tabela de handles (D7).

Regras da DLL: nenhuma string ou exceção Delphi atravessa a fronteira dos exports, a DLL não usa `ShareMem`, e todo fonte é salvo em Windows-1252.

### D4. Cliente HTTP: WinHTTP
A WinHTTP faz parte do Windows. Suporta TLS pelo repositório de certificados do Windows, proxy do sistema, keep-alive e HTTP/2 (Windows 10 1607+). Não precisa de DLLs do OpenSSL. Indy foi rejeitado porque precisa das DLLs do OpenSSL e é mais lento. WinINet foi rejeitado porque a Microsoft não o suporta em serviços. Usar uma sessão WinHTTP por processo e uma conexão keep-alive por conexão Firebird.

### D5. Linguagem do gateway: Go com cgo chamando `libfbclient.so`
O gateway encaminha cada chamada à biblioteca cliente **real**. Assim layout de dados, status vectors, várias transações por conexão e handles de BLOB vêm do próprio Firebird. Go dá um único binário de serviço, servidor HTTP/TLS padrão e concorrência barata. O binário faz link dinâmico com `libfbclient.so`.

Implantação por Docker: `Dockerfile` multi-stage (build Go com cgo, imagem final Debian slim com `libfbclient2` e só o binário, usuário não root) e `docker-compose.yml` com `restart: unless-stopped`, porta publicada, configuração e certificados montados como volumes somente leitura, e `stop_grace_period` suficiente para o rollback do `SIGTERM`. Um compose de teste separado sobe também um Firebird 3, 4 ou 5 para os testes de integração.

Alternativas consideradas:
- Driver Firebird puro em Go (`database/sql`). Rejeitado: só uma transação por conexão, sem acesso ao `XSQLVAR` cru, e formatos de erro diferentes dos nativos.
- C/C++. Rejeitado: mesmo resultado com mais código nas partes de HTTP, TLS e sessão.
- Delphi para Linux. Rejeitado: exige a edição Enterprise e o ganho é pequeno.

Modelo de concorrência: cada sessão tem um mutex, então as chamadas de uma conexão rodam uma de cada vez. Sessões diferentes rodam em paralelo. O `libfbclient` é thread-safe entre conexões diferentes.

### D6. Protocolo: HTTP POST com corpo binário próprio
- Um endpoint, `POST /v1/rpc`, com `Content-Type: application/x-fbhttp`. O header `X-Session` leva o token da sessão. O número de sequência vai no corpo.
- Corpo: registros little-endian com prefixo de tamanho. Cada registro tem um opcode e campos. Uma requisição pode levar vários registros, o que permite juntar chamadas (D8).
- Os valores trafegam como bytes crus de `XSQLVAR`: `sqltype`, `sqlsubtype`, `sqlscale`, `sqllen`, indicador de nulo e `sqllen` bytes de dados. Os dados não dependem do tamanho de ponteiro. Blob ID é `ISC_QUAD` de 8 bytes, timestamp tem 8 bytes, e VARCHAR é tamanho de 2 bytes mais dados. Por isso os bytes de um servidor Linux 64 bits podem ser copiados direto nos buffers do cliente 32 bits. O gateway não converte tipos.
- JSON foi rejeitado por três motivos: base64 para binários, risco de precisão numérica e custo de parse em cada linha.

### D7. Handles
O gateway mantém, para cada sessão, uma tabela que liga IDs opacos de 32 bits aos handles reais (conexão, transação, comando, BLOB). A DLL mantém uma tabela local que liga os handles entregues ao driver a esses IDs e ao estado local (buffer de linhas, descrição em cache). A DLL valida o handle em toda chamada, então um handle velho dá `isc_bad_stmt_handle` e os outros erros de handle inválido, não violação de acesso.

### D8. Redução de idas e voltas
- **Prepare**: uma requisição faz allocate, prepare, `describe`, `describe_bind` e `sql_info(stmt_type)`. A DLL guarda o resultado e responde localmente os `isc_dsql_describe*` e os itens comuns de `isc_dsql_sql_info` seguintes.
- **Execute + primeiro lote**: um execute que abre cursor devolve as primeiras N linhas e o bloco `records` na mesma resposta. O log da tarefa 1.3 mostrou que o driver Devart abre cursores com `isc_dsql_execute2` (saída `nil`) e não muda o XSQLDA entre o describe e o fetch. Por isso a DLL usa o layout do describe já no execute.
- **Informações de comando**: o PREPARE também devolve o resultado de `isc_dsql_sql_info` para a lista de itens que o driver pede depois do describe. A DLL responde localmente `stmt_type`, essa lista e `records` (este vem no EXECUTE).
- **Início de transação adiado**: `isc_start_multiple` devolve na hora um handle local com id na faixa do cliente (≥ 0x80000000). O START vai no mesmo lote da primeira operação que usa a transação. Erros do START aparecem nessa operação.
- **Informações estáticas da conexão**: `isc_database_info` com itens que não mudam durante a conexão (dialeto, versão) fica em cache por conexão.
- **Funções locais**: `isc_vax_integer`, `isc_portable_integer`, `isc_get_client_version` e as de data (`isc_encode_*`/`isc_decode_*`) não usam a rede.
- **Fetch**: `isc_dsql_fetch` lê do lote local. Quando o lote acaba, a DLL pede as próximas N linhas. N vem da configuração, padrão 200, e o gateway também limita N.
- **Chamadas adiadas**: `isc_dsql_free_statement` (close ou drop) e `isc_dsql_set_cursor_name` vão para uma fila. A DLL envia a fila no início da próxima requisição. Essas chamadas não falham de um jeito que o driver espere ver. Commit, rollback e execute nunca são adiados.
- **Leitura de BLOB**: `isc_open_blob2` devolve os dados de `isc_blob_info` e, abaixo do limite embutido (padrão 64 KB), o conteúdo inteiro. Os `isc_get_segment` seguintes são atendidos localmente. Acima do limite, a DLL lê blocos de 1 MB.
- **Gravação de BLOB**: a DLL acumula os dados de `isc_put_segment` e envia no `isc_close_blob`. Ela também envia um bloco quando o buffer passa de 1 MB.

### D9. Destino da conexão e configuração
O driver passa `Database` (por exemplo `servidor:alias` ou `alias`) para `isc_attach_database`. A DLL envia essa string sem mudança. O gateway primeiro tenta casar exatamente com os aliases publicados. Depois tenta o texto após o primeiro `:`. O gateway nunca aceita um caminho de arquivo que não esteja na lista de aliases.

A URL do gateway, opções de TLS, timeouts e tamanho do lote vêm do `ws-fbclient.ini`, na mesma pasta da DLL. Cada item pode ser sobrescrito por uma variável de ambiente `FBHTTP_*`. Usuário, senha, role e charset vêm do DPB que o driver já monta. O gateway repassa o DPB para `isc_attach_database` depois de remover tags que se referem ao sistema de arquivos local. O gateway usa o cliente do Firebird 4, e com ele o FB 4/5 devolve tipos novos (`INT128` em `SUM(NUMERIC)`, `DECFLOAT`, `TIMESTAMP WITH TIME ZONE` em `CURRENT_TIMESTAMP`) que o driver Devart antigo não lê. Por isso o gateway acrescenta `isc_dpb_set_bind` = `int128 to legacy;decfloat to legacy;time zone to legacy` quando o cliente não manda o seu. Esse é o mesmo resultado que o cliente nativo da aplicação recebe. A opção `set_bind` permite mudar ou desligar.

### D10. Erros
O gateway devolve o status vector completo e o texto que `fb_interpret` produz para cada item. A DLL monta um status vector na própria memória, é dona das strings dos argumentos e atende `fb_interpret` e `isc_sql_interprete` a partir do texto guardado. Falhas de rede e HTTP viram `isc_network_error` com `isc_net_read_err` ou `isc_net_write_err`. O driver Devart então mostra a exceção normal de "conexão perdida".

### D11. Número de sequência e repetição
Cada requisição leva `seq`. O gateway guarda a última resposta de cada sessão. Se `seq` for igual ao último processado, o gateway reenvia a resposta guardada. Se `seq` for igual ao que ainda está em execução, o gateway espera a execução terminar e devolve o resultado, sem executar de novo. Se `seq` não for o próximo valor, o gateway devolve erro de protocolo. A DLL repete só depois de timeout de transporte ou conexão resetada, no máximo 2 vezes, com o mesmo `seq`. Isso torna segura a repetição de `INSERT` e `COMMIT`.

O timeout de conexão (padrão 10 s) e o timeout de resposta (padrão 30 min, para relatórios longos) são configurados separadamente.

### D12. Tempo de vida da sessão
A sessão começa em `isc_attach_database` e termina em `isc_detach_database`. O timeout de inatividade tem padrão de 30 minutos. Com a conexão aberta, a DLL envia keep-alive por um timer em segundo plano quando a conexão fica parada mais que um terço do timeout. O keep-alive não usa `seq` e não pega o mutex da sessão no gateway, porque só atualiza o horário da última atividade. Uma requisição em execução também conta como atividade, então uma consulta longa não expira a sessão. Quando o gateway expira uma sessão, ele faz rollback das transações abertas e desconecta.

## Risks / Trade-offs

- [O driver Devart usa a API OO do Firebird 3 em alguma operação] → A tarefa 1.3 verifica isso primeiro. Se a API OO for usada, parar e decidir de novo antes de escrever a DLL principal. Opções: implementar as interfaces usadas, ou configurar o Devart para usar a API legada.
- [Latência em muitas consultas pequenas, por exemplo telas que fazem 50 buscas de uma linha] → Lotes e chamadas adiadas removem quase todas as idas e voltas extras, mas não a ida e volta de cada consulta. Medir com a aplicação real (tarefa 7.3) e documentar o custo esperado. Manter o gateway perto do banco.
- [Comportamento diferente do nativo em caminhos raros da API] → O proxy de log define os caminhos a suportar. Um teste de comparação roda o mesmo script pelo cliente nativo e pelo HTTP e compara os resultados byte a byte.
- [Bugs de memória no código de `XSQLDA` derrubam a aplicação] → Um único módulo escreve no `XSQLDA`, com checagem de limites, barreira de exceção em cada export e teste com FastMM em modo full debug.
- [Gateway exposto à internet] → TLS obrigatório. Só aliases são aceitos. Token aleatório de 128 bits. Limites de sessões e de tamanho de corpo. Senhas fora do log. Um proxy reverso (nginx) na frente do gateway é opcional para limitar taxa.
- [Codificação de texto do gateway ou de `fb_interpret` diferente do charset do cliente] → O gateway conecta com o mesmo `isc_dpb_lc_ctype` que o cliente enviou e devolve os bytes crus das mensagens.
- [Chamadas cgo bloqueiam threads do sistema] → O número de sessões é limitado. Cada chamada bloqueada ocupa só uma thread, e o Go lida com milhares de threads.

## Migration Plan

1. Subir o gateway com `docker compose up -d` perto do Firebird. Publicar os aliases e configurar TLS.
2. Numa estação, copiar `ws-fbclient.dll` e `ws-fbclient.ini` para a pasta da aplicação. Configurar `VendorLib = ws-fbclient.dll` e `Database = alias`.
3. Rodar a aplicação em piloto. Rollback: voltar `VendorLib` para `fbclient.dll` e o `Database` original. A aplicação não tem outra mudança, então o rollback é imediato.

## Open Questions


- Tamanho padrão do lote e limite de BLOB embutido. Definir pelas medições da tarefa 7.3. São valores de configuração, então o design não muda.
- Criptografia de rede do Firebird (`WireCrypt`) entre gateway e Firebird quando estão em hosts diferentes. É um item de configuração do gateway.
