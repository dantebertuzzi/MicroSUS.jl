```@meta
CurrentModule = MicroSUS
```

# API Reference

All exported names, organized by category.

```@docs
MicroSUS.MicroSUS
```

## Reading

```@docs
ler
TabelaDBC
materializar
```

## Conversion

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

## Schema decoding

```@docs
decodifica_idade_sim
decodifica_idade_sinan
MicroSUS.SCHEMAS
MicroSUS.detecta_sistema
```

## Dimensions

```@docs
dv_ibge
codigo7_ibge
codigo6_ibge
capitulo_cid10
eh_agressao
```

## DBF structures

```@docs
CabecalhoDBF
CampoDBF
MicroSUS.cabecalho
```

## Low-level

```@docs
dcl_descomprime
```