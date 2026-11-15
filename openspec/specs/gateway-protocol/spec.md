# gateway-protocol Specification

## Purpose

Contrato de rede versionado entre a biblioteca `ws-fbclient.dll` e o gateway HTTP, que define operações, transporte de dados, lotes, BLOBs, erros, ordem e repetição de requisições, para que os dois lados evoluam de forma independente.

## Requirements

### Requirement: Versão do protocolo
Toda sessão SHALL negociar a versão do protocolo na criação. O gateway SHALL recusar versões que não suporta com um erro que informa as versões aceitas.

#### Scenario: Versão incompatível
- **WHEN** a biblioteca pede uma sessão com uma versão de protocolo que o gateway não suporta
- **THEN** o gateway recusa, e a mensagem de erro que chega à aplicação informa as versões suportadas

### Requirement: Operações
O protocolo SHALL ter operações equivalentes às funções da API do Firebird que a biblioteca exporta: conexão e desconexão, informações do banco, transações (iniciar, confirmar, desfazer, com e sem retenção), comandos (alocar, preparar, descrever, executar, executar imediato, buscar linhas, liberar) e BLOBs (criar, abrir, ler, gravar, fechar, cancelar, informações). O protocolo SHALL também ter uma operação para manter a sessão viva.

#### Scenario: Prepare devolve descrição completa
- **WHEN** a biblioteca prepara um `SELECT`
- **THEN** uma única resposta traz o handle do comando, o tipo do comando e a descrição de todas as colunas e parâmetros

### Requirement: Dados no formato nativo do Firebird
Valores de colunas e parâmetros SHALL trafegar no mesmo formato binário que o cliente Firebird usa em `XSQLVAR` (tipo, subtipo, escala, tamanho, bytes do valor e indicador de nulo), sem conversão de tipo no gateway nem na biblioteca. Handles SHALL trafegar como identificadores opacos da sessão, nunca como ponteiros.

#### Scenario: Decimal com escala
- **WHEN** o gateway envia `NUMERIC(18,4)` com valor `-0.0001`
- **THEN** a biblioteca entrega ao driver o inteiro de 64 bits `-1` com escala `-4`, como o cliente nativo entrega

#### Scenario: Nulo versus vazio
- **WHEN** uma linha tem `VARCHAR` vazio numa coluna e `NULL` em outra
- **THEN** as duas chegam distintas ao driver

### Requirement: Lotes de linhas
A operação de execução de um comando com cursor SHALL devolver o primeiro lote de linhas na mesma resposta. A operação de busca SHALL devolver até N linhas por resposta, com N pedido pela biblioteca e limitado pelo gateway, e SHALL informar se o cursor terminou.

#### Scenario: Consulta pequena em uma ida e volta
- **WHEN** a biblioteca executa um `SELECT` que retorna 30 linhas com lote de 100
- **THEN** uma única resposta traz as 30 linhas e a indicação de fim do cursor

### Requirement: BLOBs
Ao ler um BLOB, a resposta de abertura SHALL trazer o conteúdo inteiro quando o tamanho for até um limite configurado. Acima do limite, o conteúdo SHALL vir em partes sob demanda.

#### Scenario: BLOB pequeno
- **WHEN** o driver abre e lê um BLOB de 2 KB
- **THEN** a biblioteca faz uma única requisição de rede para abrir e ler esse BLOB

#### Scenario: BLOB acima do limite
- **WHEN** o driver lê um BLOB maior que o limite
- **THEN** a biblioteca recebe o conteúdo em partes até completar todos os bytes

### Requirement: Erros estruturados
Toda resposta de erro SHALL conter a categoria (Firebird, sessão, protocolo, limite, interno). Erros do Firebird SHALL trazer o status vector completo (códigos e argumentos) e as mensagens já formatadas pelo `libfbclient` do gateway. Erros do Firebird SHALL NOT invalidar a sessão. Só erros de categoria sessão a invalidam.

#### Scenario: Violação de chave
- **WHEN** um `INSERT` viola uma chave primária
- **THEN** a resposta traz categoria Firebird, o status vector e a mensagem, e a sessão continua utilizável

### Requirement: Ordem e repetição de requisições
Cada requisição de uma sessão SHALL levar um número de sequência. O gateway SHALL processar as requisições de uma sessão em ordem. Quando receber de novo a última requisição já processada, o gateway SHALL devolver a resposta guardada sem executar a operação outra vez.

#### Scenario: Repetição após resposta perdida
- **WHEN** a biblioteca reenvia um `INSERT` com o mesmo número de sequência porque a resposta se perdeu
- **THEN** o gateway devolve a resposta original e o `INSERT` acontece uma única vez

#### Scenario: Repetição durante execução longa
- **WHEN** a biblioteca reenvia uma requisição com o mesmo número de sequência enquanto o gateway ainda executa a original
- **THEN** o gateway espera a execução terminar, devolve o resultado e não executa a operação de novo

#### Scenario: Keep-alive durante consulta longa
- **WHEN** a biblioteca envia keep-alive enquanto outra requisição da mesma sessão está em execução
- **THEN** o keep-alive responde sem esperar a execução e sem afetar a sequência das requisições
