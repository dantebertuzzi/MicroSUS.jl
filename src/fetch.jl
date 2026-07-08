# fetch.jl — Interface principal do pacote.

"""
    fetch_datasus(fonte::Symbol; uf = :all, anos, meses = nothing,
                  processar = true, cache = true, verbose = true) -> DataFrame

Baixa, descomprime, lê e concatena microdados públicos do DATASUS.

# Argumentos
- `fonte`: identificador da fonte — ver [`fontes`](@ref). Ex.: `:SIM_DO`,
  `:SINASC`, `:SIH_RD`, `:SIA_PA`, `:CNES_ST`, `:SINAN_DENGUE`;
- `uf`: sigla (`"PE"`), vetor de siglas (`["PE", "BA"]`) ou `:all` para as
  27 unidades federativas. Ignorado em fontes de abrangência nacional
  (SINAN);
- `anos`: ano (`2023`) ou coleção de anos (`2019:2023`);
- `meses`: mês ou coleção de meses (`1:12`), obrigatório apenas para fontes
  mensais (SIH, SIA, CNES);
- `processar`: aplica a padronização da fonte quando disponível
  ([`process_sim`](@ref), [`process_sinasc`](@ref));
- `cache`: reutiliza arquivos já baixados (ver [`cache_dir`](@ref));
- `verbose`: registra progresso via `@info`/`@warn`.

Arquivos ausentes no FTP (ano ainda não publicado para uma UF, mês sem
partição extra) geram um `@warn` e são pulados; o resultado concatena tudo
que foi encontrado, unindo colunas por nome (`cols = :union`). As colunas
`UF_ARQUIVO`, `ANO_ARQUIVO` e, se aplicável, `MES_ARQUIVO` identificam a
origem de cada linha.

# Exemplos
```julia
# Óbitos de Pernambuco, 2019–2023, já padronizados
do_pe = fetch_datasus(:SIM_DO; uf = "PE", anos = 2019:2023)

# Nascidos vivos, PE e BA, sem padronização (códigos brutos)
dn = fetch_datasus(:SINASC; uf = ["PE", "BA"], anos = 2022, processar = false)

# Internações hospitalares de PE no primeiro semestre de 2024
rd = fetch_datasus(:SIH_RD; uf = "PE", anos = 2024, meses = 1:6)

# Dengue no Brasil inteiro (fonte nacional: uf é ignorada)
dengue = fetch_datasus(:SINAN_DENGUE; anos = 2024)
```
"""
function fetch_datasus(fonte_id::Symbol;
                       uf = :all,
                       anos,
                       meses = nothing,
                       processar::Bool = true,
                       cache::Bool = true,
                       verbose::Bool = true)
    f = fonte(fonte_id)

    ufs   = _normalizar_ufs(f, uf)
    anos_ = _normalizar_periodo(anos, "anos")
    meses_ = if f.periodicidade == :mensal
        meses === nothing && throw(ArgumentError(
            "a fonte :$(f.id) é mensal: informe `meses` (ex.: meses = 1:12)"))
        _normalizar_periodo(meses, "meses")
    else
        [0]   # marcador de fonte anual
    end

    for a in anos_
        a in f.anos || @warn "ano $a fora da faixa de cobertura conhecida de :$(f.id) ($(first(f.anos))+)"
    end

    partes = DataFrame[]
    faltantes = String[]

    for u in ufs, a in anos_, m in meses_
        arquivos = _baixar_periodo(f, u, a, m; cache, verbose)
        if isempty(arquivos)
            rotulo = f.periodicidade == :mensal ? "$u $a-$(mm(m))" : "$u $a"
            push!(faltantes, rotulo)
            continue
        end
        for caminho in arquivos
            df = read_dbc(caminho)
            df[!, :UF_ARQUIVO]  .= u
            df[!, :ANO_ARQUIVO] .= a
            f.periodicidade == :mensal && (df[!, :MES_ARQUIVO] .= m)
            push!(partes, df)
        end
    end

    isempty(faltantes) || @warn "arquivos não encontrados no FTP" faltantes

    isempty(partes) && throw(DBCError(
        "nenhum arquivo encontrado para :$(f.id) com os parâmetros informados"))

    df = vcat(partes...; cols = :union)

    if processar
        df = processar_fonte(f.id, df; verbose)
    end

    return df
end

function _normalizar_ufs(f::FonteDATASUS, uf)
    f.abrangencia == :br && return ["BR"]
    return (uf === :all || uf == "all") ? UFS : _validar_ufs(uf)
end

_validar_ufs(uf::AbstractString) = _validar_ufs([uf])
_validar_ufs(uf::Symbol) = _validar_ufs([string(uf)])
function _validar_ufs(ufs::AbstractVector)
    out = uppercase.(string.(ufs))
    for u in out
        u in UFS || throw(ArgumentError("UF inválida: $u"))
    end
    return out
end

_normalizar_periodo(x::Integer, _) = [Int(x)]
function _normalizar_periodo(x, nome)
    v = collect(Int, x)
    isempty(v) && throw(ArgumentError("`$nome` não pode ser vazio"))
    return v
end

"""
Baixa todos os arquivos de um período (UF, ano, mês), incluindo partições
por sufixo (caso do SIA-PA). Para cada sufixo, tenta as URLs candidatas em
ordem; sufixos vazios ("") que falham em todas as URLs encerram o período.
"""
function _baixar_periodo(f::FonteDATASUS, uf, ano, mes; cache, verbose)
    encontrados = String[]
    for sufixo in f.sufixos
        achou = false
        for url in f.urls(uf, ano, mes)
            url_suf = _inserir_sufixo(url, sufixo)
            caminho = baixar_url(url_suf; cache, verbose)
            if caminho !== nothing
                push!(encontrados, caminho)
                achou = true
                break
            end
        end
        # Partições são contíguas: se "b" não existe, "c" também não.
        achou || break
    end
    return encontrados
end

_inserir_sufixo(url, sufixo) =
    isempty(sufixo) ? url : replace(url, r"\.dbc$" => "$(sufixo).dbc")
