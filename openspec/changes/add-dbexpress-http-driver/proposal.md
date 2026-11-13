# Proposal

## Why

Aplicações Delphi 10.x–12 (32 bits) usam `TSQLConnection` com o driver dbExpress da Devart para InterBase/Firebird. Esse driver carrega `fbclient.dll` (parâmetro `VendorLib`) e fala direto com o Firebird 3–5 na porta 3050. Isso exige que o banco esteja exposto na rede do cliente. Uma camada HTTP no meio permite acessar o Firebird pela internet (TLS, proxy, firewall corporativo, balanceador) sem mudar o código da aplicação nem o driver dbExpress.

**Viabilidade:** sim, é viável. A cadeia fica:

```
TSQLConnection -> driver dbExpress Devart (inalterado) -> fbclient HTTP (DLL nova) -> gateway HTTP (Linux) -> libfbclient -> Firebird
```

O driver Devart chama a API C pública do Firebird (`isc_attach_database`, `isc_dsql_prepare`, `isc_dsql_fetch`, `isc_get_segment` etc.). Essa API é documentada, usa `stdcall` com estruturas fixas (`XSQLDA`/`XSQLVAR`) e não muda com a versão do Delphi. Uma DLL que exporta as mesmas funções pode encaminhar cada chamada a um gateway que executa a chamada equivalente num `libfbclient` real. Tipos, metadados, erros e transações continuam os do Firebird, porque o próprio Firebird produz os dados. Os riscos reais são latência por ida e volta na rede e cobrir toda a parte da API que o driver Devart usa. O design trata os dois.

Substituir o `fbclient.dll` foi escolhido em vez de escrever um driver dbExpress próprio, porque a API do driver dbExpress não tem documentação oficial e está presa à versão do Delphi.

## What Changes

- Nova DLL Windows 32 bits (`ws-fbclient.dll`) que exporta a parte da API `isc_*`/`fb_*` usada pelo driver dbExpress da Devart e encaminha as chamadas ao gateway por HTTPS. Não precisa de `fbclient.dll` na estação.
- Novo gateway HTTP para Linux que mantém sessões com estado (uma conexão Firebird por conexão da aplicação), executa as chamadas num `libfbclient` real e devolve resultados em lotes.
- Novo protocolo binário versionado entre DLL e gateway, com otimizações contra latência: busca de linhas em lotes, leitura antecipada de BLOBs e junção de chamadas encadeadas.
- Configuração só por `VendorLib = ws-fbclient.dll` e pelo parâmetro `Database` da conexão (alias publicado no gateway). A URL do gateway e as opções de TLS ficam num arquivo de configuração ao lado da DLL ou em variáveis de ambiente.
- Nenhuma mudança no código da aplicação nem no driver dbExpress.

## Capabilities

### New Capabilities
- `fbclient-http-library`: DLL Windows 32 bits que se apresenta como `fbclient.dll` ao driver dbExpress da Devart e executa as chamadas da API do Firebird pelo gateway.
- `firebird-http-gateway`: servidor HTTP para Linux que autentica clientes, gerencia sessões com estado, executa as chamadas no Firebird e expira sessões ociosas.
- `gateway-protocol`: contrato de rede versionado entre a DLL e o gateway (operações, sessão, lotes, BLOBs, erros, ordem e repetição de requisições).

### Modified Capabilities
- Nenhuma (projeto novo, sem specs existentes).

## Impact

- Código novo: projeto da DLL (Win32) e projeto do gateway (Linux x86-64).
- Dependências: no gateway, `libfbclient.so` do Firebird 3–5. Na DLL, só a RTL e a API WinHTTP do Windows.
- Implantação: o gateway roda perto do Firebird, atrás de TLS. As estações só precisam de saída HTTPS e da DLL nova. `VendorLib` aponta para a DLL nova.
- Desempenho: cada ida e volta HTTP soma latência. Consultas grandes dependem da busca em lotes. Muitos comandos pequenos em sequência ficam mais lentos que a conexão direta.
- Segurança: credenciais do Firebird passam a trafegar por HTTP. TLS é obrigatório fora de redes de teste, e o gateway passa a ser a superfície exposta à internet.
