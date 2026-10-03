# Tabelas em Markdown a partir de benchmark/resultados.jsonl.
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1] if len(sys.argv) > 1 else "benchmark/resultados.jsonl")]
def curto(f):
    return ("MicroSUS (1 thread)" if "1 thread)" in f else "MicroSUS (16 threads)" if "threads" in f else
            "microdatasus (R)" if "microdatasus" in f else "pilha do PySUS (Python)" if "pyreaddbc" in f else f)
ordem = ["MicroSUS (1 thread)", "MicroSUS (16 threads)", "microdatasus (R)", "pilha do PySUS (Python)"]
nomes = {"python": "pilha do PySUS (Python)", "r": "microdatasus (R)"}
ARQ = {"DOPE2023.dbc": "DOPE2023 (SIM, 68 mil × 87)", "DOSP2023.dbc": "DOSP2023 (SIM, 334 mil × 87)",
       "DNSP2023.dbc": "DNSP2023 (SINASC, 504 mil × 61)", "DENGBR23.dbc": "DENGBR23 (SINAN, 1,65 milhão × 121)"}
fmt = lambda x: f"{x:.2f}".replace(".", ",")
for tarefa, titulo in (("tudo", "Ler o arquivo inteiro"), ("cvli", "Óbitos por agressão: 3 colunas, filtrados"),
                       ("padronizar", "Ler e padronizar (`process_sim`)")):
    print(f"\n### {titulo}\n")
    print("| arquivo | ferramenta | 1ª execução (s) | seguintes (s) | memória (MB) |")
    print("|---|---|--:|--:|--:|")
    for arq in ARQ:
        sel = [r for r in rows if r["arquivo"] == arq and r["tarefa"] == tarefa]
        sel.sort(key=lambda r: ordem.index(curto(r["ferramenta"])) if curto(r["ferramenta"]) in ordem
                 else ordem.index(nomes.get(r["ferramenta"], r["ferramenta"])) if nomes.get(r["ferramenta"]) in ordem else 9)
        for r in sel:
            nome = nomes.get(r["ferramenta"], curto(r["ferramenta"]))
            if r.get("falhou"):
                print(f"| {ARQ[arq]} | {nome} | — | — | não coube em 9 GB |")
            else:
                print(f"| {ARQ[arq]} | {nome} | {fmt(r['t_frio'])} | {fmt(r['t_quente'])} | "
                      f"{round(r['rss_pico_mb'] - r['rss_base_mb'])} |")
