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
agravos_sinan
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
process_sih
process_sinan
```

## Decodificação de schemas

```@docs
decodifica_idade_sim
decodifica_idade_sinan
idade_sih
MicroSUS.SCHEMAS
MicroSUS.detecta_sistema
```

## Dimensões

```@docs
dv_ibge
codigo7_ibge
codigo6_ibge
uf_de
regiao
municipio
municipios
capitulo_cid10
normaliza_cid
cid_casa
cids_em
menciona_cid
eh_agressao
```

## Estruturas DBF

```@docs
CabecalhoDBF
CampoDBF
cabecalho
```

## Baixo nível

```@docs
dcl_descomprime
```