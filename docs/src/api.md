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
TabelaConcatenada
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
eh_preliminar
MicroSUS.limpar_cache
MicroSUS.ErroDeRede
verificar_cache
proveniencia
exportar_espelho
travar_dados
restaurar_dados
soltar_dados
MicroSUS.baixar_url
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
process_cnes
```

## Qualidade dos dados

```@docs
auditar
MicroSUS.Auditoria
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
cid10
descricao_cid
normaliza_cid
cid_casa
cids_em
menciona_cid
eh_agressao
populacao
populacao_por_idade
faixa_etaria
taxa_padronizada
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