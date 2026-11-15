# Tasks

## 1. Leitura do arquivo e tabela atômica (config)

- [x] 1.1 Adicionar `AliasesFile` (`aliases_file` no JSON, `FBHTTP_ALIASES_FILE` no env) a `config.Config` e verificar com teste em `config_test.go` que env e JSON preenchem o campo
- [x] 1.2 Implementar o parse do formato `nome = destino` (comentário `#`, linhas vazias, nome duplicado e linha sem `=` como erro com número da linha, mesma validação de nome de hoje) e verificar com testes de tabela em `config_test.go`
- [x] 1.3 Remover a leitura de `FBHTTP_ALIASES` de `applyEnv` e migrar os testes que a usam (`config_test.go`, `server/clientip_test.go`) para arquivo temporário ou o campo `Aliases`; verificar com teste que `FBHTTP_ALIASES` definida não gera aliases e com `go test ./...`
- [x] 1.4 Trocar a leitura de aliases por `atomic.Pointer[map[string]string]`, fazendo `ResolveAlias` usar a tabela atômica, e verificar que os testes de `ResolveAlias` continuam passando (`go test ./internal/config/`)
- [x] 1.5 Em `Load`/`validate`: carregar o arquivo na inicialização, recusar `aliases_file` junto de `aliases` no JSON, e aplicar a regra "firebird_host ou aliases" ao conteúdo do arquivo; verificar com testes de arquivo inexistente, inválido e fontes duplicadas
- [x] 1.6 Implementar `ReloadAliases()` que relê o arquivo, ignora conteúdo igual ao anterior e, em erro ou tabela vazia sem `firebird_host`, mantém a tabela atual e devolve o erro; verificar com testes de inclusão, remoção e arquivo inválido mantendo a tabela anterior

## 2. Recarga periódica no servidor

- [x] 2.1 Iniciar em `main.go` (junto de `RunReaper`, mesmo `ctx`) `cfg.WatchAliases` (em `internal/config`, que chama `ReloadAliases` a cada 60 s) quando `AliasesFile` está definido, logando `info` em sucesso (quantidade, incluídos, removidos) e `warn` em erro só quando o erro muda; verificar com `TestWatchAliases` em `internal/config` (o pacote `internal/server` só roda testes com Firebird)
- [x] 2.2 Ajustar o log de inicialização em `main.go` para a quantidade de aliases da tabela atômica e o caminho do arquivo, e logar `warn` quando `FBHTTP_ALIASES` estiver definida; verificar rodando o gateway local com e sem a variável antiga
- [x] 2.3 Escrever teste que recarrega a tabela em loop enquanto outra goroutine chama `ResolveAlias`, e verificar com `go test -race ./...`
- [x] 2.4 Verificar com teste de integração que uma sessão aberta num alias removido continua executando comandos e que um novo ATTACH para ele é recusado

## 3. Deploy e documentação

- [x] 3.1 Em `docker-compose.yml`, remover `FBHTTP_ALIASES`, montar `${FBHTTP_CONFIG_DIR:-./config}:/config:ro` (pasta do host configurável) e passar `FBHTTP_ALIASES_FILE`; criar `config/aliases.conf.example`; verificar com `docker compose config` e subindo o container
- [x] 3.2 Em `docker-compose.test.yml`, trocar `FBHTTP_ALIASES` por um arquivo de aliases de teste montado por diretório com o alias `test`; verificar rodando os testes de integração que usam esse compose
- [x] 3.3 Trocar `FBHTTP_ALIASES` por `FBHTTP_ALIASES_FILE` em `.env.example`; verificar com `grep -rn FBHTTP_ALIASES[^_]` que só restam menções de migração
- [x] 3.4 Atualizar `docs/deploy.md` (remover a linha de `FBHTTP_ALIASES`, documentar `FBHTTP_ALIASES_FILE`, formato do arquivo, montagem por diretório, Coolify, atraso de até 60 s, sessões abertas não caem, passo de migração destacado) e `docs/client-setup.md` (linha que cita `FBHTTP_ALIASES`); verificar que os exemplos batem com o formato implementado

## 4. Verificação final

- [x] 4.1 Com o container rodando, incluir e remover um alias em `config/aliases.conf` e confirmar no log a recarga e o ATTACH aceito/recusado sem reinício
