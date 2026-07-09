# Dimensões: IBGE e CID-10

## Códigos de município (6 ↔ 7 dígitos)

SIM e SINASC gravam municípios com **6 dígitos**; o IBGE moderno (e a
maioria dos shapefiles/DTB) usa **7** — o sétimo é um dígito
verificador. A conversão ingênua (`cod6 * 10`) é a pegadinha clássica
de join de microdados.

```julia
dv_ibge(261110)        # 1
codigo7_ibge(261110)   # 2611101  (Petrolina)
codigo7_ibge("355030") # 3550308  (São Paulo — aceita string do DBF)
codigo6_ibge(2611101)  # 261110, validando o DV
codigo6_ibge(2611100)  # ArgumentError (DV errado)
codigo6_ibge(2611100; validar = false)   # 261110, sem validar
```

O algoritmo é o módulo 10 do IBGE: pesos alternados 1,2 da esquerda
para a direita, produtos ≥ 10 reduzidos (−9), DV = (10 − soma mod 10)
mod 10.

Join típico com a DTB do IBGE (que traz nomes, UF, região):

```julia
using DataFrames
df.cod7 = codigo7_ibge.(String.(df.CODMUNRES))
leftjoin!(df, dtb; on = :cod7 => :codigo_municipio)
```

!!! warning "Códigos vazios ou ignorados"
    Campos de município podem vir vazios ou como códigos-fantasma
    (`"000000"`, UF + `"9999"` para município ignorado). Filtre antes
    de converter: `filter(c -> length(c) == 6 && c[3:6] != "9999", ...)`.

## Capítulos da CID-10

```julia
capitulo_cid10("X954")
# (numeral = "XX", nome = "Causas externas de morbidade e mortalidade")

capitulo_cid10("I219").numeral   # "IX"
capitulo_cid10("")               # nothing (código inválido)
```

Cobre os 22 capítulos, com os limites não-óbvios corretos (C00–D48 é
um capítulo, D50–D89 é outro; S00–T98 é natureza da lesão, V01–Y98 é
causa externa).

## Agressões e o recorte CVLI

```julia
eh_agressao("X954")   # true  — X85–Y09 (agressões)
eh_agressao("Y871")   # true  — sequelas de agressões
eh_agressao("Y10")    # false — intenção indeterminada
eh_agressao(missing)  # false
```

É o recorte usual de CVLI a partir do SIM (causa básica). Dois avisos
metodológicos:

- **Y10–Y34 (intenção indeterminada)** fica fora por definição, mas em
  séries municipais a migração de registros entre X85–Y09 e Y10–Y34
  pode criar degraus artificiais — vale inspecionar as duas séries.
- CVLI *stricto sensu* (conceito de segurança pública) inclui latrocínio
  e lesão corporal seguida de morte, que a CID não separa de outras
  agressões; o recorte pelo SIM é uma aproximação epidemiológica.

Uso no leitor:

```julia
t = ler(caminho; colunas = [:DTOBITO, :CODMUNRES, :IDADE, :SEXO],
        filtro = r -> eh_agressao(r[:CAUSABAS]))
```

Note que `CAUSABAS` não precisa estar em `colunas` para ser usado no
filtro — o [`MicroSUS.RegistroDBF`](@ref) decodifica qualquer campo do
layout sob demanda.
