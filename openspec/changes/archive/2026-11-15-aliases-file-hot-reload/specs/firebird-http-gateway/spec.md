# Spec Delta

## ADDED Requirements

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
