import concurrent.futures, hashlib, json, os, re, subprocess, tempfile, time, urllib.request
from pathlib import Path
from audit_analyzer import analisar
ENDPOINT="https://itobvfemswylcawdydrz.supabase.co/functions/v1/trt16-audit"
def call(body):
    req=urllib.request.Request(os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]+"&audience=trt16-audit",headers={"Authorization":"Bearer "+os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
    with urllib.request.urlopen(req,timeout=30) as r:
        token=json.load(r)["value"]
    req=urllib.request.Request(ENDPOINT,data=json.dumps(body).encode(),headers={"Authorization":"Bearer "+token,"Content-Type":"application/json"})
    with urllib.request.urlopen(req,timeout=60) as r:return json.load(r)
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
    limit=time.monotonic()+600;counts={}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for _ in range(125):
            if time.monotonic()>limit:break
            jobs=[]
            for n in range(4):
                job=call({"action":"claim"})
                if not job:break
                jobs.append(job)
            if not jobs:break
            for estado in pool.map(processar,jobs):counts[estado]=counts.get(estado,0)+1
    print(json.dumps(counts,ensure_ascii=False))
if __name__=="__main__":main()
