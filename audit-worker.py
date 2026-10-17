import concurrent.futures, hashlib, json, os, re, subprocess, tempfile, time, urllib.request
import socket
import urllib.error
from pathlib import Path
from audit_analyzer import analisar
ENDPOINT="https://itobvfemswylcawdydrz.supabase.co/functions/v1/trt16-audit"
MAX_ATTEMPTS = 3
TRANSIENT = {408, 429, 500, 502, 503, 504}

def error_info(exc):
    # Não registrar tokens, leases, URLs assinadas ou corpos de resposta.
    info = {"erro": type(exc).__name__}
    if isinstance(exc, urllib.error.HTTPError):
        info["http_status"] = exc.code
    return info

def request_json(req, timeout):
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)

def get_token():
    req=urllib.request.Request(os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]+"&audience=trt16-audit",headers={"Authorization":"Bearer "+os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
    return request_json(req, 30)["value"]

def call(body):
    for attempt in range(MAX_ATTEMPTS):
        stage = "autenticacao"
        try:
            # Obter credencial nova em cada tentativa, inclusive após HTTP 401.
            token = get_token()
            stage = body["action"]
            req = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            return request_json(req, 60)
        except (urllib.error.URLError, TimeoutError, socket.timeout, ConnectionError) as exc:
            status = exc.code if isinstance(exc, urllib.error.HTTPError) else None
            retryable = status in TRANSIENT or status == 401 or status is None
            # claim modifica a fila: resposta perdida pode já ter reservado um item.
            # Não repetir claim após erro ambíguo; a reserva expira no servidor.
            if stage == "claim" and status != 401:
                retryable = False
            if not retryable or attempt + 1 == MAX_ATTEMPTS:
                raise
            print(json.dumps({"evento": "nova_tentativa", "etapa": stage, "tentativa": attempt + 1, **error_info(exc)}), flush=True)
            time.sleep(2 ** attempt)
def processar(job):
    texto=job.get("texto") or ""
    metodo="texto_previamente_extraido"
    result=analisar(texto,job["cadastro"],job["categoria"],metodo)
    if job["categoria"]=="original" and (not texto or result["estado"]=="inconclusivo"):
        try:
            if not re.fullmatch(r"https://bibliotecadigital\.trt16\.jus\.br/server/api/core/bitstreams/[0-9a-f-]{36}/content",job["url"],re.I):
                raise ValueError("URL não oficial")
            with tempfile.TemporaryDirectory() as directory:
                d=Path(directory);pdf=d/"original.pdf"
                with urllib.request.urlopen(job["url"],timeout=45) as r,pdf.open("wb") as out:
                    size=0
                    while chunk:=r.read(1048576):
                        size+=len(chunk)
                        if size>100*1024*1024:raise ValueError("PDF excede 100 MB")
                        out.write(chunk)
                digest=hashlib.sha256(pdf.read_bytes()).hexdigest()
                subprocess.run(["pdftotext","-f","1","-l","1","-layout",str(pdf),str(d/"texto.txt")],check=True,timeout=45,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                texto=(d/"texto.txt").read_text(encoding="utf-8",errors="replace")
                result=analisar(texto,job["cadastro"],job["categoria"],"texto_primeira_pagina",digest)
                if result["estado"]=="inconclusivo" and job["categoria"]=="original":
                    subprocess.run(["pdftoppm","-f","1","-l","1","-singlefile","-r","250","-png",str(pdf),str(d/"pagina")],check=True,timeout=90,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    ocr=subprocess.run(["tesseract",str(d/"pagina.png"),"stdout","-l","por+eng","--psm","3"],check=True,timeout=90,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
                    result=analisar(ocr.stdout.decode("utf-8"),job["cadastro"],job["categoria"],"ocr_primeira_pagina",digest)
        except Exception as exc:
            result={"estado":"inconclusivo","documento":None,"evidencia":texto[:1800],"metodo":"falha_leitura","hash_evidencia":None,"motivo":type(exc).__name__+": "+str(exc)[:180]}
    saved=call({"action":"save","id":job["id"],"lease":job["lease"],"result":result})
    if not saved.get("saved"):raise RuntimeError("Resultado não gravado")
    return result["estado"]
def main():
    limit=time.monotonic()+600;counts={};pending=[];claim_error=None;in_flight=set()
    report = Path("audit-report")
    report.mkdir(exist_ok=True)

    def checkpoint():
        summary = {"resultados_gravados": counts, "itens_sem_confirmacao": pending, "ids_em_processamento": sorted(in_flight), "falha_reserva": claim_error}
        temporary = report / "summary.tmp"
        temporary.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        temporary.replace(report / "summary.json")

    checkpoint()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for _ in range(125):
            if time.monotonic()>limit:break
            jobs=[]
            for n in range(4):
                try:
                    job=call({"action":"claim"})
                except Exception as exc:
                    claim_error = error_info(exc)
                    checkpoint()
                    break
                if not job:break
                jobs.append(job)
                in_flight.add(job["id"])
                checkpoint()
            if not jobs:break
            futures = {pool.submit(processar, job): job for job in jobs}
            for future in concurrent.futures.as_completed(futures):
                job = futures[future]
                try:
                    estado = future.result()
                    counts[estado] = counts.get(estado, 0) + 1
                except Exception as exc:
                    pending.append({"id": job["id"], "situacao": "sem_confirmacao_de_gravacao", **error_info(exc)})
                in_flight.discard(job["id"])
                checkpoint()
            # Evitar consumir outras reservas durante uma indisponibilidade.
            if pending or claim_error:break
    print(json.dumps(counts,ensure_ascii=False))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as out:
            out.write("## Auditoria dos PDFs\n\nResultados com gravação confirmada: " + str(sum(counts.values())) + ".\n\n")
            out.write("Itens sem confirmação de gravação: " + str(len(pending)) + ".\n\n")
            out.write("Falha ao reservar item: " + ("sim" if claim_error else "não") + ". Consulte o artefato audit-report.\n")
    return 1 if pending or claim_error else 0
if __name__=="__main__":raise SystemExit(main())

