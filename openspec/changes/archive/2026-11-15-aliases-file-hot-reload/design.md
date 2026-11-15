# Design

## Context

- `config.Config.Aliases` é um `map[string]string` preenchido uma vez em `config.Load` (JSON e/ou `FBHTTP_ALIASES`) e validado em `validate()`. Esta change remove a leitura de `FBHTTP_ALIASES` em `applyEnv`.
- `Config.ResolveAlias` lê esse mapa direto; é chamado só em `server.attach` (`gateway/internal/server/server.go`), uma vez por sessão nova.
- O container roda com `read_only: true`, sem dependências Go externas (`go.mod` sem `require`).
- Requisitos: ver `specs/firebird-http-gateway/spec.md`.

## Goals / Non-Goals

**Goals:**
- Trocar a tabela de aliases em execução, com segurança entre goroutines e sem bloquear ATTACH.
- Nenhuma nova dependência.

**Non-Goals:**
- Recarregar outras configurações (limites, TLS, `firebird_host`, proxies).
- API HTTP de administração para editar aliases.
- Encerrar sessões de aliases removidos.
- Guardar aliases em banco de dados ou serviço externo.

## Decisions

**D1. Formato do arquivo: texto, uma linha por alias.**
`nome = destino`, espaços nas pontas ignorados, `#` inicia comentário de linha, linhas vazias ignoradas, nome duplicado é erro. Reaproveita a sintaxe `nome=destino` que os operadores já usavam em `FBHTTP_ALIASES` e a validação de nome existente.
Alternativas: JSON (já suportado em `FBHTTP_CONFIG`, mas pior para editar à mão com dezenas de linhas e sem comentários); YAML (exige dependência).

**D2. Tabela imutável atrás de `atomic.Pointer[map[string]string]`.**
A recarga monta um mapa novo, valida e troca o ponteiro inteiro. `ResolveAlias` faz um `Load()` e uma busca. Sem lock no caminho do ATTACH, sem cópia por requisição.
Alternativa: `sync.RWMutex` — funciona, mas o ponteiro atômico é mais simples para escrita única e rara.
O campo público `Aliases` continua sendo a entrada (JSON/env); após `Load` o gateway passa a ler só a tabela atômica.

**D3. Recarga por polling a cada 60 segundos, comparando o conteúdo.**
Uma goroutine (`Config.WatchAliases`, iniciada em `main.go` junto do reaper, com o mesmo `ctx`) lê o arquivo; se os bytes forem iguais aos da última leitura, nada faz. Se mudaram, faz parse, valida e troca. Comparar bytes evita falhas de granularidade de mtime e funciona com qualquer forma de gravação.
Alternativas: fsnotify (dependência nova; inotify não é confiável através de bind mounts do Docker e perde o arquivo quando o editor troca o inode); SIGHUP (no Coolify não há como enviar sinal com facilidade). Intervalo fixo, sem variável nova.

**D4. Falha na recarga mantém a tabela anterior.**
Erro de leitura, de parse ou tabela vazia sem `firebird_host`: log `warn` com o arquivo e o motivo (número da linha no parse), tabela atual intacta. Erros iguais repetidos não são logados de novo a cada ciclo (só quando o conteúdo muda). Sucesso: log `info` com a quantidade de aliases, incluídos e removidos (só nomes, nunca senhas — o destino não tem senha).

**D5. `FBHTTP_ALIASES` removida; fontes exclusivas.**
O bloco de `FBHTTP_ALIASES` sai de `applyEnv`. Se a variável estiver definida, `main.go` loga `warn` na inicialização ("FBHTTP_ALIASES foi removida; use FBHTTP_ALIASES_FILE") e o gateway sobe normalmente. Alternativa: falhar a inicialização — rejeitada porque derrubaria o serviço só por uma variável sobrando no `.env`; se não houver `firebird_host` nem arquivo, `validate()` já recusa subir.
`aliases_file` junto de `aliases` no JSON é erro em `validate()`. O campo JSON `aliases` continua (sem recarga). Com `aliases_file`, a regra "pelo menos `firebird_host` ou aliases" é avaliada sobre o conteúdo do arquivo.

**D6. Montagem por diretório no Docker.**
`docker-compose.yml` monta `${FBHTTP_CONFIG_DIR:-./config}:/config:ro` (a pasta do host é configurável pela variável `FBHTTP_CONFIG_DIR`) e repassa `FBHTTP_ALIASES_FILE` (vazio por padrão = sem arquivo; ativar com `/config/aliases.conf`). Assim instalações só com `FBHTTP_FIREBIRD_HOST` sobem sem criar o arquivo. Bind mount de arquivo único prende o inode: editores e `sed -i` gravam por rename e o container continuaria vendo o conteúdo antigo. No Coolify, usar "Directory Mount" (ou "File Mount", sabendo que a edição pela UI recria o arquivo — validar no ambiente).

### Impacto em desempenho

- Consultas, fetch, execute e commit não tocam a tabela: impacto zero.
- ATTACH: um `atomic.Load` e uma busca em mapa (dezenas de nanossegundos), contra milissegundos do attach no Firebird. Com dezenas ou centenas de aliases não há diferença mensurável.
- Polling: uma leitura de arquivo de poucos KB a cada 60 s, ~1 ms de CPU por ciclo, no máximo.
- Memória: um mapa pequeno; o anterior é coletado pelo GC após a troca.

## Risks / Trade-offs

- [Edição parcial lida no meio da gravação] → linha truncada vira erro de parse e a tabela anterior é mantida; o ciclo seguinte lê o arquivo completo. Documentar gravar por arquivo temporário + rename quando automatizado.
- [Operador acha que remover alias derruba os usuários] → documentar que sessões abertas continuam até fechar ou expirar (`FBHTTP_IDLE_TIMEOUT_SECONDS`).
- [Bind mount de arquivo único não reflete edições] → D6, documentado no `docs/deploy.md`.
- [Até 60 s de atraso para um alias novo valer] → aceito; documentado.
- [Instalação atualiza a imagem sem migrar `FBHTTP_ALIASES`: aliases somem, ATTACH por nome passa a ser recusado ou cai no `firebird_host`] → aviso no log de inicialização e passo de migração destacado em `docs/deploy.md`.

## Migration Plan

1. Antes de atualizar a imagem: criar `config/aliases.conf` com as entradas de `FBHTTP_ALIASES` (trocar `;` por quebra de linha), apagar `FBHTTP_ALIASES` do `.env` e definir `FBHTTP_ALIASES_FILE`.
2. Atualizar a imagem e recriar o container uma vez. Conferir no log de inicialização a quantidade de aliases e a ausência do aviso de variável removida.
3. Daqui em diante, incluir/remover servidores só editando o arquivo.
Rollback: voltar a imagem anterior com `FBHTTP_ALIASES` no `.env`.
