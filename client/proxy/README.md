# Proxy de log do fbclient (tarefas 1.2 e 1.3)

Objetivo: descobrir **exatamente** quais funções do `fbclient.dll` o driver dbExpress da Devart chama,
com quais parâmetros, e se ele depende da API orientada a objetos do Firebird 3+
(`fb_get_master_interface`). O resultado decide se o design segue como está.

## Compilar

Num "RAD Studio Command Prompt" (Delphi 10.x–12, Win32):

```bat
cd client\proxy
build.bat
```

Gera duas variantes:

| Pasta | Diferença |
|---|---|
| `client\bin\proxy\` | exporta `fb_get_master_interface` (registra e repassa) |
| `client\bin\proxy-no-oo\` | **não** exporta `fb_get_master_interface` |

Se `exports.txt` mudar, rode `python client/tools/gen_proxy.py` antes de compilar.

## Rodar

### Quando o `VendorLib` é ignorado (o driver carrega `fbclient.dll` da pasta da aplicação)

Com todas as instâncias da aplicação fechadas, num `cmd` na pasta da aplicação:

```bat
ren fbclient.dll fbclient_real.dll
copy <repo>\client\bin\proxy\fbclient_proxy.dll fbclient.dll
```

O proxy encontra `fbclient_real.dll` sozinho. Desfazer: `del fbclient.dll` e `ren fbclient_real.dll fbclient.dll`.

### Quando o `VendorLib` é respeitado

1. Copie `fbclient_proxy.dll` para a pasta onde está o `fbclient.dll` real (32 bits) usado pela aplicação.
   O proxy carrega `fbclient.dll` da mesma pasta. Para outro caminho: variável `FBPROXY_REAL=C:\caminho\fbclient.dll`.
2. Na conexão (`TSQLConnection` ou `dbxconnections.ini`), troque `VendorLib=fbclient.dll` por `VendorLib=fbclient_proxy.dll`.
3. Rode as telas principais da aplicação: abrir conexão, consultas com e sem parâmetros, gravação com
   transação (commit e rollback), campos BLOB (leitura e gravação), procedures, `GetTableNames`/`GetFieldNames`.
4. Feche a aplicação (o resumo é gravado no encerramento).
5. Repita os passos 1–4 com a variante `proxy-no-oo`.

O log fica em `fbclient_proxy.log` na pasta da DLL (ou em `FBPROXY_LOG`).

**Atenção:** o log contém o texto SQL (sem senhas e sem valores de parâmetros, mas literais dentro do SQL aparecem).
Use um banco de teste ou revise o log antes de compartilhar.

## O que devolver

Os dois arquivos de log. As linhas mais importantes:

- `summary <função> <n>`: lista final das funções chamadas. Vira `docs/api-surface.md`.
- `fb_get_master_interface`: se aparecer na variante normal, verifique se a variante `proxy-no-oo` funciona igual.
  Se funcionar, o driver só testa a API OO e usa a API legada. Se falhar, o design precisa ser revisto.
- `-> isc_dsql_prepare ... described out=[...]` comparado com `first_fetch out=[...]`: mostra se o driver
  muda tipos/tamanhos do XSQLDA entre o describe e o fetch (decide a decisão D8 do design).
- `note: real library does not export ...`: normal para funções antigas.
- Itens de `isc_database_info`, `isc_dsql_sql_info`, `isc_transaction_info`, `isc_blob_info` (`items=`).
- Sequência desde `isc_attach_database` até a primeira linha: mostra quantas idas e voltas a conexão vai custar.

Se a aplicação der erro de "procedure entry point not found" ou parecido com o proxy, anote o nome da função:
ela precisa entrar em `exports.txt`. Para comparar com a lista completa do cliente real:
`tdump -ee fbclient.dll` (ou `dumpbin /exports fbclient.dll`).
