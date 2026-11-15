# Proposal

## Why

Os servidores/bancos publicados pelo gateway (aliases) hoje ficam em `FBHTTP_ALIASES`, uma única linha no `.env` no formato `nome=host:/caminho;outro=...`. Com dezenas de servidores essa linha fica ilegível e difícil de manter, e qualquer inclusão ou remoção exige recriar o container (novo deploy), derrubando todas as sessões abertas.

## What Changes

- Novo arquivo de aliases, um por linha (`nome = host:/caminho/banco.fdb`), com comentários (`#`) e linhas em branco. Caminho informado por `FBHTTP_ALIASES_FILE` (ou `aliases_file` no JSON de configuração).
- O gateway relê o arquivo sozinho a cada 60 segundos. Mudanças valem para os próximos ATTACH sem reiniciar o processo e sem derrubar sessões abertas.
- Arquivo inválido na recarga: o gateway mantém a tabela anterior e registra o erro no log. Arquivo inválido na inicialização: o gateway não sobe (mesmo comportamento das demais configurações inválidas).
- Remover um alias não encerra sessões já abertas nele; só novos ATTACH passam a ser recusados.
- **BREAKING**: a variável `FBHTTP_ALIASES` é removida. O gateway passa a ignorá-la e registra um aviso no log na inicialização se ela estiver definida, para o operador migrar.
- `aliases_file` junto com `aliases` no JSON de configuração é erro de configuração na inicialização, para não haver duas fontes de verdade.
- `docker-compose.yml`, `.env.example` e `docs/` passam a mostrar o arquivo montado por diretório (`./config:/config:ro`).

Alternativa considerada: o JSON de `FBHTTP_CONFIG` já aceita `aliases` como objeto, o que resolve a linha longa, mas exige reinício a cada alteração. Por isso não basta.

## Capabilities

### New Capabilities

(nenhuma)

### Modified Capabilities

- `firebird-http-gateway`: novo requisito de aliases em arquivo com recarga sem reinício; `FBHTTP_ALIASES` deixa de existir.

## Impact

- Código: `gateway/internal/config` (leitura do arquivo, tabela de aliases trocável de forma atômica, validação), `gateway/internal/server` (inicia a recarga periódica), `gateway/cmd/fbhttp-gateway/main.go` (log de inicialização).
- Deploy: `docker-compose.yml` troca `FBHTTP_ALIASES` por volume de diretório e `FBHTTP_ALIASES_FILE`; `docker-compose.test.yml` passa a usar um arquivo de aliases de teste; `.env.example`; `docs/deploy.md`; `docs/client-setup.md`.
- Testes: `config_test.go` e `server/clientip_test.go` hoje montam aliases por `FBHTTP_ALIASES` e passam a usar arquivo temporário ou o campo `Aliases` direto.
- Instalações existentes com `FBHTTP_ALIASES` precisam migrar para o arquivo antes de atualizar a imagem.
- Dependências: nenhuma nova (somente biblioteca padrão do Go).
- Desempenho: sem impacto mensurável. A tabela de aliases só é consultada no ATTACH (uma leitura atômica e uma busca em mapa); consultas, fetch e commit não a usam. A recarga é uma leitura de arquivo pequeno a cada 60 segundos.
- Clientes (`ws-fbclient.dll`, driver dbExpress): nenhuma mudança.
