```@meta
CurrentModule = MicroSUS
```

# Referência da API

Todos os nomes exportados, organizados por categoria.

```@docs
MicroSUS.MicroSUS
```

## Leitura

```@docs
ler
TabelaDBC
materializar
```

## Conversão

```@docs
converter
descomprime_dbc_para_dbf
```

## Download

```@docs
baixar
url_arquivo
baixar_sinan
url_sinan
MicroSUS.limpar_cache
MicroSUS.UFS
```

## Fetch (interface de alto nível)

```@docs
fetch_datasus
fontes
fonte
process_sim
process_sinasc
```

## Decodificação de schemas

```@docs
decodifica_idade_sim
decodifica_idade_sinan
MicroSUS.SCHEMAS
MicroSUS.detecta_sistema
```

## Dimensões

```@docs
dv_ibge
codigo7_ibge
codigo6_ibge
capitulo_cid10
eh_agressao
```

## Estruturas DBF

```@docs
CabecalhoDBF
CampoDBF
MicroSUS.cabecalho
```

## Baixo nível

```@docs
dcl_descomprime
```