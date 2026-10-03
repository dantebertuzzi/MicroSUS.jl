# fetch.jl — Interface principal do pacote.

# o mesmo limite do `baixar` no plural: o FTP do DATASUS não gosta de
# muitas conexões simultâneas
const _DOWNLOADS_SIMULTANEOS = 4

"""
    fetch_datasus(fonte::Symbol; uf = :all, anos, meses = nothing,
                  colunas = nothing, filtro = nothing,
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
- `colunas`: `Vector{Symbol}` com os campos desejados, como em [`ler`](@ref)
  — os demais nem são lidos. Campos que não existem no layout de algum ano
  vêm `missing` nas linhas dele;
- `filtro`: função `RegistroDBF -> Bool` aplicada a cada registro **antes**
  do parse, como em [`ler`](@ref). Vê os códigos crus do arquivo
  (`r[:SEXO] == "2"`), não os rótulos da padronização;
- `processar`: aplica a padronização da fonte quando disponível
  ([`process_sim`](@ref), [`process_sinasc`](@ref));
- `cache`: reutiliza arquivos já baixados (ver [`MicroSUS.limpar_cache`](@ref));
- `verbose`: registra progresso via `@info`/`@warn`.

Os arquivos são lidos em streaming, um depois do outro
(ver `ler(caminhos::AbstractVector)`), e a padronização roda no próprio
resultado, sem cópia: o pico de memória fica perto do tamanho do
`DataFrame` devolvido. Com `colunas` e `filtro`, só o que foi pedido chega
a existir. Até 4 arquivos são baixados ao mesmo tempo, e com mais de uma
thread (`julia -t auto`) vários são lidos em paralelo; a ordem das linhas
não muda.

Arquivos ausentes no FTP (ano ainda não publicado para uma UF, mês sem
partição extra) geram um `@warn` e são pulados; o resultado concatena tudo
que foi encontrado, unindo colunas por nome. As colunas
`UF_ARQUIVO`, `ANO_ARQUIVO` e, se aplicável, `MES_ARQUIVO` identificam a
origem de cada linha, e `PRELIMINAR` diz se ela veio de um arquivo ainda não
consolidado pelo DATASUS (pasta `PRELIM/`, ver [`eh_preliminar`](@ref)) —
quando houver algum, um `@warn` lista quais.

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

# Só o que interessa: óbitos por agressão em PE, três colunas, dez anos
cvli = fetch_datasus(:SIM_DO; uf = "PE", anos = 2014:2023,
                     colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES],
                     filtro = r -> eh_agressao(r[:CAUSABAS]))
```
"""
function fetch_datasus(fonte_id::Symbol;
                       uf = :all,
                       anos,
                       meses = nothing,
                       colunas::Union{Nothing,Vector{Symbol}} = nothing,
                       filtro::Union{Nothing,Function} = nothing,
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

    arquivos = String[]
    metadados = Dict{String,NamedTuple}()
    faltantes = String[]
    preliminares = String[]

    # downloads em paralelo (como o `baixar` no plural), resultados na ordem
    # dos períodos; a leitura e os avisos seguem essa ordem
    periodos = [(u, a, m) for u in ufs for a in anos_ for m in meses_]
    baixados = try
        asyncmap(periodos; ntasks = _DOWNLOADS_SIMULTANEOS) do (u, a, m)
            _baixar_periodo(f, u, a, m; cache, verbose)
        end
    catch e
        throw(_desembrulha(e))   # ErroDeRede chega a quem chamou como ErroDeRede
    end

    for ((u, a, m), achados) in zip(periodos, baixados)
        if isempty(achados)
            rotulo = f.periodicidade == :mensal ? "$u $a-$(mm(m))" : "$u $a"
            push!(faltantes, rotulo)
            continue
        end
        for caminho in achados
            prelim = eh_preliminar(caminho)
            push!(arquivos, caminho)
            metadados[caminho] = f.periodicidade == :mensal ?
                (UF_ARQUIVO = u, ANO_ARQUIVO = a, MES_ARQUIVO = m, PRELIMINAR = prelim) :
                (UF_ARQUIVO = u, ANO_ARQUIVO = a, PRELIMINAR = prelim)
            prelim && push!(preliminares,
                "$(basename(caminho)) (baixado em $(_baixado_em(caminho)))")
        end
    end

    isempty(faltantes) || @warn "arquivos não encontrados no FTP" faltantes
    isempty(preliminares) ||
        @warn "o resultado inclui dados PRELIMINARES, sujeitos a revisão " *
              "(coluna PRELIMINAR; `cache = false` rebaixa)" preliminares

    isempty(arquivos) && error(
        "nenhum arquivo encontrado para :$(f.id) com os parâmetros informados")

    # layouts mudam entre anos: com colunas pedidas, a que falta num ano
    # vem missing nele (ignorar_ausentes + uniao)
    t = ler(arquivos; uniao = true, origem = c -> metadados[c],
            colunas, filtro, ignorar_ausentes = colunas !== nothing)
    df = DataFrame(materializar(t); copycols = false)

    if processar
        df = processar_fonte(f.id, df; verbose, copiar = false)
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
        candidatas = [_inserir_sufixo(u, sufixo) for u in f.urls(uf, ano, mes)]
        for (i, url_suf) in enumerate(candidatas)
            caminho = try
                baixar_url(url_suf; cache, verbose)
            catch e
                e isa ErroDeRede || rethrow()
                # sem rede: uma candidata seguinte já no cache (tipicamente
                # o preliminar) serve, com aviso; nada no cache é erro
                c = _no_cache(candidatas[i+1:end], cache)
                c === nothing && rethrow()
                @warn "sem acesso à rede; usando o arquivo do cache" *
                      (eh_preliminar(c) ? " (dados PRELIMINARES)" : "") arquivo = c baixado_em = _baixado_em(c) e.url
                c
            end
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

# asyncmap embrulha o erro da tarefa (CapturedException; TaskFailedException
# em outras versões do Julia)
function _desembrulha(e)
    while true
        if e isa CapturedException
            e = e.ex
        elseif e isa TaskFailedException
            e = e.task.result
        else
            return e
        end
    end
end

function _no_cache(urls, cache::Bool)
    cache || return nothing
    for u in urls
        c = _destino_cache(u)
        _cache_valido(c) && return c
    end
    return nothing
end

_inserir_sufixo(url, sufixo) =
    isempty(sufixo) ? url : replace(url, r"\.dbc$" => "$(sufixo).dbc")
